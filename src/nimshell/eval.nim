## Evaluate pipelines against the environment.

import std/[strutils, tables, os, algorithm]
import alias, builtins, config, env, parser, sys, value

type
  EvalResultKind* = enum
    erContinue, erQuit

  EvalResult* = object
    case kind*: EvalResultKind
    of erContinue:
      env*: Env
      value*: Value
    of erQuit:
      code*: int

proc cont(env: Env, v: Value): EvalResult =
  EvalResult(kind: erContinue, env: env, value: v)

proc evalExpr(env: Env, e: Expr): (bool, Value, string) =
  case e.kind
  of exLit:
    # Unquoted `~` / `~/x` means home, like POSIX shells; `"~"` stays literal.
    if e.bare and e.lit.kind == vkString: (true, strV(expandHome(e.lit.s)), "")
    else: (true, e.lit, "")
  of exVar:
    let v = getVar(env, e.name)
    if e.suffix == "": (true, v, "")
    elif v.kind == vkString: (true, strV(v.s & e.suffix), "")
    elif v.kind == vkNothing: (false, nothing(), "$" & e.name & " is not set")
    else: (false, nothing(), "$" & e.name & " is not a string; can't append `" &
                             e.suffix & "`")
  of exList:
    var vals: seq[Value]
    for it in e.items:
      let (ok, v, msg) = evalExpr(env, it)
      if not ok: return (false, nothing(), msg)
      vals.add v
    (true, listV(vals), "")
  of exRecord:
    var pairs: seq[(string, Value)]
    for (k, it) in e.fields:
      let (ok, v, msg) = evalExpr(env, it)
      if not ok: return (false, nothing(), msg)
      pairs.add((k, v))
    (true, recordV(pairs), "")

proc evalArgs(env: Env, args: seq[Arg], pos: var seq[Value], flags: var Flags): string =
  for a in args:
    case a.kind
    of argValue:
      let (ok, v, msg) = evalExpr(env, a.expr)
      if not ok: return msg
      pos.add v
    of argFlag:
      if a.hasValue:
        let (ok, v, msg) = evalExpr(env, a.flagValue)
        if not ok: return msg
        flags[a.flagName] = v
      else:
        flags[a.flagName] = boolV(true)
  ""

proc formatFlagName(name: string, short: bool): string =
  ## Rebuild the flag as typed: `-fr` stays `-fr`, `--force` stays `--force`.
  if name.startsWith("-"): name
  elif short: "-" & name
  else: "--" & name

proc expandGlob(pattern: string): seq[string] =
  ## Bare `*`/`?` words expand to sorted matches; no match keeps the word.
  if not (pattern.contains('*') or pattern.contains('?')): return @[pattern]
  for f in walkPattern(pattern): result.add f
  result.sort()
  if result.len == 0: result = @[pattern]

proc evalArgv(env: Env, args: seq[Arg], argv: var seq[string]): string =
  ## Flatten command args to an argv for external programs, preserving order.
  for a in args:
    case a.kind
    of argValue:
      let (ok, v, msg) = evalExpr(env, a.expr)
      if not ok: return msg
      if a.expr.kind == exLit and a.expr.bare and v.kind == vkString:
        argv.add expandGlob(v.s)
      else:
        argv.add asString(v)
    of argFlag:
      argv.add formatFlagName(a.flagName, a.flagShort)
      if a.hasValue:
        let (ok, v, msg) = evalExpr(env, a.flagValue)
        if not ok: return msg
        argv.add asString(v)
  ""

proc commandBasename(name: string): string =
  let parts = name.split("/")
  if parts.len == 0: name else: parts[^1]

proc capturesForPager(name: string): bool =
  ## Tools that open system `less`/`more` by default. Capture with nested
  ## pagers forced to cat; the interactive REPL shows long output in the
  ## builtin pager.
  commandBasename(name) in ["systemctl", "journalctl", "man", "info", "git"]

proc stdinBytes(input: Value): string =
  ## Bytes fed to an external's stdin from the previous pipeline stage.
  case input.kind
  of vkNothing: ""
  of vkString: input.s
  else: asString(input)

proc runExternal(env: Env, name: string, argv: seq[string], input: Value,
                 interactive: bool): EvalResult =
  # Pipeline input becomes the external's stdin (Unix-style `cmd | less`).
  let stdinData = stdinBytes(input)
  # Live TTY by default so long-lived processes stream output. Only tools
  # that open system `less` by default are captured.
  let (ok, status, output) =
    if interactive and not capturesForPager(name): runCmdTty(name, argv, stdinData)
    else: runCmd(name, argv, stdinData)
  if not ok: return cont(setExit(env, 127), failV(output))
  let outText = output.strip(leading = false)
  let env2 = setExit(env, status)
  if status == 0: cont(env2, strV(outText))
  elif outText == "": cont(env2, failV(name & " exited with status " & $status))
  else: cont(env2, strV(outText))

proc evalCommand(env: Env, cmd: Command, input: Value, interactive: bool): EvalResult =
  let env = setInput(env, input)
  # Bare value stage produced by the parser for `$env`, `$x`, literals, …
  if cmd.name == "__value__" and not cmd.external and cmd.args.len == 1 and
      cmd.args[0].kind == argValue:
    clearOutputShown()
    let (ok, v, msg) = evalExpr(env, cmd.args[0].expr)
    return if ok: cont(setExit(env, 0), v) else: cont(setExit(env, 1), failV(msg))
  var b: Builtin
  if cmd.external or not lookup(cmd.name, b):
    # Externals keep argv order exactly as written (`jj log -n 1`).
    var argv: seq[string]
    let msg = evalArgv(env, cmd.args, argv)
    if msg != "": return cont(setExit(env, 1), failV(msg))
    let name = if cmd.bareName: expandHome(cmd.name) else: cmd.name
    return runExternal(env, name, argv, input, interactive)
  var pos: seq[Value]
  var flags: Flags
  let msg = evalArgs(env, cmd.args, pos, flags)
  if msg != "": return cont(setExit(env, 1), failV(msg))
  # Builtins produce a new value that was not streamed to the TTY.
  clearOutputShown()
  let r = b(env, input, pos, flags)
  case r.kind
  of brExit: EvalResult(kind: erQuit, code: r.code)
  of brValue: cont(setExit(r.env, if r.value.kind == vkFail: 1 else: 0), r.value)

proc evalPipeline(env: Env, pipeline: Pipeline, input: Value, allowTty: bool): EvalResult =
  ## `allowTty` — when true, the last stage runs on a live TTY unless it is a
  ## known nested-pager tool. Otherwise output is captured.
  result = cont(env, input)
  let pipeline = expandAliases(pipeline)
  for i, cmd in pipeline.commands:
    if result.kind == erQuit or result.value.kind == vkFail: return
    let isLast = i + 1 == pipeline.commands.len
    result = evalCommand(result.env, cmd, result.value, allowTty and isLast)

proc evalStatement(env: Env, stmt: Statement): EvalResult =
  case stmt.kind
  of stLet:
    # Assignments always capture external output into a value.
    let r = evalPipeline(env, stmt.pipeline, nothing(), false)
    if r.kind == erQuit or r.value.kind == vkFail: return r
    cont(setVar(r.env, stmt.name, r.value), r.value)
  of stEnvAssign:
    let r = evalPipeline(env, stmt.pipeline, nothing(), false)
    if r.kind == erQuit or r.value.kind == vkFail: return r
    let (ok, env3, msg) = setOsEnv(r.env, stmt.name, r.value)
    # Echo what was stored (`~` expanded, `PATH` re-split into a list).
    if ok: cont(setExit(env3, 0), getVar(env3, "env." & stmt.name))
    else: cont(setExit(r.env, 1), failV(msg))
  of stExport:
    # `export NAME = …`: like `$env.NAME = …`, then saved to config.ns
    # (not while the config itself runs). Bare `export NAME` saves the
    # variable's current value.
    let save = not stmt.noSave and not loadingConfig
    if stmt.name == "PATH" and save:
      return cont(setExit(env, 1), failV("export: save PATH entries with `add-path`, " &
                                         "or use `export --no-save PATH = …`"))
    var env2 = env
    if stmt.pipeline.commands.len > 0:
      let r = evalPipeline(env, stmt.pipeline, nothing(), false)
      if r.kind == erQuit or r.value.kind == vkFail: return r
      let (ok, env3, msg) = setOsEnv(r.env, stmt.name, r.value)
      if not ok: return cont(setExit(r.env, 1), failV("export: " & msg))
      env2 = env3
    let value = getVar(env2, "env." & stmt.name)
    if value.kind == vkNothing:
      return cont(setExit(env2, 1), failV("export: " & stmt.name & " is not set"))
    if save:
      let msg = saveConfigEnv(stmt.name, envToString(stmt.name, value))
      if msg != "": return cont(setExit(env2, 1), failV("export: " & msg))
    cont(setExit(env2, 0), value)
  of stExpr:
    # Bare expression: last stage gets a live TTY by default.
    evalPipeline(env, stmt.pipeline, nothing(), true)

proc evalSource*(env: Env, source: string): EvalResult =
  # Fresh statement — do not inherit a prior external's TTY-shown flag.
  clearOutputShown()
  let src = source.strip
  if src == "": return cont(env, nothing())
  var stmt: Statement
  var msg: string
  if not parse(src, stmt, msg): return cont(setExit(env, 1), failV(msg))
  evalStatement(env, stmt)

proc runConfig(src: string): seq[string] =
  ## Evaluate config.ns statement by statement; failures become warnings
  ## and the rest of the file still runs.
  var env = newEnv()
  for s in splitStatements(src):
    let r = evalSource(env, s.text)
    case r.kind
    of erQuit: result.add("line " & $s.line & ": `exit` is ignored in the config")
    of erContinue:
      if r.value.kind == vkFail: result.add("line " & $s.line & ": " & r.value.msg)
      env = r.env

configRunner = runConfig

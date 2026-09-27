## nimshell — a structured-data shell in Nim, inspired by Nushell.
## A port of gleshell (https://github.com/codegod100/gleshell).

import std/[os, strutils, times]
import std/monotimes
import nimshell/[config, display, env, eval, lineedit, pager, prompt, sys, update, value]

proc printUsage() =
  println(@[
    "nimshell — Nim shell inspired by Nushell",
    "",
    "Usage:",
    "  nimshell              Interactive REPL",
    "  nimshell -c <code>    Evaluate a one-liner",
    "  nimshell <code>…      Evaluate remaining args as code",
    "  nimshell --version    Print the version",
    "  nimshell --self-update [--check]",
    "                        Update the AppImage to the latest release",
    "",
    "Examples:",
    "  nimshell -c 'ls | where type == file | first 5'",
    "  nimshell -c 'range 10 | reverse | first 3'",
    "  nimshell -c 'echo {name: \"nimshell\", cool: true}'",
    "",
    "In the REPL, type `help` for built-in commands.",
  ].join("\n"))

proc printValue(v: Value, allowPage: bool) =
  ## Print a pipeline result. When `allowPage` is true (interactive REPL) and
  ## the text does not fit on one screen, use the builtin pager. One-shot
  ## `-c` always dumps so scripts do not hang in a TUI.
  if v.kind == vkNothing: return
  # Externals that ran on the live TTY already streamed their output.
  if takeOutputShown(): return
  let text = render(v)
  if text == "": return
  if allowPage and needsPaging(text): pager.run(text)
  else: println(text)

proc applyUserConfig() =
  ## Apply `config.kdl` (PATH, env, prompt). Problems are reported, never fatal.
  for w in loadConfig(): printlnErr("nimshell: config: " & w)

# --- modes ---

proc runOnce(code: string) =
  applyUserConfig()
  let r = evalSource(newEnv(), code)
  case r.kind
  of erQuit: quit(r.code)
  of erContinue:
    printValue(r.value, false)
    if r.value.kind == vkFail: quit(1)

proc repl() =
  installSigint()
  applyUserConfig()
  loadHistory()
  println("nimshell " & NimshellVersion & " — structured data shell (type `help`, `exit` to quit; " &
          "Tab completes, grey history hints, Ctrl+R fuzzy history)")
  # AppImage: announce an update installed by a previous session's background
  # check, then maybe start today's check (detached; takes effect next launch).
  let notice = takeNotice()
  if notice != "": println("✨ " & notice)
  maybeBackgroundUpdate()
  var env = newEnv()
  var lastDurationMs = 0'i64
  pushTitle()
  while true:
    # Tab title: the directory while idle, the command line while it runs.
    setTitle(idleTitle(env.cwd))
    let (status, line) = readLine(prompt.render(env.cwd, env.lastExit, lastDurationMs))
    case status
    of rsEof:
      saveHistory()
      popTitle()
      return
    of rsInterrupted: continue
    of rsLine:
      let src = line.strip
      if src == "": continue
      pushHistory(src)
      saveHistory()
      interrupted = false
      setTitle(if src.startsWith("^"): src[1 .. ^1] else: src)
      let started = getMonoTime()
      let r = evalSource(env, src)
      lastDurationMs = (getMonoTime() - started).inMilliseconds
      case r.kind
      of erQuit:
        saveHistory()
        popTitle()
        quit(r.code)
      of erContinue:
        printValue(r.value, true)
        env = r.env

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    repl()
  elif args.len == 1 and args[0] in ["-h", "--help", "help"]:
    printUsage()
  elif args.len == 1 and args[0] in ["-V", "--version"]:
    println("nimshell " & NimshellVersion)
  elif args[0] == "--self-update":
    let quiet = "--quiet" in args
    let r = selfUpdate(checkOnly = "--check" in args)
    if not quiet:
      if r.ok: println(r.message) else: printlnErr("nimshell: " & r.message)
    quit(if r.ok: 0 else: 1)
  elif args[0] == "-c":
    if args.len < 2:
      printlnErr("nimshell: -c requires a command string")
      quit(2)
    runOnce(args[1 .. ^1].join(" "))
  else:
    runOnce(args.join(" "))

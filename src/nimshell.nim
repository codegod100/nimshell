## nimshell — a structured-data shell in Nim, inspired by Nushell.
## A port of gleshell (https://github.com/codegod100/gleshell).

import std/[os, strutils]
import nimshell/[color, display, env, eval, lineedit, pager, sys, value]

proc printUsage() =
  println(@[
    "nimshell — Nim shell inspired by Nushell",
    "",
    "Usage:",
    "  nimshell              Interactive REPL",
    "  nimshell -c <code>    Evaluate a one-liner",
    "  nimshell <code>…      Evaluate remaining args as code",
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

# --- prompt ---

proc firstLine(s: string): string =
  let i = s.find('\n')
  if i >= 0: s[0 ..< i] else: s

proc readGitdirPointer(gitFile: string): string =
  ## Worktree / linked checkout: `.git` is a file `gitdir: <path>`.
  try:
    let line = readFile(gitFile).firstLine.strip
    if not line.startsWith("gitdir:"): return ""
    let raw = line[7 .. ^1].strip
    if raw == "": return ""
    if raw.isAbsolute: raw else: gitFile.parentDir / raw
  except IOError: ""

proc findGitDir(start: string): string =
  var dir = start
  for _ in 0 ..< 32:
    let candidate = dir / ".git"
    if dirExists(candidate): return candidate
    if fileExists(candidate): return readGitdirPointer(candidate)
    let parent = dir.parentDir
    if parent == "" or parent == dir: return ""
    dir = parent
  ""

proc gitBranch(cwd: string): string =
  ## Best-effort branch name by reading `.git` (no `git` process).
  let gitDir = findGitDir(cwd)
  if gitDir == "": return ""
  try:
    let line = readFile(gitDir / "HEAD").firstLine.strip
    if line.startsWith("ref: "):
      let reference = line[5 .. ^1].strip
      if reference.startsWith("refs/heads/"): reference[11 .. ^1]
      else: reference.extractFilename
    elif line.len >= 7: line[0 ..< 7] # detached HEAD: short SHA
    else: line
  except IOError: ""

proc displayCwd(cwd: string): string =
  ## Full cwd with `$HOME` shown as `~`.
  let (ok, home) = homeDir()
  if not ok: return cwd
  if cwd == home: "~"
  elif cwd.startsWith(home & "/"): "~" & cwd[home.len .. ^1]
  else: cwd

proc promptFor(env: Env): string =
  ## Zero-config Starship-inspired prompt: blank line, directory (+ git
  ## branch), then a green/red Nerd Font terminal icon as the prompt char.
  let on = enabled()
  var status = promptPath(on, displayCwd(env.cwd))
  let branch = gitBranch(env.cwd)
  if branch != "":
    status.add separator(on, " on ") & promptGit(on, " " & branch)
  println("")
  println(status)
  # PUA glyphs often draw ~2 cells wide while the terminal advances one, so
  # use two spaces after the icon.
  let icon = if env.lastExit == 0: promptCharacterOk(on, "")
             else: promptCharacterErr(on, "")
  icon & "  "

# --- modes ---

proc runOnce(code: string) =
  let r = evalSource(newEnv(), code)
  case r.kind
  of erQuit: quit(r.code)
  of erContinue:
    printValue(r.value, false)
    if r.value.kind == vkFail: quit(1)

proc repl() =
  installSigint()
  loadHistory()
  println("nimshell 0.1 — structured data shell (type `help`, `exit` to quit; " &
          "Tab completes, grey history hints, Ctrl+R fuzzy history)")
  var env = newEnv()
  while true:
    let (status, line) = readLine(promptFor(env))
    case status
    of rsEof:
      saveHistory()
      return
    of rsInterrupted: continue
    of rsLine:
      let src = line.strip
      if src == "": continue
      pushHistory(src)
      saveHistory()
      interrupted = false
      let r = evalSource(env, src)
      case r.kind
      of erQuit:
        saveHistory()
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
  elif args[0] == "-c":
    if args.len < 2:
      printlnErr("nimshell: -c requires a command string")
      quit(2)
    runOnce(args[1 .. ^1].join(" "))
  else:
    runOnce(args.join(" "))

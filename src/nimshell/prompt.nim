## Zero-config, Starship-inspired prompt.
##
##   ~/code/nimshell on  main [!+?] ⇡1 took 3.2s ✘ 1
##   ❯
##
## Works in any terminal: plain Unicode by default. Set `NIMSHELL_NERD_FONT=1`
## for Nerd Font glyphs (branch icon, terminal prompt character).

import std/[os, osproc, strutils]
import color, sys

const
  boldYellow = "\e[1;33m"
  boldRed = "\e[1;31m"
  boldCyan = "\e[1;36m"
  boldPurple = "\e[1;35m"

proc nerdFont*(): bool =
  getEnv("NIMSHELL_NERD_FONT") notin ["", "0", "false", "no"]

# --- git (branch from .git files; status from `git status`) ---

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

proc findGitDir*(start: string): string =
  var dir = start
  for _ in 0 ..< 32:
    let candidate = dir / ".git"
    if dirExists(candidate): return candidate
    if fileExists(candidate): return readGitdirPointer(candidate)
    let parent = dir.parentDir
    if parent == "" or parent == dir: return ""
    dir = parent
  ""

proc gitBranch*(cwd: string): string =
  ## Best-effort branch name by reading `.git/HEAD` (no `git` process).
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

type GitStatus* = object
  staged*, modified*, untracked*, conflicted*: bool
  ahead*, behind*: int

proc parseGitStatus*(porcelain: string): GitStatus =
  ## Parse `git status --porcelain=v1 --branch` output.
  for line in porcelain.splitLines:
    if line.len < 2: continue
    if line.startsWith("## "):
      let open = line.find('[')
      if open >= 0:
        for part in line[open + 1 .. ^1].strip(chars = {']'}).split(", "):
          let bits = part.splitWhitespace
          if bits.len == 2:
            try:
              if bits[0] == "ahead": result.ahead = parseInt(bits[1])
              elif bits[0] == "behind": result.behind = parseInt(bits[1])
            except ValueError: discard
      continue
    let x = line[0]
    let y = line[1]
    if x == '?' and y == '?': result.untracked = true
    elif x == 'U' or y == 'U' or (x == 'A' and y == 'A') or (x == 'D' and y == 'D'):
      result.conflicted = true
    else:
      if x notin {' ', '?', '!'}: result.staged = true
      if y notin {' ', '?', '!'}: result.modified = true

proc gitStatusText*(s: GitStatus): string =
  ## Compact markers: `[=!+?]` then `⇡n` / `⇣n`. Empty when clean and in sync.
  var flags = ""
  if s.conflicted: flags.add "="
  if s.modified: flags.add "!"
  if s.staged: flags.add "+"
  if s.untracked: flags.add "?"
  if flags != "": result = "[" & flags & "]"
  var sync = ""
  if s.ahead > 0: sync.add "⇡" & $s.ahead
  if s.behind > 0: sync.add "⇣" & $s.behind
  if sync != "":
    result = if result == "": sync else: result & " " & sync

proc gitStatus(cwd: string): GitStatus =
  if findExe("git") == "": return
  try:
    # GIT_OPTIONAL_LOCKS=0: never take index.lock just to draw a prompt.
    let (outp, code) = execCmdEx(
      "git --no-optional-locks status --porcelain=v1 --branch --ignore-submodules=dirty",
      options = {poUsePath}, workingDir = cwd)
    if code == 0: result = parseGitStatus(outp)
  except CatchableError:
    discard

# --- pieces ---

proc displayCwd*(cwd: string): string =
  ## Full cwd with `$HOME` shown as `~`.
  let (ok, home) = homeDir()
  if not ok: return cwd
  if cwd == home: "~"
  elif cwd.startsWith(home & "/"): "~" & cwd[home.len .. ^1]
  else: cwd

proc formatDuration*(ms: int64): string =
  ## `850ms`, `3.2s`, `1m5s`, `2h3m`.
  if ms < 1000: $ms & "ms"
  elif ms < 60_000:
    let tenths = ms div 100
    if tenths mod 10 == 0: $(tenths div 10) & "s"
    else: $(tenths div 10) & "." & $(tenths mod 10) & "s"
  elif ms < 3_600_000: $(ms div 60_000) & "m" & $((ms mod 60_000) div 1000) & "s"
  else: $(ms div 3_600_000) & "h" & $((ms mod 3_600_000) div 60_000) & "m"

proc statusLine*(on: bool, cwd, branch, gitText: string, lastExit: int,
                 durationMs: int64, nerd: bool): string =
  ## First prompt line (pure; tested).
  result = paint(on, boldCyan, displayCwd(cwd))
  if branch != "":
    let icon = if nerd: " " else: ""
    result.add separator(on, " on ") & paint(on, boldPurple, icon & branch)
    if gitText != "": result.add " " & paint(on, boldRed, gitText)
  if durationMs >= 2000:
    result.add separator(on, " took ") & paint(on, boldYellow, formatDuration(durationMs))
  if lastExit != 0:
    result.add " " & paint(on, boldRed, "✘ " & $lastExit)

proc promptChar*(on: bool, lastExit: int, nerd: bool): string =
  ## Green on success, red after a non-zero exit.
  if nerd:
    # PUA glyphs often draw ~2 cells wide while the terminal advances one.
    let icon = ""
    (if lastExit == 0: promptCharacterOk(on, icon) else: promptCharacterErr(on, icon)) & "  "
  else:
    (if lastExit == 0: promptCharacterOk(on, "❯") else: promptCharacterErr(on, "❯")) & " "

proc render*(cwd: string, lastExit: int, durationMs: int64): string =
  ## Print the status line (blank line first) and return the editor prompt.
  let on = enabled()
  let nerd = nerdFont()
  let branch = gitBranch(cwd)
  let gitText = if branch != "": gitStatusText(gitStatus(cwd)) else: ""
  println("")
  println(statusLine(on, cwd, branch, gitText, lastExit, durationMs, nerd))
  promptChar(on, lastExit, nerd)


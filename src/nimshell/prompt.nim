## Zero-config, Starship-inspired prompt.
##
##   ~/code/nimshell on  main [!+?] ⇡1 took 3.2s ✘ 1
##   ❯
##
## Works in any terminal: plain Unicode by default. Set `NIMSHELL_NERD_FONT=1`
## for Nerd Font glyphs (branch icon, terminal prompt character).
## Customizable via `prompt {…}` in config.ns (see config.nim).

import std/[os, osproc, strutils]
import color, sys

const
  boldYellow = "\e[1;33m"
  boldRed = "\e[1;31m"
  boldCyan = "\e[1;36m"
  boldPurple = "\e[1;35m"
  boldGreen = "\e[1;32m"

type PromptConfig* = object
  ## Prompt settings; `defaultPromptConfig()` is the zero-config look.
  character*: string       ## prompt character ("" = ❯, or the Nerd Font glyph)
  errorCharacter*: string  ## after a non-zero exit ("" = same as `character`)
  nerdFont*: int           ## -1 = from NIMSHELL_NERD_FONT, 0 = off, 1 = on
  singleLine*: bool        ## status and input on one line
  blankLine*: bool         ## empty line before each prompt
  git*: bool               ## show the branch
  gitStatus*: bool         ## run `git status` for the [!+?] ⇡⇣ markers
  minDurationMs*: int64    ## show "took …" at or above this
  cwdDepth*: int           ## show only the last N path components (0 = all)
  cwdStyle*, branchStyle*, gitStyle*, durationStyle*, errorStyle*,
    characterStyle*, errorCharacterStyle*: string  ## ANSI SGR codes

proc defaultPromptConfig*(): PromptConfig =
  PromptConfig(nerdFont: -1, blankLine: true, git: true, gitStatus: true,
               minDurationMs: 2000, cwdStyle: boldCyan, branchStyle: boldPurple,
               gitStyle: boldRed, durationStyle: boldYellow, errorStyle: boldRed,
               characterStyle: boldGreen, errorCharacterStyle: boldRed)

var promptConfig* = defaultPromptConfig()

proc nerdFont*(): bool =
  if promptConfig.nerdFont >= 0: return promptConfig.nerdFont == 1
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

proc truncateCwd*(shown: string, depth: int): string =
  ## Keep the last `depth` components of a displayed path (`…/a/b`).
  if depth <= 0: return shown
  let parts = shown.split('/')
  # "/a/b" splits to ["", "a", "b"]; "~/a" to ["~", "a"]
  let real = if parts.len > 0 and parts[0] == "": parts.len - 1 else: parts.len
  if real <= depth: shown
  else: "…/" & parts[^depth .. ^1].join("/")

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
  ## First prompt line (pure given `promptConfig`; tested).
  let c = promptConfig
  result = paint(on, c.cwdStyle, truncateCwd(displayCwd(cwd), c.cwdDepth))
  if branch != "":
    let icon = if nerd: " " else: ""
    result.add separator(on, " on ") & paint(on, c.branchStyle, icon & branch)
    if gitText != "": result.add " " & paint(on, c.gitStyle, gitText)
  if durationMs >= c.minDurationMs:
    result.add separator(on, " took ") & paint(on, c.durationStyle, formatDuration(durationMs))
  if lastExit != 0:
    result.add " " & paint(on, c.errorStyle, "✘ " & $lastExit)

proc promptChar*(on: bool, lastExit: int, nerd: bool): string =
  ## Green on success, red after a non-zero exit.
  let c = promptConfig
  # PUA glyphs often draw ~2 cells wide while the terminal advances one.
  let useNerd = nerd and c.character == ""
  let ok = if c.character != "": c.character elif nerd: "" else: "❯"
  let err = if c.errorCharacter != "": c.errorCharacter else: ok
  (if lastExit == 0: paint(on, c.characterStyle, ok)
   else: paint(on, c.errorCharacterStyle, err)) & (if useNerd: "  " else: " ")

proc render*(cwd: string, lastExit: int, durationMs: int64): string =
  ## Print the status line (blank line first) and return the editor prompt.
  ## With `single-line`, the status line is part of the returned prompt.
  let c = promptConfig
  let on = enabled()
  let nerd = nerdFont()
  let branch = if c.git: gitBranch(cwd) else: ""
  let gitText = if branch != "" and c.gitStatus: gitStatusText(gitStatus(cwd)) else: ""
  if c.blankLine: println("")
  let status = statusLine(on, cwd, branch, gitText, lastExit, durationMs, nerd)
  if c.singleLine: return status & " " & promptChar(on, lastExit, nerd)
  println(status)
  promptChar(on, lastExit, nerd)


# --- terminal tab / window title (OSC 0) ---

proc titleEnabled*(): bool =
  ## On for a real terminal; `NIMSHELL_NO_TITLE=1` or `TERM=dumb` turns it off.
  stdoutIsatty() and getEnv("TERM") != "dumb" and
    getEnv("NIMSHELL_NO_TITLE") in ["", "0", "false", "no"]

proc sanitizeTitle*(text: string, maxLen = 80): string =
  ## Strip ANSI and control characters (an ESC/BEL would end the OSC early),
  ## collapse whitespace, and truncate long command lines with `…`.
  var cps: seq[string]
  var lastSpace = false
  for (start, n, esc) in ansiScan(text):
    if esc: continue
    let piece = text[start ..< start + n]
    if piece.len == 1 and (ord(piece[0]) < 32 or ord(piece[0]) == 127):
      if not lastSpace and cps.len > 0: cps.add " "
      lastSpace = true
    elif piece == " ":
      if not lastSpace and cps.len > 0: cps.add " "
      lastSpace = true
    else:
      cps.add piece
      lastSpace = false
  while cps.len > 0 and cps[^1] == " ": cps.setLen(cps.len - 1)
  if cps.len > maxLen: cps = cps[0 ..< maxLen - 1] & @["…"]
  cps.join("")

proc titleSequence*(text: string): string = "\e]0;" & sanitizeTitle(text) & "\a"

proc setTitle*(text: string) =
  if titleEnabled(): sys.write(titleSequence(text))

proc idleTitle*(cwd: string): string =
  ## Title while sitting at the prompt: the directory, e.g. `~/code/project`.
  displayCwd(cwd)

proc pushTitle*() =
  ## Save the terminal's current title (XTWINOPS 22) so exit can restore it.
  if titleEnabled(): sys.write("\e[22;0t")

proc popTitle*() =
  if titleEnabled(): sys.write("\e[23;0t")

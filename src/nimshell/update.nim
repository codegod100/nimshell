## Self-update for the AppImage build.
##
## Releases are published on GitHub (see `.github/workflows/release.yml`).
## When nimshell runs from an AppImage (`$APPIMAGE` is set) it can replace
## that file with the newest release:
##
## - `self-update` (builtin) / `nimshell --self-update` — check and install now
## - the interactive shell checks in the background at most once a day and
##   installs a newer release for the next launch (`NIMSHELL_NO_UPDATE=1`
##   turns that off)
##
## The download is verified before it replaces anything: it must be an ELF
## AppImage and `new --version` must report the release tag. The swap is an
## atomic rename in the AppImage's own directory, so a running shell keeps
## its (old) file open and nothing is left half-written.

import std/[httpclient, json, os, posix, strutils, times]
import std/osproc
import netclient

proc nimbleVersion(): string {.compileTime.} =
  for line in staticRead("../../nimshell.nimble").splitLines:
    let l = line.strip
    if l.startsWith("version") and '"' in l:
      return l[l.find('"') + 1 ..< l.rfind('"')]
  "0.0.0"

const
  NimshellVersion* {.strdefine.} = nimbleVersion()
    ## From nimshell.nimble; release builds pass `-d:NimshellVersion=<tag>`.
  UpdateRepo* {.strdefine.} = "codegod100/nimshell"
  UpdateHost* {.strdefine.} = "https://github.com"
    ## Only changed by the end-to-end test, which serves releases locally.
  checkInterval = 24 * 60 * 60 # seconds between background checks

type
  Release* = object
    tag*: string
    assetName*: string
    assetUrl*: string

  UpdateResult* = object
    ok*: bool
    updated*: bool
    message*: string

# --- versions ---

proc parseVersion*(v: string): seq[int] =
  ## `v1.2.3`, `1.2.3-rc1` → `@[1, 2, 3]` (pre-release suffix ignored).
  var s = v.strip
  if s.startsWith("v") or s.startsWith("V"): s = s[1 .. ^1]
  let cut = s.find({'-', '+'})
  if cut >= 0: s = s[0 ..< cut]
  for part in s.split('.'):
    try: result.add parseInt(part)
    except ValueError: result.add 0

proc isNewer*(candidate, current: string): bool =
  ## True when `candidate` is a strictly higher version than `current`.
  let a = parseVersion(candidate)
  let b = parseVersion(current)
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: a[i] else: 0
    let y = if i < b.len: b[i] else: 0
    if x != y: return x > y
  false

proc archName*(): string =
  ## AppImage architecture suffix for this build.
  when defined(amd64): "x86_64"
  elif defined(arm64): "aarch64"
  elif defined(i386): "i686"
  else: hostCPU

proc assetName*(arch = archName()): string =
  ## Fixed release asset name, so the download URL is predictable and the
  ## embedded zsync update info matches (`nimshell-x86_64.AppImage`).
  "nimshell-" & arch & ".AppImage"

proc tagFromLocation*(location: string): string =
  ## `https://github.com/o/r/releases/tag/v1.2.3` → `v1.2.3` ("" otherwise).
  let marker = "/releases/tag/"
  let i = location.find(marker)
  if i < 0: "" else: location[i + marker.len .. ^1].strip(chars = {'/'})

# --- state (last check, pending notice) ---

proc stateFile(): string =
  let cache = getEnv("XDG_CACHE_HOME")
  let base = if cache != "": cache else: getHomeDir() / ".cache"
  base / "nimshell" / "update.json"

proc loadState(): JsonNode =
  try: parseFile(stateFile())
  except CatchableError: newJObject()

proc saveState(state: JsonNode) =
  try:
    createDir(stateFile().parentDir)
    writeFile(stateFile(), $state)
  except CatchableError: discard

# --- network ---

proc newClient(url: string, timeoutMs = 20_000, maxRedirects = 5): HttpClient =
  let headers = newHttpHeaders({"user-agent": "nimshell/" & NimshellVersion})
  newShellClient(url, timeoutMs, headers, maxRedirects = maxRedirects)

proc latestRelease*(): (bool, Release, string) =
  ## Newest release tag from the `releases/latest` redirect (no GitHub API,
  ## so no API rate limit). Returns (ok, release, error).
  let url = UpdateHost & "/" & UpdateRepo & "/releases/latest"
  let client = newClient(url, maxRedirects = 0)
  defer: client.close()
  try:
    let resp = client.request(url, httpMethod = HttpHead)
    let location = resp.headers.getOrDefault("location")
    let tag = tagFromLocation(location)
    if tag == "":
      # With no releases GitHub redirects `latest` to the release list.
      if resp.code == Http404 or location.strip(chars = {'/'}).endsWith("/releases"):
        return (false, Release(), "no releases published yet")
      return (false, Release(), "unexpected response from GitHub: " & $resp.code)
    let name = assetName()
    (true, Release(tag: tag, assetName: name,
                   assetUrl: UpdateHost & "/" & UpdateRepo &
                     "/releases/download/" & tag & "/" & name), "")
  except CatchableError as e:
    (false, Release(), e.msg)

# --- install ---

proc looksLikeAppImage*(path: string): bool =
  ## ELF magic plus the AppImage type-2 marker `AI\x02` at offset 8.
  try:
    var f = open(path)
    defer: f.close()
    var buf: array[11, char]
    if f.readChars(buf) != 11: return false
    buf[0] == '\x7f' and buf[1] == 'E' and buf[2] == 'L' and buf[3] == 'F' and
      buf[8] == 'A' and buf[9] == 'I' and buf[10] == '\x02'
  except CatchableError:
    false

proc reportsVersion(path, tag: string): bool =
  ## Run the downloaded AppImage once to prove it starts and is `tag`.
  try:
    let (outp, code) = execCmdEx(quoteShell(path) & " --version")
    code == 0 and outp.strip == "nimshell " & tag.strip(chars = {'v', 'V'}, trailing = false)
  except CatchableError:
    false

proc install(release: Release, target: string): UpdateResult =
  let dir = target.parentDir
  let tmp = dir / ("." & target.extractFilename & ".update-" & $getCurrentProcessId())
  let client = newClient(release.assetUrl, timeoutMs = 120_000)
  defer:
    client.close()
    if fileExists(tmp): removeFile(tmp)
  try:
    client.downloadFile(release.assetUrl, tmp)
  except CatchableError as e:
    return UpdateResult(message: "download failed: " & e.msg)
  if not looksLikeAppImage(tmp):
    return UpdateResult(message: "downloaded file is not an AppImage")
  try:
    setFilePermissions(tmp, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
                             fpGroupExec, fpOthersRead, fpOthersExec})
  except OSError as e:
    return UpdateResult(message: "chmod failed: " & e.msg)
  if not reportsVersion(tmp, release.tag):
    return UpdateResult(message: "downloaded AppImage did not start or reported the wrong version")
  # Atomic swap: the running process keeps the old inode.
  # (same directory → rename(2), which replaces `target` atomically)
  try:
    moveFile(tmp, target)
  except OSError as e:
    return UpdateResult(message: "cannot replace " & target & ": " & e.msg)
  UpdateResult(ok: true, updated: true,
               message: "updated nimshell " & NimshellVersion & " → " & release.tag)

proc appImagePath*(): string =
  ## Path of the running AppImage, or "" when not running from one.
  getEnv("APPIMAGE")

proc selfUpdate*(checkOnly = false): UpdateResult =
  let target = appImagePath()
  let (ok, release, err) = latestRelease()
  var state = loadState()
  state["last_check"] = %getTime().toUnix
  saveState(state)
  if not ok: return UpdateResult(message: "update check failed: " & err)
  if not isNewer(release.tag, NimshellVersion):
    return UpdateResult(ok: true, message: "nimshell " & NimshellVersion & " is up to date")
  if checkOnly:
    return UpdateResult(ok: true, message: "update available: " & NimshellVersion &
                        " → " & release.tag & " (run `self-update`)")
  if target == "":
    return UpdateResult(message: "update available (" & release.tag &
      "), but nimshell is not running from an AppImage; download it from " &
      "https://github.com/" & UpdateRepo & "/releases/latest")
  if not fileExists(target) or access(target.parentDir.cstring, W_OK) != 0:
    return UpdateResult(message: "cannot write to " & target.parentDir)
  result = install(release, target)
  if result.updated:
    state = loadState()
    state["notice"] = %("nimshell updated " & NimshellVersion & " → " & release.tag)
    saveState(state)

# --- background checks from the REPL ---

proc autoUpdateEnabled*(): bool =
  appImagePath() != "" and getEnv("NIMSHELL_NO_UPDATE") in ["", "0", "false", "no"]

proc takeNotice*(): string =
  ## One-shot message left by a background update ("updated a → b").
  let state = loadState()
  result = state{"notice"}.getStr
  if result != "":
    state.delete("notice")
    saveState(state)

proc spawnDetached(exe: string, args: seq[string]) =
  ## Double-fork so the updater outlives the shell and never becomes a
  ## zombie; its stdio goes to /dev/null so it cannot draw on the terminal.
  let pid = fork()
  if pid < 0: return
  if pid == 0:
    discard setsid()
    if fork() != 0: exitnow(0)
    let devnull = posix.open("/dev/null", O_RDWR)
    if devnull >= 0:
      for fd in 0.cint .. 2.cint: discard dup2(devnull, fd)
    let argv = allocCStringArray(@[exe] & args)
    discard execv(exe.cstring, argv)
    exitnow(127)
  var status: cint
  discard waitpid(pid, status, 0)

proc maybeBackgroundUpdate*() =
  ## At most once per `checkInterval`, update in a detached process.
  if not autoUpdateEnabled(): return
  var state = loadState()
  let last = state{"last_check"}.getBiggestInt(0)
  let now = getTime().toUnix
  if now - last < checkInterval: return
  # Record the attempt first so several shells do not all start updaters.
  state["last_check"] = %now
  saveState(state)
  spawnDetached(appImagePath(), @["--self-update", "--quiet"])

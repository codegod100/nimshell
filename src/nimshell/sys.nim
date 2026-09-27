## OS / process helpers: cwd, env, externals, ps, sockets, time.

import std/[os, posix, strutils, times, re, tables, algorithm, tempfiles]
import term
export term

# --- output ---

proc println*(text: string) =
  stdout.write text
  stdout.write "\n"
  stdout.flushFile()

proc write*(text: string) =
  stdout.write text
  stdout.flushFile()

proc printlnErr*(text: string) =
  stderr.write text & "\n"
  stderr.flushFile()

# --- "output already shown" flag ---

var outputShown = false

proc takeOutputShown*(): bool =
  ## True if the last external command already streamed its output to the
  ## TTY. Consumes the flag.
  result = outputShown
  outputShown = false

proc clearOutputShown*() = outputShown = false

# --- SIGINT handling (REPL) ---

var interrupted* {.volatile.} = false

proc onSigint(sig: cint) {.noconv.} =
  interrupted = true

proc installSigint*() =
  ## Ctrl+C sets a flag instead of killing the shell. Children get the default
  ## disposition back after exec, so Ctrl+C still stops a running program.
  var sa: Sigaction
  sa.sa_handler = onSigint
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0 # no SA_RESTART: blocking reads return EINTR
  discard sigaction(SIGINT, sa, nil)

# --- cwd / env ---

proc getCwd*(): (bool, string) =
  try: (true, getCurrentDir())
  except OSError as e: (false, e.msg)

proc setCwd*(path: string): (bool, string) =
  try:
    setCurrentDir(path)
    (true, "")
  except OSError:
    if not dirExists(path): (false, "no such directory: " & path)
    else: (false, "cannot enter directory: " & path)

proc getenvOpt*(name: string): (bool, string) =
  if existsEnv(name): (true, getEnv(name)) else: (false, "")

proc setenv*(name, value: string) = putEnv(name, value)

proc listEnv*(): seq[(string, string)] =
  for k, v in envPairs(): result.add((k, v))

proc homeDir*(): (bool, string) =
  let h = getEnv("HOME")
  if h != "": return (true, h)
  let d = getHomeDir()
  if d == "": (false, "no home directory")
  else: (true, d.strip(leading = false, chars = {'/'}))

proc expandHome*(p: string): string =
  ## `~` → home, `~/x` → home/x. Anything else (incl. `~user`) is unchanged.
  if p != "~" and not p.startsWith("~/"): return p
  let (ok, home) = homeDir()
  if not ok: p
  elif p == "~": home
  else: home / p[2 .. ^1]

# --- which ---

proc isExecutableFile(path: string): bool =
  var st: Stat
  if stat(path.cstring, st) != 0: return false
  S_ISREG(st.st_mode) and access(path.cstring, X_OK) == 0

proc whichAll*(command: string): seq[string] =
  ## All matching executables on `PATH` (or the path itself if it has `/`).
  if command == "": return
  if '/' in command:
    if isExecutableFile(command): result.add command
    return
  for dir in getEnv("PATH").split(':'):
    if dir == "": continue
    let p = dir / command
    if isExecutableFile(p) and p notin result: result.add p

proc which*(command: string): (bool, string) =
  let all = whichAll(command)
  if all.len == 0: (false, "") else: (true, all[0])

proc realpath*(path: string): (bool, string) =
  ## Canonical absolute path: resolve `.`/`..` and follow all symlinks.
  try: (true, expandFilename(path))
  except OSError: (false, "")

# --- regex ---

proc reContains*(text, pattern: string, ignoreCase: bool): (bool, bool, string) =
  ## (ok, matched, error). Error on an invalid pattern.
  try:
    let flags = if ignoreCase: {reIgnoreCase, reStudy} else: {reStudy}
    let rx = re(pattern, flags)
    (true, text.find(rx) >= 0, "")
  except RegexError as e:
    (false, false, e.msg)

# --- time ---

proc unixNow*(): int64 = getTime().toUnix

proc formatUnixLocal*(seconds: int64): string =
  ## Format Unix epoch seconds as local `Jul 3 2026 9:39:40 PM` (12-hour).
  try:
    fromUnix(seconds).local.format("MMM d yyyy h:mm:ss tt")
  except CatchableError:
    $seconds

# --- external processes ---

proc cSetenv(k, v: cstring, overwrite: cint): cint {.importc: "setenv",
    header: "<stdlib.h>".}

proc forceColorSet(): bool =
  for name in ["FORCE_COLOR", "CLICOLOR_FORCE"]:
    let v = getEnv(name)
    if v != "" and v != "0": return true
  false

proc wantChildColor(): bool =
  ## Match the shell color policy: off under NO_COLOR; otherwise on for a TTY
  ## or when the parent already forces color.
  if getEnv("NO_COLOR") != "": return false
  stdoutIsatty() or forceColorSet()

proc childEnvBase(): seq[(string, string)] =
  let (ok, rows, cols) = termSize()
  if ok:
    result.add(("COLUMNS", $cols))
    result.add(("LINES", $rows))
  # External pagers pass through ANSI (-R), exit on short output (-F) and do
  # not clear the screen (-X).
  if getEnv("LESS") == "": result.add(("LESS", "FRX"))

proc childEnvCapture(): seq[(string, string)] =
  ## Capture must not hang inside the child's own pager (git/jj → less).
  result = childEnvBase()
  for p in ["PAGER", "GIT_PAGER", "JJ_PAGER", "SYSTEMD_PAGER", "MANPAGER"]:
    result.add((p, "cat"))
  if wantChildColor():
    # Tools that only colorize on a TTY: honor FORCE_COLOR / CLICOLOR_FORCE.
    if not existsEnv("FORCE_COLOR"): result.add(("FORCE_COLOR", "1"))
    if not existsEnv("CLICOLOR_FORCE"): result.add(("CLICOLOR_FORCE", "1"))
    # git ignores FORCE_COLOR; decorate=auto drops ref names on pipes.
    if not existsEnv("GIT_CONFIG_COUNT"):
      result.add(("GIT_CONFIG_COUNT", "2"))
      result.add(("GIT_CONFIG_KEY_0", "color.ui"))
      result.add(("GIT_CONFIG_VALUE_0", "always"))
      result.add(("GIT_CONFIG_KEY_1", "log.decorate"))
      result.add(("GIT_CONFIG_VALUE_1", "short"))

proc spawnWait(path: string, args: seq[string], stdinData: string,
               capture: bool, extraEnv: seq[(string, string)],
               output: var string): (bool, int, string) =
  ## Fork/exec `path`. Returns (ok, exit status, error message).
  var stdinFd: cint = -1
  var tmpPath = ""
  if stdinData != "":
    # Feed pipeline input through a temp file so the child never blocks on a
    # half-written pipe while we are waiting to read its output.
    let (f, p) = createTempFile("nimshell-stdin-", "")
    f.write stdinData
    f.close()
    tmpPath = p
    stdinFd = posix.open(p.cstring, O_RDONLY)
  elif capture:
    stdinFd = posix.open("/dev/null", O_RDONLY)

  var pipeFds: array[2, cint]
  if capture and pipe(pipeFds) != 0:
    return (false, 0, "pipe failed: " & $strerror(errno))

  let argv = allocCStringArray(@[path] & args)
  let pid = fork()
  if pid < 0:
    deallocCStringArray(argv)
    return (false, 0, "fork failed: " & $strerror(errno))
  if pid == 0:
    # child
    posix.signal(SIGINT, SIG_DFL)
    posix.signal(SIGPIPE, SIG_DFL)
    if stdinFd >= 0:
      discard dup2(stdinFd, 0)
      discard close(stdinFd)
    if capture:
      discard dup2(pipeFds[1], 1)
      discard dup2(pipeFds[1], 2)
      discard close(pipeFds[0])
      discard close(pipeFds[1])
    for (k, v) in extraEnv: discard cSetenv(k.cstring, v.cstring, 1)
    discard execv(path.cstring, argv)
    exitnow(127)

  deallocCStringArray(argv)
  if stdinFd >= 0: discard close(stdinFd)
  if capture:
    discard close(pipeFds[1])
    var buf: array[8192, char]
    while true:
      let n = posix.read(pipeFds[0], addr buf[0], buf.len)
      if n > 0:
        let start = output.len
        output.setLen(start + n)
        copyMem(addr output[start], addr buf[0], n)
      elif n < 0 and errno == EINTR:
        continue
      else:
        break
    discard close(pipeFds[0])
  var status: cint
  while waitpid(pid, status, 0) < 0:
    if errno != EINTR: break
  if tmpPath != "": removeFile(tmpPath)
  let code =
    if WIFEXITED(status): int(WEXITSTATUS(status))
    elif WIFSIGNALED(status): 128 + int(WTERMSIG(status))
    else: 1
  (true, code, "")

proc resolveCmd(command: string): (bool, string) =
  let (ok, path) = which(command)
  if ok: (true, path) else: (false, "command not found: " & command)

proc runCmd*(command: string, args: seq[string], stdinData: string): (bool, int, string) =
  ## Run an external command capturing stdout/stderr (pipelines, `let`,
  ## non-TTY). Returns (ok, status, output-or-error).
  let (found, path) = resolveCmd(command)
  if not found: return (false, 0, path)
  var output = ""
  let (ok, code, err) = spawnWait(path, args, stdinData, true, childEnvCapture(), output)
  if not ok: return (false, 0, err)
  (true, code, output)

proc runCmdTty*(command: string, args: seq[string], stdinData: string): (bool, int, string) =
  ## Run an external command in the foreground on the TTY so long-lived
  ## processes stream and interactive programs (vim, less, sudo) work.
  ## Falls back to capture when stdout is not a terminal.
  if not stdoutIsatty(): return runCmd(command, args, stdinData)
  let (found, path) = resolveCmd(command)
  if not found: return (false, 0, path)
  var output = ""
  let (ok, code, err) = spawnWait(path, args, stdinData, false, childEnvBase(), output)
  if not ok: return (false, 0, err)
  outputShown = true
  (true, code, "")

# --- input builtin ---

proc readUserInput*(prompt: string): (bool, string) =
  ## Multi-line user input: read until Ctrl+D / EOF (interactive paste) or
  ## drain piped stdin. Returns (ok, text-or-error).
  if prompt != "": println(prompt)
  interrupted = false
  var data = ""
  var buf: array[4096, char]
  while true:
    let n = posix.read(0, addr buf[0], buf.len)
    if n > 0:
      let start = data.len
      data.setLen(start + n)
      copyMem(addr data[start], addr buf[0], n)
    elif n == 0:
      break
    elif errno == EINTR:
      if interrupted:
        interrupted = false
        return (false, "interrupted")
    else:
      return (false, "io_error")
  (true, data)

# --- ps (Linux /proc) ---

type
  ProcessInfo* = object
    ## One process row (Nushell `ps` columns). Memory fields are bytes;
    ## `startTime` is Unix epoch seconds (0 if unknown).
    pid*, ppid*: int
    name*, status*: string
    cpu*: float
    mem*, virtual*: int64
    command*: string
    startTime*: int64
    userId*, processGroupId*, sessionId*, priority*, processThreads*: int
    working*, paged*: int64
    cwd*: string

  StatFields = object
    comm: string
    state: char
    ppid, pgrp, session, priority, numThreads: int
    utime, stime, starttime, vsize, rss: int64

proc isPidName(s: string): bool =
  s.len > 0 and s.allCharsInSet({'0' .. '9'})

proc readFileSafe(path: string): (bool, string) =
  try: (true, readFile(path))
  except CatchableError: (false, "")

proc readStatFields(pid: int, f: var StatFields): bool =
  ## Parse /proc/<pid>/stat. Comm is between the first '(' and the last ") ".
  let (ok, body) = readFileSafe("/proc/" & $pid & "/stat")
  if not ok: return false
  let open = body.find('(')
  let close = body.rfind(") ")
  if open < 0 or close < open: return false
  f.comm = body[open + 1 ..< close]
  let fs = body[close + 2 .. ^1].strip.splitWhitespace
  proc nth(i: int): int64 =
    if i < fs.len:
      try: parseBiggestInt(fs[i]) except ValueError: 0
    else: 0
  f.state = if fs.len > 0 and fs[0].len > 0: fs[0][0] else: '?'
  f.ppid = int nth(1)
  f.pgrp = int nth(2)
  f.session = int nth(3)
  f.utime = nth(11)
  f.stime = nth(12)
  f.priority = int nth(15)
  f.numThreads = int nth(17)
  f.starttime = nth(19)
  f.vsize = nth(20)
  f.rss = nth(21)
  true

proc statusName(c: char): string =
  case c
  of 'S': "Sleeping"
  of 'R': "Running"
  of 'D': "Disk sleep"
  of 'Z': "Zombie"
  of 'T': "Stopped"
  of 't': "Tracing"
  of 'X', 'x': "Dead"
  of 'K': "Wakekill"
  of 'W': "Waking"
  of 'P': "Parked"
  of 'I': "Idle"
  else: "Unknown"

proc firstInt(s: string, default: int64): int64 =
  var digits = ""
  for c in s:
    if c in {'0' .. '9'}: digits.add c
    elif digits.len > 0: break
  if digits == "": default
  else:
    try: parseBiggestInt(digits) except ValueError: default

proc readCmdline(pid: int, fallback: string): string =
  let (ok, body) = readFileSafe("/proc/" & $pid & "/cmdline")
  if not ok or body == "": return fallback
  var parts: seq[string]
  for p in body.split('\0'):
    if p != "": parts.add p
  if parts.len == 0: return fallback
  parts.join(" ").multiReplace(("\n", " "), ("\t", " "))

proc readCwd(pid: int): string =
  try: expandSymlink("/proc/" & $pid & "/cwd")
  except CatchableError: ""

proc sysconfInt(name: cint, default: int): int =
  let v = sysconf(name)
  if v > 0: int(v) else: default

proc bootTimeSeconds(): int64 =
  let (ok, body) = readFileSafe("/proc/stat")
  if not ok: return 0
  for line in body.splitLines:
    if line.startsWith("btime "):
      return firstInt(line, 0)
  0

proc snapshotCpuTimes(): Table[int, int64] =
  for kind, path in walkDir("/proc"):
    let name = path.extractFilename
    if isPidName(name):
      var f: StatFields
      let pid = parseInt(name)
      if readStatFields(pid, f): result[pid] = f.utime + f.stime

proc listProcesses*(): seq[ProcessInfo] =
  ## System processes (Linux `/proc`; empty on other OSes). Samples CPU over
  ## ~100ms like Nushell `ps`.
  when not defined(linux):
    return @[]
  else:
    let ticks = sysconfInt(SC_CLK_TCK, 100)
    let pageSize = sysconfInt(SC_PAGESIZE, 4096)
    let boot = bootTimeSeconds()
    let base = snapshotCpuTimes()
    sleep(100)
    let intervalMs = 100.0
    var pids: seq[int]
    for kind, path in walkDir("/proc"):
      let name = path.extractFilename
      if isPidName(name): pids.add parseInt(name)
    pids.sort()
    for pid in pids:
      var f: StatFields
      if not readStatFields(pid, f): continue
      let total = f.utime + f.stime
      let prev = base.getOrDefault(pid, total)
      let delta = max(0'i64, total - prev)
      let usageMs = if ticks > 0: float(delta) * 1000.0 / float(ticks) else: 0.0
      var p = ProcessInfo(
        pid: pid, ppid: f.ppid, name: f.comm, status: statusName(f.state),
        cpu: usageMs * 100.0 / intervalMs,
        processGroupId: f.pgrp, sessionId: f.session, priority: f.priority,
        processThreads: f.numThreads)
      p.startTime = if boot > 0 and ticks > 0: boot + f.starttime div ticks else: 0
      let memFromStat = f.rss * pageSize
      p.mem = memFromStat
      p.virtual = f.vsize
      let (ok, status) = readFileSafe("/proc/" & $pid & "/status")
      if ok:
        for line in status.splitLines:
          if line.startsWith("VmRSS:"): p.mem = firstInt(line, memFromStat div 1024) * 1024
          elif line.startsWith("VmSize:"): p.virtual = firstInt(line, f.vsize div 1024) * 1024
          elif line.startsWith("VmSwap:"): p.paged = firstInt(line, 0) * 1024
          elif line.startsWith("Uid:"): p.userId = int firstInt(line, 0)
      p.working = p.mem
      p.command = readCmdline(pid, f.comm)
      p.cwd = readCwd(pid)
      result.add p

# --- whyport (Linux /proc/net) ---

type
  PortSocket* = object
    ## One socket touching a port (like `lsof -i :<port>`). `pid`/`fd` are 0
    ## when the owner is unknown; `state` is empty for UDP.
    protocol*, family*, localAddress*: string
    localPort*: int
    remoteAddress*: string
    remotePort*: int
    state*: string
    pid*: int
    name*, command*: string
    userId*, fd*: int

  SockOwner = tuple[pid, fd: int, name, command: string]

proc socketInodeMap(): Table[int64, seq[SockOwner]] =
  for kind, path in walkDir("/proc"):
    let pname = path.extractFilename
    if not isPidName(pname): continue
    let pid = parseInt(pname)
    let fdDir = path / "fd"
    var owners: seq[(int64, int)]
    try:
      for k2, fdPath in walkDir(fdDir):
        let fdName = fdPath.extractFilename
        if not isPidName(fdName): continue
        var target = ""
        try: target = expandSymlink(fdPath)
        except CatchableError: continue
        if target.startsWith("socket:[") and target.endsWith("]"):
          try: owners.add((parseBiggestInt(target[8 .. ^2]), parseInt(fdName)))
          except ValueError: discard
    except CatchableError:
      continue
    if owners.len == 0: continue
    var f: StatFields
    let name = if readStatFields(pid, f): f.comm else: ""
    let command = if name != "": readCmdline(pid, name) else: ""
    for (inode, fd) in owners:
      result.mgetOrPut(inode, @[]).add((pid, fd, name, command))

proc decodeIpv4(hex: string): string =
  let n = fromHex[uint32](hex)
  # little-endian 32-bit word
  $(n and 0xff) & "." & $((n shr 8) and 0xff) & "." & $((n shr 16) and 0xff) &
    "." & $((n shr 24) and 0xff)

proc decodeIpv6(hex: string): string =
  ## 32 hex chars = 4 little-endian 32-bit words → 16 network-order bytes.
  var bytes: array[16, int]
  for w in 0 .. 3:
    let word = fromHex[uint32](hex[w * 8 ..< w * 8 + 8])
    for b in 0 .. 3:
      bytes[w * 4 + b] = int((word shr (8 * b)) and 0xff)
  var allZero = true
  for b in bytes:
    if b != 0: allZero = false
  if allZero: return "::"
  var mapped = bytes[10] == 255 and bytes[11] == 255
  for i in 0 .. 9:
    if bytes[i] != 0: mapped = false
  if mapped:
    return "::ffff:" & $bytes[12] & "." & $bytes[13] & "." & $bytes[14] & "." & $bytes[15]
  var groups: seq[string]
  for g in 0 .. 7:
    groups.add toLowerAscii(toHex((bytes[g * 2] shl 8) or bytes[g * 2 + 1])).strip(
      trailing = false, chars = {'0'})
    if groups[^1] == "": groups[^1] = "0"
  groups.join(":")

proc tcpStateName(proto, stHex: string): string =
  if proto == "udp": return ""
  try:
    case fromHex[int](stHex)
    of 1: "ESTABLISHED"
    of 2: "SYN_SENT"
    of 3: "SYN_RECV"
    of 4: "FIN_WAIT1"
    of 5: "FIN_WAIT2"
    of 6: "TIME_WAIT"
    of 7: "CLOSE"
    of 8: "CLOSE_WAIT"
    of 9: "LAST_ACK"
    of 10: "LISTEN"
    of 11: "CLOSING"
    of 12: "NEW_SYN_RECV"
    else: "UNKNOWN(" & $fromHex[int](stHex) & ")"
  except ValueError:
    stHex

proc listPortSockets*(port: int): seq[PortSocket] =
  ## Sockets whose local or remote port is `port` (Linux `/proc/net` + fd
  ## inodes). Empty on unsupported OS or when nothing matches.
  when not defined(linux):
    return @[]
  else:
    var sockMap: Table[int64, seq[SockOwner]]
    var mapBuilt = false
    for (path, proto, family) in [("/proc/net/tcp", "tcp", "ipv4"),
                                  ("/proc/net/tcp6", "tcp", "ipv6"),
                                  ("/proc/net/udp", "udp", "ipv4"),
                                  ("/proc/net/udp6", "udp", "ipv6")]:
      let (ok, body) = readFileSafe(path)
      if not ok: continue
      var first = true
      for line in body.splitLines:
        if first:
          first = false
          continue
        let parts = line.splitWhitespace
        # sl local rem st tx:rx tr:tm retrnsmt uid timeout inode …
        if parts.len < 10: continue
        let lp = parts[1].split(':')
        let rp = parts[2].split(':')
        if lp.len != 2 or rp.len != 2: continue
        var lport, rport: int
        var laddr, raddr: string
        try:
          lport = fromHex[int](lp[1])
          rport = fromHex[int](rp[1])
          laddr = if family == "ipv4": decodeIpv4(lp[0]) else: decodeIpv6(lp[0])
          raddr = if family == "ipv4": decodeIpv4(rp[0]) else: decodeIpv6(rp[0])
        except ValueError, IndexDefect:
          continue
        if lport != port and rport != port: continue
        if not mapBuilt:
          sockMap = socketInodeMap()
          mapBuilt = true
        let uid = try: parseInt(parts[7]) except ValueError: 0
        let inode = try: parseBiggestInt(parts[9]) except ValueError: 0'i64
        var s = PortSocket(protocol: proto, family: family, localAddress: laddr,
                           localPort: lport, remoteAddress: raddr,
                           remotePort: rport,
                           state: tcpStateName(proto, parts[3]), userId: uid)
        let owners = sockMap.getOrDefault(inode)
        if owners.len == 0:
          result.add s
        else:
          for o in owners:
            var s2 = s
            s2.pid = o.pid
            s2.fd = o.fd
            s2.name = o.name
            s2.command = o.command
            result.add s2

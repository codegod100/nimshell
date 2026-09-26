## Low-level terminal helpers: raw mode, key decoding, window size.

import std/[posix, strutils, termios]

type
  WinSize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort

var TIOCGWINSZ {.importc, header: "<sys/ioctl.h>".}: culong

var rawSaved: Termios
var rawActive = false

proc stdoutIsatty*(): bool = isatty(1) != 0
proc stdinIsatty*(): bool = isatty(0) != 0

proc termSize*(): (bool, int, int) =
  ## Terminal `(rows, cols)` when stdout is a TTY. Defaults to 24x80 if the
  ## driver reports zeros.
  if not stdoutIsatty(): return (false, 0, 0)
  var ws: WinSize
  if ioctl(1, TIOCGWINSZ, addr ws) != 0: return (true, 24, 80)
  let rows = if ws.ws_row == 0: 24 else: int(ws.ws_row)
  let cols = if ws.ws_col == 0: 80 else: int(ws.ws_col)
  (true, rows, cols)

proc enableRaw*(): bool =
  ## Single-key input with echo and signals off. Output post-processing stays
  ## on so `\n` still returns to column 0 (no staircase).
  if rawActive: return true
  if not stdinIsatty(): return false
  if tcGetAttr(0, addr rawSaved) != 0: return false
  var t = rawSaved
  t.c_iflag = t.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  t.c_lflag = t.c_lflag and not Cflag(ECHO or ICANON or ISIG or IEXTEN)
  t.c_cc[VMIN] = 1.char
  t.c_cc[VTIME] = 0.char
  if tcSetAttr(0, TCSADRAIN, addr t) != 0: return false
  rawActive = true
  true

proc disableRaw*() =
  if rawActive:
    discard tcSetAttr(0, TCSADRAIN, addr rawSaved)
    rawActive = false

proc isRaw*(): bool = rawActive

proc writeOut*(s: string) =
  stdout.write s
  stdout.flushFile()

proc readByte(b: var char): bool =
  while true:
    let n = posix.read(0, addr b, 1)
    if n == 1: return true
    if n < 0 and errno == EINTR: continue
    return false

proc byteReady(timeoutMs: int): bool =
  var fds = [TPollfd(fd: 0, events: POLLIN)]
  poll(addr fds[0], 1, timeoutMs.cint) > 0

proc readUtf8Tail(first: char): string =
  result = $first
  let b = ord(first)
  let extra =
    if (b and 0xE0) == 0xC0: 1
    elif (b and 0xF0) == 0xE0: 2
    elif (b and 0xF8) == 0xF0: 3
    else: 0
  for _ in 0 ..< extra:
    var c: char
    if not readByte(c): break
    result.add c

proc mouseButtonName(button: int): string =
  ## Wheel events carry bit 6 (64 = up, 65 = down); modifiers add 4/8/16.
  if (button and 64) != 0:
    if (button and 3) == 0: "wheel_up"
    elif (button and 3) == 1: "wheel_down"
    else: "mouse"
  else: "mouse"

proc readCsi(): string =
  ## After `ESC [`: collect params up to the final byte.
  var params = ""
  while true:
    var c: char
    if not readByte(c): return "esc"
    if ord(c) >= 0x40 and ord(c) <= 0x7E:
      # SGR mouse report (mode 1006): `ESC [ < button ; col ; row M|m`
      if params.startsWith("<") and c in {'M', 'm'}:
        try: return mouseButtonName(parseInt(params[1 .. ^1].split(';')[0]))
        except ValueError: return "mouse"
      # Legacy X10 mouse report: `ESC [ M` + three raw bytes (button + 32).
      if params == "" and c == 'M':
        var b, x, y: char
        if readByte(b) and readByte(x) and readByte(y):
          return mouseButtonName(ord(b) - 32)
        return "mouse"
      case c
      of 'A': return "up"
      of 'B': return "down"
      of 'C': return "right"
      of 'D': return "left"
      of 'H': return "home"
      of 'F': return "end"
      of '~':
        case params
        of "1", "7": return "home"
        of "4", "8": return "end"
        of "3": return "delete"
        of "5": return "page_up"
        of "6": return "page_down"
        of "200": return "paste_start"
        of "201": return "paste_end"
        else: return "unknown"
      else: return "unknown"
    params.add c

proc readEscape(): string =
  if not byteReady(30): return "esc"
  var n: char
  if not readByte(n): return "esc"
  case n
  of '[': readCsi()
  of 'O':
    var f: char
    if not readByte(f): return "esc"
    case f
    of 'A': "up"
    of 'B': "down"
    of 'C': "right"
    of 'D': "left"
    of 'H': "home"
    of 'F': "end"
    else: "unknown"
  of 'f': "alt_f"
  of 'b': "alt_b"
  of '\x7f': "alt_backspace"
  else: "esc"

proc readKeyName*(): string =
  ## One keypress as a name: "enter", "up", "ctrl_c", "a", "é", "eof", …
  var c: char
  if not readByte(c): return "eof"
  case ord(c)
  of 27: readEscape()
  of 1: "ctrl_a"
  of 2: "ctrl_b"
  of 3: "ctrl_c"
  of 4: "ctrl_d"
  of 5: "ctrl_e"
  of 6: "ctrl_f"
  of 7: "ctrl_g"
  of 8, 127: "backspace"
  of 9: "tab"
  of 10, 13: "enter"
  of 11: "ctrl_k"
  of 12: "ctrl_l"
  of 14: "ctrl_n"
  of 16: "ctrl_p"
  of 18: "ctrl_r"
  of 21: "ctrl_u"
  of 23: "ctrl_w"
  of 32: "space"
  else:
    if ord(c) < 32: "unknown"
    else: readUtf8Tail(c)

template withKeyMode*(body: untyped) =
  ## Run `body` with the TTY in single-key mode (restored afterwards).
  let wasRaw = isRaw()
  if not wasRaw: discard enableRaw()
  try:
    body
  finally:
    if not wasRaw: disableRaw()

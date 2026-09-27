## Color-aware pager (builtin `less`).
##
## Passes ANSI through unchanged, sizes pages with `color.visibleLength`,
## and uses the alternate screen while interactive so the REPL is restored
## on quit. When stdout is not a TTY, or the text fits on one screen, the
## caller should print the text itself (see `needsPaging`).
##
## Search: `/` live-finds a fixed string (ANSI-stripped, case-insensitive) as
## you type; Enter accepts. `n` / `N` jump to the next / previous match
## (wraps at the ends).

import std/[options, strutils]
from std/unicode import toLower, runes, runeLen, `$`
import color, sys

const
  wheelStep = 3 ## lines per scroll-wheel notch
  matchOn = "\e[30;103m"  ## black on bright yellow
  matchOff = "\e[39;49m"

proc pageHeight(rows: int): int = max(1, rows - 1)

proc wrapLine*(line: string, cols: int): seq[string] =
  ## Soft-wrap one logical line to at most `cols` visible columns. Escape
  ## sequences never count toward width and are never split mid-sequence.
  let cols = max(1, cols)
  if visibleLength(line) <= cols: return @[line]
  var acc = ""
  var vis = 0
  for (start, n, esc) in ansiScan(line):
    let piece = line[start ..< start + n]
    if esc:
      acc.add piece
    else:
      if vis >= cols:
        result.add acc
        acc = ""
        vis = 0
      acc.add piece
      inc vis
  if acc != "" or result.len == 0: result.add acc

proc displayLines*(text: string, cols: int): seq[string] =
  ## Split on newlines, then soft-wrap each logical line to `cols` using
  ## ANSI-aware visible width so color codes do not throw off wrapping.
  let t = text.replace("\r\n", "\n").replace("\r", "\n")
  for line in t.split("\n"):
    result.add wrapLine(line, max(1, cols))

proc logicalLines*(text: string): seq[string] =
  ## Lines as written (no soft wrap) — the unit of chop (`less -S`) mode.
  text.replace("\r\n", "\n").replace("\r", "\n").split("\n")

proc sliceVisible*(line: string, start, width: int): string =
  ## Visible columns `[start, start + width)` of `line`. Every escape sequence
  ## up to the right edge is kept, so colors opened left of the window still
  ## apply; a reset is appended when the line carried any escapes.
  var vis = 0
  var sawEsc = false
  for (a, n, esc) in ansiScan(line):
    if esc:
      result.add line[a ..< a + n]
      sawEsc = true
    else:
      if vis >= start + width: break
      if vis >= start: result.add line[a ..< a + n]
      inc vis
  if sawEsc: result.add "\e[0m"

proc wrapWithOrigins(logical: seq[string], cols: int): (seq[string], seq[int]) =
  ## Soft-wrapped lines plus, for each, the index of its logical line.
  for i, l in logical:
    for piece in wrapLine(l, cols):
      result[0].add piece
      result[1].add i

proc needsPaging*(text: string, chop = false): bool =
  ## True when stdout is a TTY and wrapping `text` to the terminal width yields
  ## more lines than fit on one screen (minus the status row).
  let (ok, rows, cols) = termSize()
  if not ok: return false
  if chop:
    let lines = logicalLines(text)
    if lines.len > pageHeight(rows): return true
    for l in lines:
      if visibleLength(l) > cols: return true
    return false
  displayLines(text, cols).len > pageHeight(rows)

proc lineMatches*(line, pattern: string): bool =
  ## True if the line matches `pattern` as a fixed substring of its
  ## ANSI-stripped text (case-insensitive). Empty patterns never match.
  if pattern == "": return false
  toLower(stripAnsi(line)).contains(toLower(pattern))

proc matchRanges(plain, pattern: string): seq[(int, int)] =
  ## Non-overlapping match ranges as visible-codepoint `(start, end)`.
  var pcs, pat: seq[string]
  for r in plain.runes: pcs.add $r
  for r in pattern.runes: pat.add $r
  if pat.len == 0: return
  var i = 0
  while i + pat.len <= pcs.len:
    if pcs[i ..< i + pat.len] == pat:
      result.add((i, i + pat.len))
      i += pat.len
    else:
      inc i

proc matchColumn*(line, pattern: string): int =
  ## Visible column of the first case-insensitive match, or -1.
  if pattern == "": return -1
  let r = matchRanges(toLower(stripAnsi(line)), toLower(pattern))
  if r.len == 0: -1 else: r[0][0]

proc hoffShowing*(line, pattern: string, hoff, cols: int): int =
  ## Horizontal offset that brings the first match in `line` into view:
  ## unchanged if already visible, otherwise the match lands a quarter of
  ## the way into the window.
  let col = matchColumn(line, pattern)
  if col < 0: return hoff
  let plen = visibleLength(pattern)
  if col >= hoff and col + plen <= hoff + cols: hoff
  else: max(0, col - cols div 4)

proc highlightMatches*(line, pattern: string): string =
  ## Wrap each non-overlapping fixed-string match in black-on-bright-yellow.
  ## Matches are located on ANSI-stripped text so color codes do not break
  ## search; matching is case-insensitive. While inside a match, SGR
  ## sequences are followed by a re-open of the accent so a content reset
  ## does not cancel the highlight.
  if pattern == "": return line
  let ranges = matchRanges(toLower(stripAnsi(line)), toLower(pattern))
  if ranges.len == 0: return line
  var vis = 0
  var inMatch = false
  for (start, n, esc) in ansiScan(line):
    let piece = line[start ..< start + n]
    if esc:
      result.add piece
      if inMatch and piece.endsWith("m"): result.add matchOn
    else:
      var nextIn = false
      for (a, b) in ranges:
        if vis >= a and vis < b: nextIn = true
      if inMatch and not nextIn: result.add matchOff
      elif not inMatch and nextIn: result.add matchOn
      result.add piece
      inMatch = nextIn
      inc vis
  if inMatch: result.add matchOff

proc firstMatchIn(lines: seq[string], pattern: string, fromI, untilI: int): int =
  for i in max(fromI, 0) ..< min(untilI, lines.len):
    if lineMatches(lines[i], pattern): return i
  -1

proc lastMatchIn(lines: seq[string], pattern: string, fromI, untilI: int): int =
  for i in countdown(min(untilI, lines.len) - 1, max(fromI, 0)):
    if lineMatches(lines[i], pattern): return i
  -1

proc findAfter*(lines: seq[string], pattern: string, after: int): Option[(int, bool)] =
  ## First match strictly after `after` (use `-1` to search from the start).
  ## Wraps once from the top. Returns `(index, wrapped)`.
  if pattern == "" or lines.len == 0: return none((int, bool))
  let i = firstMatchIn(lines, pattern, after + 1, lines.len)
  if i >= 0: return some((i, false))
  let j = firstMatchIn(lines, pattern, 0, min(lines.len, after + 1))
  if j >= 0: return some((j, true))
  none((int, bool))

proc findBefore*(lines: seq[string], pattern: string, before: int): Option[(int, bool)] =
  ## First match strictly before `before` (use `lines.len` to search from the
  ## end). Wraps once from the bottom. Returns `(index, wrapped)`.
  if pattern == "" or lines.len == 0: return none((int, bool))
  let i = lastMatchIn(lines, pattern, 0, clamp(before, 0, lines.len))
  if i >= 0: return some((i, false))
  let j = lastMatchIn(lines, pattern, max(0, before), lines.len)
  if j >= 0: return some((j, true))
  none((int, bool))

proc liveSearchPreview*(lines: seq[string], query: string,
                        startOffset: int): (int, Option[string], Option[string]) =
  ## Pure preview for live `/` search: view offset, highlight pattern, and an
  ## optional status suffix. Empty query restores `startOffset`.
  if query == "": return (startOffset, none(string), none(string))
  let found = findAfter(lines, query, startOffset - 1)
  if found.isSome: (found.get[0], some(query), none(string))
  else: (startOffset, some(query), some("not found"))

# --- interactive loop ---

proc padStatus(text: string, cols: int): string =
  let vis = visibleLength(text)
  if vis >= cols: text else: text & " ".repeat(cols - vis)

proc statusLine(offset, height, total, cols: int, message: Option[string],
                chop = false, hoff = 0): string =
  var plain: string
  if message.isSome:
    plain = " " & message.get & " "
  else:
    let label =
      if total == 0: " (empty) "
      elif offset + height >= total: " (END) "
      else:
        let bottom = min(total, offset + height)
        " " & $(offset + 1) & "-" & $bottom & "/" & $total & " (" &
          $(bottom * 100 div total) & "%) "
    let mode = if chop: (if hoff > 0: "[chop col " & $(hoff + 1) & "] " else: "[chop] ")
               else: ""
    let help = if chop: " q:quit  /:search  ←/→:scroll  S:wrap  h:help "
               else: " q:quit  /:search  n/N  j/k:line  space/b:page  S:chop  h:help "
    plain = if visibleLength(label & mode & help) > cols: label & mode
            else: label & mode & help
  let body = if enabled(): "\e[7m" & padStatus(plain, cols) & "\e[0m"
             else: padStatus(plain, cols)
  body & "\e[K"

proc redraw(lines: seq[string], offset, height, cols: int,
            pattern, message: Option[string], chop = false, hoff = 0) =
  ## In chop mode `lines` are logical lines, cut to the window at column
  ## `hoff`; otherwise they are already soft-wrapped to `cols`.
  var buf = "\e[H\e[2J\e[0m"
  for k in 0 ..< height:
    let i = offset + k
    var line = if i < lines.len: lines[i] else: ""
    if pattern.isSome: line = highlightMatches(line, pattern.get)
    if chop: line = sliceVisible(line, hoff, cols)
    buf.add line & "\e[K\r\n"
  buf.add "\e[0m" & statusLine(offset, height, lines.len, cols, message, chop, hoff)
  sys.write(buf)

proc drawSearchStatus(cols: int, query: string, message: Option[string]) =
  let (ok, rows, _) = termSize()
  if not ok: return
  let plain = if message.isSome: "/" & query & "  (" & message.get & ") "
              else: "/" & query
  let body = if enabled(): "\e[7m" & padStatus(plain, cols) & "\e[0m"
             else: padStatus(plain, cols)
  sys.write("\e[" & $max(1, rows) & ";1H\e[0m" & body & "\e[K")

proc dropLastRune(s: string): string =
  var rs: seq[string]
  for r in s.runes: rs.add $r
  if rs.len > 0: rs.setLen(rs.len - 1)
  rs.join("")

proc isSearchChar(key: string): bool =
  not key.startsWith("ctrl_") and key.runeLen == 1

proc liveSearch(lines: seq[string], startOffset, height, cols: int,
                entered: var string, viewOffset: var int,
                chop: bool, hoff: var int): bool =
  ## Live incremental search. Returns false on cancel.
  var query = ""
  while true:
    let (off, paintP, status) = liveSearchPreview(lines, query, startOffset)
    # Chop mode: scroll sideways so the live match is on screen.
    let h = if chop and paintP.isSome and off < lines.len:
              hoffShowing(lines[off], query, hoff, cols)
            else: hoff
    redraw(lines, off, height, cols, paintP, none(string), chop, h)
    drawSearchStatus(cols, query, status)
    let key = readKeyName()
    case key
    of "eof", "ctrl_c", "ctrl_g", "ctrl_d", "esc": return false
    of "enter":
      entered = query
      viewOffset = off
      hoff = h
      return true
    of "backspace": query = dropLastRune(query)
    of "ctrl_u": query = ""
    of "space": query.add " "
    else:
      if isSearchChar(key): query.add key

proc showHelp(height, cols: int) =
  let text = @[
    "nimshell less — color-aware pager",
    "",
    "  j / ↓ / Enter     one line down",
    "  k / ↑             one line up",
    "  mouse wheel       scroll 3 lines (hold Shift to select text)",
    "  S                 toggle chop mode (like less -S): cut long lines",
    "  ← / → (h / l)     scroll sideways half a screen (chop mode)",
    "  0 / $             jump to the left / right edge (chop mode)",
    "  space / f / PgDn  one page down",
    "  b / PgUp          one page up",
    "  g / Home          top",
    "  G / End           bottom",
    "  /pattern          live search forward (fixed string, ignore case)",
    "  n / N             next / previous match",
    "  Ctrl+L            redraw",
    "  ? (h when wrapping) this help",
    "  q / Q / Ctrl+C    quit",
    "",
    "ANSI colors from tools and tables are kept (like less -R).",
    "Search finds as you type (case-insensitive; ANSI ignored); hits are black on yellow.",
    "",
    "Press any key to return…"].join("\n")
  redraw(displayLines(text, cols), 0, height, cols, none(string), none(string))
  discard readKeyName()

proc maxLineWidth(lines: seq[string]): int =
  for l in lines: result = max(result, visibleLength(l))

proc run*(text: string, chop = false) =
  ## Interactive page session. Call only when `needsPaging` is true.
  ## `chop` starts in `less -S` mode: long lines are cut at the window edge
  ## and ←/→ scroll sideways; `S` toggles between chop and soft wrap.
  ## Leaves the alternate screen on exit; does not print the text afterwards.
  let (ok, rows, cols) = termSize()
  if not ok: return
  let height = pageHeight(rows)
  let logical = logicalLines(text)
  let (wrapped, origins) = wrapWithOrigins(logical, cols)
  let widest = maxLineWidth(logical)
  let hstep = max(1, cols div 2) # like less: half a screen per ←/→
  var chop = chop
  withKeyMode:
    # Alternate screen + mouse reporting (button events, SGR encoding) so the
    # scroll wheel reaches us. Hold Shift to select text in most terminals.
    sys.write("\e[?1049h\e[H\e[?1000h\e[?1006h")
    var offset = 0
    var hoff = 0
    var pattern = none(string)
    var message = none(string)
    template lines(): seq[string] = (if chop: logical else: wrapped)
    proc search(forward: bool) =
      if pattern.isNone:
        message = some("No previous pattern")
        return
      let r = if forward: findAfter(lines, pattern.get, offset)
              else: findBefore(lines, pattern.get, offset)
      if r.isNone:
        message = some("Pattern not found")
      else:
        offset = r.get[0]
        if r.get[1]: message = some("Search wrapped")
        if chop: hoff = hoffShowing(logical[offset], pattern.get, hoff, cols)
    while true:
      let maxOff = max(0, lines.len - height)
      offset = clamp(offset, 0, maxOff)
      hoff = if chop: clamp(hoff, 0, max(0, widest - cols)) else: 0
      redraw(lines, offset, height, cols, pattern, message, chop, hoff)
      message = none(string)
      let key = readKeyName()
      case key
      of "eof", "q", "Q", "ctrl_c", "ctrl_d": break
      of "down", "j", "enter": inc offset
      of "up", "k": dec offset
      of "wheel_down": offset += wheelStep
      of "wheel_up": offset -= wheelStep
      of "space", "f", "page_down", "ctrl_f": offset += height
      of "b", "page_up", "ctrl_b": offset -= height
      of "g", "home": offset = 0
      of "G", "end": offset = maxOff
      of "right", "l":
        if chop: hoff += hstep
        else: message = some("Press S to chop long lines, then ←/→ scroll")
      of "left", "h":
        if chop: hoff -= hstep
        elif key == "h": showHelp(height, cols)
      of "0": hoff = 0
      of "$": hoff = widest - cols
      of "S":
        # Keep the same logical line at the top across the switch.
        if chop:
          let target = offset
          offset = 0
          for i, o in origins:
            if o == target:
              offset = i
              break
          chop = false
          message = some("Wrapping long lines")
        else:
          offset = if offset < origins.len: origins[offset] else: 0
          chop = true
          message = some("Chopping long lines (←/→ to scroll)")
      of "/":
        var entered = ""
        var liveOff = offset
        if liveSearch(lines, offset, height, cols, entered, liveOff, chop, hoff):
          if entered == "":
            # Empty Enter reuses the previous pattern.
            search(true)
          else:
            pattern = some(entered)
            offset = liveOff
      of "n": search(true)
      of "N": search(false)
      of "?": showHelp(height, cols)
      else: discard
    sys.write("\e[?1006l\e[?1000l\e[?1049l")

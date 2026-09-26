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

proc needsPaging*(text: string): bool =
  ## True when stdout is a TTY and wrapping `text` to the terminal width yields
  ## more lines than fit on one screen (minus the status row).
  let (ok, rows, cols) = termSize()
  if not ok: return false
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

proc statusLine(offset, height, total, cols: int, message: Option[string]): string =
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
    let help = " q:quit  /:search  n/N  j/k:line  space/b:page  g/G  h:help "
    plain = if visibleLength(label & help) > cols: label else: label & help
  let body = if enabled(): "\e[7m" & padStatus(plain, cols) & "\e[0m"
             else: padStatus(plain, cols)
  body & "\e[K"

proc redraw(lines: seq[string], offset, height, cols: int,
            pattern, message: Option[string]) =
  var buf = "\e[H\e[2J\e[0m"
  for k in 0 ..< height:
    let i = offset + k
    var line = if i < lines.len: lines[i] else: ""
    if pattern.isSome: line = highlightMatches(line, pattern.get)
    buf.add line & "\e[K\r\n"
  buf.add "\e[0m" & statusLine(offset, height, lines.len, cols, message)
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
                entered: var string, viewOffset: var int): bool =
  ## Live incremental search. Returns false on cancel.
  var query = ""
  while true:
    let (off, paintP, status) = liveSearchPreview(lines, query, startOffset)
    redraw(lines, off, height, cols, paintP, none(string))
    drawSearchStatus(cols, query, status)
    let key = readKeyName()
    case key
    of "eof", "ctrl_c", "ctrl_g", "ctrl_d", "esc": return false
    of "enter":
      entered = query
      viewOffset = off
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
    "  space / f / PgDn  one page down",
    "  b / PgUp          one page up",
    "  g / Home          top",
    "  G / End           bottom",
    "  /pattern          live search forward (fixed string, ignore case)",
    "  n / N             next / previous match",
    "  Ctrl+L            redraw",
    "  h / ?             this help",
    "  q / Q / Ctrl+C    quit",
    "",
    "ANSI colors from tools and tables are kept (like less -R).",
    "Search finds as you type (case-insensitive; ANSI ignored); hits are black on yellow.",
    "",
    "Press any key to return…"].join("\n")
  redraw(displayLines(text, cols), 0, height, cols, none(string), none(string))
  discard readKeyName()

proc run*(text: string) =
  ## Interactive page session. Call only when `needsPaging` is true.
  ## Leaves the alternate screen on exit; does not print the text afterwards.
  let (ok, rows, cols) = termSize()
  if not ok: return
  let height = pageHeight(rows)
  let lines = displayLines(text, cols)
  let total = lines.len
  let maxOff = max(0, total - height)
  withKeyMode:
    sys.write("\e[?1049h\e[H")
    var offset = 0
    var pattern = none(string)
    var message = none(string)
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
    while true:
      offset = clamp(offset, 0, maxOff)
      redraw(lines, offset, height, cols, pattern, message)
      message = none(string)
      let key = readKeyName()
      case key
      of "eof", "q", "Q", "ctrl_c", "ctrl_d": break
      of "down", "j", "enter": inc offset
      of "up", "k": dec offset
      of "space", "f", "page_down", "ctrl_f": offset += height
      of "b", "page_up", "ctrl_b": offset -= height
      of "g", "home": offset = 0
      of "G", "end": offset = maxOff
      of "/":
        var entered = ""
        var liveOff = offset
        if liveSearch(lines, offset, height, cols, entered, liveOff):
          if entered == "":
            # Empty Enter reuses the previous pattern.
            search(true)
          else:
            pattern = some(entered)
            offset = liveOff
      of "n": search(true)
      of "N": search(false)
      of "h", "?": showHelp(height, cols)
      else: discard
    sys.write("\e[?1049l")

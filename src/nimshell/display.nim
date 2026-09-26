## Pretty-print structured values (Nushell-style tables + colors).

import std/strutils
from std/unicode import runeLen, runeSubStr, runes, Rune, `$`
import std/os
import color, sys, value

proc padRight(s: string, width: int): string =
  let n = s.runeLen
  if n >= width: s.runeSubStr(0, width)
  else: s & " ".repeat(width - n)

proc formatDatetime*(unixSeconds: int64): string =
  ## Format Unix epoch seconds as local `Jul 3 2026 9:39:40 PM` (12-hour).
  formatUnixLocal(unixSeconds)

proc scaleUnit(n, unit: int64, suffix: string): string =
  # tenths with half-up rounding: (n * 10 + unit/2) / unit
  let tenths = (n * 10 + unit div 2) div unit
  let whole = tenths div 10
  let frac = tenths mod 10
  if frac == 0: $whole & suffix
  else: $whole & "." & $frac & suffix

proc formatFilesize*(bytes: int64): string =
  ## Format a byte count for display: B below 1 KiB, then KB / MB / GB / TB
  ## (1024-based). One decimal place when the fractional part is non-zero.
  let n = max(bytes, 0)
  if n < 1024: $n & " B"
  elif n < 1_048_576: scaleUnit(n, 1024, " KB")
  elif n < 1_073_741_824: scaleUnit(n, 1_048_576, " MB")
  elif n < 1_099_511_627_776: scaleUnit(n, 1_073_741_824, " GB")
  else: scaleUnit(n, 1_099_511_627_776, " TB")

proc isEpochSeconds(n: int64): bool =
  ## Plausible wall-clock epoch seconds (2001-09-09 .. 2100-01-01).
  n >= 1_000_000_000 and n < 4_102_444_800

proc cellPlain(col: string, value: Value): string =
  ## Plain cell text before coloring. Pipeline data stays raw ints; only
  ## display converts byte counts to KB/MB/… and epoch seconds to datetimes.
  if value.kind == vkInt:
    case col
    of "size", "mem", "virtual", "working", "paged": return formatFilesize(value.i)
    of "modified", "start_time": return formatDatetime(value.i)
    else: discard
  cellString(value)

proc colorByValue(on: bool, value: Value, plain: string): string =
  case value.kind
  of vkNothing: color.nothing(on, plain)
  of vkBool: boolC(on, plain)
  of vkInt: intC(on, plain)
  of vkFloat: floatC(on, plain)
  # Preserve pre-colored external text inside tables/lists/records.
  of vkString: (if containsAnsi(plain): plain else: stringC(on, plain))
  of vkFail: color.error(on, plain)
  of vkList, vkRecord, vkTable: stringC(on, plain)

proc colorPathName(on: bool, plain, typeHint: string): string =
  case typeHint
  of "dir", "directory": dirName(on, plain)
  of "symlink", "link": symlinkName(on, plain)
  of "file": fileName(on, plain)
  else: stringC(on, plain)

proc colorEntryType(on: bool, plain: string): string =
  case plain
  of "dir", "directory": typeDir(on, plain)
  of "symlink", "link": typeSymlink(on, plain)
  of "file": typeFile(on, plain)
  else: stringC(on, plain)

proc colorCellForColumn(on: bool, col: string, value: Value, plain,
                        typeHint: string): string =
  case col
  of "name": colorPathName(on, plain, typeHint)
  of "type": colorEntryType(on, plain)
  of "size", "mem", "virtual", "working", "paged": filesize(on, plain)
  of "modified", "start_time": datetime(on, plain)
  else: colorByValue(on, value, plain)

proc colorCell(on: bool, value: Value, plain: string): string =
  colorCellForColumn(on, "", value, plain, "")

proc boxLine(widths: seq[int], left, mid, right, fill: string): string =
  var segs: seq[string]
  for w in widths: segs.add fill.repeat(w + 2)
  left & segs.join(mid) & right

proc truncateVisible*(s: string, width: int): string =
  ## Cut `s` to at most `width` visible columns, ending in `…` when cut.
  ## Escape sequences are kept (never split), and a reset is appended when a
  ## cut string carried ANSI so its color cannot bleed into the next cell.
  if width <= 0: return ""
  if visibleLength(s) <= width: return s
  var vis = 0
  var sawEsc = false
  for (start, n, esc) in ansiScan(s):
    if esc:
      result.add s[start ..< start + n]
      sawEsc = true
    elif vis < width - 1:
      result.add s[start ..< start + n]
      inc vis
    else:
      break
  result.add "…"
  if sawEsc: result.add "\e[0m"

proc oneLine(s: string): string =
  ## Table cells are single-line: show embedded newlines as `↵`.
  if '\n' in s: s.replace("\r\n", "↵").replace("\n", "↵") else: s

proc fitColumns*(natural, headerW: seq[int], maxWidth: int,
                 protected: seq[bool] = @[]): (seq[int], int) =
  ## Fit column widths into `maxWidth` terminal columns (Nushell-style).
  ## Returns `(widths, shownColumns)`. First the widest columns shrink (never
  ## below their header, or 4) — free-text columns before `protected` ones
  ## (numbers, sizes, dates); if that is still too wide, columns are dropped
  ## from the right and the caller draws a `…` marker column.
  ## `maxWidth <= 0` means unlimited.
  var widths = natural
  let n = widths.len
  proc total(ws: seq[int], shown: int, marker: bool): int =
    # "│ cell " per column + closing "│"; the marker column is "│ … ".
    result = 1
    for i in 0 ..< shown: result += ws[i] + 3
    if marker: result += 4
  if maxWidth <= 0 or total(widths, n, false) <= maxWidth: return (widths, n)
  var minW = newSeq[int](n)
  for i in 0 ..< n: minW[i] = min(natural[i], max(headerW[i], 4))
  var shown = n
  while true:
    let marker = shown < n
    # Shrink the currently widest shrinkable column one step at a time,
    # free-text columns first, then protected ones.
    for pass in 0 .. 1:
      while total(widths, shown, marker) > maxWidth:
        var best = -1
        for i in 0 ..< shown:
          let isProt = i < protected.len and protected[i]
          if pass == 0 and isProt: continue
          if widths[i] > minW[i] and (best < 0 or widths[i] > widths[best]): best = i
        if best < 0: break
        dec widths[best]
    if total(widths, shown, marker) <= maxWidth or shown <= 1:
      return (widths, shown)
    # Still too wide at minimum widths: hide the rightmost column and retry
    # with the natural widths of what is left.
    dec shown
    for i in 0 ..< shown: widths[i] = natural[i]

proc renderTableWith(on: bool, columns: seq[string], rows: seq[seq[Value]],
                     maxWidth = 0): string =
  if columns.len == 0: return color.nothing(on, "(empty table)")
  # Column-aware plain text (e.g. size → KB/MB) for widths and coloring.
  var plains: seq[seq[string]]
  for row in rows:
    var p: seq[string]
    for i, col in columns:
      p.add(if i < row.len: oneLine(cellPlain(col, row[i])) else: "")
    plains.add p
  # Widths use visible length so cells with ANSI do not inflate the table.
  var natural, headerW: seq[int]
  for i, col in columns:
    var w = visibleLength(col)
    for p in plains: w = max(w, visibleLength(p[i]))
    natural.add max(w, 1)
    headerW.add visibleLength(col)
  # Numbers, sizes and dates are short and lose meaning when cut; shrink
  # free-text columns (names, commands, paths) first.
  var protected: seq[bool]
  for i, col in columns:
    var numeric = col in ["size", "mem", "virtual", "working", "paged", "modified", "start_time"]
    if not numeric:
      numeric = rows.len > 0
      for row in rows:
        if i < row.len and row[i].kind notin {vkInt, vkFloat, vkBool, vkNothing}:
          numeric = false
          break
    protected.add numeric
  let (fitted, shown) = fitColumns(natural, headerW, maxWidth, protected)
  let hidden = shown < columns.len
  var widths = fitted[0 ..< shown]
  if hidden: widths.add 1 # `…` marker column
  let bar = separator(on, "│")
  let top = separator(on, boxLine(widths, "╭", "┬", "╮", "─"))
  let sep = separator(on, boxLine(widths, "├", "┼", "┤", "─"))
  let bot = separator(on, boxLine(widths, "╰", "┴", "╯", "─"))
  let marker = " " & separator(on, "…") & " "
  var headerCells: seq[string]
  for i in 0 ..< shown:
    headerCells.add " " & header(on, padRight(truncateVisible(columns[i], widths[i]), widths[i])) & " "
  if hidden: headerCells.add marker
  let headerLine = bar & headerCells.join(bar) & bar
  let typeIdx = columns.find("type")
  var body: seq[string]
  for r, row in rows:
    let typeHint = if typeIdx >= 0: plains[r][typeIdx] else: ""
    var cells: seq[string]
    for i in 0 ..< shown:
      let col = columns[i]
      let plain = truncateVisible(plains[r][i], widths[i])
      let val = if i < row.len: row[i] else: value.nothing()
      # Color the unpadded text, then pad outside the ANSI codes so
      # type/name matchers see exact values ("dir", not "dir ").
      let painted = colorCellForColumn(on, col, val, plain, typeHint)
      cells.add " " & painted & " ".repeat(max(0, widths[i] - visibleLength(plain))) & " "
    if hidden: cells.add marker
    body.add bar & cells.join(bar) & bar
  if body.len == 0: top & "\n" & headerLine & "\n" & bot
  else: top & "\n" & headerLine & "\n" & sep & "\n" & body.join("\n") & "\n" & bot

proc renderTable*(columns: seq[string], rows: seq[seq[Value]]): string =
  renderTableWith(enabled(), columns, rows)

proc renderList(on: bool, items: seq[Value], maxWidth = 0): string =
  if items.len == 0: return separator(on, "[]")
  var lines: seq[string]
  let idxW = len($(items.len - 1))
  for i, item in items:
    var plain = oneLine(cellString(item))
    # "  <idx> │ " prefix
    if maxWidth > 0: plain = truncateVisible(plain, max(1, maxWidth - idxW - 5))
    lines.add "  " & index(on, $i) & " " & separator(on, "│") & " " &
      colorCell(on, item, plain)
  separator(on, "╭──── list ───") & "\n" & lines.join("\n") & "\n" &
    separator(on, "╰────────────")

proc renderRecord(on: bool, fields: seq[(string, Value)], maxWidth = 0): string =
  if fields.len == 0: return separator(on, "{}")
  var keyW = 0
  for (k, _) in fields: keyW = max(keyW, k.runeLen)
  var typeHint = ""
  var tv: Value
  if keyFind(fields, "type", tv) and tv.kind == vkString: typeHint = tv.s
  var lines: seq[string]
  for (k, v) in fields:
    var plain = oneLine(cellPlain(k, v))
    # "  <key> │ " prefix
    if maxWidth > 0: plain = truncateVisible(plain, max(1, maxWidth - keyW - 5))
    lines.add "  " & key(on, padRight(k, keyW)) & " " & separator(on, "│") &
      " " & colorCellForColumn(on, k, v, plain, typeHint)
  separator(on, "╭──── record ───") & "\n" & lines.join("\n") & "\n" &
    separator(on, "╰──────────────")

proc renderString(on: bool, s: string): string =
  ## External programs often embed their own colors. Pass those through.
  ## Short plain strings still get Nu-style string coloring.
  if containsAnsi(s) or '\n' in s: s else: stringC(on, s)

proc renderWith*(on: bool, v: Value, maxWidth = 0): string =
  ## Render with an explicit color switch (useful for tests / `NO_COLOR`).
  ## `maxWidth > 0` fits tables, lists and records into that many columns.
  case v.kind
  of vkNothing: ""
  of vkFail: color.error(on, "Error: " & v.msg)
  of vkString: renderString(on, v.s)
  of vkTable: renderTableWith(on, v.columns, v.rows, maxWidth)
  of vkList:
    var allRecords = true
    for it in v.items:
      if it.kind != vkRecord: allRecords = false
    if allRecords:
      let t = tableFromRecords(v.items)
      renderTableWith(on, t.columns, t.rows, maxWidth)
    else:
      renderList(on, v.items, maxWidth)
  of vkRecord: renderRecord(on, v.fields, maxWidth)
  of vkInt:
    # Bare epoch seconds (e.g. `now`) print like the `modified` column.
    if isEpochSeconds(v.i): datetime(on, formatDatetime(v.i))
    else: intC(on, $v.i)
  else: colorCell(on, v, cellString(v))

proc terminalWidth*(): int =
  ## Width to fit structured output into: the terminal's columns on a TTY
  ## (`COLUMNS` overrides), otherwise unlimited (0) so pipes get full data.
  let cols = getEnv("COLUMNS")
  if cols != "":
    try:
      let n = parseInt(cols)
      if n > 0 and stdoutIsatty(): return n
    except ValueError: discard
  let (ok, _, c) = termSize()
  if ok: c else: 0

proc render*(v: Value): string = renderWith(enabled(), v, terminalWidth())

proc renderError*(msg: string): string =
  ## Color-friendly error line for the REPL.
  color.error(enabled(), "✗ " & msg)

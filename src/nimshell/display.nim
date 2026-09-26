## Pretty-print structured values (Nushell-style tables + colors).

import std/strutils
from std/unicode import runeLen, runeSubStr, runes, Rune, `$`
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

proc renderTableWith(on: bool, columns: seq[string], rows: seq[seq[Value]]): string =
  if columns.len == 0: return color.nothing(on, "(empty table)")
  # Column-aware plain text (e.g. size → KB/MB) for widths and coloring.
  var plains: seq[seq[string]]
  for row in rows:
    var p: seq[string]
    for i, col in columns:
      p.add(if i < row.len: cellPlain(col, row[i]) else: "")
    plains.add p
  # Widths use visible length so cells with ANSI do not inflate the table.
  var widths: seq[int]
  for i, col in columns:
    var w = visibleLength(col)
    for p in plains: w = max(w, visibleLength(p[i]))
    widths.add max(w, 1)
  let bar = separator(on, "│")
  let top = separator(on, boxLine(widths, "╭", "┬", "╮", "─"))
  let sep = separator(on, boxLine(widths, "├", "┼", "┤", "─"))
  let bot = separator(on, boxLine(widths, "╰", "┴", "╯", "─"))
  var headerCells: seq[string]
  for i, col in columns:
    headerCells.add " " & header(on, padRight(col, widths[i])) & " "
  let headerLine = bar & headerCells.join(bar) & bar
  let typeIdx = columns.find("type")
  var body: seq[string]
  for r, row in rows:
    let typeHint = if typeIdx >= 0: plains[r][typeIdx] else: ""
    var cells: seq[string]
    for i, col in columns:
      let plain = plains[r][i]
      let val = if i < row.len: row[i] else: value.nothing()
      # Color the unpadded text, then pad outside the ANSI codes so
      # type/name matchers see exact values ("dir", not "dir ").
      let painted = colorCellForColumn(on, col, val, plain, typeHint)
      cells.add " " & painted & " ".repeat(max(0, widths[i] - visibleLength(plain))) & " "
    body.add bar & cells.join(bar) & bar
  if body.len == 0: top & "\n" & headerLine & "\n" & bot
  else: top & "\n" & headerLine & "\n" & sep & "\n" & body.join("\n") & "\n" & bot

proc renderTable*(columns: seq[string], rows: seq[seq[Value]]): string =
  renderTableWith(enabled(), columns, rows)

proc renderList(on: bool, items: seq[Value]): string =
  if items.len == 0: return separator(on, "[]")
  var lines: seq[string]
  for i, item in items:
    lines.add "  " & index(on, $i) & " " & separator(on, "│") & " " &
      colorCell(on, item, cellString(item))
  separator(on, "╭──── list ───") & "\n" & lines.join("\n") & "\n" &
    separator(on, "╰────────────")

proc renderRecord(on: bool, fields: seq[(string, Value)]): string =
  if fields.len == 0: return separator(on, "{}")
  var keyW = 0
  for (k, _) in fields: keyW = max(keyW, k.runeLen)
  var typeHint = ""
  var tv: Value
  if keyFind(fields, "type", tv) and tv.kind == vkString: typeHint = tv.s
  var lines: seq[string]
  for (k, v) in fields:
    let plain = cellPlain(k, v)
    lines.add "  " & key(on, padRight(k, keyW)) & " " & separator(on, "│") &
      " " & colorCellForColumn(on, k, v, plain, typeHint)
  separator(on, "╭──── record ───") & "\n" & lines.join("\n") & "\n" &
    separator(on, "╰──────────────")

proc renderString(on: bool, s: string): string =
  ## External programs often embed their own colors. Pass those through.
  ## Short plain strings still get Nu-style string coloring.
  if containsAnsi(s) or '\n' in s: s else: stringC(on, s)

proc renderWith*(on: bool, v: Value): string =
  ## Render with an explicit color switch (useful for tests / `NO_COLOR`).
  case v.kind
  of vkNothing: ""
  of vkFail: color.error(on, "Error: " & v.msg)
  of vkString: renderString(on, v.s)
  of vkTable: renderTableWith(on, v.columns, v.rows)
  of vkList:
    var allRecords = true
    for it in v.items:
      if it.kind != vkRecord: allRecords = false
    if allRecords:
      let t = tableFromRecords(v.items)
      renderTableWith(on, t.columns, t.rows)
    else:
      renderList(on, v.items)
  of vkRecord: renderRecord(on, v.fields)
  of vkInt:
    # Bare epoch seconds (e.g. `now`) print like the `modified` column.
    if isEpochSeconds(v.i): datetime(on, formatDatetime(v.i))
    else: intC(on, $v.i)
  else: colorCell(on, v, cellString(v))

proc render*(v: Value): string = renderWith(enabled(), v)

proc renderError*(msg: string): string =
  ## Color-friendly error line for the REPL.
  color.error(enabled(), "✗ " & msg)

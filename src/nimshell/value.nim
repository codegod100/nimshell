## Structured values inspired by Nushell — data, not just text streams.

import std/strutils
from std/unicode import runeLen, runeSubStr, runes, Rune, `$`

type
  ValueKind* = enum
    vkNothing, vkBool, vkInt, vkFloat, vkString, vkList, vkRecord, vkTable,
    vkFail

  ## A shell value. Pipelines pass these between commands.
  Value* = object
    case kind*: ValueKind
    of vkNothing: discard
    of vkBool: b*: bool
    of vkInt: i*: int64
    of vkFloat: f*: float
    of vkString: s*: string
    of vkList: items*: seq[Value]
    of vkRecord:
      ## Ordered key/value pairs (column order preserved).
      fields*: seq[(string, Value)]
    of vkTable:
      ## Homogeneous table: column names + rows of values.
      columns*: seq[string]
      rows*: seq[seq[Value]]
    of vkFail:
      ## Runtime failure value (distinct from a raised error).
      msg*: string

  Cmp* = enum
    cmpLt, cmpEq, cmpGt

# --- constructors ---

proc nothing*(): Value = Value(kind: vkNothing)
proc boolV*(b: bool): Value = Value(kind: vkBool, b: b)
proc intV*(i: int64): Value = Value(kind: vkInt, i: i)
proc intV*(i: int): Value = Value(kind: vkInt, i: int64(i))
proc floatV*(f: float): Value = Value(kind: vkFloat, f: f)
proc strV*(s: string): Value = Value(kind: vkString, s: s)
proc listV*(items: seq[Value]): Value = Value(kind: vkList, items: items)
proc recordV*(fields: seq[(string, Value)]): Value =
  Value(kind: vkRecord, fields: fields)
proc tableV*(columns: seq[string], rows: seq[seq[Value]]): Value =
  Value(kind: vkTable, columns: columns, rows: rows)
proc failV*(msg: string): Value = Value(kind: vkFail, msg: msg)

proc `==`*(a, b: Value): bool {.noSideEffect.}

proc `==`*(a, b: Value): bool {.noSideEffect.} =
  ## Structural equality (used by tests and `uniq`-style helpers).
  if a.kind != b.kind: return false
  case a.kind
  of vkNothing: true
  of vkBool: a.b == b.b
  of vkInt: a.i == b.i
  of vkFloat: a.f == b.f
  of vkString: a.s == b.s
  of vkList: a.items == b.items
  of vkRecord: a.fields == b.fields
  of vkTable: a.columns == b.columns and a.rows == b.rows
  of vkFail: a.msg == b.msg

proc isRecord*(v: Value): bool = v.kind == vkRecord

proc typeName*(value: Value): string =
  case value.kind
  of vkNothing: "nothing"
  of vkBool: "bool"
  of vkInt: "int"
  of vkFloat: "float"
  of vkString: "string"
  of vkList: "list"
  of vkRecord: "record"
  of vkTable: "table"
  of vkFail: "error"

proc isTruthy*(value: Value): bool =
  case value.kind
  of vkNothing: false
  of vkBool: value.b
  of vkInt: value.i != 0
  of vkFloat: value.f != 0.0
  of vkString: value.s != ""
  of vkList: value.items.len > 0
  of vkTable: value.rows.len > 0
  of vkFail: false
  of vkRecord: true

proc floatToString*(f: float): string =
  ## `1.0` stays `1.0` (not `1`), matching Gleam's float printing.
  result = $f

proc asString*(value: Value): string =
  case value.kind
  of vkNothing: ""
  of vkBool: (if value.b: "true" else: "false")
  of vkInt: $value.i
  of vkFloat: floatToString(value.f)
  of vkString: value.s
  of vkList:
    var parts: seq[string]
    for it in value.items: parts.add asString(it)
    "[" & parts.join(", ") & "]"
  of vkRecord:
    var parts: seq[string]
    for (k, v) in value.fields: parts.add k & ": " & asString(v)
    "{" & parts.join(", ") & "}"
  of vkTable:
    "table<" & value.columns.join(", ") & "; " & $value.rows.len & " rows>"
  of vkFail: "error: " & value.msg

proc cellString*(value: Value): string =
  ## Compact single-line representation for table cells.
  case value.kind
  of vkNothing: ""
  of vkBool: (if value.b: "true" else: "false")
  of vkInt: $value.i
  of vkFloat: floatToString(value.f)
  of vkString: value.s
  of vkList:
    var parts: seq[string]
    for it in value.items: parts.add cellString(it)
    "[" & parts.join(" ") & "]"
  of vkRecord:
    var parts: seq[string]
    for (k, v) in value.fields: parts.add k & ":" & cellString(v)
    "{" & parts.join(" ") & "}"
  of vkTable:
    "table(" & $value.columns.len & "x" & $value.rows.len & ")"
  of vkFail: "error:" & value.msg

proc keyFind*(fields: seq[(string, Value)], key: string, found: var Value): bool =
  for (k, v) in fields:
    if k == key:
      found = v
      return true
  false

proc getField*(record: Value, name: string): (bool, Value, string) =
  ## Returns (ok, value, error).
  case record.kind
  of vkRecord:
    var v: Value
    if keyFind(record.fields, name, v): (true, v, "")
    else: (false, nothing(), "no field '" & name & "'")
  of vkTable: (false, nothing(), "use 'get' on a row record, not a table")
  else: (false, nothing(), "expected record, got " & typeName(record))

proc parseCellPath*(path: string): (bool, seq[string], string) =
  ## Split a dotted cell path (`"foo.bar"` → `["foo", "bar"]`).
  ## Empty segments (e.g. `"a..b"`) are rejected.
  if path == "": return (false, @[], "empty path")
  let parts = path.split(".")
  for p in parts:
    if p == "":
      return (false, @[], "invalid path '" & path & "' (empty segment)")
  (true, parts, "")

proc tableToRecords*(table: Value): (bool, seq[Value], string)

proc getOne(value: Value, key: string): (bool, Value, string) =
  ## One path segment: field on a record, column on a table, or map over a list.
  case value.kind
  of vkRecord: getField(value, key)
  of vkTable:
    let idx = value.columns.find(key)
    if idx < 0: return (false, nothing(), "no column '" & key & "'")
    var col: seq[Value]
    for row in value.rows:
      col.add(if idx < row.len: row[idx] else: nothing())
    (true, listV(col), "")
  of vkList:
    var col: seq[Value]
    for item in value.items:
      let (ok, v, _) = getField(item, key)
      if ok: col.add v
    (true, listV(col), "")
  else:
    (false, nothing(), "cannot get '" & key & "' from " & typeName(value))

proc getPath*(value: Value, path: seq[string]): (bool, Value, string) =
  ## Follow a Nushell-style cell path through records, lists, and tables.
  ## Dots nest: `{a: {b: 1}} | get a.b` → `1`.
  ## When a list/table is encountered mid-path, the rest of the path is applied
  ## to each item (missing fields are skipped, matching plain `get` on lists).
  if path.len == 0: return (true, value, "")
  let (ok, next, err) = getOne(value, path[0])
  if not ok: return (false, nothing(), err)
  let rest = path[1 .. ^1]
  if rest.len == 0: return (true, next, "")
  case next.kind
  of vkList:
    var outItems: seq[Value]
    for item in next.items:
      let (ok2, v, _) = getPath(item, rest)
      if ok2: outItems.add v
    (true, listV(outItems), "")
  of vkTable:
    let (ok2, rows, err2) = tableToRecords(next)
    if not ok2: return (false, nothing(), err2)
    var outItems: seq[Value]
    for row in rows:
      let (ok3, v, _) = getPath(row, rest)
      if ok3: outItems.add v
    (true, listV(outItems), "")
  else:
    getPath(next, rest)

proc tableFromRecords*(records: seq[Value]): Value =
  ## Build a table from a list of records (union of keys, stable first-seen order).
  if records.len == 0: return tableV(@[], @[])
  var columns: seq[string]
  for rec in records:
    if rec.kind == vkRecord:
      for (k, _) in rec.fields:
        if k notin columns: columns.add k
  var rows: seq[seq[Value]]
  for rec in records:
    var row: seq[Value]
    if rec.kind == vkRecord:
      for col in columns:
        var v: Value
        row.add(if keyFind(rec.fields, col, v): v else: nothing())
    else:
      for _ in columns: row.add rec
    rows.add row
  tableV(columns, rows)

proc zipRow*(cols: seq[string], row: seq[Value]): Value =
  var fields: seq[(string, Value)]
  for i in 0 ..< min(cols.len, row.len):
    fields.add((cols[i], row[i]))
  recordV(fields)

proc tableToRecords*(table: Value): (bool, seq[Value], string) =
  ## Convert a table into a list of records.
  case table.kind
  of vkTable:
    var outRows: seq[Value]
    for row in table.rows: outRows.add zipRow(table.columns, row)
    (true, outRows, "")
  of vkList:
    for v in table.items:
      if v.kind != vkRecord:
        return (false, @[], "list is not a list of records")
    (true, table.items, "")
  of vkRecord: (true, @[table], "")
  else:
    (false, @[], "expected table or list of records, got " & typeName(table))

proc lengthOf*(value: Value): int =
  case value.kind
  of vkNothing: 0
  of vkList: value.items.len
  of vkTable: value.rows.len
  of vkString: value.s.runeLen
  of vkRecord: value.fields.len
  else: 1

proc cmpOrd[T](x, y: T): Cmp =
  if x < y: cmpLt elif x > y: cmpGt else: cmpEq

proc compare*(a, b: Value): (bool, Cmp, string) =
  if a.kind == vkInt and b.kind == vkInt: return (true, cmpOrd(a.i, b.i), "")
  if a.kind == vkFloat and b.kind == vkFloat: return (true, cmpOrd(a.f, b.f), "")
  if a.kind == vkInt and b.kind == vkFloat:
    return (true, cmpOrd(float(a.i), b.f), "")
  if a.kind == vkFloat and b.kind == vkInt:
    return (true, cmpOrd(a.f, float(b.i)), "")
  if a.kind == vkString and b.kind == vkString:
    return (true, cmpOrd(a.s, b.s), "")
  if a.kind == vkBool and b.kind == vkBool:
    return (true, cmpOrd(ord(a.b), ord(b.b)), "")
  (false, cmpEq, "cannot compare " & typeName(a) & " and " & typeName(b))

proc equals*(a, b: Value): bool =
  let (ok, c, _) = compare(a, b)
  if ok: c == cmpEq
  else: asString(a) == asString(b)

proc asRows*(value: Value): seq[Value] =
  ## Try to coerce pipeline input into rows (list of values).
  case value.kind
  of vkNothing: @[]
  of vkList: value.items
  of vkTable:
    var rows: seq[Value]
    for row in value.rows: rows.add zipRow(value.columns, row)
    rows
  else: @[value]

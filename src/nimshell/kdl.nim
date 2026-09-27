## Minimal KDL document parser (enough for config files; no dependencies).
##
## Supports nodes, arguments, `key=value` properties, `{ … }` children, `;`
## terminators, `//` and nested `/* */` comments, `/-` slashdash, `\` line
## continuations, quoted strings with escapes, raw strings (`#"…"#` and v1
## `r#"…"#`), numbers, `#true`/`#false`/`#null` (and v1 bare forms), and
## `(type)` annotations (parsed and ignored). Multi-line `"""` strings are not
## supported.

import std/[strutils, unicode]

type
  KdlKind* = enum kkString, kkNumber, kkBool, kkNull

  KdlVal* = object
    kind*: KdlKind
    str*: string   ## string contents, or the number's source text
    num*: float
    b*: bool

  KdlNode* = object
    name*: string
    args*: seq[KdlVal]
    props*: seq[(string, KdlVal)]
    children*: seq[KdlNode]
    line*: int

  KdlError* = object of CatchableError

  Parser = object
    s: string
    i: int
    line: int

proc `$`*(v: KdlVal): string =
  case v.kind
  of kkString, kkNumber: v.str
  of kkBool: (if v.b: "true" else: "false")
  of kkNull: "null"

proc fail(p: Parser, msg: string) {.noreturn.} =
  raise newException(KdlError, "line " & $p.line & ": " & msg)

proc eof(p: Parser): bool = p.i >= p.s.len
proc cur(p: Parser, off = 0): char =
  if p.i + off < p.s.len: p.s[p.i + off] else: '\0'

proc adv(p: var Parser, n = 1) =
  for _ in 0 ..< n:
    if p.i < p.s.len:
      if p.s[p.i] == '\n': inc p.line
      inc p.i

const
  Newlines = {'\n', '\r', '\f'}
  NonIdent = {'\\', '/', '(', ')', '{', '}', ';', '[', ']', '"', '#', '='} +
             Whitespace + Newlines

proc isIdentChar(c: char): bool = c notin NonIdent and c != '\0'

proc skipBlockComment(p: var Parser) =
  # at "/*"; nests
  var depth = 0
  while not p.eof:
    if p.cur == '/' and p.cur(1) == '*':
      inc depth; p.adv(2)
    elif p.cur == '*' and p.cur(1) == '/':
      dec depth; p.adv(2)
      if depth == 0: return
    else: p.adv
  p.fail("unterminated block comment")

proc skipLineComment(p: var Parser) =
  while not p.eof and p.cur notin Newlines: p.adv

proc skipWs(p: var Parser) =
  ## Inline whitespace, block comments and `\` line continuations.
  while not p.eof:
    let c = p.cur
    if c in {' ', '\t'} or c == '\xEF' and p.s.continuesWith("\xEF\xBB\xBF", p.i):
      p.adv(if c == '\xEF': 3 else: 1)
    elif c == '/' and p.cur(1) == '*': p.skipBlockComment
    elif c == '\\':
      p.adv
      while p.cur in {' ', '\t'}: p.adv
      if p.cur == '/' and p.cur(1) == '/': p.skipLineComment
      if p.cur == '\r': p.adv
      if p.cur in Newlines: p.adv
      elif not p.eof: p.fail("expected newline after line continuation")
    else: return

proc skipLineSpace(p: var Parser) =
  ## Whitespace, newlines and all comments between nodes.
  while not p.eof:
    p.skipWs
    if p.cur in Newlines: p.adv
    elif p.cur == '/' and p.cur(1) == '/': p.skipLineComment
    else: return

proc parseEscape(p: var Parser, res: var string) =
  # at the char after '\'
  let c = p.cur
  p.adv
  case c
  of 'n': res.add '\n'
  of 't': res.add '\t'
  of 'r': res.add '\r'
  of 'b': res.add '\b'
  of 'f': res.add '\f'
  of 's': res.add ' '
  of '\\': res.add '\\'
  of '"': res.add '"'
  of '/': res.add '/'
  of 'u':
    if p.cur != '{': p.fail("expected '{' in \\u escape")
    p.adv
    var hex = ""
    while not p.eof and p.cur != '}': hex.add p.cur; p.adv
    if p.eof or hex.len == 0 or hex.len > 6: p.fail("bad \\u escape")
    p.adv
    try: res.add $Rune(parseHexInt(hex))
    except ValueError: p.fail("bad \\u escape")
  of ' ', '\t', '\n', '\r', '\f':
    # whitespace escape: drop all following whitespace
    while p.cur in Whitespace + Newlines: p.adv
  else: p.fail("unknown escape \\" & c)

proc parseQuoted(p: var Parser): string =
  # at '"'
  p.adv
  while true:
    if p.eof: p.fail("unterminated string")
    let c = p.cur
    if c == '"': p.adv; return
    if c == '\\': p.adv; p.parseEscape(result)
    else: result.add c; p.adv

proc parseRaw(p: var Parser): string =
  # at '#'* '"' (the optional v1 `r` already consumed)
  var hashes = 0
  while p.cur == '#': inc hashes; p.adv
  if p.cur != '"': p.fail("expected '\"' in raw string")
  p.adv
  let close = "\"" & repeat('#', hashes)
  while true:
    if p.eof: p.fail("unterminated raw string")
    if p.s.continuesWith(close, p.i):
      p.adv(close.len); return
    result.add p.cur; p.adv

proc parseBareword(p: var Parser): string =
  while isIdentChar(p.cur): result.add p.cur; p.adv

proc numberVal(p: Parser, t: string): KdlVal =
  let clean = t.replace("_", "")
  result = KdlVal(kind: kkNumber, str: t)
  try:
    let body = if clean.len > 0 and clean[0] in {'+', '-'}: clean[1 .. ^1] else: clean
    let neg = clean.startsWith("-")
    var n: float
    if body.startsWith("0x"): n = float(parseHexInt(body))
    elif body.startsWith("0o"): n = float(parseOctInt(body))
    elif body.startsWith("0b"): n = float(parseBinInt(body))
    else: n = parseFloat(body)
    result.num = if neg: -n else: n
  except ValueError: p.fail("invalid number: " & t)

proc parseTypeAnn(p: var Parser) =
  if p.cur == '(':
    p.adv
    while not p.eof and p.cur != ')': p.adv
    if p.eof: p.fail("unterminated type annotation")
    p.adv

proc parseString(p: var Parser): string =
  ## Identifier-or-string (node names, property keys).
  case p.cur
  of '"': p.parseQuoted
  of '#':
    if p.cur(1) in {'#', '"'}: p.parseRaw
    else: p.fail("unexpected '#'")
  else:
    if p.cur == 'r' and p.cur(1) in {'#', '"'}: p.adv; return p.parseRaw
    let w = p.parseBareword
    if w == "": p.fail("expected identifier, got '" & $p.cur & "'")
    w

proc parseValue(p: var Parser): KdlVal =
  p.parseTypeAnn
  let c = p.cur
  if c == '"': return KdlVal(kind: kkString, str: p.parseQuoted)
  if c == '#' and p.cur(1) in {'#', '"'}: return KdlVal(kind: kkString, str: p.parseRaw)
  if c == 'r' and p.cur(1) in {'#', '"'}:
    p.adv; return KdlVal(kind: kkString, str: p.parseRaw)
  if c == '#': p.adv
  let w = p.parseBareword
  case w
  of "": p.fail("expected value")
  of "true": KdlVal(kind: kkBool, b: true)
  of "false": KdlVal(kind: kkBool, b: false)
  of "null": KdlVal(kind: kkNull)
  of "inf", "-inf", "nan":
    if c != '#': KdlVal(kind: kkString, str: w)
    else: KdlVal(kind: kkNumber, str: w, num: (if w == "inf": Inf elif w == "-inf": NegInf else: NaN))
  else:
    if c == '#': p.fail("unknown keyword #" & w)
    if w[0] in Digits or (w.len > 1 and w[0] in {'+', '-', '.'} and w[1] in Digits):
      p.numberVal(w)
    else: KdlVal(kind: kkString, str: w)

proc parseNodes(p: var Parser, nested: bool): seq[KdlNode]

proc parseNode(p: var Parser): KdlNode =
  ## Parses one node (caller has skipped leading space).
  p.parseTypeAnn
  result.line = p.line
  result.name = p.parseString
  var childrenSeen = false
  while true:
    let before = p.i
    p.skipWs
    if p.eof or p.cur in Newlines or p.cur in {';', '}'}: break
    if p.cur == '/' and p.cur(1) == '/': p.skipLineComment; break
    if p.i == before and not childrenSeen and p.cur != '{':
      p.fail("expected space before entry")
    var skip = false
    if p.cur == '/' and p.cur(1) == '-':
      skip = true; p.adv(2); p.skipLineSpace
    if p.cur == '{':
      p.adv
      let kids = p.parseNodes(nested = true)
      if p.cur != '}': p.fail("expected '}'")
      p.adv
      if not skip:
        if childrenSeen: p.fail("node has more than one children block")
        result.children = kids
        childrenSeen = true
      continue
    if childrenSeen: p.fail("entries after children block")
    # property `key=value` or argument
    let save = p.i
    let saveLine = p.line
    if p.cur notin {'('} and not (p.cur == '#' and p.cur(1) notin {'#', '"'}):
      var key = ""
      try: key = p.parseString
      except KdlError: discard
      if key != "" and p.cur == '=':
        p.adv
        let v = p.parseValue
        if not skip:
          var replaced = false
          for kv in result.props.mitems:
            if kv[0] == key: kv[1] = v; replaced = true
          if not replaced: result.props.add((key, v))
        continue
      p.i = save
      p.line = saveLine
    let v = p.parseValue
    if not skip: result.args.add v
  if p.cur == ';': p.adv

proc parseNodes(p: var Parser, nested: bool): seq[KdlNode] =
  while true:
    p.skipLineSpace
    if p.eof: return
    if p.cur == '}':
      if nested: return
      p.fail("unexpected '}'")
    if p.cur == ';': p.adv; continue
    var skip = false
    if p.cur == '/' and p.cur(1) == '-':
      skip = true; p.adv(2); p.skipLineSpace
    let n = p.parseNode
    if not skip: result.add n

proc parseKdl*(src: string): seq[KdlNode] =
  ## Parse a KDL document. Raises `KdlError` with a line number on bad input.
  var p = Parser(s: src, line: 1)
  result = p.parseNodes(nested = false)
  if not p.eof: p.fail("unexpected '" & $p.cur & "'")

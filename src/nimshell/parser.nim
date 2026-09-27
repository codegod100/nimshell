## Parse tokens into a Nushell-like AST (pipelines of commands).

import std/strutils
import lexer, value

type
  ParseError* = object of CatchableError

  ExprKind* = enum
    exLit, exVar, exList, exRecord

  Expr* = object
    case kind*: ExprKind
    of exLit:
      lit*: Value
      bare*: bool ## unquoted word: a leading `~` expands to home at eval
    of exVar:
      name*: string
      suffix*: string ## path tail glued on at eval: `$HOME/x` → name HOME, suffix `/x`
    of exList: items*: seq[Expr]
    of exRecord: fields*: seq[(string, Expr)]

  ArgKind* = enum
    argValue, ## Literal or evaluated value expression
    argFlag   ## `--flag` or `--flag value`

  Arg* = object
    case kind*: ArgKind
    of argValue: expr*: Expr
    of argFlag:
      flagName*: string
      flagShort*: bool ## written as `-x`/`-fr` rather than `--name`
      hasValue*: bool
      flagValue*: Expr

  Command* = object
    name*: string
    bareName*: bool ## unquoted name: a leading `~` expands to home at eval
    args*: seq[Arg]
    external*: bool

  Pipeline* = object
    commands*: seq[Command]

  StatementKind* = enum
    stLet,       ## `let name = pipeline`
    stEnvAssign, ## `$env.NAME = pipeline` — set a process environment variable
    stExport,    ## `export NAME = pipeline` — set and save to config.kdl
    stExpr       ## Bare pipeline expression

  Statement* = object
    kind*: StatementKind
    name*: string
    pipeline*: Pipeline ## empty for `export NAME` (keep the current value)
    noSave*: bool       ## `export --no-save`: this session only

proc lit*(v: Value, bare = false): Expr = Expr(kind: exLit, lit: v, bare: bare)
proc valueArg*(e: Expr): Arg = Arg(kind: argValue, expr: e)
proc flagArg*(name: string, short = false): Arg =
  Arg(kind: argFlag, flagName: name, flagShort: short)
proc flagArg*(name: string, e: Expr, short = false): Arg =
  Arg(kind: argFlag, flagName: name, flagShort: short, hasValue: true, flagValue: e)

proc `==`*(a, b: Expr): bool {.noSideEffect.}

proc `==`*(a, b: Expr): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of exLit: a.lit == b.lit
  of exVar: a.name == b.name and a.suffix == b.suffix
  of exList: a.items == b.items
  of exRecord: a.fields == b.fields

proc `==`*(a, b: Arg): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of argValue: a.expr == b.expr
  of argFlag:
    a.flagName == b.flagName and a.hasValue == b.hasValue and
      (not a.hasValue or a.flagValue == b.flagValue)

type Cursor = object
  toks: seq[Token]
  pos: int

proc peek(c: Cursor, off = 0): Token =
  let i = c.pos + off
  if i < c.toks.len: c.toks[i] else: tok(tkEof)

proc atEnd(c: Cursor): bool = c.peek.kind == tkEof

proc fail(msg: string) {.noreturn.} =
  raise newException(ParseError, msg)

proc tokenName(t: Token): string =
  case t.kind
  of tkIdent: "ident(" & t.text & ")"
  of tkStringLit: "string"
  of tkIntLit: "int"
  of tkFloatLit: "float"
  of tkBoolLit: "bool"
  of tkPipe: "|"
  of tkFlag: (if t.short: "-" else: "--") & t.text
  of tkEof: "eof"
  of tkAssign: "="
  of tkEq: "=="
  of tkNe: "!="
  of tkGt: ">"
  of tkLt: "<"
  of tkGe: ">="
  of tkLe: "<="
  of tkExternal: "^"
  else: "token"

proc isExprStart(c: Cursor): bool =
  c.peek.kind in {tkStringLit, tkIntLit, tkFloatLit, tkBoolLit, tkNothingLit,
                  tkLBracket, tkLBrace, tkDollar, tkIdent}

proc parseExpr(c: var Cursor): Expr

proc parseList(c: var Cursor): Expr =
  var items: seq[Expr]
  while true:
    case c.peek.kind
    of tkRBracket:
      inc c.pos
      return Expr(kind: exList, items: items)
    of tkComma: inc c.pos
    else: items.add parseExpr(c)

proc parseRecord(c: var Cursor): Expr =
  var fields: seq[(string, Expr)]
  while true:
    let t = c.peek
    case t.kind
    of tkRBrace:
      inc c.pos
      return Expr(kind: exRecord, fields: fields)
    of tkComma: inc c.pos
    of tkIdent, tkStringLit:
      if c.peek(1).kind != tkColon:
        fail("expected record field `name: value` or `}`")
      c.pos += 2
      fields.add((t.text, parseExpr(c)))
    else: fail("expected record field `name: value` or `}`")

proc parseExpr(c: var Cursor): Expr =
  let t = c.peek
  case t.kind
  of tkStringLit: inc c.pos; lit(strV(t.text))
  of tkIntLit: inc c.pos; lit(intV(t.intVal))
  of tkFloatLit: inc c.pos; lit(floatV(t.floatVal))
  of tkBoolLit: inc c.pos; lit(boolV(t.boolVal))
  of tkNothingLit: inc c.pos; lit(nothing())
  of tkDollar:
    let n = c.peek(1)
    if n.kind != tkIdent: fail("expected variable name after $")
    c.pos += 2
    # `/` is a word char for paths, so `$HOME/x` lexes as one ident; the
    # variable name stops at the first `/` and the rest is a path suffix.
    let slash = n.text.find('/')
    if slash == 0: fail("expected variable name after $")
    if slash > 0:
      Expr(kind: exVar, name: n.text[0 ..< slash], suffix: n.text[slash .. ^1])
    else:
      Expr(kind: exVar, name: n.text)
  of tkLBracket: inc c.pos; parseList(c)
  of tkLBrace: inc c.pos; parseRecord(c)
  of tkIdent: inc c.pos; lit(strV(t.text), bare = true)
  else: fail("expected expression")

proc parseColonAtom(c: var Cursor, piece: var string): bool =
  ## Token after `:` in a bareword: number, ident/path, string, or bool.
  let t = c.peek
  case t.kind
  of tkIntLit: piece = $t.intVal
  of tkFloatLit: piece = floatToString(t.floatVal)
  of tkStringLit, tkIdent: piece = t.text
  of tkBoolLit: piece = (if t.boolVal: "true" else: "false")
  else: return false
  inc c.pos
  true

proc isSimpleBareLit(e: Expr): bool =
  e.kind == exLit and e.lit.kind in {vkString, vkInt, vkFloat, vkBool}

proc glueColonSuffix(e: Expr, c: var Cursor): Expr =
  ## Absorb adjacent `:atom` tails into one bareword (`host:4004`, `http://x`).
  ## Colon is a separate lexer token (records need it), so argv words
  ## reassemble here.
  result = e
  while c.peek.kind == tkColon and isSimpleBareLit(result):
    let head = asString(result.lit)
    inc c.pos
    var piece: string
    if parseColonAtom(c, piece):
      result = lit(strV(head & ":" & piece), e.bare)
    else:
      return lit(strV(head & ":"), e.bare)

proc parseArgs(c: var Cursor): seq[Arg] =
  while true:
    let t = c.peek
    case t.kind
    of tkEof, tkPipe: return
    of tkFlag:
      inc c.pos
      if t.text == "":
        # Bare `--` → literal argv element, not a named flag.
        result.add valueArg(lit(strV("--")))
      elif isExprStart(c):
        let e = glueColonSuffix(parseExpr(c), c)
        result.add flagArg(t.text, e, t.short)
      else:
        result.add flagArg(t.text, t.short)
    # Comparison operators as bare string args (for `where field == value`)
    of tkEq, tkAssign: inc c.pos; result.add valueArg(lit(strV("==")))
    of tkNe: inc c.pos; result.add valueArg(lit(strV("!=")))
    of tkGt: inc c.pos; result.add valueArg(lit(strV(">")))
    of tkLt: inc c.pos; result.add valueArg(lit(strV("<")))
    of tkGe: inc c.pos; result.add valueArg(lit(strV(">=")))
    of tkLe: inc c.pos; result.add valueArg(lit(strV("<=")))
    of tkColon:
      # Port specs / URL pieces: `:4004`, `://host` (Colon is reserved for records).
      inc c.pos
      var piece: string
      if parseColonAtom(c, piece):
        result.add valueArg(lit(strV(":" & piece)))
      else:
        result.add valueArg(lit(strV(":")))
    else:
      if isExprStart(c):
        result.add valueArg(glueColonSuffix(parseExpr(c), c))
      else:
        return

proc parseCommand(c: var Cursor): Command =
  let t = c.peek
  case t.kind
  of tkExternal:
    let n = c.peek(1)
    if n.kind != tkIdent: fail("expected command name")
    c.pos += 2
    Command(name: n.text, bareName: true, args: parseArgs(c), external: true)
  of tkIdent, tkStringLit:
    inc c.pos
    Command(name: t.text, bareName: t.kind == tkIdent, args: parseArgs(c),
            external: false)
  # Bare value as pipeline stage: `$env`, `$x`, `[1 2]`, `{a: 1}`, …
  # Becomes internal `__value__` that yields the expression.
  of tkDollar, tkLBracket, tkLBrace, tkIntLit, tkFloatLit, tkBoolLit,
     tkNothingLit:
    Command(name: "__value__", args: @[valueArg(parseExpr(c))])
  of tkEof: fail("expected command")
  else: fail("expected command name")

proc parsePipeline(c: var Cursor): Pipeline =
  result.commands.add parseCommand(c)
  while c.peek.kind == tkPipe:
    inc c.pos
    result.commands.add parseCommand(c)

proc parseAssignRhs(c: var Cursor): Pipeline =
  ## RHS of `$env.NAME = …`: a single expression becomes a value stage so bare
  ## words are strings (`$env.FOO = hello`); otherwise a full pipeline
  ## (`$env.FOO = range 3`, `$env.FOO = echo hi`).
  if isExprStart(c):
    let save = c.pos
    try:
      let e = parseExpr(c)
      if c.atEnd:
        return Pipeline(commands: @[Command(name: "__value__",
                                            args: @[valueArg(e)])])
    except ParseError:
      discard
    c.pos = save
  parsePipeline(c)

proc isEnvName*(s: string): bool =
  ## Portable environment variable name: `[A-Za-z_][A-Za-z0-9_]*`.
  s.len > 0 and s[0] in IdentStartChars and s.allCharsInSet(IdentChars)

proc parseExport(c: var Cursor): Statement =
  ## `export [-n|--no-save] NAME [= value…]` (`NAME=value` lexes the same).
  const usage = "usage: export [--no-save] NAME = value"
  inc c.pos
  result = Statement(kind: stExport)
  while c.peek.kind == tkFlag:
    let f = c.peek.text
    if f notin ["n", "no-save"]: fail("export: unknown flag `" & f & "` (" & usage & ")")
    result.noSave = true
    inc c.pos
  let t = c.peek
  if t.kind notin {tkIdent, tkStringLit}: fail("export: expected a variable name (" & usage & ")")
  if not isEnvName(t.text): fail("export: invalid variable name `" & t.text & "`")
  result.name = t.text
  inc c.pos
  if c.atEnd: return
  if c.peek.kind != tkAssign: fail("export: expected `=` after " & t.text & " (" & usage & ")")
  inc c.pos
  if c.atEnd: fail("export: expected a value after `=`")
  result.pipeline = parseAssignRhs(c)

proc parseStatement(c: var Cursor): Statement =
  let t0 = c.peek
  if t0.kind == tkIdent and t0.text == "export": return parseExport(c)
  let t1 = c.peek(1)
  let t2 = c.peek(2)
  if t0.kind == tkIdent and t0.text == "let" and t1.kind == tkIdent and
      t2.kind == tkAssign:
    c.pos += 3
    return Statement(kind: stLet, name: t1.text, pipeline: parsePipeline(c))
  if t0.kind == tkDollar and t1.kind == tkIdent and t2.kind == tkAssign:
    # `$env.NAME = …` (Nushell-style process env assignment)
    if t1.text.startsWith("env."):
      let key = t1.text[4 .. ^1]
      if key == "": fail("expected environment variable name after $env.")
      c.pos += 3
      return Statement(kind: stEnvAssign, name: key, pipeline: parseAssignRhs(c))
    if t1.text == "PATH":
      # `$PATH = …` — shorthand for `$env.PATH = …`
      c.pos += 3
      return Statement(kind: stEnvAssign, name: t1.text, pipeline: parseAssignRhs(c))
    fail("only `$env.NAME = …` assignment is supported (use `let name = …` for shell vars)")
  Statement(kind: stExpr, pipeline: parsePipeline(c))

proc parse*(source: string, stmt: var Statement, err: var string): bool =
  var toks: seq[Token]
  var lexErr: LexError
  if not tokenize(source, toks, lexErr):
    err = "lex error at " & $lexErr.position & ": " & lexErr.message
    return false
  var c = Cursor(toks: toks)
  try:
    stmt = parseStatement(c)
  except ParseError as e:
    err = e.msg
    return false
  if not c.atEnd:
    var names: seq[string]
    for i in c.pos ..< min(c.pos + 5, toks.len): names.add tokenName(toks[i])
    err = "unexpected tokens after statement: " & names.join(", ")
    return false
  true

## Tokenize shell input.

import std/strutils
from std/unicode import runeLen, runeSubStr, runes, Rune, `$`

type
  TokenKind* = enum
    tkIdent, tkStringLit, tkIntLit, tkFloatLit, tkBoolLit, tkPipe, tkLBracket,
    tkRBracket, tkLBrace, tkRBrace, tkLParen, tkRParen, tkColon, tkComma,
    tkDollar, tkEq, tkNe, tkGt, tkLt, tkGe, tkLe, tkAssign, tkFlag, tkExternal,
    tkNothingLit, tkEof

  Token* = object
    case kind*: TokenKind
    of tkIdent, tkStringLit, tkFlag: text*: string
    of tkIntLit: intVal*: int64
    of tkFloatLit: floatVal*: float
    of tkBoolLit: boolVal*: bool
    else: discard

  LexError* = object
    message*: string
    position*: int

proc tok*(kind: TokenKind): Token = Token(kind: kind)
proc ident*(s: string): Token = Token(kind: tkIdent, text: s)
proc strLit*(s: string): Token = Token(kind: tkStringLit, text: s)
proc flag*(s: string): Token = Token(kind: tkFlag, text: s)
proc intLit*(n: int64): Token = Token(kind: tkIntLit, intVal: n)
proc floatLit*(f: float): Token = Token(kind: tkFloatLit, floatVal: f)
proc boolLit*(b: bool): Token = Token(kind: tkBoolLit, boolVal: b)

proc `==`*(a, b: Token): bool =
  if a.kind != b.kind: return false
  case a.kind
  of tkIdent, tkStringLit, tkFlag: a.text == b.text
  of tkIntLit: a.intVal == b.intVal
  of tkFloatLit: a.floatVal == b.floatVal
  of tkBoolLit: a.boolVal == b.boolVal
  else: true

proc `$`*(t: Token): string =
  case t.kind
  of tkIdent: "Ident(" & t.text & ")"
  of tkStringLit: "StringLit(" & t.text & ")"
  of tkFlag: "Flag(" & t.text & ")"
  of tkIntLit: "IntLit(" & $t.intVal & ")"
  of tkFloatLit: "FloatLit(" & $t.floatVal & ")"
  of tkBoolLit: "BoolLit(" & $t.boolVal & ")"
  else: $t.kind

proc chars*(s: string): seq[string] =
  ## Split into one string per code point (the unit the lexer walks).
  for r in s.runes: result.add $r

proc isDigit*(c: string): bool =
  c.len == 1 and c[0] in {'0' .. '9'}

proc isIdentStart*(c: string): bool =
  # Paths: `.jj`, `..`, `./src`, `/tmp`, `~/code`
  c.len == 1 and c[0] in {'a' .. 'z', 'A' .. 'Z', '_', '.', '/', '~'}

proc isIdentContinue*(c: string): bool =
  # Path-ish chars: letters/digits already covered; keep `.` `/` `-` `~` mid-token.
  # `#` mid-token for flake refs (`nixpkgs#hello`, `.#package`); bare `#` still
  # starts a comment at a word boundary (handled in tokenize).
  # `@` mid-token for SSH/git URLs (`git@host:path`, `user@host`).
  isIdentStart(c) or isDigit(c) or c == "-" or c == "#" or c == "@"

proc at(cs: seq[string], i: int): string {.inline.} =
  if i < cs.len: cs[i] else: ""

proc readIdentBody(cs: seq[string], i: var int): string =
  while i < cs.len and isIdentContinue(cs[i]):
    result.add cs[i]
    inc i

proc readNumber(cs: seq[string], i: var int): string =
  if at(cs, i) == "-":
    result.add "-"
    inc i
  while i < cs.len and (isDigit(cs[i]) or cs[i] == "."):
    result.add cs[i]
    inc i

proc parseNumber(s: string, tok: var Token): string =
  ## Returns an error message, or "" on success.
  if '.' in s:
    try:
      tok = floatLit(parseFloat(s))
    except ValueError:
      return "invalid float '" & s & "'"
  else:
    try:
      tok = intLit(parseBiggestInt(s))
    except ValueError:
      return "invalid integer '" & s & "'"
  ""

proc keywordOrIdent(name: string): Token =
  case name
  of "true", "True": boolLit(true)
  of "false", "False": boolLit(false)
  of "null", "nothing", "Nothing": tok(tkNothingLit)
  else: ident(name)

proc tokenize*(source: string, tokens: var seq[Token], err: var LexError): bool =
  ## Tokenize `source`. Returns false and fills `err` on failure.
  let cs = chars(source)
  var i = 0
  tokens = @[]
  while i < cs.len:
    let c = cs[i]
    let n = at(cs, i + 1)
    case c
    of " ", "\t", "\r", "\n": inc i
    of "#":
      while i < cs.len and cs[i] != "\n": inc i
    of "|": tokens.add tok(tkPipe); inc i
    of "[": tokens.add tok(tkLBracket); inc i
    of "]": tokens.add tok(tkRBracket); inc i
    of "{": tokens.add tok(tkLBrace); inc i
    of "}": tokens.add tok(tkRBrace); inc i
    of "(": tokens.add tok(tkLParen); inc i
    of ")": tokens.add tok(tkRParen); inc i
    of ":": tokens.add tok(tkColon); inc i
    of ",": tokens.add tok(tkComma); inc i
    of "$": tokens.add tok(tkDollar); inc i
    of "^": tokens.add tok(tkExternal); inc i
    of "!", ">", "<", "=":
      if n == "=":
        tokens.add tok(case c
          of "!": tkNe
          of ">": tkGe
          of "<": tkLe
          else: tkEq)
        i += 2
      elif c == "=": tokens.add tok(tkAssign); inc i
      elif c == ">": tokens.add tok(tkGt); inc i
      elif c == "<": tokens.add tok(tkLt); inc i
      else:
        err = LexError(message: "unexpected character '!'", position: i)
        return false
    of "\"":
      let start = i
      inc i
      var s = ""
      var closed = false
      while i < cs.len:
        let ch = cs[i]
        if ch == "\"":
          closed = true; inc i; break
        elif ch == "\\" and i + 1 < cs.len:
          let e = cs[i + 1]
          s.add(case e
            of "n": "\n"
            of "t": "\t"
            else: e)
          i += 2
        else:
          s.add ch; inc i
      if not closed:
        err = LexError(message: "unterminated string", position: max(i, start))
        return false
      tokens.add strLit(s)
    of "'":
      let start = i
      inc i
      var s = ""
      var closed = false
      while i < cs.len:
        let ch = cs[i]
        if ch == "'":
          closed = true; inc i; break
        elif ch == "\\" and (at(cs, i + 1) == "'" or at(cs, i + 1) == "\\"):
          s.add cs[i + 1]; i += 2
        else:
          s.add ch; inc i
      if not closed:
        err = LexError(message: "unterminated string", position: max(i, start))
        return false
      tokens.add strLit(s)
    of "-":
      if n == "-":
        i += 2
        # Bare `--` is the POSIX end-of-options marker (`nix run . -- args`);
        # an empty flag name is parsed as a literal `"--"` argument.
        tokens.add flag(readIdentBody(cs, i))
      elif isDigit(n):
        let pos = i
        let numStr = readNumber(cs, i)
        var t: Token
        let msg = parseNumber(numStr, t)
        if msg != "":
          err = LexError(message: msg, position: pos)
          return false
        tokens.add t
      else:
        # short flag -x
        let pos = i
        inc i
        let name = readIdentBody(cs, i)
        if name == "":
          err = LexError(message: "expected flag name after -", position: pos)
          return false
        tokens.add flag(name)
    else:
      if isDigit(c):
        let pos = i
        let numStr = readNumber(cs, i)
        var t: Token
        let msg = parseNumber(numStr, t)
        if msg != "":
          err = LexError(message: msg, position: pos)
          return false
        tokens.add t
      elif isIdentStart(c):
        tokens.add keywordOrIdent(readIdentBody(cs, i))
      else:
        err = LexError(message: "unexpected character '" & c & "'", position: i)
        return false
  tokens.add tok(tkEof)
  true

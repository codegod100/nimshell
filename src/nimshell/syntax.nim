## File language detection and syntax highlighting for `cat`.
##
## Truecolor palette + bat-style gutters. Highlighters are lightweight pure
## Nim — not a full syntect replacement; unknown languages stay plain text
## (still get line numbers when framed).

import std/[os, strutils]
from std/unicode import runes, Rune
import lexer

type
  Language* = enum
    Plain, Json, Gleam, Nim, Toml, Markdown

# Catppuccin Mocha–inspired truecolor roles (file syntax only; REPL shapes stay
# on the classic Nu 16-color palette in `color.nim`).
const
  reset = "\e[0m"
  cKeyword = "\e[1;38;2;203;166;247m"  ## Mauve — keywords
  cString = "\e[38;2;166;227;161m"     ## Soft green — string values
  cKey = "\e[1;38;2;137;220;235m"      ## Sky — keys, attributes, accents
  cNumber = "\e[38;2;250;179;135m"     ## Peach — numbers
  cBool = "\e[1;38;2;148;226;213m"     ## Teal — bools / null
  cComment = "\e[3;38;2;108;112;134m"  ## Overlay0 italic — comments
  cType = "\e[1;38;2;249;226;175m"     ## Yellow — types / section headers
  cFn = "\e[1;38;2;137;180;250m"       ## Blue — function names
  cOp = "\e[38;2;245;194;231m"         ## Pink — operators / punctuation pop
  cDim = "\e[38;2;108;112;134m"        ## Subtext0 — dim punctuation, gutters
  cH1 = "\e[1;38;2;180;190;254m"       ## Lavender — markdown H1
  cH2 = "\e[1;38;2;137;180;250m"       ## Blue — markdown H2
  cH3 = "\e[1;38;2;116;199;236m"       ## Sapphire — markdown H3+
  cCode = "\e[38;2;166;227;161m"       ## Green — inline/fence code
  cCodeBg = "\e[48;2;49;50;68m"        ## Surface0 background for code
  cBold = "\e[1;38;2;250;179;135m"     ## Peach bold — markdown bold
  cQuote = "\e[3;38;2;148;226;213m"    ## Italic soft — blockquotes
  cLink = "\e[4;38;2;137;220;235m"     ## Underline sky — links
  cBullet = "\e[1;38;2;235;160;172m"   ## Maroon — list bullets

proc syn(code, text: string): string = code & text & reset

# =============================================================================
# Public API
# =============================================================================

proc languageFromName*(name: string, lang: var Language): bool =
  ## Parse a language name (`json`, `gleam`, `nim`, `md`, …).
  case name.toLowerAscii
  of "plain", "text", "txt": lang = Plain
  of "json": lang = Json
  of "gleam": lang = Gleam
  of "nim", "nims", "nimble": lang = Nim
  of "toml": lang = Toml
  of "md", "markdown": lang = Markdown
  else: return false
  true

proc languageName*(lang: Language): string =
  case lang
  of Plain: "plain"
  of Json: "json"
  of Gleam: "gleam"
  of Nim: "nim"
  of Toml: "toml"
  of Markdown: "markdown"

proc languageFromPath*(path: string): Language =
  ## Guess language from a file path (extension only).
  let ext = path.splitFile.ext
  if ext.len > 1 and languageFromName(ext[1 .. ^1], result): return
  Plain

proc sniffPlain(content: string): Language =
  let trimmed = content.strip(trailing = false)
  if trimmed.startsWith("{") or trimmed.startsWith("["): Json
  elif trimmed.startsWith("---"): Markdown
  elif trimmed.startsWith("# ") or trimmed.startsWith("## "): Markdown
  else: Plain

proc detect*(path, content: string): Language =
  ## Refine a path-based guess with a light content sniff.
  result = languageFromPath(path)
  if result == Plain: result = sniffPlain(content)

proc isBinary*(content: string): bool =
  ## True when content looks non-text (NUL bytes or high control-char ratio).
  if '\0' in content: return true
  var n, bad = 0
  for r in content.runes:
    if n >= 8192: break
    inc n
    let code = int(r)
    if (code < 32 and code notin [9, 10, 13]) or code == 127: inc bad
  n > 0 and bad * 10 > n * 3

# =============================================================================
# Shared helpers (walk code points as strings)
# =============================================================================

type Src = object
  cs: seq[string]
  i: int

proc cur(s: Src, off = 0): string =
  let j = s.i + off
  if j < s.cs.len: s.cs[j] else: ""

proc done(s: Src): bool = s.i >= s.cs.len

proc isAlpha(c: string): bool = c.len == 1 and c[0] in {'a' .. 'z', 'A' .. 'Z'}
proc isSIdentStart(c: string): bool = isAlpha(c) or c == "_"
proc isSIdentContinue(c: string): bool = isSIdentStart(c) or isDigit(c)
proc isWs(c: string): bool = c in [" ", "\t", "\n", "\r"]

proc takeWhile(s: var Src, pred: proc(c: string): bool): string =
  while not s.done and pred(s.cur):
    result.add s.cur
    inc s.i

proc takeIdent(s: var Src): string = takeWhile(s, isSIdentContinue)

proc takeNumber(s: var Src): string =
  if s.cur == "-":
    result = "-"
    inc s.i
    if not isDigit(s.cur): return
  while not s.done:
    let c = s.cur
    if isDigit(c) or c in [".", "e", "E", "_", "x", "X"] or
        (result.startsWith("0x") and c.len == 1 and c[0] in HexDigits):
      result.add c; inc s.i
    elif (c == "+" or c == "-") and (result.endsWith("e") or result.endsWith("E")):
      result.add c; inc s.i
    else: break

proc takeQuoted(s: var Src, q: string): string =
  ## Assumes the opening quote was consumed; returns it plus body + close.
  result = q
  while not s.done:
    let c = s.cur
    if c == q:
      result.add c; inc s.i; return
    if c == "\\" and s.i + 1 < s.cs.len:
      result.add c & s.cur(1); s.i += 2
    else:
      result.add c; inc s.i

proc takeLineRest(s: var Src, prefix: string): string =
  result = prefix
  while not s.done and s.cur != "\n" and s.cur != "\r":
    result.add s.cur; inc s.i

proc peekNonWs(s: Src): string =
  var j = s.i
  while j < s.cs.len and isWs(s.cs[j]): inc j
  if j < s.cs.len: s.cs[j] else: ""

# =============================================================================
# JSON — keys (sky) vs string values (green)
# =============================================================================

proc paintJson(content: string): string =
  var s = Src(cs: chars(content))
  while not s.done:
    let c = s.cur
    if isWs(c):
      result.add c; inc s.i
    elif c == "\"":
      inc s.i
      let str = takeQuoted(s, "\"")
      result.add syn(if peekNonWs(s) == ":": cKey else: cString, str)
    elif c in ["{", "}", "[", "]"]:
      result.add syn(cOp, c); inc s.i
    elif c in [":", ","]:
      result.add syn(cDim, c); inc s.i
    elif isDigit(c) or c == "-":
      result.add syn(cNumber, takeNumber(s))
    elif isSIdentStart(c):
      let w = takeIdent(s)
      result.add(if w in ["true", "false", "null"]: syn(cBool, w) else: w)
    else:
      result.add c; inc s.i

# =============================================================================
# TOML — section headers, keys, rich values
# =============================================================================

proc paintToml(content: string): string =
  var s = Src(cs: chars(content))
  while not s.done:
    let c = s.cur
    if isWs(c):
      result.add c; inc s.i
    elif c == "#":
      inc s.i
      result.add syn(cComment, takeLineRest(s, "#"))
    elif c == "[":
      inc s.i
      var body = "["
      while not s.done:
        let ch = s.cur
        body.add ch; inc s.i
        if ch == "]": break
      result.add syn(cType, body)
    elif c == "\"" or c == "'":
      inc s.i
      result.add syn(cString, takeQuoted(s, c))
    elif c == "=":
      result.add syn(cOp, c); inc s.i
    elif c in [",", "."]:
      result.add syn(cDim, c); inc s.i
    elif isDigit(c) or c == "-":
      result.add syn(cNumber, takeNumber(s))
    elif isSIdentStart(c):
      let w = takeIdent(s)
      result.add(if w in ["true", "false"]: syn(cBool, w) else: syn(cKey, w))
    else:
      result.add c; inc s.i

# =============================================================================
# Code (Gleam / Nim) — keywords, types, fn names, attributes, comments
# =============================================================================

const gleamKeywords = ["as", "assert", "auto", "case", "const", "delegate",
  "derive", "echo", "else", "fn", "if", "implement", "import", "let", "macro",
  "opaque", "panic", "pub", "test", "todo", "type", "use"]

const nimKeywords = ["addr", "and", "as", "asm", "bind", "block", "break",
  "case", "cast", "concept", "const", "continue", "converter", "defer",
  "discard", "distinct", "div", "do", "elif", "else", "end", "enum", "except",
  "export", "finally", "for", "from", "func", "if", "import", "in", "include",
  "interface", "is", "isnot", "iterator", "let", "macro", "method", "mixin",
  "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc", "ptr",
  "raise", "ref", "return", "shl", "shr", "static", "template", "try", "tuple",
  "type", "using", "var", "when", "while", "xor", "yield"]

const opChars = ["(", ")", "[", "]", "{", "}", ",", ".", ":", ";", "|", "=",
  ">", "<", "!", "+", "-", "*", "/", "%", "#", "&", "^", "~", "@", "$", "?"]

proc isTypeName(w: string): bool =
  w.len > 0 and w[0] in {'A' .. 'Z'}

proc paintCode(content: string, lang: Language): string =
  let isNim = lang == Nim
  var s = Src(cs: chars(content))
  var afterFn = false
  var afterAt = false
  while not s.done:
    let c = s.cur
    # comments
    if not isNim and c == "/" and s.cur(1) == "/":
      s.i += 2
      result.add syn(cComment, takeLineRest(s, "//"))
      continue
    if isNim and c == "#":
      inc s.i
      result.add syn(cComment, takeLineRest(s, "#"))
      continue
    if isWs(c):
      result.add c; inc s.i
    elif c == "\"":
      inc s.i
      result.add syn(cString, takeQuoted(s, "\""))
      afterFn = false
    elif isNim and c == "'" and s.cur(2) == "'":
      result.add syn(cString, c & s.cur(1) & s.cur(2)); s.i += 3
    elif not isNim and c == "@":
      result.add syn(cOp, "@"); inc s.i
      afterAt = true
    elif isNim and c == "{" and s.cur(1) == ".":
      # pragma `{. … .}`
      var body = ""
      while not s.done:
        body.add s.cur; inc s.i
        if body.endsWith(".}"): break
      result.add syn(cKey, body)
    elif isDigit(c):
      result.add syn(cNumber, takeNumber(s))
      afterFn = false
    elif isSIdentStart(c):
      let w = takeIdent(s)
      if afterFn:
        result.add syn(cFn, w)
        afterFn = false
      elif afterAt:
        result.add syn(cKey, w)
        afterAt = false
      elif (not isNim and w in gleamKeywords) or (isNim and w in nimKeywords):
        result.add syn(cKeyword, w)
        afterFn = if isNim: w in ["proc", "func", "method", "iterator",
                                  "template", "macro", "converter"]
                  else: w == "fn"
      elif w in ["True", "False", "true", "false"]:
        result.add syn(cBool, w)
      elif w == "Nil":
        result.add syn(cDim, w)
      elif isTypeName(w):
        result.add syn(cType, w)
      else:
        result.add w
    elif c in opChars:
      result.add syn(cOp, c); inc s.i
      afterFn = false
    else:
      result.add c; inc s.i
      afterFn = false

# =============================================================================
# Markdown — leveled headings, fences, quotes, inline spice
# =============================================================================

proc headingLevel(trimmed: string): int =
  for lvl in countdown(6, 1):
    if trimmed.startsWith("#".repeat(lvl) & " "): return lvl
  0

proc isHr(trimmed: string): bool =
  let cs = chars(trimmed)
  if cs.len < 3: return false
  var marks = 0
  for c in cs:
    if c notin ["-", "*", "_", " "]: return false
    if c != " ": inc marks
  marks > 0

proc isFenceLine(trimmed: string): bool =
  trimmed.startsWith("```") or trimmed.startsWith("~~~")

proc takeUntil(cs: seq[string], i: var int, stop: string): (string, bool) =
  var acc = ""
  while i < cs.len:
    if cs[i] == stop:
      inc i
      return (acc, true)
    acc.add cs[i]; inc i
  (acc, false)

proc takeUntilPair(cs: seq[string], i: var int, stop: string): (string, bool) =
  var acc = ""
  while i < cs.len:
    if cs[i] == stop and i + 1 < cs.len and cs[i + 1] == stop:
      i += 2
      return (acc, true)
    acc.add cs[i]; inc i
  (acc, false)

proc paintMdChars(text: string): string =
  let cs = chars(text)
  var i = 0
  while i < cs.len:
    let c = cs[i]
    let n = if i + 1 < cs.len: cs[i + 1] else: ""
    if c == "`":
      inc i
      let (code, closed) = takeUntil(cs, i, "`")
      result.add(if closed: cCodeBg & syn(cCode, "`" & code & "`")
                 else: syn(cCode, "`" & code))
    elif (c == "*" and n == "*") or (c == "_" and n == "_"):
      i += 2
      let (body, closed) = takeUntilPair(cs, i, c)
      result.add(if closed: syn(cBold, c & c & body & c & c) else: c & c & body)
    elif c == "*":
      inc i
      let (body, closed) = takeUntil(cs, i, "*")
      result.add(if closed: syn(cQuote, "*" & body & "*") else: "*" & body)
    elif c == "[":
      var j = i + 1
      let (label, okLabel) = takeUntil(cs, j, "]")
      if okLabel and j < cs.len and cs[j] == "(":
        inc j
        let (url, okUrl) = takeUntil(cs, j, ")")
        if okUrl:
          result.add syn(cLink, "[" & label & "]") & syn(cDim, "(" & url & ")")
          i = j
          continue
      result.add "["
      inc i
    else:
      result.add c
      inc i

proc splitListMarker(line: string): (string, string) =
  var j = 0
  while j < line.len and line[j] in {' ', '\t'}: inc j
  let indent = line[0 ..< j]
  let rest = line[j .. ^1]
  if rest.len >= 2 and rest[0] in {'-', '*', '+'} and rest[1] == ' ':
    return (indent & syn(cBullet, rest[0 .. 1]), rest[2 .. ^1])
  var k = 0
  while k < rest.len and rest[k] in Digits: inc k
  if k > 0 and k + 1 < rest.len and rest[k] == '.' and rest[k + 1] == ' ':
    return (indent & syn(cBullet, rest[0 .. k + 1]), rest[k + 2 .. ^1])
  ("", line)

proc paintMarkdownLine(line, trimmed: string): string =
  let lvl = headingLevel(trimmed)
  if lvl == 1: syn(cH1, line)
  elif lvl == 2: syn(cH2, line)
  elif lvl > 2: syn(cH3, line)
  elif isHr(trimmed): syn(cDim, line)
  elif trimmed.startsWith("> ") or trimmed == ">": syn(cQuote, line)
  else:
    let (prefix, rest) = splitListMarker(line)
    prefix & paintMdChars(rest)

proc paintMarkdown(content: string): string =
  var outLines: seq[string]
  var inFence = false
  for line in content.split("\n"):
    let trimmed = line.strip(trailing = false)
    if isFenceLine(trimmed):
      outLines.add syn(cDim, line)
      inFence = not inFence
    elif inFence:
      outLines.add cCodeBg & syn(cCode, line) & reset
    else:
      outLines.add paintMarkdownLine(line, trimmed)
  outLines.join("\n")

# =============================================================================
# Public painting
# =============================================================================

proc paint*(on: bool, language: Language, content: string): string =
  ## Syntax-color `content` for `language` when `on` is true (no gutters).
  if not on: return content
  case language
  of Plain: content
  of Json: paintJson(content)
  of Gleam, Nim: paintCode(content, language)
  of Toml: paintToml(content)
  of Markdown: paintMarkdown(content)

proc frame*(path: string, language: Language, body: string): string =
  ## Bat-style header + numbered gutter around already-colored (or plain) body.
  var lines = body.split("\n")
  # Trailing newline → final empty segment; drop it so we don't show an extra row.
  if lines.len > 0 and lines[^1] == "": lines.setLen(lines.len - 1)
  let width = len($max(lines.len, 1))
  let rule = "─".repeat(max(width + 24, 40))
  let header = syn(cDim, "──") & syn(cKey, " " & path.extractFilename & " ") &
    syn(cDim, "──") & syn(cType, " " & languageName(language) & " ") &
    syn(cDim, "─".repeat(12))
  var numbered: seq[string]
  for i, line in lines:
    numbered.add syn(cDim, " " & align($(i + 1), width) & " ") & syn(cDim, "│") &
      " " & line
  header & "\n" & numbered.join("\n") & "\n" & syn(cDim, rule)

proc present*(on: bool, language: Language, path, content: string): string =
  ## Full `cat` presentation: syntax paint + bat-style header and line gutter.
  if not on: content
  else: frame(path, language, paint(true, language, content))

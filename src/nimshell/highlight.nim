## Live syntax highlighting for the REPL input line (Nushell-style shapes).

import color, builtins, lexer

type Expect = enum
  ExpectCommand, ExpectArg

proc highlight*(on: bool, source: string): string =
  ## Colorize a (possibly incomplete) input line. Never fails.
  if not on: return source
  let cs = chars(source)
  var i = 0
  var expect = ExpectCommand
  template at(k: int): string = (if k < cs.len: cs[k] else: "")
  proc takeIdent(cs: seq[string], i: var int): string =
    while i < cs.len and isIdentContinue(cs[i]):
      result.add cs[i]
      inc i
  while i < cs.len:
    let c = cs[i]
    let n = at(i + 1)
    case c
    of " ", "\t":
      result.add c; inc i
    of "\r", "\n": inc i
    of "#":
      var rest = ""
      while i < cs.len:
        rest.add cs[i]; inc i
      result.add shapeComment(true, rest)
    of "|":
      result.add shapePipe(true, "|"); inc i
      expect = ExpectCommand
    of "^":
      result.add shapeOperator(true, "^"); inc i
      # Force external: next word is an external command.
      while i < cs.len and (cs[i] == " " or cs[i] == "\t"):
        result.add cs[i]; inc i
      let w = takeIdent(cs, i)
      if w != "": result.add shapeExternal(true, w)
      expect = ExpectArg
    of "$":
      inc i
      result.add shapeVariable(true, "$" & takeIdent(cs, i))
      expect = ExpectArg
    of "\"", "'":
      var body = c
      inc i
      while i < cs.len:
        let ch = cs[i]
        if ch == c:
          body.add ch; inc i; break
        if ch == "\\" and i + 1 < cs.len:
          body.add ch & cs[i + 1]; i += 2
        else:
          body.add ch; inc i
      result.add shapeString(true, body)
      expect = ExpectArg
    of "[", "]":
      result.add shapeList(true, c); inc i
      expect = ExpectArg
    of "{", "}":
      result.add shapeRecord(true, c); inc i
      expect = ExpectArg
    of "(", ")", ":", ",":
      result.add shapeOperator(true, c); inc i
      expect = ExpectArg
    of "!", ">", "<", "=":
      if n == "=":
        result.add shapeOperator(true, c & "="); i += 2
      elif c == "!":
        result.add shapeGarbage(true, c); inc i
      else:
        result.add shapeOperator(true, c); inc i
      expect = ExpectArg
    else:
      if c == "-" and n == "-":
        i += 2
        result.add shapeFlag(true, "--" & takeIdent(cs, i))
        expect = ExpectArg
      elif isDigit(c) or (c == "-" and isDigit(n)):
        var num = c
        var seenDot = false
        inc i
        while i < cs.len:
          if isDigit(cs[i]): num.add cs[i]
          elif cs[i] == "." and not seenDot:
            seenDot = true
            num.add cs[i]
          else: break
          inc i
        result.add(if seenDot: shapeFloat(true, num) else: shapeInt(true, num))
        expect = ExpectArg
      elif c == "-":
        inc i
        result.add shapeFlag(true, "-" & takeIdent(cs, i))
        expect = ExpectArg
      elif isIdentStart(c):
        let w = takeIdent(cs, i)
        case w
        of "true", "True", "false", "False": result.add shapeBool(true, w)
        of "null", "nothing", "Nothing": result.add shapeNothing(true, w)
        else:
          if expect == ExpectCommand:
            if w == "let": result.add shapeKeyword(true, w)
            elif isBuiltin(w): result.add shapeInternalcall(true, w)
            else: result.add shapeExternal(true, w)
          else:
            result.add shapeExternalarg(true, w)
        expect = ExpectArg
      else:
        # Unknown char — mark as garbage and continue
        result.add shapeGarbage(true, c); inc i

proc line*(source: string): string =
  ## Colorize for the line editor with the current color policy.
  highlight(enabled(), source)

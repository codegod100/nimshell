## Nushell-inspired ANSI colors for structured values.

import std/os
import term

const
  reset = "\e[0m"
  boldGreen = "\e[1;32m"   ## headers, record keys, list indices
  green = "\e[32m"         ## strings
  purple = "\e[35m"        ## ints & floats
  lightCyan = "\e[96m"     ## bools
  darkGray = "\e[90m"      ## nothing / empty
  cyan = "\e[36m"          ## filesizes
  blue = "\e[34m"          ## directories (type column)
  brightBlue = "\e[94m"    ## directory names in tables
  brightCyan = "\e[96m"    ## symlinks
  boldRed = "\e[1;31m"     ## errors
  dim = "\e[2m"            ## box-drawing separators
  bold = "\e[1m"
  yellow = "\e[33m"        ## operators
  boldCyan = "\e[1;36m"    ## internal commands / lists / records
  boldBlue = "\e[1;34m"    ## flags
  boldPurple = "\e[1;35m"  ## ints, floats, pipes (input shapes)
  garbage = "\e[1;37;41m"  ## lex errors

proc isForceValue(v: string): bool =
  v notin ["", "0", "false", "False", "no", "No"]

proc forceColor(): bool =
  if existsEnv("FORCE_COLOR"): return isForceValue(getEnv("FORCE_COLOR"))
  if existsEnv("CLICOLOR_FORCE"): return isForceValue(getEnv("CLICOLOR_FORCE"))
  false

proc enabled*(): bool =
  ## Whether ANSI color should be emitted.
  ##
  ## - Off when `NO_COLOR` is set to a non-empty value (https://no-color.org).
  ## - On when `FORCE_COLOR` / `CLICOLOR_FORCE` is set to a non-empty, non-`0` value.
  ## - Otherwise on only when stdout is a terminal.
  if getEnv("NO_COLOR") != "": return false
  forceColor() or stdoutIsatty()

proc paint*(on: bool, code, text: string): string =
  ## Wrap `text` in an ANSI code when colors are on.
  if on: code & text & reset else: text

proc header*(on: bool, text: string): string = paint(on, boldGreen, text)
proc key*(on: bool, text: string): string = paint(on, boldGreen, text)
proc index*(on: bool, text: string): string = paint(on, boldGreen, text)
proc separator*(on: bool, text: string): string = paint(on, dim, text)
proc error*(on: bool, text: string): string = paint(on, boldRed, text)
proc intC*(on: bool, text: string): string = paint(on, purple, text)
proc floatC*(on: bool, text: string): string = paint(on, purple, text)
proc boolC*(on: bool, text: string): string = paint(on, lightCyan, text)
proc stringC*(on: bool, text: string): string = paint(on, green, text)
proc nothing*(on: bool, text: string): string = paint(on, darkGray, text)
proc filesize*(on: bool, text: string): string = paint(on, cyan, text)
proc datetime*(on: bool, text: string): string = paint(on, darkGray, text)
proc dirName*(on: bool, text: string): string = paint(on, brightBlue, text)
proc fileName*(on: bool, text: string): string = paint(on, green, text)
proc symlinkName*(on: bool, text: string): string = paint(on, brightCyan, text)
proc typeDir*(on: bool, text: string): string = paint(on, blue, text)
proc typeFile*(on: bool, text: string): string = paint(on, green, text)
proc typeSymlink*(on: bool, text: string): string = paint(on, cyan, text)
proc promptName*(on: bool, text: string): string = paint(on, boldGreen, text)
proc promptPath*(on: bool, text: string): string = paint(on, boldCyan, text)
proc promptGit*(on: bool, text: string): string = paint(on, boldPurple, text)
proc promptMark*(on: bool, text: string): string = paint(on, bold, text)
proc promptCharacterOk*(on: bool, text: string): string = paint(on, boldGreen, text)
proc promptCharacterErr*(on: bool, text: string): string = paint(on, boldRed, text)

# --- syntax shapes (Nushell `shape_*` defaults) ---

proc shapeInternalcall*(on: bool, text: string): string = paint(on, boldCyan, text)
proc shapeExternal*(on: bool, text: string): string = paint(on, cyan, text)
proc shapeExternalarg*(on: bool, text: string): string = paint(on, boldGreen, text)
proc shapeString*(on: bool, text: string): string = paint(on, green, text)
proc shapeInt*(on: bool, text: string): string = paint(on, boldPurple, text)
proc shapeFloat*(on: bool, text: string): string = paint(on, boldPurple, text)
proc shapeBool*(on: bool, text: string): string = paint(on, lightCyan, text)
proc shapeNothing*(on: bool, text: string): string = paint(on, lightCyan, text)
proc shapeFlag*(on: bool, text: string): string = paint(on, boldBlue, text)
proc shapePipe*(on: bool, text: string): string = paint(on, boldPurple, text)
proc shapeOperator*(on: bool, text: string): string = paint(on, yellow, text)
proc shapeVariable*(on: bool, text: string): string = paint(on, purple, text)
proc shapeList*(on: bool, text: string): string = paint(on, boldCyan, text)
proc shapeRecord*(on: bool, text: string): string = paint(on, boldCyan, text)
proc shapeComment*(on: bool, text: string): string = paint(on, darkGray, text)
proc shapeKeyword*(on: bool, text: string): string = paint(on, boldCyan, text)
proc shapeGarbage*(on: bool, text: string): string = paint(on, garbage, text)

proc containsAnsi*(s: string): bool =
  ## True if `s` already contains ANSI/VT escapes (e.g. external tool output).
  ## Such strings should be printed as-is rather than re-colored by the shell.
  '\e' in s

iterator ansiScan*(s: string): (int, int, bool) =
  ## Yields `(start, len, isEscape)` chunks: whole escape sequences (CSI
  ## `ESC [ … final`, or ESC + one byte) and single UTF-8 code points.
  var i = 0
  while i < s.len:
    if s[i] == '\e':
      var j = i + 1
      if j < s.len and s[j] == '[':
        inc j
        while j < s.len and not (ord(s[j]) >= 0x40 and ord(s[j]) <= 0x7E): inc j
        if j < s.len: inc j
      elif j < s.len:
        inc j
      yield (i, j - i, true)
      i = j
    else:
      let b = ord(s[i])
      var n =
        if b < 0x80: 1
        elif (b and 0xE0) == 0xC0: 2
        elif (b and 0xF0) == 0xE0: 3
        elif (b and 0xF8) == 0xF0: 4
        else: 1
      n = min(n, s.len - i)
      yield (i, n, false)
      i += n

proc visibleLength*(s: string): int =
  ## Visible length (code points) ignoring ANSI escape sequences.
  for (_, _, esc) in ansiScan(s):
    if not esc: inc result

proc stripAnsi*(s: string): string =
  ## Drop ANSI/VT escape sequences, leaving only visible text.
  for (start, n, esc) in ansiScan(s):
    if not esc: result.add s[start ..< start + n]

## Raw-mode line editor for the REPL: live syntax highlighting, persistent
## history with greyed-out hints, Tab completion, and Ctrl+R fuzzy search.

import std/[algorithm, os, sets, strutils]
from std/unicode import toLower, runes, `$`
import builtins, color, highlight, sys

const
  historyMax = 2000
  searchMaxRows = 12

type
  ReadStatus* = enum
    rsLine, rsEof, rsInterrupted

var history*: seq[string] ## newest first

# --- history file ---

proc historyFile*(): string =
  let cache = getEnv("XDG_CACHE_HOME")
  let base = if cache != "": cache else: getHomeDir() / ".cache"
  base / "nimshell-history" / "lines"

proc historyBlank(s: string): bool =
  ## Blank, whitespace-only, or ANSI/zero-width-only entries are never kept.
  stripAnsi(s).replace("​", "").strip == ""

proc loadHistory*() =
  history = @[]
  try:
    var lines = readFile(historyFile()).split("\n")
    lines.reverse()
    for l in lines:
      let t = l.strip(leading = false, chars = {'\r'})
      if not historyBlank(t): history.add t
  except CatchableError:
    discard

proc saveHistory*() =
  try:
    let f = historyFile()
    createDir(f.parentDir)
    var kept = history[0 ..< min(history.len, historyMax)]
    kept.reverse()
    writeFile(f, kept.join("\n") & (if kept.len > 0: "\n" else: ""))
  except CatchableError:
    discard

proc pushHistory*(line: string) =
  let t = line.strip
  if historyBlank(t): return
  if history.len == 0 or history[0] != t: history.insert(t, 0)
  if history.len > historyMax: history.setLen(historyMax)

# --- hints & fuzzy search (pure; tested) ---

proc historyHint*(hist: seq[string], buffer: string): string =
  ## Greyed-out autosuggestion suffix for `buffer`, given `hist` newest-first.
  ## Empty when there is no proper prefix match (and for an empty buffer).
  if buffer == "": return ""
  for h in hist:
    if h.len > buffer.len and h.startsWith(buffer): return h[buffer.len .. ^1]
  ""

proc uniqHistory(hist: seq[string]): seq[string] =
  var seen: HashSet[string]
  for h in hist:
    if historyBlank(h) or h in seen: continue
    seen.incl h
    result.add h

proc fuzzyScore(query, cand: seq[string]): int =
  ## Case-insensitive subsequence score (inspired by sahilm/fuzzy used by
  ## stinkpot). Higher is better; -1 when not a subsequence. Consecutive
  ## and early matches score up.
  var qi = 0
  var last = -2
  var run = 0
  for idx, c in cand:
    if qi >= query.len: break
    if c == query[qi]:
      run = if idx == last + 1: run + 1 else: 0
      result += 16 + run * 4 + max(0, 32 - idx)
      last = idx
      inc qi
    else:
      run = 0
  if qi < query.len: -1 else: result

proc lowerRunes(s: string): seq[string] =
  for r in toLower(s).runes: result.add $r

proc historySearch*(hist: seq[string], query: string): seq[string] =
  ## Fuzzy history filter for Ctrl+R. `hist` is newest-first; an empty or
  ## whitespace query returns all unique entries in that order. Otherwise
  ## subsequence matches, best scores first (ties keep newest-first order).
  let cands = uniqHistory(hist)
  let q = query.strip
  if q == "": return cands
  let ql = lowerRunes(q)
  var scored: seq[(int, int, string)]
  for i, c in cands:
    let s = fuzzyScore(ql, lowerRunes(c))
    if s >= 0: scored.add((s, i, c))
  scored.sort(proc(a, b: (int, int, string)): int =
    if a[0] != b[0]: cmp(b[0], a[0]) else: cmp(a[1], b[1]))
  for (_, _, c) in scored: result.add c

# --- completion (pure-ish; tested) ---

proc isCommandPosition(prefix: string): bool =
  ## Empty prefix, or the last non-space before the word is a pipeline /
  ## statement separator or assignment (`let x = …`).
  let before = prefix.strip(leading = false)
  before == "" or before[^1] in {'|', ';', '&', '='}

proc isPathLikeWord(word: string): bool =
  word.len > 0 and ('/' in word or '\\' in word or word[0] == '~')

proc showDotfile(base, name: string): bool =
  base.startsWith(".") or not name.startsWith(".")

proc isExecutable(path: string): bool =
  try:
    let info = getFileInfo(path)
    info.kind in {pcFile, pcLinkToFile} and
      (fpUserExec in info.permissions or fpGroupExec in info.permissions or
       fpOthersExec in info.permissions)
  except OSError: false

proc commandCompletions(word: string): seq[string] =
  var found: HashSet[string]
  for n in names():
    if n.startsWith(word): found.incl n
  if "let".startsWith(word): found.incl "let"
  # Empty prefix: skip PATH dump (can be thousands of names).
  if word != "":
    for dir in getEnv("PATH").split(':'):
      if dir == "" or not dirExists(dir): continue
      try:
        for kind, path in walkDir(dir):
          let name = path.extractFilename
          if name.startsWith(word) and showDotfile(word, name) and
              name notin found and isExecutable(path):
            found.incl name
      except OSError: discard
  for n in found: result.add n
  result.sort()

proc filenameCompletions(word: string): seq[string] =
  ## Sorted completion strings as typed (`~` preserved; dirs end in `/`).
  var listDir, base, insertPrefix: string
  let slash = word.rfind('/')
  if slash < 0:
    listDir = "."
    base = word
    insertPrefix = ""
  else:
    let dir = word[0 ..< slash]
    base = word[slash + 1 .. ^1]
    listDir = if dir == "": "/" else: dir
    insertPrefix = if dir == "": "/" else: dir & "/"
  let realDir = expandHome(listDir)
  if not dirExists(realDir): return
  var entries: seq[string]
  try:
    for kind, path in walkDir(realDir, relative = true): entries.add path
  except OSError: return
  entries.sort()
  for name in entries:
    if name.startsWith(base) and showDotfile(base, name):
      result.add insertPrefix & name & (if dirExists(realDir / name): "/" else: "")

proc completeWord*(prefix, word: string): (seq[string], string) =
  ## Tab-completion candidates for `word` given the text before it on the
  ## line. Returns `(matches, kind)` where kind is "command" or "path".
  if isCommandPosition(prefix) and not isPathLikeWord(word):
    (commandCompletions(word), "command")
  else:
    (filenameCompletions(word), "path")

proc longestCommonPrefix(xs: seq[string]): string =
  ## Longest common prefix by code point (never splits a UTF-8 sequence).
  if xs.len == 0: return ""
  var common: seq[string]
  for r in xs[0].runes: common.add $r
  for x in xs[1 .. ^1]:
    var i = 0
    for r in x.runes:
      if i >= common.len or common[i] != $r: break
      inc i
    common.setLen(min(i, common.len))
  common.join("")

proc delRange(s: var seq[string], a, b: int) =
  ## Delete elements a..b inclusive.
  if a > b: return
  s = s[0 ..< a] & s[b + 1 .. ^1]

# --- editor ---

type Editor = object
  prompt: string
  buf: seq[string] ## one code point per element
  cur: int
  rowsAbove: int   ## terminal rows between the prompt start and the cursor
  histPos: int     ## 0 = live draft; n = history[n-1]
  noHint: bool     ## final redraw on Enter: drop the ghost suggestion
  draft: seq[string]

proc text(e: Editor): string = e.buf.join("")

proc toBuf(s: string): seq[string] =
  for r in s.runes: result.add $r

proc cols(): int =
  let (ok, _, c) = termSize()
  if ok: max(c, 1) else: 80

proc render(e: var Editor) =
  let width = cols()
  let full = e.text
  let hint = if e.cur == e.buf.len and not e.noHint: historyHint(history, full)
             else: ""
  let hintPainted = if hint != "" and enabled(): "\e[90m" & hint & "\e[0m" else: hint
  var outp = ""
  if e.rowsAbove > 0: outp.add "\e[" & $e.rowsAbove & "A"
  outp.add "\r\e[J" & e.prompt & highlight.line(full) & hintPainted
  let promptW = visibleLength(e.prompt)
  let endW = promptW + e.buf.len + visibleLength(hint)
  if endW > 0 and endW mod width == 0: outp.add "\n"
  let endRow = endW div width
  let curW = promptW + e.cur
  let curRow = curW div width
  let curCol = curW mod width
  if endRow > curRow: outp.add "\e[" & $(endRow - curRow) & "A"
  outp.add "\r"
  if curCol > 0: outp.add "\e[" & $curCol & "C"
  e.rowsAbove = curRow
  writeOut(outp)

proc setText(e: var Editor, s: string) =
  e.buf = toBuf(s)
  e.cur = e.buf.len

proc insert(e: var Editor, s: string) =
  for r in s.runes:
    e.buf.insert($r, e.cur)
    inc e.cur

proc acceptHint(e: var Editor, wordOnly: bool): bool =
  let hint = historyHint(history, e.text)
  if hint == "": return false
  if not wordOnly:
    e.insert hint
    return true
  # One word: leading spaces plus the next run of non-spaces.
  var i = 0
  while i < hint.len and hint[i] in {' ', '\t'}: inc i
  while i < hint.len and hint[i] notin {' ', '\t'}: inc i
  e.insert hint[0 ..< i]
  true

proc isCompletionBreak(c: string): bool =
  c in [" ", "\t", "|", ";", "&", "(", ")", "[", "]", "{", "}", "<", ">", "'", "\""]

proc showCompletions(e: var Editor, matches: seq[string]) =
  let width = cols()
  var maxW = 0
  for m in matches: maxW = max(maxW, visibleLength(m))
  let cell = maxW + 2
  let perRow = max(1, width div cell)
  var outp = "\n"
  for i, m in matches:
    outp.add m & " ".repeat(max(0, cell - visibleLength(m)))
    if (i + 1) mod perRow == 0 and i + 1 < matches.len: outp.add "\n"
  outp.add "\n"
  # Move below the current input first so the list does not overwrite it.
  let promptW = visibleLength(e.prompt)
  let endRow = (promptW + e.buf.len) div width
  if endRow > e.rowsAbove: writeOut("\e[" & $(endRow - e.rowsAbove) & "B")
  writeOut(outp)
  e.rowsAbove = 0

proc tabComplete(e: var Editor) =
  var start = e.cur
  while start > 0 and not isCompletionBreak(e.buf[start - 1]): dec start
  let word = e.buf[start ..< e.cur].join("")
  let prefix = e.buf[0 ..< start].join("")
  let (matches, kind) = completeWord(prefix, word)
  proc replaceWord(e: var Editor, s: string) =
    e.buf.delRange(start, e.cur - 1)
    e.cur = start
    e.insert s
  if matches.len == 0:
    writeOut("\a")
  elif matches.len == 1:
    var m = matches[0]
    # Trailing space after a unique command so the user can type args next.
    if kind == "command" and not m.endsWith("/"): m.add " "
    replaceWord(e, m)
  else:
    let lcp = longestCommonPrefix(matches)
    if lcp.len > word.len:
      replaceWord(e, lcp)
    else:
      showCompletions(e, matches)

proc histNav(e: var Editor, delta: int) =
  ## delta > 0 = older (↑); delta < 0 = newer (↓). Position 0 is the draft.
  let target = e.histPos + delta
  if target < 0 or target > history.len: return
  if e.histPos == 0: e.draft = e.buf
  e.histPos = target
  if target == 0:
    e.buf = e.draft
    e.cur = e.buf.len
  else:
    e.setText(history[target - 1])

proc reverseSearch(e: var Editor) =
  ## Ctrl+R: stinkpot-style fuzzy picker on the alternate screen.
  var query = ""
  var cursor = 0
  writeOut("\e[?1049h")
  var accepted = ""
  var done = false
  while not done:
    let filtered = historySearch(history, query)
    cursor = if filtered.len == 0: 0 else: clamp(cursor, 0, filtered.len - 1)
    let on = enabled()
    var screen = "\e[H\e[2J"
    screen.add paint(on, "\e[1;36m", "history") & " " &
      paint(on, "\e[2m", "(↑/↓ move · Enter/Tab accept · Esc cancel)") & "\r\n"
    screen.add paint(on, "\e[1;35m", "❯ ") & query & "\r\n\r\n"
    let first = max(0, cursor - searchMaxRows + 1)
    for i in first ..< min(filtered.len, first + searchMaxRows):
      let entry = filtered[i]
      if i == cursor: screen.add paint(on, "\e[7m", "> " & entry) & "\e[K\r\n"
      else: screen.add "  " & highlight.line(entry) & "\e[K\r\n"
    screen.add "\r\n" & paint(on, "\e[2m", $filtered.len & " match" &
      (if filtered.len == 1: "" else: "es"))
    # Park the cursor at the end of the query line.
    screen.add "\e[2;" & $(3 + visibleLength(query)) & "H"
    writeOut(screen)
    let key = readKeyName()
    case key
    of "eof", "esc", "ctrl_c", "ctrl_g": done = true
    of "enter", "tab":
      if filtered.len > 0: accepted = filtered[cursor]
      done = true
    of "up", "ctrl_p": dec cursor
    of "down", "ctrl_n": inc cursor
    of "backspace":
      var q = toBuf(query)
      if q.len > 0: q.setLen(q.len - 1)
      query = q.join("")
      cursor = 0
    of "ctrl_u":
      query = ""
      cursor = 0
    of "space":
      query.add " "
      cursor = 0
    else:
      if not key.startsWith("ctrl_") and not key.startsWith("alt_") and
          visibleLength(key) == 1:
        query.add key
        cursor = 0
  writeOut("\e[?1049l")
  e.rowsAbove = 0
  if accepted != "": e.setText(accepted)

proc killWord(e: var Editor) =
  var i = e.cur
  while i > 0 and e.buf[i - 1] in [" ", "\t"]: dec i
  while i > 0 and e.buf[i - 1] notin [" ", "\t"]: dec i
  if i < e.cur: e.buf.delRange(i, e.cur - 1)
  e.cur = i

proc rawReadLine(prompt: string): (ReadStatus, string) =
  var e = Editor(prompt: prompt)
  if not enableRaw(): return (rsEof, "")
  defer: disableRaw()
  e.render()
  while true:
    let key = readKeyName()
    let atEnd = e.cur == e.buf.len
    case key
    of "eof":
      writeOut("\r\n")
      return (rsEof, "")
    of "enter":
      # Drop the ghost hint before leaving the line.
      e.cur = e.buf.len
      e.noHint = true
      e.render()
      writeOut("\r\n")
      return (rsLine, e.text)
    of "ctrl_c":
      writeOut("^C\r\n")
      return (rsInterrupted, "")
    of "ctrl_d":
      if e.buf.len == 0:
        writeOut("\r\n")
        return (rsEof, "")
      if e.cur < e.buf.len: e.buf.delete(e.cur)
    of "backspace":
      if e.cur > 0:
        e.buf.delete(e.cur - 1)
        dec e.cur
    of "delete":
      if e.cur < e.buf.len: e.buf.delete(e.cur)
    of "left", "ctrl_b":
      if e.cur > 0: dec e.cur
    of "right", "ctrl_f":
      if atEnd: discard e.acceptHint(false)
      else: inc e.cur
    of "home", "ctrl_a": e.cur = 0
    of "end", "ctrl_e":
      if atEnd: discard e.acceptHint(false)
      else: e.cur = e.buf.len
    of "alt_f":
      if atEnd: discard e.acceptHint(true)
      else:
        while e.cur < e.buf.len and e.buf[e.cur] in [" ", "\t"]: inc e.cur
        while e.cur < e.buf.len and e.buf[e.cur] notin [" ", "\t"]: inc e.cur
    of "alt_b":
      while e.cur > 0 and e.buf[e.cur - 1] in [" ", "\t"]: dec e.cur
      while e.cur > 0 and e.buf[e.cur - 1] notin [" ", "\t"]: dec e.cur
    of "ctrl_w", "alt_backspace": e.killWord()
    of "ctrl_u":
      if e.cur > 0: e.buf.delRange(0, e.cur - 1)
      e.cur = 0
    of "ctrl_k":
      if e.cur < e.buf.len: e.buf.setLen(e.cur)
    of "ctrl_l":
      writeOut("\e[H\e[2J")
      e.rowsAbove = 0
    of "up", "ctrl_p": e.histNav(1)
    of "down", "ctrl_n": e.histNav(-1)
    of "tab": e.tabComplete()
    of "ctrl_r": e.reverseSearch()
    of "space": e.insert " "
    of "esc", "unknown", "page_up", "page_down", "paste_start", "paste_end",
       "ctrl_g": discard
    else:
      e.insert key
    e.render()

proc readLine*(prompt: string): (ReadStatus, string) =
  ## Read one line. Raw editor on a TTY; plain line reads otherwise.
  if stdinIsatty() and stdoutIsatty():
    return rawReadLine(prompt)
  sys.write(prompt)
  var line: string
  if stdin.readLine(line): (rsLine, line) else: (rsEof, "")

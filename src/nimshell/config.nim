## User config: `$XDG_CONFIG_HOME/nimshell/config.ns`
## (default `~/.config/nimshell/config.ns`), a nimshell script run at startup.
##
##   $env.EDITOR = nvim
##   $env.GOPATH = ~/go
##   add-path ~/.local/bin $GOPATH/bin
##   add-path --append /opt/tools/bin
##
##   alias ll "ls -l"
##   alias gs "^git status"
##
##   prompt {
##       character: "λ"
##       single-line: true
##       colors: {cwd: "bold blue", character: "#ff8800"}
##   }
##
## Statements run in file order; a statement continues onto the next line
## while a `{`, `[` or `(` is open or the line ends with `|`. While the config
## runs, `add-path` and `export` only change this session (they never write
## back to the file), and `add-path` skips directories that don't exist.
##
## An old `config.kdl` is converted to `config.ns` once (see `migrateKdl`).

import std/[os, strutils]
import alias, color, kdl, lexer, parser, prompt, sys, value

proc configDir(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  (if xdg != "": xdg else: getHomeDir() / ".config") / "nimshell"

proc configFile*(): string = configDir() / "config.ns"

var loadingConfig*: bool
  ## True while the config runs: `add-path` / `export` don't save.

var configRunner*: proc (src: string): seq[string] {.nimcall.}
  ## Evaluates config source, returning warnings (set by `eval`, which
  ## imports this module).

proc expandValue*(s: string): string =
  ## Expand a leading `~` and `$VAR` / `${VAR}` (unset vars become "");
  ## `$$` is a literal `$`.
  var s = expandHome(s)
  var i = 0
  while i < s.len:
    if s[i] == '$' and i + 1 < s.len:
      if s[i + 1] == '$':
        result.add '$'
        i += 2
        continue
      elif s[i + 1] == '{':
        let close = s.find('}', i + 2)
        if close > 0:
          result.add getEnv(s[i + 2 ..< close])
          i = close + 1
          continue
      elif s[i + 1] in IdentStartChars:
        var j = i + 1
        while j < s.len and s[j] in IdentChars: inc j
        result.add getEnv(s[i + 1 ..< j])
        i = j
        continue
    result.add s[i]
    inc i

proc updatePath*(dirs: seq[string], prepend: bool) =
  ## Add `dirs` to PATH (keeping their order); an entry already present
  ## moves to the requested end instead of being duplicated.
  var parts: seq[string]
  for p in getEnv("PATH").split(':'):
    if p != "" and p notin dirs and p notin parts: parts.add p
  var added: seq[string]
  for d in dirs:
    if d != "" and d notin added: added.add d
  setenv("PATH", (if prepend: added & parts else: parts & added).join(":"))

# --- statements ---

type ConfigStmt* = object
  line*: int      ## 1-based first line
  lines*: int     ## how many lines it spans
  text*: string

proc splitStatements*(src: string): seq[ConfigStmt] =
  ## Group config lines into statements. Blank and comment-only lines are
  ## dropped; a statement goes on while a bracket is open or the last token
  ## is `|`. Text that doesn't lex is kept as-is so evaluating it reports
  ## the error.
  let lines = src.split('\n')
  var i = 0
  while i < lines.len:
    var cur = ConfigStmt(line: i + 1)
    var text = ""
    var toks: seq[Token]
    while i < lines.len:
      text.add (if text == "": lines[i] else: "\n" & lines[i])
      inc i
      inc cur.lines
      var e: LexError
      if not tokenize(text, toks, e): break
      var depth = 0
      for t in toks:
        case t.kind
        of tkLBrace, tkLBracket, tkLParen: inc depth
        of tkRBrace, tkRBracket, tkRParen: dec depth
        else: discard
      let last = if toks.len > 1: toks[^2].kind else: tkEof
      if depth <= 0 and last != tkPipe: break
    var e: LexError
    if tokenize(text, toks, e) and toks.len <= 1: continue
    cur.text = text
    result.add cur

proc parseStmt(text: string, stmt: var Statement): bool =
  var msg: string
  parse(text.strip, stmt, msg)

# --- `prompt { … }` ---

proc applyPromptSettings*(v: Value, cfg: var PromptConfig): seq[string] =
  ## Apply a `prompt` settings record to `cfg`; returns problems (valid
  ## settings are still applied).
  if v.kind != vkRecord: return @["expected a record like {character: \"λ\"}"]
  proc wantBool(k: string, x: Value, dst: var bool, res: var seq[string]) =
    if x.kind == vkBool: dst = x.b
    else: res.add(k & ": expected true or false")
  proc wantInt(k: string, x: Value, res: var seq[string]): int64 =
    if x.kind == vkInt: return max(x.i, 0)
    res.add(k & ": expected a number")
    -1
  for (key, x) in v.fields:
    let k = key.replace('_', '-')
    case k
    of "character", "error-character":
      if x.kind != vkString: result.add(k & ": expected a string")
      elif k == "character": cfg.character = x.s
      else: cfg.errorCharacter = x.s
    of "nerd-font":
      if x.kind == vkBool: cfg.nerdFont = ord(x.b)
      else: result.add(k & ": expected true or false")
    of "single-line": wantBool(k, x, cfg.singleLine, result)
    of "blank-line": wantBool(k, x, cfg.blankLine, result)
    of "git": wantBool(k, x, cfg.git, result)
    of "git-status": wantBool(k, x, cfg.gitStatus, result)
    of "min-duration":
      let n = wantInt(k, x, result)
      if n >= 0: cfg.minDurationMs = n
    of "cwd-depth":
      let n = wantInt(k, x, result)
      if n >= 0: cfg.cwdDepth = int(n)
    of "colors":
      if x.kind != vkRecord:
        result.add("colors: expected a record like {cwd: \"bold blue\"}")
        continue
      for (ckey, c) in x.fields:
        let ck = ckey.replace('_', '-')
        var code: string
        if c.kind != vkString or not parseStyle(c.s, code):
          result.add("colors." & ck & ": unknown style " &
                     (if c.kind == vkString: "\"" & c.s & "\"" else: asString(c)))
          continue
        case ck
        of "cwd": cfg.cwdStyle = code
        of "branch": cfg.branchStyle = code
        of "git": cfg.gitStyle = code
        of "duration": cfg.durationStyle = code
        of "error": cfg.errorStyle = code
        of "character": cfg.characterStyle = code
        of "error-character": cfg.errorCharacterStyle = code
        else: result.add("unknown prompt color `" & ck & "`")
    else: result.add("unknown prompt setting `" & k & "`")

# --- writing nimshell source ---

proc quoteNs*(s: string): string =
  ## A nimshell string literal.
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    else: result.add ch
  result.add '"'

proc isBareWord(s: string): bool =
  ## `s` lexes back as the same single bare word.
  if s == "" or s[0] notin {'a' .. 'z', 'A' .. 'Z', '_', '.', '/', '~'}: return false
  if s in ["true", "True", "false", "False", "null", "nothing", "Nothing"]: return false
  for ch in s:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '.', '/', '~', '-', '@'}:
      return false
  true

proc nsWord*(s: string): string =
  if isBareWord(s): s else: quoteNs(s)

proc contractHome(dir: string): string =
  ## `/home/me/bin` → `~/bin` so the config stays portable.
  let (ok, home) = homeDir()
  let h = home.strip(leading = false, chars = {'/'})
  if ok and h != "" and dir == h: "~"
  elif ok and h != "" and dir.startsWith(h & "/"): "~" & dir[h.len .. ^1]
  else: dir

proc commentStart(line: string): int =
  ## Index of a trailing `# comment` (a `#` at a word start outside quotes).
  var q = '\0'
  var i = 0
  while i < line.len:
    let ch = line[i]
    if q != '\0':
      if ch == '\\' and i + 1 < line.len: inc i
      elif ch == q: q = '\0'
    elif ch in {'"', '\''}: q = ch
    elif ch == '#' and (i == 0 or line[i - 1] in Whitespace): return i
    inc i
  -1

proc lineIndent(l: string): string =
  for ch in l:
    if ch in {' ', '\t'}: result.add ch
    else: break

proc withComment(line, code: string): string =
  ## `code` in place of `line`, keeping its indentation and `# comment`.
  let c = commentStart(line)
  lineIndent(line) & code & (if c > 0: " " & line[c .. ^1] else: "")

proc readConfig(src: var string): string =
  ## Load config.ns (missing file = empty); returns an error.
  let path = configFile()
  if fileExists(path):
    try: src = readFile(path)
    except IOError as e: return path & ": " & e.msg

proc writeConfig(src: string): string =
  let path = configFile()
  try:
    createDir(path.parentDir)
    writeFile(path, src)
  except IOError, OSError:
    return "cannot write " & path & ": " & getCurrentExceptionMsg()

proc appendLine(src: var string, line: string) =
  if src != "" and not src.endsWith("\n"): src.add "\n"
  src.add line & "\n"

# --- `add-path` / `remove-path`: edit the `add-path` lines in config.ns ---
# Edits are textual so comments and formatting survive: `add-path` appends an
# `add-path <dir>` line, `remove-path` drops the dir from the line listing it.

const addPathNames = ["add-path", "add_to_path"]
const addPathFlags = ["n", "no-save", "a", "append"]

proc exprWord(e: Expr, word: var string): bool =
  ## Source text of a dir argument (a literal or `$VAR/suffix`).
  case e.kind
  of exLit:
    if e.lit.kind != vkString: return false
    word = if e.bare: nsWord(e.lit.s) else: quoteNs(e.lit.s)
  of exVar: word = "$" & e.name & e.suffix
  else: return false
  true

proc exprDir(e: Expr, dir: var string): bool =
  ## The absolute directory a config `add-path` argument names.
  case e.kind
  of exLit:
    if e.lit.kind != vkString: return false
    dir = expandHome(e.lit.s)
  of exVar:
    let name = if e.name.startsWith("env."): e.name[4 .. ^1] else: e.name
    let v = getEnv(name)
    if v == "": return false
    dir = v & e.suffix
  else: return false
  if not dir.isAbsolute: return false
  dir = normalizedPath(dir)
  true

iterator dirArgs(cmd: Command): (int, string) =
  ## `(arg index, dir)` for each directory an `add-path` command lists
  ## (including ones a bool flag swallowed: `add-path --append /x`).
  for i, a in cmd.args:
    var dir: string
    case a.kind
    of argValue:
      if exprDir(a.expr, dir): yield (i, dir)
    of argFlag:
      if a.hasValue and a.flagName in addPathFlags and exprDir(a.flagValue, dir):
        yield (i, dir)

proc isAddPath(cmd: Command): bool =
  not cmd.external and cmd.name in addPathNames

proc configPathDirs*(): seq[string] =
  ## Directories config.ns adds with `add-path` (expanded).
  var src: string
  if readConfig(src) != "": return
  for s in splitStatements(src):
    var stmt: Statement
    if not parseStmt(s.text, stmt) or stmt.kind != stExpr: continue
    for cmd in stmt.pipeline.commands:
      if not isAddPath(cmd): continue
      for (_, d) in dirArgs(cmd):
        if d notin result: result.add d

proc addConfigPaths*(dirs: seq[string]): string =
  ## Save `dirs` as `add-path …` lines (skipping ones already listed).
  ## Returns an error message, or "".
  var src: string
  let e = readConfig(src)
  if e != "": return e
  var known = configPathDirs()
  var added = false
  for d in dirs:
    if d in known: continue
    known.add d
    src.appendLine "add-path " & nsWord(contractHome(d))
    added = true
  if added: writeConfig(src) else: ""

proc removeConfigPaths*(dirs: seq[string]): string =
  ## Remove `dirs` from the `add-path` lines in config.ns; a line left
  ## without directories is dropped. Returns an error message, or "".
  var src: string
  let e = readConfig(src)
  if e != "": return e
  var lines = src.split('\n')
  var drop: seq[int]
  var unedited: seq[int]
  var changed = false
  for s in splitStatements(src):
    var stmt: Statement
    if not parseStmt(s.text, stmt) or stmt.kind != stExpr: continue
    var hit = false
    for cmd in stmt.pipeline.commands:
      if not isAddPath(cmd): continue
      for (_, d) in dirArgs(cmd):
        if d in dirs: hit = true
    if not hit: continue
    let cmd = stmt.pipeline.commands[0]
    if s.lines != 1 or stmt.pipeline.commands.len != 1:
      unedited.add s.line
      continue
    # Rebuild the line without the removed dirs.
    var removed: seq[int]
    for (i, d) in dirArgs(cmd):
      if d in dirs: removed.add i
    var words = @[cmd.name]
    var remaining = 0
    var editable = true
    for i, a in cmd.args:
      var w: string
      case a.kind
      of argValue:
        if i in removed: continue
        if not exprWord(a.expr, w): editable = false
        words.add w
        inc remaining
      of argFlag:
        words.add (if a.flagShort: "-" else: "--") & a.flagName
        if a.hasValue and i notin removed:
          if not exprWord(a.flagValue, w): editable = false
          words.add w
          inc remaining
    if not editable:
      unedited.add s.line
      continue
    changed = true
    if remaining == 0: drop.add s.line - 1
    else: lines[s.line - 1] = withComment(lines[s.line - 1], words.join(" "))
  if changed:
    var kept: seq[string]
    for i, l in lines:
      if i notin drop: kept.add l
    let w = writeConfig(kept.join("\n"))
    if w != "": return w
  if unedited.len > 0:
    return configFile() & ": could not edit line(s) " & unedited.join(", ") &
           "; remove the entry by hand"
  ""

# --- `export`: save a `$env.NAME = "value"` line in config.ns ---
# An existing one-line `$env.NAME = …` / `export NAME = …` is rewritten in
# place (the last one, since it wins at startup), otherwise a line is added.

proc saveConfigEnv*(name, value: string): string =
  ## Save `$env.name = "value"` in config.ns. Returns an error, or "".
  var src: string
  let e = readConfig(src)
  if e != "": return e
  let entry = "$env." & name & " = " & quoteNs(value)
  var hit = -1
  for s in splitStatements(src):
    var stmt: Statement
    if s.lines == 1 and parseStmt(s.text, stmt) and
        stmt.kind in {stEnvAssign, stExport} and stmt.name == name:
      hit = s.line - 1
  if hit >= 0:
    var lines = src.split('\n')
    lines[hit] = withComment(lines[hit], entry)
    return writeConfig(lines.join("\n"))
  src.appendLine entry
  writeConfig(src)

# --- one-time migrations ---

proc nsValue(s: string): string =
  ## A config.kdl string (which expanded `~`, `$VAR`, `${VAR}`) as nimshell
  ## source: a bare word where nimshell expands it the same way, else a
  ## string (expanded now if needed).
  var s2 = s
  if s2.startsWith("${"):
    let close = s2.find('}')
    if close > 2: s2 = "$" & s2[2 ..< close] & s2[close + 1 .. ^1]
  if '$' notin s2 and isBareWord(s2): return s2
  if s2.startsWith("$") and s2.len > 1 and s2[1] in IdentStartChars:
    var j = 1
    while j < s2.len and s2[j] in IdentChars: inc j
    let rest = s2[j .. ^1]
    if '$' notin rest and (rest == "" or rest[0] == '/' and isBareWord(rest)):
      return s2
  if '$' in s or s.startsWith("~"): quoteNs(expandValue(s)) else: quoteNs(s)

proc kdlToNs(src: string, warnings: var seq[string]): string =
  ## Convert config.kdl to equivalent config.ns lines.
  let nodes = parseKdl(src)
  var lines = @["# nimshell config (converted from config.kdl)", ""]
  proc strings(n: KdlNode, warnings: var seq[string]): seq[string] =
    for a in n.args:
      if a.kind == kkString: result.add nsValue(a.str)
      else: warnings.add("line " & $n.line & ": skipped non-string path " & $a)
  for n in nodes:
    case n.name
    of "env":
      for c in n.children:
        if c.args.len != 1 or c.name == "PATH" or not isEnvName(c.name):
          warnings.add("line " & $c.line & ": skipped env " & c.name)
          continue
        let v = c.args[0]
        lines.add "$env." & c.name & " = " & (
          case v.kind
          of kkString: nsValue(v.str)
          of kkNull: "null"
          else: quoteNs($v))
    of "path":
      if n.args.len > 0: lines.add "add-path " & strings(n, warnings).join(" ")
      for c in n.children:
        let ws = strings(c, warnings)
        if ws.len == 0: continue
        case c.name
        of "prepend": lines.add "add-path " & ws.join(" ")
        of "append": lines.add "add-path --append " & ws.join(" ")
        else: warnings.add("line " & $c.line & ": skipped path " & c.name)
    of "aliases", "alias":
      var pairs: seq[(string, KdlVal)]
      if n.name == "alias" and n.args.len == 2 and n.args[0].kind == kkString:
        pairs.add((n.args[0].str, n.args[1]))
      for c in n.children:
        if c.args.len == 1: pairs.add((c.name, c.args[0]))
      for (name, v) in pairs:
        if v.kind == kkString: lines.add "alias " & nsWord(name) & " " & quoteNs(v.str)
        else: warnings.add("line " & $n.line & ": skipped alias " & name)
    of "prompt":
      proc val(v: KdlVal): string =
        case v.kind
        of kkString: quoteNs(v.str)
        of kkBool: (if v.b: "true" else: "false")
        of kkNumber: $int64(v.num)
        else: "null"
      lines.add "prompt {"
      for c in n.children:
        if c.name == "colors":
          var cs: seq[string]
          for cc in c.children:
            if cc.args.len == 1: cs.add cc.name & ": " & val(cc.args[0])
          lines.add "    colors: {" & cs.join(", ") & "}"
        elif c.args.len == 1:
          lines.add "    " & c.name & ": " & val(c.args[0])
      lines.add "}"
    else: warnings.add("line " & $n.line & ": skipped unknown setting `" & n.name & "`")
  lines.join("\n") & "\n"

proc migrateKdl(): seq[string] =
  ## Convert an old config.kdl into config.ns (once: the old file is renamed
  ## to config.kdl.bak).
  let old = configDir() / "config.kdl"
  if fileExists(configFile()) or not fileExists(old): return
  var src: string
  try: src = readFile(old)
  except IOError as e: return @[old & ": " & e.msg]
  var ns: string
  var warnings: seq[string]
  try: ns = kdlToNs(src, warnings)
  except KdlError as e: return @[old & ": " & e.msg & " (not converted to config.ns)"]
  let e = writeConfig(ns)
  if e != "": return @[e]
  try: moveFile(old, old & ".bak")
  except OSError: discard
  result.add "converted " & old & " to " & configFile() & " (old file kept as config.kdl.bak)"
  for w in warnings: result.add old & ": " & w

proc migrateLegacyPaths(): seq[string] =
  ## Early `add-path` saved dirs to `nimshell/paths`; fold them into config.ns.
  let legacy = configDir() / "paths"
  if not fileExists(legacy): return
  var dirs: seq[string]
  try:
    for line in readFile(legacy).splitLines:
      if line.strip != "": dirs.add normalizedPath(expandValue(line.strip))
  except IOError as e: return @[legacy & ": " & e.msg]
  let e = addConfigPaths(dirs)
  if e != "": return @[e]
  try: removeFile(legacy)
  except OSError: discard

# --- loading ---

proc applyConfig*(src: string): seq[string] =
  ## Run config source. Prompt settings and aliases start from the defaults;
  ## returns warnings (`line N: …`).
  promptConfig = defaultPromptConfig()
  clearAliases()
  loadingConfig = true
  try: result = configRunner(src)
  finally: loadingConfig = false

proc loadConfig*(): seq[string] =
  ## Run the user's config file if it exists. Warnings are prefixed with
  ## the file path.
  result = migrateKdl() & migrateLegacyPaths()
  let path = configFile()
  if not fileExists(path): return
  var src: string
  try: src = readFile(path)
  except IOError as e: return result & @[path & ": " & e.msg]
  for w in applyConfig(src): result.add(path & ": " & w)

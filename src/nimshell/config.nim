## User config: `$XDG_CONFIG_HOME/nimshell/config.kdl`
## (default `~/.config/nimshell/config.kdl`), applied at startup.
##
##   env {
##       EDITOR "nvim"
##       GOPATH "~/go"
##   }
##   path {
##       prepend "~/.local/bin" "$GOPATH/bin"
##       append "/opt/tools/bin"
##   }
##
##   prompt {
##       character "λ"
##       single-line #true
##       colors { cwd "bold blue"; character "#ff8800" }
##   }
##
## `path "a" "b"` is shorthand for `path { prepend "a" "b" }`. Values expand a
## leading `~` and `$VAR` / `${VAR}`. Top-level nodes apply in file order, so
## `path` can use variables set by an earlier `env`.

import std/[os, strutils]
import color, kdl, prompt, sys

proc configFile*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  let base = if xdg != "": xdg else: getHomeDir() / ".config"
  base / "nimshell" / "config.kdl"

proc expandValue*(s: string): string =
  ## Expand a leading `~` and `$VAR` / `${VAR}` (unset vars become "").
  var s = s
  if s == "~" or s.startsWith("~/"):
    let (ok, home) = homeDir()
    if ok: s = home & s[1 .. ^1]
  var i = 0
  while i < s.len:
    if s[i] == '$' and i + 1 < s.len:
      if s[i + 1] == '{':
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

proc stringArgs(n: KdlNode, where: string, warnings: var seq[string]): seq[string] =
  for a in n.args:
    if a.kind == kkString: result.add expandValue(a.str)
    else: warnings.add("line " & $n.line & ": " & where & ": expected a string, got " & $a)

proc updatePath(dirs: seq[string], prepend: bool) =
  ## Add `dirs` to PATH (keeping their order); an entry already present
  ## moves to the requested end instead of being duplicated.
  var parts: seq[string]
  for p in getEnv("PATH").split(':'):
    if p != "" and p notin dirs and p notin parts: parts.add p
  var added: seq[string]
  for d in dirs:
    if d != "" and d notin added: added.add d
  setenv("PATH", (if prepend: added & parts else: parts & added).join(":"))

proc applyPath(n: KdlNode, warnings: var seq[string]) =
  if n.args.len > 0: updatePath(stringArgs(n, "path", warnings), prepend = true)
  for c in n.children:
    case c.name
    of "prepend": updatePath(stringArgs(c, "path prepend", warnings), prepend = true)
    of "append": updatePath(stringArgs(c, "path append", warnings), prepend = false)
    else: warnings.add("line " & $c.line & ": unknown path entry `" & c.name &
                       "` (expected prepend or append)")

proc applyEnv(n: KdlNode, warnings: var seq[string]) =
  for c in n.children:
    if c.args.len != 1:
      warnings.add("line " & $c.line & ": env " & c.name & ": expected exactly one value")
    elif c.name == "PATH":
      warnings.add("line " & $c.line & ": set PATH with a `path` block, not `env`")
    elif c.args[0].kind == kkNull:
      delEnv(c.name)
    else:
      let v = c.args[0]
      setenv(c.name, if v.kind == kkString: expandValue(v.str) else: $v)

proc oneArg(c: KdlNode, kind: KdlKind, what: string, warnings: var seq[string]): bool =
  if c.args.len == 1 and c.args[0].kind == kind: return true
  warnings.add("line " & $c.line & ": prompt " & c.name & ": expected " & what)

proc applyPromptColors(n: KdlNode, cfg: var PromptConfig, warnings: var seq[string]) =
  for c in n.children:
    if not oneArg(c, kkString, "a style like \"bold cyan\"", warnings): continue
    var code: string
    if not parseStyle(c.args[0].str, code):
      warnings.add("line " & $c.line & ": prompt colors " & c.name &
                   ": unknown style \"" & c.args[0].str & "\"")
      continue
    case c.name
    of "cwd": cfg.cwdStyle = code
    of "branch": cfg.branchStyle = code
    of "git": cfg.gitStyle = code
    of "duration": cfg.durationStyle = code
    of "error": cfg.errorStyle = code
    of "character": cfg.characterStyle = code
    of "error-character": cfg.errorCharacterStyle = code
    else: warnings.add("line " & $c.line & ": unknown prompt color `" & c.name & "`")

proc applyPrompt(n: KdlNode, warnings: var seq[string]) =
  var cfg = promptConfig
  for c in n.children:
    case c.name
    of "character":
      if oneArg(c, kkString, "a string", warnings): cfg.character = c.args[0].str
    of "error-character":
      if oneArg(c, kkString, "a string", warnings): cfg.errorCharacter = c.args[0].str
    of "nerd-font":
      if oneArg(c, kkBool, "#true or #false", warnings): cfg.nerdFont = ord(c.args[0].b)
    of "single-line":
      if oneArg(c, kkBool, "#true or #false", warnings): cfg.singleLine = c.args[0].b
    of "blank-line":
      if oneArg(c, kkBool, "#true or #false", warnings): cfg.blankLine = c.args[0].b
    of "git":
      if oneArg(c, kkBool, "#true or #false", warnings): cfg.git = c.args[0].b
    of "git-status":
      if oneArg(c, kkBool, "#true or #false", warnings): cfg.gitStatus = c.args[0].b
    of "min-duration":
      if oneArg(c, kkNumber, "milliseconds", warnings):
        cfg.minDurationMs = int64(max(c.args[0].num, 0))
    of "cwd-depth":
      if oneArg(c, kkNumber, "a number of path components", warnings):
        cfg.cwdDepth = int(max(c.args[0].num, 0))
    of "colors": applyPromptColors(c, cfg, warnings)
    else: warnings.add("line " & $c.line & ": unknown prompt setting `" & c.name & "`")
  promptConfig = cfg

proc applyConfig*(src: string): seq[string] =
  ## Apply config text to the process environment and prompt settings
  ## (which start from the defaults); returns warnings.
  promptConfig = defaultPromptConfig()
  var nodes: seq[KdlNode]
  try: nodes = parseKdl(src)
  except KdlError as e: return @[e.msg]
  for n in nodes:
    case n.name
    of "path": applyPath(n, result)
    of "env": applyEnv(n, result)
    of "prompt": applyPrompt(n, result)
    else: result.add("line " & $n.line & ": unknown setting `" & n.name & "`")

proc loadConfig*(): seq[string] =
  ## Apply the user's config file if it exists. Warnings are prefixed with
  ## the file path.
  let path = configFile()
  if not fileExists(path): return
  var src: string
  try: src = readFile(path)
  except IOError as e: return @[path & ": " & e.msg]
  for w in applyConfig(src): result.add(path & ": " & w)

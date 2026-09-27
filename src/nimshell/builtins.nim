## Built-in commands (Nushell-inspired structured data tools).

import std/[algorithm, base64, httpclient, json, net, options, os, strutils,
            tables, times, uri]
from std/unicode import runes, `$`, validateUtf8, toLower
import alias, color, config, display, env, netclient, pager, syntax, sys, update, value

type
  BuiltinResultKind* = enum
    brValue, brExit

  BuiltinResult* = object
    case kind*: BuiltinResultKind
    of brValue:
      env*: Env
      value*: Value
    of brExit:
      code*: int

  Flags* = Table[string, Value]

  Builtin* = proc(env: Env, input: Value, args: seq[Value],
                  flags: Flags): BuiltinResult {.nimcall.}

proc ok(env: Env, v: Value): BuiltinResult =
  BuiltinResult(kind: brValue, env: env, value: v)

proc err(env: Env, msg: string): BuiltinResult =
  BuiltinResult(kind: brValue, env: setExit(env, 1), value: failV(msg))

proc names*(): seq[string]
proc isBuiltin*(name: string): bool

# --- helpers ---

proc resolvePath(env: Env, path: string): string =
  if path == "": return env.cwd
  let p = expandHome(path)
  if p.startsWith("/"): p else: env.cwd / p

proc flagSet(flags: Flags, name: string): bool =
  ## Present and not `false` / nothing.
  if not flags.hasKey(name): return false
  let v = flags[name]
  not ((v.kind == vkBool and not v.b) or v.kind == vkNothing)

proc flagInt(flags: Flags, name: string): Option[int64] =
  if flags.hasKey(name) and flags[name].kind == vkInt: some(flags[name].i)
  else: none(int64)

proc findBoolFlag(flags: Flags, flagNames: openArray[string]): (bool, seq[Value]) =
  ## Parse a boolean flag that may have stolen a following value as its arg
  ## (`find -i hello` → flag i = "hello"). Returns `(flagSet, stolenTerms)`.
  for name in flagNames:
    if not flags.hasKey(name): continue
    let v = flags[name]
    if v.kind == vkNothing or (v.kind == vkBool and not v.b): continue
    result[0] = true
    if not (v.kind == vkBool and v.b): result[1].add v

proc flagValue(flags: Flags, flagNames: openArray[string]): Option[Value] =
  for name in flagNames:
    if flags.hasKey(name): return some(flags[name])
  none(Value)

proc flagString(flags: Flags, flagNames: openArray[string]): Option[string] =
  let v = flagValue(flags, flagNames)
  if v.isSome: some(asString(v.get)) else: none(string)

proc runeSeq(s: string): seq[string] =
  for r in s.runes: result.add $r

# --- JSON ---

proc jsonEscape(s: string): string =
  var e = s.multiReplace(("\\", "\\\\"), ("\"", "\\\""), ("\n", "\\n"),
                         ("\r", "\\r"), ("\t", "\\t"))
  "\"" & e & "\""

proc encodeJson*(v: Value, indent: Option[int], depth = 0): string =
  ## Encode a value as JSON. `indent` is none for compact (`--raw`), or
  ## `some(n)` for n-space pretty-print (Nushell default is 2).
  case v.kind
  of vkNothing: "null"
  of vkBool: (if v.b: "true" else: "false")
  of vkInt: $v.i
  of vkFloat: floatToString(v.f)
  of vkString: jsonEscape(v.s)
  of vkFail: jsonEscape("error: " & v.msg)
  of vkTable:
    var recs: seq[Value]
    for row in v.rows: recs.add zipRow(v.columns, row)
    encodeJson(listV(recs), indent, depth)
  of vkList:
    if v.items.len == 0: return "[]"
    var parts: seq[string]
    if indent.isNone:
      for it in v.items: parts.add encodeJson(it, indent)
      return "[" & parts.join(",") & "]"
    let pad = " ".repeat(indent.get * (depth + 1))
    for it in v.items: parts.add pad & encodeJson(it, indent, depth + 1)
    "[\n" & parts.join(",\n") & "\n" & " ".repeat(indent.get * depth) & "]"
  of vkRecord:
    if v.fields.len == 0: return "{}"
    var parts: seq[string]
    if indent.isNone:
      for (k, val) in v.fields: parts.add jsonEscape(k) & ":" & encodeJson(val, indent)
      return "{" & parts.join(",") & "}"
    let pad = " ".repeat(indent.get * (depth + 1))
    for (k, val) in v.fields:
      parts.add pad & jsonEscape(k) & ": " & encodeJson(val, indent, depth + 1)
    "{\n" & parts.join(",\n") & "\n" & " ".repeat(indent.get * depth) & "}"

proc fromJsonNode(n: JsonNode): Value =
  case n.kind
  of JNull: nothing()
  of JBool: boolV(n.getBool)
  of JInt: intV(n.getBiggestInt)
  of JFloat: floatV(n.getFloat)
  of JString: strV(n.getStr)
  of JArray:
    var items: seq[Value]
    for it in n.elems: items.add fromJsonNode(it)
    listV(items)
  of JObject:
    var pairs: seq[(string, Value)]
    for k, v in n.fields: pairs.add((k, fromJsonNode(v)))
    pairs.sort(proc(a, b: (string, Value)): int = cmp(a[0], b[0]))
    recordV(pairs)

proc parseJsonValue*(source: string): (bool, Value, string) =
  try:
    (true, fromJsonNode(parseJson(source.strip)), "")
  except CatchableError as e:
    (false, nothing(), e.msg)

# --- help ---

proc helpText(): Table[string, string] =
  {
    "help": "help [command] — list builtins, or show help for one command",
    "echo": "echo <values>… — emit values (list if multiple)",
    "print": "print <values>… — alias for echo",
    "ls": "ls [path] — list directory entries as a table (name, type, size, modified)",
    "pwd": "pwd — print working directory",
    "cd": "cd [path] — change directory (~ supported)",
    "cat": "cat <path> [--raw] [--language <id>] — read file; syntax-color on TTY",
    "open": "open <path> — open file; parses .json into structured data",
    "save": "save <path> — save pipeline input to a file",
    "where": "where <field> <op> <value> — filter rows (ops: == != > < >= <=)",
    "filter": "filter <field> <op> <value> — alias for where",
    "find": "find [-i] [-v] [--regex pat] <term>… — search list/table/string input for terms",
    "select": "select <col>… — keep only named columns",
    "get": "get <field|path|index> — get a field, dotted path (a.b), or list index",
    "first": "first [n] — first row/item (default 1)",
    "last": "last [n] — last row/item",
    "take": "take <n> — take first n items",
    "skip": "skip <n> — skip first n items",
    "length": "length — number of items in list/table/string input",
    "count": "count — alias for length",
    "reverse": "reverse — reverse list, table rows, or string characters",
    "sort-by": "sort-by <field> — sort table rows by field",
    "sort_by": "sort_by <field> — alias for sort-by",
    "uniq": "uniq — drop duplicate list items (order preserved)",
    "wrap": "wrap <name> — wrap pipeline input as a single-field record",
    "unwrap": "unwrap [name] — unwrap a record field (default: first field)",
    "to": "to <format> — convert pipeline input (subcommands: json)",
    "from": "from <format> — parse structured input (subcommands: json, jwt)",
    "http": "http <get|post|put|delete|patch|head> <url> [body] — HTTP client",
    "lines": "lines — split string input into a list of lines",
    "typeof": "typeof — type name of pipeline input",
    "type": "type — alias for typeof",
    "describe": "describe — record with type, length, and string form of input",
    "env": "env [NAME] — process environment table, or one var (same as `$env` / `$env.NAME`)",
    "which": "which [-a|--all] [-f|--follow] <name> — path of command (alias, builtin or on PATH); -a all matches, -f follow symlinks",
    "aliases": "aliases — table of command aliases from config.kdl (name, expansion)",
    "add-path": "add-path [-n|--no-save] <dir>… — prepend dirs to PATH and save them to config.kdl (like fish_add_path)",
    "add_to_path": "add_to_path — alias for add-path",
    "remove-path": "remove-path <dir>… — remove dirs from PATH and from config.kdl",
    "exit": "exit [code] — leave the shell (default code 0)",
    "quit": "quit [code] — alias for exit",
    "ignore": "ignore — discard pipeline input; emit nothing",
    "identity": "identity — pass pipeline input through unchanged",
    "input": "input [prompt] — read multi-line text until Ctrl+D (pipe into next stage)",
    "range": "range <end> | range <start> <end> — integer range list",
    "append": "append <values>… — append values to list input",
    "prepend": "prepend <values>… — prepend values to list input",
    "is-empty": "is-empty — true if list/table/string input has length 0",
    "is_empty": "is_empty — alias for is-empty",
    "table": "table — coerce list of records (or table) into a table",
    "columns": "columns — column names of a table, or keys of a record",
    "flatten": "flatten — one level of list-of-lists flattening",
    "values": "values — list of values from a record",
    "keys": "keys — list of keys from a record",
    "sys": "sys — host info record (cwd, home, shell, last_exit)",
    "ps": "ps [-l|--long] — system processes table (pid, name, cpu, mem, …)",
    "whyport": "whyport [-a|--all] [-l|--long] <port> — who is bound to a TCP/UDP port",
    "now": "now — current time as Unix epoch seconds (prints as local datetime)",
    "about": "about — authorship, ATProto handle, and a little sparkle",
    "self-update": "self-update [--check] — update the nimshell AppImage to the latest release",
    "version": "version — nimshell version and build info",
    "less": "less [-S] [file]… — page pipeline input or files (ANSI colors kept)",
  }.toTable

proc missingHelp*(): seq[string] =
  ## Registered builtins that lack a dedicated help entry (should be empty).
  let h = helpText()
  for n in names():
    if not h.hasKey(n): result.add n

proc helpLine(name: string): Option[string] =
  let h = helpText()
  if h.hasKey(name): some(h[name])
  elif isBuiltin(name): some(name & " — builtin command")
  else: none(string)

proc httpHelpText(): string =
  @[
    "http <method> <url> [body] — make an HTTP request",
    "",
    "Subcommands:",
    "  get <url>              GET request",
    "  post <url> [body]      POST (body from arg or pipeline input)",
    "  put <url> [body]       PUT",
    "  delete <url> [body]    DELETE",
    "  patch <url> [body]     PATCH",
    "  head <url>             HEAD (headers only)",
    "",
    "Flags:",
    "  -H, --headers <record|string>  request headers (record or \"Name: value\")",
    "  -t, --content-type <type>      Content-Type for the body",
    "  -u, --user <name>              basic-auth username",
    "  -p, --password <pass>          basic-auth password",
    "  -m, --max-time <secs>          response timeout in seconds (default 30)",
    "  -k, --insecure                 skip TLS certificate verification",
    "  -r, --raw                      keep body as text (do not parse JSON)",
    "  -f, --full                     return {status, headers, body, url}",
    "  -e, --allow-errors             do not fail on non-2xx status",
    "",
    "JSON responses are parsed into structured data unless --raw is set.",
    "Structured request bodies (records/lists/tables) are JSON-encoded and",
    "sent with Content-Type: application/json when no type is specified.",
    "",
    "Examples:",
    "  http get https://example.com",
    "  http get --full https://httpbin.org/get",
    "  http post https://httpbin.org/post {name: alice}",
    "  http get -H {accept: application/json} https://api.example.com/v1",
    "  echo {x: 1} | http post https://httpbin.org/post",
  ].join("\n")

proc helpFor(name: string): Option[string] =
  ## Full help text for `help <name>`, including subcommands where relevant.
  case name
  of "to":
    some(@[
      "to <format> — convert pipeline input to a text format",
      "",
      "Subcommands:",
      "  json [--raw|-r] [--indent|-i n] — JSON string (pretty by default;",
      "                                   --raw is compact, no trailing newline)",
      "",
      "Examples:",
      "  range 3 | to json",
      "  ls | to json --raw",
    ].join("\n"))
  of "from":
    some(@[
      "from <format> — parse text input into structured data",
      "",
      "Subcommands:",
      "  json — parse a JSON string (pipeline input or a string argument)",
      "  jwt  — decode a JWT (JWS compact) into header/payload/signature",
      "",
      "JWT notes: does not verify the signature; only base64url-decodes and",
      "parses the JSON header and claims. Optional \"Bearer \" prefix is",
      "stripped. Signature is returned as the original base64url segment.",
      "",
      "Examples:",
      "  open data.json | from json",
      "  echo '{\"a\": 1}' | from json | get a",
      "  echo $token | from jwt | get payload",
      "  echo $token | from jwt | get header.alg",
      "  from jwt eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.…",
    ].join("\n"))
  of "http": some(httpHelpText())
  of "cat":
    some(@[
      "cat <path> — read a text file as a string",
      "",
      "On a color TTY: truecolor syntax highlight (json, nim, gleam, toml,",
      "markdown), bat-style line numbers, and a filename header.",
      "Detection uses the extension, then a light content sniff.",
      "Binary files are refused.",
      "",
      "Flags:",
      "  -r, --raw                 plain text (no colors; safe for pipelines)",
      "  -l, --language <id>       force language (json|nim|gleam|toml|markdown|plain)",
      "",
      "Examples:",
      "  cat README.md",
      "  cat src/nimshell.nim",
      "  cat data.json --raw | from json",
      "  cat notes.txt --language markdown",
    ].join("\n"))
  of "find":
    some(@[
      "find [-i] [-v] [--regex pat] [--columns cols] <term>… — search pipeline input",
      "",
      "Filters lists/tables for items matching any term (OR). Strings use",
      "substring match; numbers/bools match by equality. Multi-line strings",
      "are split into lines (unless --multiline).",
      "",
      "Flags:",
      "  -i, --ignore-case     case-insensitive match",
      "  -v, --invert          keep non-matching items",
      "  -r, --regex <pat>     PCRE regex (not combined with terms)",
      "  -c, --columns <list>  only search these table columns",
      "  -m, --multiline       do not split multi-line strings into lines",
      "",
      "Examples:",
      "  ls | find toml md",
      "  echo [moe larry curly] | find l",
      "  echo [Hello world] | find hello -i",
      "  echo [abc odb abf] | find --regex \"b.\"",
    ].join("\n"))
  of "less":
    some(@[
      "less [-S|--chop-long-lines] [file]… — page pipeline input or files (ANSI colors kept)",
      "",
      "Builtin pager inspired by less -FRX: colors from tools and nimshell",
      "tables pass through; if the text fits on one screen (or stdout is not",
      "a TTY), it is printed and the pager exits. Use `^less` for the",
      "external binary on PATH.",
      "",
      "Flags:",
      "  -S, --chop-long-lines  cut long lines at the window edge instead of",
      "                         wrapping them; scroll sideways with ← / →",
      "",
      "Keys (interactive):",
      "  j / ↓ / Enter     line down     k / ↑        line up",
      "  space / f / PgDn  page down     b / PgUp     page up",
      "  g / Home          top           G / End      bottom",
      "  mouse wheel       scroll (hold Shift to select text)",
      "  S                 toggle chop mode: cut long lines instead of wrapping",
      "  ← / →             scroll sideways (chop mode)   0 / $  left / right edge",
      "  /pattern          live search   n / N        next/prev",
      "  ?                 help          q / Ctrl+C   quit",
      "",
      "Examples:",
      "  ls | less",
      "  less -S server.log",
      "  cat README.md | less",
      "  less README.md",
      "  ^jj log | less",
    ].join("\n"))
  of "ps":
    some(@[
      "ps [-l|--long] — view system processes as a table",
      "",
      "Inspired by Nushell `ps`. Default columns: pid, ppid, name, status,",
      "cpu, mem, virtual. With --long, also: command, start_time, user_id,",
      "process_group_id, session_id, priority, process_threads, working,",
      "paged, cwd.",
      "",
      "Flags:",
      "  -l, --long   include all available columns",
      "",
      "Examples:",
      "  ps",
      "  ps | sort-by mem | last 5",
      "  ps | sort-by cpu | last 3",
      "  ps --long | where name == nimshell",
      "  ps | where pid == 1 | get name",
    ].join("\n"))
  of "whyport":
    some(@[
      "whyport [-a|--all] [-l|--long] <port> — who is bound to a port",
      "",
      "Answers “why is this port taken?” Default: local listeners only",
      "(TCP LISTEN + UDP binds), short columns — not every ESTABLISHED",
      "client or TIME_WAIT row, and not full command lines.",
      "",
      "Flags:",
      "  -a, --all    all sockets touching the port (local or remote),",
      "               like `lsof -i :<port>` (adds state + remote cols)",
      "  -l, --long   extra columns: family, command, user_id, fd",
      "",
      "Default columns: protocol, local_address, local_port, pid, name",
      "With --all:     + remote_address, remote_port, state",
      "With --long:    + family, command, user_id, fd",
      "",
      "Accepts the port as an argument or pipeline input. Leading `:` is",
      "optional (`whyport 8080` and `whyport :8080` are the same).",
      "",
      "Examples:",
      "  whyport 22",
      "  whyport 4004",
      "  whyport --all 4004",
      "  whyport -al 8080",
      "  echo 3000 | whyport",
    ].join("\n"))
  of "now":
    some(@[
      "now — current Unix time (epoch seconds)",
      "",
      "Inspired by Nushell `date now`. Returns an int of UTC epoch seconds,",
      "the same representation as `ls` modified / `ps` start_time. Display",
      "formats it as a local 12-hour datetime (e.g. Jul 26 2026 3:17:35 AM).",
      "",
      "Examples:",
      "  now",
      "  let t = now",
      "  ls | where modified > 1700000000",
    ].join("\n"))
  of "input":
    some(@[
      "input [prompt] — read multi-line text from the terminal (or stdin)",
      "",
      "Type or paste freely; finish with Ctrl+D (EOF). The collected text is",
      "a string you can pipe into anything — `from json`, `lines`, `save`, …",
      "",
      "Interactive: after Enter on the command line, paste content, then Ctrl+D.",
      "Piped: `printf '…' | nimshell -c 'input | from json'` drains stdin.",
      "",
      "Optional prompt string is printed before reading (on its own line).",
      "Ctrl+C cancels.",
      "",
      "Examples:",
      "  input | from json",
      "  input | lines | find TODO",
      "  input \"Paste JWT:\" | from jwt | get payload",
      "  input | save notes.txt",
      "  let body = input",
    ].join("\n"))
  else: helpLine(name)

proc cmdHelp(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len == 1 and args[0].kind == vkString:
    let name = args[0].s
    let text = helpFor(name)
    if text.isSome: return ok(env, strV(text.get))
    return err(env, "unknown command: " & name)
  var lines = @[
    "nimshell — a Nim shell inspired by Nushell (port of gleshell)",
    "",
    "Pipelines pass structured data (not just text):",
    "  ls | where type == file | select name size",
    "  open data.json | get users | first 3",
    "  range 5 | reverse",
    "",
    "Commands:"]
  for n in names():
    let l = helpLine(n)
    lines.add "  " & (if l.isSome: l.get else: n)
  lines.add @[
    "",
    "Use `help <command>` for details. `^cmd` forces an external binary.",
    "Variables: `let x = ...` then `$x`. Pipeline input is `$in`.",
    "Env: `$env`, `$env.HOME`, `$env.FOO = bar` (process environment)."]
  ok(env, strV(lines.join("\n")))

# --- echo / fs ---

proc cmdEcho(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  case args.len
  of 0: ok(env, input)
  of 1: ok(env, args[0])
  else: ok(env, listV(args))

proc cmdPwd(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ok(env, strV(env.cwd))

proc cmdCd(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  var target = ""
  if args.len == 0 or (args.len == 1 and args[0].kind == vkString and args[0].s == "~"):
    let (hasHome, home) = homeDir()
    target = if hasHome: home else: "/"
  elif args.len == 1 and args[0].kind == vkString:
    target = resolvePath(env, args[0].s)
  if target == "": return err(env, "cd: expected path")
  let (success, env2, msg) = setCwd(env, target)
  if success: ok(env2, nothing()) else: err(env, "cd: " & msg)

proc cmdLs(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  let path = if args.len == 1 and args[0].kind == vkString: resolvePath(env, args[0].s)
             else: env.cwd
  if not dirExists(path):
    return err(env, "ls: " & (if fileExists(path): "not a directory" else: "no such file or directory") & ": " & path)
  var entries: seq[string]
  try:
    for kind, full in walkDir(path, relative = true): entries.add full
  except OSError as e:
    return err(env, "ls: " & e.msg)
  entries.sort()
  var records: seq[Value]
  for name in entries:
    let full = path / name
    try:
      let info = getFileInfo(full, followSymlink = false)
      let ftype = case info.kind
        of pcFile: "file"
        of pcDir: "dir"
        of pcLinkToFile, pcLinkToDir: "symlink"
      records.add recordV(@[("name", strV(name)), ("type", strV(ftype)),
                            ("size", intV(int64(info.size))),
                            ("modified", intV(info.lastWriteTime.toUnix))])
    except OSError:
      records.add recordV(@[("name", strV(name)), ("type", strV("unknown")),
                            ("size", intV(0)), ("modified", intV(0))])
  ok(env, tableFromRecords(records))

proc readFileResult(path: string): (bool, string, string) =
  if dirExists(path): return (false, "", "is a directory")
  if not fileExists(path): return (false, "", "no such file or directory")
  try: (true, readFile(path), "")
  except IOError as e: (false, "", e.msg)

proc catLanguageFlag(flags: Flags, lang: var Option[Language]): string =
  ## `--language` / `-l` override. Returns a user-facing error, or "".
  let v = flagValue(flags, ["language", "l"])
  if v.isNone: return ""
  if v.get.kind == vkNothing or (v.get.kind == vkBool and v.get.b):
    return "language flag requires a name (json, nim, gleam, toml, markdown, plain)"
  let name = asString(v.get)
  var l: Language
  if not languageFromName(name, l):
    return "unknown language `" & name & "` (try json, nim, gleam, toml, markdown, plain)"
  lang = some(l)
  ""

proc cmdCat(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  # Boolean flags may steal the next word (`cat --raw path` → flag raw = path).
  let (raw, stolenR) = findBoolFlag(flags, ["raw", "r"])
  var langOverride = none(Language)
  let langErr = catLanguageFlag(flags, langOverride)
  if langErr != "": return err(env, "cat: " & langErr)
  let candidates = args & stolenR
  if candidates.len != 1 or candidates[0].kind != vkString:
    return err(env, "cat: expected path (try `cat <path>`; --raw / --language <id> optional)")
  let path = resolvePath(env, candidates[0].s)
  let (success, content, msg) = readFileResult(path)
  if not success: return err(env, "cat: " & msg)
  if isBinary(content):
    return err(env, "cat: binary file (refusing to print; use an external tool)")
  let language = if langOverride.isSome: langOverride.get else: detect(path, content)
  ok(env, strV(if raw: content else: present(enabled(), language, path, content)))

proc cmdOpen(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len != 1 or args[0].kind != vkString: return err(env, "open: expected path")
  let path = resolvePath(env, args[0].s)
  let (success, content, msg) = readFileResult(path)
  if not success: return err(env, "open: " & msg)
  if path.toLowerAscii.endsWith(".json"):
    let (okJ, v, jmsg) = parseJsonValue(content)
    if okJ: ok(env, v) else: err(env, "open: " & jmsg)
  else:
    ok(env, strV(content))

proc cmdSave(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len != 1 or args[0].kind != vkString: return err(env, "save: expected path")
  let path = resolvePath(env, args[0].s)
  try:
    writeFile(path, asString(input))
    ok(env, nothing())
  except IOError as e:
    err(env, "save: " & e.msg)

# --- table ops ---

proc rowMatches(row: Value, field, op: string, rhs: Value): bool =
  let (found, lhs, _) = getField(row, field)
  if not found: return false
  let (cmpOk, c, _) = compare(lhs, rhs)
  case op
  of "==", "eq": equals(lhs, rhs)
  of "!=", "ne": not equals(lhs, rhs)
  of ">", "gt": cmpOk and c == cmpGt
  of "<", "lt": cmpOk and c == cmpLt
  of ">=", "ge": cmpOk and c in {cmpGt, cmpEq}
  of "<=", "le": cmpOk and c in {cmpLt, cmpEq}
  else: false

proc cmdWhere(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len != 3 or args[0].kind != vkString or args[1].kind != vkString:
    return err(env, "where: expected `where <field> <op> <value>` e.g. type == file")
  let (success, rows, msg) = tableToRecords(input)
  if not success: return err(env, "where: " & msg)
  var kept: seq[Value]
  for row in rows:
    if rowMatches(row, args[0].s, args[1].s, args[2]): kept.add row
  ok(env, tableFromRecords(kept))

# --- find (Nushell-style search filter) ---

type FindOpts = object
  terms: seq[Value]
  regex: Option[string]
  ignoreCase: bool

proc textMatches(text: string, o: FindOpts, matched: var bool): string =
  if o.regex.isSome:
    let (success, m, msg) = reContains(text, o.regex.get, o.ignoreCase)
    if not success: return "invalid regex: " & msg
    matched = m
    return ""
  let hay = if o.ignoreCase: toLower(text) else: text
  matched = false
  for t in o.terms:
    let needle = if o.ignoreCase: toLower(asString(t)) else: asString(t)
    if needle == "" or hay.contains(needle):
      matched = true
      return ""
  ""

proc itemMatches(item: Value, o: FindOpts, columns: Option[seq[string]],
                 matched: var bool): string =
  matched = false
  case item.kind
  of vkRecord:
    for t in o.terms:
      if equals(item, t):
        matched = true
        return ""
    for (k, v) in item.fields:
      if columns.isSome and k notin columns.get: continue
      let e = itemMatches(v, o, none(seq[string]), matched)
      if e != "" or matched: return e
    ""
  of vkList:
    for v in item.items:
      let e = itemMatches(v, o, none(seq[string]), matched)
      if e != "" or matched: return e
    textMatches(asString(item), o, matched)
  # Scalars: strings substring-match; numbers/bools only by equality
  # (Nu: `find 5` does not keep 35) unless a regex is given.
  of vkString: textMatches(item.s, o, matched)
  of vkInt, vkFloat, vkBool, vkNothing:
    if o.regex.isSome: return textMatches(asString(item), o, matched)
    for t in o.terms:
      if equals(item, t): matched = true
    ""
  else:
    for t in o.terms:
      if equals(item, t):
        matched = true
        return ""
    textMatches(asString(item), o, matched)

proc filterItems(items: seq[Value], o: FindOpts, invert: bool,
                 columns: Option[seq[string]], kept: var seq[Value]): string =
  for item in items:
    var m: bool
    let e = itemMatches(item, o, columns, m)
    if e != "": return e
    if m != invert: kept.add item
  ""

proc cmdFind(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  # Boolean flags may steal the next word (`find -i hello` → flag i = "hello").
  let (ignoreCase, stolenI) = findBoolFlag(flags, ["i", "ignore-case"])
  let (invert, stolenV) = findBoolFlag(flags, ["v", "invert"])
  let (multiline, stolenM) = findBoolFlag(flags, ["m", "multiline"])
  let (_, stolenN) = findBoolFlag(flags, ["n", "no-highlight"])
  let (_, stolenS) = findBoolFlag(flags, ["s", "dotall"])
  let (_, stolenRf) = findBoolFlag(flags, ["R", "rfind"])
  var regex = none(string)
  let rv = flagValue(flags, ["regex", "r"])
  if rv.isSome:
    if rv.get.kind == vkBool and rv.get.b:
      return err(env, "find: regex flag requires a pattern (try `find --regex <pat>`)")
    regex = some(asString(rv.get))
  var columns = none(seq[string])
  let cv = flagValue(flags, ["columns", "c"])
  if cv.isSome:
    var cols: seq[string]
    if cv.get.kind == vkList:
      for it in cv.get.items: cols.add asString(it)
    else: cols.add asString(cv.get)
    columns = some(cols)
  let terms = args & stolenI & stolenV & stolenM & stolenN & stolenS & stolenRf
  if terms.len == 0 and regex.isNone:
    return err(env, "find: expected search term(s) or --regex <pattern>")
  if terms.len > 0 and regex.isSome:
    return err(env, "find: cannot use --regex with additional search terms")
  let o = FindOpts(terms: terms, regex: regex, ignoreCase: ignoreCase)
  var kept: seq[Value]
  case input.kind
  of vkList:
    let e = filterItems(input.items, o, invert, columns, kept)
    if e != "": return err(env, "find: " & e)
    ok(env, listV(kept))
  of vkTable:
    let (_, rows, _) = tableToRecords(input)
    let e = filterItems(rows, o, invert, columns, kept)
    if e != "": return err(env, "find: " & e)
    ok(env, tableFromRecords(kept))
  of vkString:
    if multiline or '\n' notin input.s:
      var m: bool
      let e = textMatches(input.s, o, m)
      if e != "": return err(env, "find: " & e)
      ok(env, if m != invert: input else: nothing())
    else:
      var lines: seq[Value]
      for l in input.s.split("\n"): lines.add strV(l)
      let e = filterItems(lines, o, invert, none(seq[string]), kept)
      if e != "": return err(env, "find: " & e)
      ok(env, listV(kept))
  of vkNothing:
    err(env, "find: pipeline input is required (try `ls | find term`)")
  else:
    var m: bool
    let e = itemMatches(input, o, columns, m)
    if e != "": return err(env, "find: " & e)
    ok(env, if m != invert: input else: nothing())

proc cmdSelect(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  var cols: seq[string]
  for a in args:
    if a.kind == vkString: cols.add a.s
  if cols.len == 0: return err(env, "select: expected column names")
  let (success, rows, msg) = tableToRecords(input)
  if not success: return err(env, "select: " & msg)
  var selected: seq[Value]
  for row in rows:
    if row.kind == vkRecord:
      var fields: seq[(string, Value)]
      for c in cols:
        var v: Value
        fields.add((c, if keyFind(row.fields, c, v): v else: nothing()))
      selected.add recordV(fields)
    else:
      selected.add row
  ok(env, tableFromRecords(selected))

proc cmdGet(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len == 1 and args[0].kind == vkInt:
    let rows = asRows(input)
    let i = args[0].i
    if i >= 0 and i < rows.len: return ok(env, rows[i])
    return err(env, "get: index out of bounds")
  if args.len == 1 and args[0].kind == vkString:
    let (pOk, path, pErr) = parseCellPath(args[0].s)
    if not pOk: return err(env, "get: " & pErr)
    let (gOk, v, gErr) = getPath(input, path)
    if gOk: return ok(env, v)
    return err(env, "get: " & gErr)
  err(env, "get: expected field name, dotted path, or index")

proc sliceRange(total, n: int, fromEnd: bool): (int, int) =
  let k = clamp(n, 0, total)
  if fromEnd: (total - k, total) else: (0, k)

proc takeN(env: Env, input: Value, n: int, fromEnd: bool): BuiltinResult =
  case input.kind
  of vkTable:
    let (a, b) = sliceRange(input.rows.len, n, fromEnd)
    let rows = input.rows[a ..< b]
    if n == 1 and rows.len == 1: ok(env, zipRow(input.columns, rows[0]))
    else: ok(env, tableV(input.columns, rows))
  of vkList:
    let (a, b) = sliceRange(input.items.len, n, fromEnd)
    let items = input.items[a ..< b]
    if n == 1 and items.len == 1: ok(env, items[0])
    else: ok(env, listV(items))
  of vkString:
    let cs = runeSeq(input.s)
    let (a, b) = sliceRange(cs.len, n, fromEnd)
    ok(env, strV(cs[a ..< b].join("")))
  else: ok(env, input)

proc countArg(args: seq[Value]): int =
  if args.len == 1 and args[0].kind == vkInt and args[0].i > 0: int(args[0].i) else: 1

proc cmdFirst(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  takeN(env, input, countArg(args), false)

proc cmdLast(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  takeN(env, input, countArg(args), true)

proc cmdTake(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len == 1 and args[0].kind == vkInt: takeN(env, input, int(args[0].i), false)
  else: err(env, "take: expected count")

proc cmdSkip(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if not (args.len == 1 and args[0].kind == vkInt): return err(env, "skip: expected count")
  let n = max(0, int(args[0].i))
  case input.kind
  of vkTable: ok(env, tableV(input.columns, input.rows[min(n, input.rows.len) .. ^1]))
  of vkList: ok(env, listV(input.items[min(n, input.items.len) .. ^1]))
  else: ok(env, input)

proc cmdLength(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ok(env, intV(lengthOf(input)))

proc cmdReverse(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  case input.kind
  of vkList: ok(env, listV(input.items.reversed))
  of vkTable: ok(env, tableV(input.columns, input.rows.reversed))
  of vkString: ok(env, strV(runeSeq(input.s).reversed.join("")))
  else: ok(env, input)

proc cmdSortBy(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if not (args.len == 1 and args[0].kind == vkString):
    return err(env, "sort-by: expected field name")
  let field = args[0].s
  let (success, rows, msg) = tableToRecords(input)
  if not success: return err(env, "sort-by: " & msg)
  var sortedRows = rows
  sortedRows.sort(proc(a, b: Value): int =
    let va = getField(a, field)[1]
    let vb = getField(b, field)[1]
    let (cOk, c, _) = compare(va, vb)
    if cOk:
      case c
      of cmpLt: -1
      of cmpEq: 0
      of cmpGt: 1
    else: cmp(asString(va), asString(vb)))
  ok(env, tableFromRecords(sortedRows))

proc cmdUniq(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if input.kind != vkList: return ok(env, input)
  var outItems: seq[Value]
  for item in input.items:
    var dup = false
    for x in outItems:
      if equals(x, item): dup = true
    if not dup: outItems.add item
  ok(env, listV(outItems))

proc cmdWrap(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len == 1 and args[0].kind == vkString: ok(env, recordV(@[(args[0].s, input)]))
  else: err(env, "wrap: expected column name")

proc cmdUnwrap(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len == 1 and args[0].kind == vkString:
    let (found, v, msg) = getField(input, args[0].s)
    return if found: ok(env, v) else: err(env, "unwrap: " & msg)
  if args.len == 0:
    if input.kind == vkRecord and input.fields.len > 0: return ok(env, input.fields[0][1])
    return err(env, "unwrap: expected single-field record or field name")
  err(env, "unwrap: expected field name")

# --- to / from ---

proc cmdToJson(env: Env, input: Value, flags: Flags): BuiltinResult =
  # Default: pretty-print with 2-space indent (like Nu). `--raw` / `-r` is compact.
  let raw = flagSet(flags, "raw") or flagSet(flags, "r")
  var indent = none(int)
  if not raw:
    let i1 = flagInt(flags, "indent")
    let i2 = flagInt(flags, "i")
    indent = some(if i1.isSome: int(i1.get) elif i2.isSome: int(i2.get) else: 2)
  let body = encodeJson(input, indent)
  # Nu's default includes a trailing newline; `--raw` omits it.
  ok(env, strV(if indent.isNone: body else: body & "\n"))

proc cmdTo(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len == 0: return err(env, "to: expected subcommand (try `to json`; see `help to`)")
  if args[0].kind != vkString: return err(env, "to: expected subcommand name")
  if args[0].s == "json": return cmdToJson(env, input, flags)
  err(env, "to: unknown subcommand: " & args[0].s)

proc cmdFromJson(env: Env, input: Value, args: seq[Value]): BuiltinResult =
  let source =
    if args.len == 1 and args[0].kind == vkString: args[0].s
    elif args.len == 0: asString(input)
    else: ""
  if source == "": return err(env, "from: json: empty input")
  let (success, v, msg) = parseJsonValue(source)
  if success: ok(env, v) else: err(env, "from: json: " & msg)

proc base64UrlDecode(s: string, decoded: var string): bool =
  var t = ""
  for c in s:
    case c
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9': t.add c
    of '-': t.add '+'
    of '_': t.add '/'
    of '=': discard
    else: return false
  if t.len mod 4 == 1: return false
  while t.len mod 4 != 0: t.add '='
  try:
    decoded = base64.decode(t)
    true
  except ValueError:
    false

proc decodeJwtPart(segment, part: string, v: var Value): string =
  if segment == "": return part & ": empty segment"
  var text: string
  if not base64UrlDecode(segment, text): return part & ": invalid base64url"
  if validateUtf8(text) >= 0: return part & ": not valid UTF-8 after decode"
  let (success, parsed, msg) = parseJsonValue(text)
  if not success: return part & ": JSON: " & msg
  v = parsed
  ""

proc parseJwt(token: string, v: var Value): string =
  ## Parse a compact JWT into `{ header, payload, signature }`. Does **not**
  ## verify the signature. The signature stays the original base64url text.
  var cleaned = token.strip
  if cleaned.toLowerAscii.startsWith("bearer "): cleaned = cleaned[7 .. ^1].strip
  let parts = cleaned.split(".")
  if parts.len != 3:
    return "expected 3 dot-separated segments (header.payload.signature), got " & $parts.len
  var header, payload: Value
  var e = decodeJwtPart(parts[0], "header", header)
  if e != "": return e
  e = decodeJwtPart(parts[1], "payload", payload)
  if e != "": return e
  v = recordV(@[("header", header), ("payload", payload), ("signature", strV(parts[2]))])
  ""

proc cmdFromJwt(env: Env, input: Value, args: seq[Value]): BuiltinResult =
  let source =
    if args.len == 1: asString(args[0])
    elif args.len == 0: asString(input)
    else: ""
  if source.strip == "": return err(env, "from: jwt: empty input")
  var v: Value
  let e = parseJwt(source, v)
  if e == "": ok(env, v) else: err(env, "from: jwt: " & e)

proc cmdFrom(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len == 0:
    return err(env, "from: expected subcommand (try `from json` or `from jwt`; see `help from`)")
  if args[0].kind != vkString: return err(env, "from: expected subcommand name")
  case args[0].s
  of "json": cmdFromJson(env, input, args[1 .. ^1])
  of "jwt": cmdFromJwt(env, input, args[1 .. ^1])
  else: err(env, "from: unknown subcommand: " & args[0].s)

# --- http (Nushell-style HTTP client with method subcommands) ---

proc httpLooksLikeUrl(s: string): bool =
  s.startsWith("http://") or s.startsWith("https://") or s.contains("://")

proc httpParseHeaderLine(s: string): seq[(string, string)] =
  let idx = s.find(':')
  if idx >= 0: @[(s[0 ..< idx].strip, s[idx + 1 .. ^1].strip)]
  elif s.strip == "": @[]
  else: @[(s.strip, "")]

proc httpParseHeaders(v: Value): seq[(string, string)] =
  case v.kind
  of vkRecord:
    for (k, x) in v.fields: result.add((k, asString(x)))
  of vkList:
    for it in v.items:
      if it.kind == vkString: result.add httpParseHeaderLine(it.s)
      elif it.kind == vkRecord:
        for (k, x) in it.fields: result.add((k, asString(x)))
  of vkString: result = httpParseHeaderLine(v.s)
  else: discard

proc httpDecodeBody(body: string, contentType: string): Value =
  let lower = contentType.toLowerAscii
  let trimmed = body.strip
  if lower.contains("json") or trimmed.startsWith("{") or trimmed.startsWith("["):
    let (success, v, _) = parseJsonValue(body)
    if success: return v
  strV(body)

proc cmdHttp(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len == 0:
    return err(env, "http: expected subcommand (try `http get <url>`; see `help http`)")
  if args[0].kind != vkString: return err(env, "http: expected subcommand name")
  let sub = args[0].s.toLowerAscii
  let meth = case sub
    of "get": HttpGet
    of "post": HttpPost
    of "put": HttpPut
    of "delete": HttpDelete
    of "patch": HttpPatch
    of "head": HttpHead
    else: return err(env, "http: unknown subcommand: " & args[0].s)
  let methodName = sub.toUpperAscii
  # Boolean flags may steal the next word as their value
  # (`http get --full https://…` → flag full = "https://…").
  let (full, stolenF) = findBoolFlag(flags, ["full", "f"])
  let (raw, stolenR) = findBoolFlag(flags, ["raw", "r"])
  let (insecure, stolenK) = findBoolFlag(flags, ["insecure", "k"])
  let (allowErrors, stolenE) = findBoolFlag(flags, ["allow-errors", "e"])
  var candidates = args[1 .. ^1] & stolenF & stolenR & stolenK & stolenE
  if candidates.len == 0: return err(env, "http: " & methodName & ": expected URL")
  # Prefer a URL-shaped string; otherwise the first value.
  var urlIdx = 0
  for i, c in candidates:
    if c.kind == vkString and httpLooksLikeUrl(c.s):
      urlIdx = i
      break
  let url = asString(candidates[urlIdx]).strip
  candidates.delete(urlIdx)
  if url == "": return err(env, "http: " & methodName & ": empty URL")
  let parsed = parseUri(url)
  if parsed.scheme notin ["http", "https"] or parsed.hostname == "":
    return err(env, "http: " & methodName & ": invalid URL: " & url)
  # Body: first remaining positional, else pipeline input (not for GET/HEAD).
  var bodyText = ""
  var autoJson = false
  if meth notin {HttpGet, HttpHead}:
    var body = none(Value)
    if candidates.len > 0: body = some(candidates[0])
    elif input.kind notin {vkNothing, vkFail}: body = some(input)
    if body.isSome:
      case body.get.kind
      of vkString: bodyText = body.get.s
      of vkNothing: discard
      else:
        bodyText = encodeJson(body.get, none(int))
        autoJson = true
  let headers = newHttpHeaders()
  let contentType = flagString(flags, ["content-type", "t"])
  if contentType.isSome: headers["content-type"] = contentType.get
  elif autoJson: headers["content-type"] = "application/json"
  let hv = flagValue(flags, ["headers", "H"])
  if hv.isSome:
    for (k, v) in httpParseHeaders(hv.get): headers[k.toLowerAscii] = v
  let user = flagString(flags, ["user", "u"])
  if user.isSome:
    let pass = flagString(flags, ["password", "p"])
    headers["authorization"] = "Basic " &
      base64.encode(user.get & ":" & (if pass.isSome: pass.get else: ""))
  var timeoutMs = 30_000
  let mt = flagValue(flags, ["max-time", "m"])
  if mt.isSome:
    try:
      let secs = if mt.get.kind == vkInt: int(mt.get.i) else: parseInt(asString(mt.get))
      if secs > 0: timeoutMs = secs * 1000
    except ValueError: discard
  var client: HttpClient
  try:
    client = newShellClient(url, timeoutMs, headers, insecure)
  except CatchableError as e:
    return err(env, "http: " & methodName & ": " & e.msg)
  defer: client.close()
  var resp: Response
  try:
    resp = client.request(url, httpMethod = meth, body = bodyText)
  except TimeoutError:
    return err(env, "http: " & methodName & ": response timed out")
  except CatchableError as e:
    return err(env, "http: " & methodName & ": " & e.msg)
  let status = resp.code.int
  let respBody = try: resp.body except CatchableError: ""
  let bodyVal = if raw: strV(respBody)
                else: httpDecodeBody(respBody, resp.headers.getOrDefault("content-type"))
  let okStatus = status >= 200 and status < 300
  if not (okStatus or allowErrors):
    var msg = "http: " & methodName & ": HTTP " & $status & " from " & url
    if not full and respBody.strip != "":
      msg.add ": " & runeSeq(respBody.strip)[0 ..< min(200, runeSeq(respBody.strip).len)].join("")
    return err(env, msg)
  if full:
    var hdrs: seq[(string, Value)]
    for k, v in resp.headers: hdrs.add((k, strV(v)))
    return ok(env, recordV(@[("status", intV(status)), ("headers", recordV(hdrs)),
                             ("body", bodyVal), ("url", strV(url))]))
  ok(env, bodyVal)

# --- misc ---

proc cmdLines(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if input.kind != vkString: return err(env, "lines: expected string input")
  var lines: seq[Value]
  for l in input.s.split("\n"): lines.add strV(l)
  ok(env, listV(lines))

proc cmdType(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ok(env, strV(typeName(input)))

proc cmdDescribe(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ok(env, recordV(@[("type", strV(typeName(input))),
                    ("length", intV(lengthOf(input))),
                    ("value", strV(asString(input)))]))

proc cmdEnv(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len == 1 and args[0].kind == vkString:
    return ok(env, getVar(env, "env." & args[0].s))
  if args.len == 0:
    # Process environment (same data as `$env`), as a name/value table
    var rows: seq[Value]
    for (k, v) in envRecord(env).fields:
      rows.add recordV(@[("name", strV(k)), ("value", strV(envToString(k, v)))])
    return ok(env, tableFromRecords(rows))
  err(env, "env: unexpected args (use `env` or `env NAME`)")

proc whichMaybeFollow(follow: bool, path: string): string =
  ## With `-f`/`--follow`, resolve symlinks to a canonical absolute path.
  if not follow: return path
  let (success, resolved) = realpath(path)
  if success: resolved else: path

proc pathDirArg(env: Env, v: Value): string =
  ## `~/bin`, `./bin`, `bin` → absolute directory path.
  let p = expandHome(asString(v))
  normalizedPath(if p.isAbsolute: p else: env.cwd / p)

proc pathResult(env: Env): BuiltinResult =
  ok(setExit(env, 0), getVar(env, "env.PATH"))

proc currentPathDirs(): seq[string] =
  for part in getEnv("PATH").split(':'):
    if part != "": result.add part

proc cmdAddPath(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ## Like fish's `fish_add_path`: move/prepend dirs to the front of `PATH` and
  ## save them as `path "…"` lines in config.kdl for future sessions.
  let (noSave, stolen) = findBoolFlag(flags, ["n", "no-save"])
  let dirsIn = args & stolen
  if dirsIn.len == 0:
    return err(env, "add-path: expected directory (try `add-path [--no-save] <dir>…`)")
  var dirs: seq[string]
  for v in dirsIn:
    let d = pathDirArg(env, v)
    if not dirExists(d): return err(env, "add-path: not a directory: " & d)
    if d notin dirs: dirs.add d
  updatePath(dirs, prepend = true)
  if not noSave:
    let msg = addConfigPaths(dirs)
    if msg != "": return err(env, "add-path: " & msg)
  pathResult(env)

proc cmdRemovePath(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ## Undo `add-path`: drop dirs from `PATH` and from config.kdl.
  if args.len == 0:
    return err(env, "remove-path: expected directory (try `remove-path <dir>…`)")
  var dirs: seq[string]
  for v in args: dirs.add pathDirArg(env, v)
  var path: seq[string]
  for d in currentPathDirs():
    if d notin dirs: path.add d
  setenv("PATH", path.join(":"))
  let msg = removeConfigPaths(dirs)
  if msg != "": return err(env, "remove-path: " & msg)
  pathResult(env)

proc cmdWhich(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  # Boolean flags may steal the next word (`which -a name` → flag a = "name").
  let (all, stolenA) = findBoolFlag(flags, ["a", "all"])
  let (follow, stolenF) = findBoolFlag(flags, ["f", "follow"])
  let cands = args & stolenA & stolenF
  if cands.len != 1: return err(env, "which: expected name (try `which [-a] [-f] <name>`)")
  let name = asString(cands[0])
  let builtin = isBuiltin(name)
  let aliasText = if isAlias(name): "alias: " & name & " = " & aliases[name].source else: ""
  if all:
    var matches: seq[Value]
    if aliasText != "": matches.add strV(aliasText)
    if builtin: matches.add strV("builtin: " & name)
    for p in whichAll(name): matches.add strV(whichMaybeFollow(follow, p))
    case matches.len
    of 0: return err(env, "which: " & name & " not found")
    of 1: return ok(env, matches[0])
    else: return ok(env, listV(matches))
  if aliasText != "": return ok(env, strV(aliasText))
  if builtin: return ok(env, strV("builtin: " & name))
  let (found, path) = which(name)
  if found: ok(env, strV(whichMaybeFollow(follow, path)))
  else: err(env, "which: " & name & " not found")

proc cmdExit(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  let code = if args.len == 1 and args[0].kind == vkInt: int(args[0].i) else: 0
  BuiltinResult(kind: brExit, code: code)

proc cmdIgnore(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ok(env, nothing())

proc cmdIdentity(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ok(env, input)

proc cmdInput(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if args.len > 1:
    return err(env, "input: expected at most one prompt string (see `help input`)")
  let prompt = if args.len == 1: asString(args[0]) else: ""
  let (success, text) = readUserInput(prompt)
  if success: ok(env, strV(text))
  elif text == "interrupted": err(env, "input: interrupted")
  else: err(env, "input: " & text)

proc cmdRange(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  var start, stop: int64
  if args.len == 1 and args[0].kind == vkInt:
    stop = args[0].i
  elif args.len == 2 and args[0].kind == vkInt and args[1].kind == vkInt:
    start = args[0].i
    stop = args[1].i
  else:
    return err(env, "range: expected `range <end>` or `range <start> <end>`")
  var items: seq[Value]
  var i = start
  while i < stop:
    items.add intV(i)
    inc i
  ok(env, listV(items))

proc cmdAppend(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if input.kind == vkList: ok(env, listV(input.items & args))
  else: err(env, "append: expected list input")

proc cmdPrepend(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if input.kind == vkList: ok(env, listV(args & input.items))
  else: err(env, "prepend: expected list input")

proc cmdIsEmpty(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ok(env, boolV(lengthOf(input) == 0))

proc cmdTable(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  let (success, rows, msg) = tableToRecords(input)
  if success: ok(env, tableFromRecords(rows)) else: err(env, "table: " & msg)

proc cmdColumns(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  var cols: seq[Value]
  case input.kind
  of vkTable:
    for c in input.columns: cols.add strV(c)
  of vkRecord:
    for (k, _) in input.fields: cols.add strV(k)
  else: return err(env, "columns: expected table or record")
  ok(env, listV(cols))

proc cmdFlatten(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if input.kind != vkList: return ok(env, input)
  var flat: seq[Value]
  for it in input.items:
    if it.kind == vkList: flat.add it.items else: flat.add it
  ok(env, listV(flat))

proc cmdValues(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if input.kind != vkRecord: return err(env, "values: expected record")
  var vals: seq[Value]
  for (_, v) in input.fields: vals.add v
  ok(env, listV(vals))

proc cmdKeys(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  if input.kind != vkRecord: return err(env, "keys: expected record")
  var ks: seq[Value]
  for (k, _) in input.fields: ks.add strV(k)
  ok(env, listV(ks))

proc cmdSys(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  let (hasHome, home) = homeDir()
  ok(env, recordV(@[("cwd", strV(env.cwd)), ("home", strV(if hasHome: home else: "")),
                    ("shell", strV("nimshell")), ("last_exit", intV(env.lastExit))]))

proc cmdNow(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  # Same representation as `ls` modified / `ps` start_time: raw epoch seconds.
  ok(env, intV(unixNow()))

proc processToRecord(p: ProcessInfo, long: bool): Value =
  var fields = @[("pid", intV(p.pid)), ("ppid", intV(p.ppid)), ("name", strV(p.name)),
                 ("status", strV(p.status)), ("cpu", floatV(p.cpu)),
                 ("mem", intV(p.mem)), ("virtual", intV(p.virtual))]
  if long:
    fields.add @[("command", strV(p.command)), ("start_time", intV(p.startTime)),
                 ("user_id", intV(p.userId)), ("process_group_id", intV(p.processGroupId)),
                 ("session_id", intV(p.sessionId)), ("priority", intV(p.priority)),
                 ("process_threads", intV(p.processThreads)),
                 ("working", intV(p.working)), ("paged", intV(p.paged)),
                 ("cwd", strV(p.cwd))]
  recordV(fields)

proc cmdPs(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  let (long, _) = findBoolFlag(flags, ["l", "long"])
  var records: seq[Value]
  for p in listProcesses(): records.add processToRecord(p, long)
  ok(env, tableFromRecords(records))

# --- whyport ---

proc parsePortValue(v: Value, port: var int): string =
  var n: int64
  case v.kind
  of vkInt: n = v.i
  of vkString:
    var cleaned = v.s.strip
    let body = if cleaned.startsWith(":"): cleaned[1 .. ^1].strip else: cleaned
    try: n = parseBiggestInt(body)
    except ValueError: return "whyport: invalid port: " & cleaned
  else: return "whyport: expected port number, got " & typeName(v)
  if n < 0 or n > 65_535: return "whyport: port out of range (0–65535): " & $n
  port = int(n)
  ""

proc whyportColumns(all, long: bool): seq[string] =
  result = @["protocol", "local_address", "local_port", "pid", "name"]
  if all: result.add @["remote_address", "remote_port", "state"]
  if long: result.add @["family", "command", "user_id", "fd"]

proc cmdWhyport(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  let (all, stolenA) = findBoolFlag(flags, ["a", "all"])
  let (long, stolenL) = findBoolFlag(flags, ["l", "long"])
  # Bool flags may steal the port (`whyport --all 4004` → flag value 4004).
  let portArgs = args & stolenA & stolenL
  var port: int
  var e = ""
  if portArgs.len == 1: e = parsePortValue(portArgs[0], port)
  elif portArgs.len == 0:
    if input.kind == vkNothing:
      e = "whyport: expected port number (e.g. `whyport 8080`; see `help whyport`)"
    else: e = parsePortValue(input, port)
  else: e = "whyport: expected a single port number"
  if e != "": return err(env, e)
  var records: seq[Value]
  for s in listPortSockets(port):
    # Default: local listeners only (TCP LISTEN or an unconnected UDP bind).
    if not all:
      if s.localPort != port: continue
      let listening = case s.protocol
        of "tcp": s.state == "LISTEN"
        of "udp": s.remotePort == 0
        else: s.state == "LISTEN" or s.remotePort == 0
      if not listening: continue
    var fields = @[("protocol", strV(s.protocol)), ("local_address", strV(s.localAddress)),
                   ("local_port", intV(s.localPort)), ("pid", intV(s.pid)),
                   ("name", strV(s.name))]
    if all:
      fields.add @[("remote_address", strV(s.remoteAddress)),
                   ("remote_port", intV(s.remotePort)), ("state", strV(s.state))]
    if long:
      fields.add @[("family", strV(s.family)), ("command", strV(s.command)),
                   ("user_id", intV(s.userId)), ("fd", intV(s.fd))]
    records.add recordV(fields)
  if records.len == 0: ok(env, tableV(whyportColumns(all, long), @[]))
  else: ok(env, tableFromRecords(records))

# --- less ---

proc cmdLess(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  # `-S` / `--chop-long-lines` may steal a following file name as its value.
  let (chop, stolen) = findBoolFlag(flags, ["S", "chop-long-lines"])
  let args = args & stolen
  var text = ""
  if args.len == 0:
    case input.kind
    of vkNothing: return err(env, "less: no input (pipe data or pass a file path)")
    # Keep external text byte-for-byte so embedded ANSI is not re-painted.
    of vkString: text = input.s
    else: text = render(input)
  else:
    var parts: seq[string]
    for a in args:
      if a.kind != vkString: return err(env, "less: expected file path")
      let (success, content, msg) = readFileResult(resolvePath(env, a.s))
      if not success: return err(env, "less: " & msg)
      parts.add content
    text = parts.join("\n")
  if needsPaging(text, chop):
    pager.run(text, chop)
    ok(env, nothing())
  else:
    # Fits on one screen or not a TTY: emit the text so the REPL / -c path
    # prints it once.
    ok(env, strV(text))

# --- self-update / version ---

proc cmdSelfUpdate(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  let (check, _) = findBoolFlag(flags, ["check", "c"])
  let r = selfUpdate(checkOnly = check)
  if not r.ok: return err(env, "self-update: " & r.message)
  if r.updated: ok(env, strV(r.message & " (restart nimshell to use it)"))
  else: ok(env, strV(r.message))

proc cmdAliases(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  var rows: seq[seq[Value]]
  for n in aliasNames(): rows.add @[strV(n), strV(aliases[n].source)]
  ok(env, tableV(@["name", "expansion"], rows))

proc cmdVersion(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  let image = appImagePath()
  ok(env, recordV(@[("version", strV(NimshellVersion)),
                    ("nim", strV(NimVersion)),
                    ("arch", strV(archName())),
                    ("appimage", if image != "": strV(image) else: nothing()),
                    ("auto_update", boolV(autoUpdateEnabled()))]))

# --- about ---

proc cmdAbout(env: Env, input: Value, args: seq[Value], flags: Flags): BuiltinResult =
  ok(env, strV(@[
    "          ✨ nimshell ✨",
    "   a structured-data shell in Nim",
    "   a port of gleshell · inspired by Nushell · pipelines with types",
    "",
    "        ╱|、",
    "      (˚ˎ 。7",
    "       |、˜〵",
    "       じしˍ,)ノ  meow · you found the about page",
    "",
    "   author     NaNdi",
    "   handle     @nandi.uk",
    "   atproto    did:plc:ngokl2gnmpbvuvrfckja3g7p",
    "   web        https://latha.org",
    "   licence    Apache-2.0",
    "",
    "   \"a category is a quiver under the free functor\"",
    "",
    "   🐚  type `help` to explore · `^cmd` for externals",
    "   💜  made for people who pipe records, not just text",
  ].join("\n")))

# --- registry ---

let registryTable = {
  "help": Builtin(cmdHelp),
  "echo": cmdEcho,
  "print": cmdEcho,
  "ls": cmdLs,
  "pwd": cmdPwd,
  "cd": cmdCd,
  "cat": cmdCat,
  "open": cmdOpen,
  "save": cmdSave,
  "where": cmdWhere,
  "filter": cmdWhere,
  "find": cmdFind,
  "select": cmdSelect,
  "get": cmdGet,
  "first": cmdFirst,
  "last": cmdLast,
  "take": cmdTake,
  "skip": cmdSkip,
  "length": cmdLength,
  "count": cmdLength,
  "reverse": cmdReverse,
  "sort-by": cmdSortBy,
  "sort_by": cmdSortBy,
  "uniq": cmdUniq,
  "wrap": cmdWrap,
  "unwrap": cmdUnwrap,
  # Nushell-style: `to` / `from` with format subcommands (`json`, `jwt`)
  "to": cmdTo,
  "from": cmdFrom,
  # Nushell-style: `http get|post|put|delete|patch|head`
  "http": cmdHttp,
  "lines": cmdLines,
  "typeof": cmdType,
  "type": cmdType,
  "describe": cmdDescribe,
  "env": cmdEnv,
  "which": cmdWhich,
  "add-path": cmdAddPath,
  "add_to_path": cmdAddPath,
  "remove-path": cmdRemovePath,
  "exit": cmdExit,
  "quit": cmdExit,
  "ignore": cmdIgnore,
  "identity": cmdIdentity,
  "input": cmdInput,
  "range": cmdRange,
  "append": cmdAppend,
  "prepend": cmdPrepend,
  "is-empty": cmdIsEmpty,
  "is_empty": cmdIsEmpty,
  "table": cmdTable,
  "columns": cmdColumns,
  "flatten": cmdFlatten,
  "values": cmdValues,
  "keys": cmdKeys,
  "sys": cmdSys,
  "ps": cmdPs,
  "whyport": cmdWhyport,
  "now": cmdNow,
  "about": cmdAbout,
  "less": cmdLess,
  "self-update": cmdSelfUpdate,
  "version": cmdVersion,
  "aliases": cmdAliases,
}.toTable

proc lookup*(name: string, b: var Builtin): bool =
  if registryTable.hasKey(name):
    b = registryTable[name]
    return true
  false

proc isBuiltin*(name: string): bool = registryTable.hasKey(name)

proc names*(): seq[string] =
  for k in registryTable.keys: result.add k
  result.sort()

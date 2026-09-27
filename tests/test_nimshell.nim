## Test suite — ported from gleshell's gleeunit tests.

import std/[options, os, strutils, unittest]
import ../src/nimshell/[alias, builtins, color, config, kdl, display, env, eval, highlight, lexer,
                        lineedit, netclient, pager, parser, prompt, syntax, sys,
                        update, value]

proc evalOk(src: string, e = newEnv()): Value =
  let r = evalSource(e, src)
  doAssert r.kind == erContinue, "expected Continue for: " & src
  r.value

proc evalEnv(src: string, e = newEnv()): (Env, Value) =
  let r = evalSource(e, src)
  doAssert r.kind == erContinue
  (r.env, r.value)

proc lexOk(src: string): seq[Token] =
  var err: LexError
  doAssert tokenize(src, result, err), "lex failed: " & err.message

proc parseOk(src: string): Statement =
  var msg: string
  doAssert parse(src, result, msg), "parse failed: " & msg

proc argsOf(src: string): seq[Arg] =
  let st = parseOk(src)
  doAssert st.kind == stExpr and st.pipeline.commands.len == 1
  st.pipeline.commands[0].args

proc strArg(s: string): Arg = valueArg(lit(strV(s)))

proc field(v: Value, key: string): Value =
  var found: Value
  doAssert v.kind == vkRecord and keyFind(v.fields, key, found), "missing field " & key
  found

suite "lexer":
  test "pipeline":
    let t = lexOk("ls | where type == file")
    check t[0] == ident("ls")
    check t[1] == tok(tkPipe)
    check t[2] == ident("where")

  test "strings and numbers":
    check lexOk("echo \"hi\" 42 3.14 true") ==
      @[ident("echo"), strLit("hi"), intLit(42), floatLit(3.14), boolLit(true), tok(tkEof)]

  test "path idents":
    check lexOk("ls .jj ./src ../foo /tmp ~ ~/code") ==
      @[ident("ls"), ident(".jj"), ident("./src"), ident("../foo"), ident("/tmp"),
        ident("~"), ident("~/code"), tok(tkEof)]

  test "bare double dash":
    check lexOk("nix run . -- chadfowler.com yolo") ==
      @[ident("nix"), ident("run"), ident("."), flag(""), ident("chadfowler.com"),
        ident("yolo"), tok(tkEof)]
    check lexOk("cmd --think --scale 3") ==
      @[ident("cmd"), flag("think"), flag("scale"), intLit(3), tok(tkEof)]

  test "flake ref hash":
    check lexOk("nix run nixpkgs#hello .#package") ==
      @[ident("nix"), ident("run"), ident("nixpkgs#hello"), ident(".#package"), tok(tkEof)]
    check lexOk("echo hi # not parsed") == @[ident("echo"), ident("hi"), tok(tkEof)]

  test "ssh user@host":
    check lexOk("git clone git@tangled.org:tranquil.farm/tranquil-pds") ==
      @[ident("git"), ident("clone"), ident("git@tangled.org"), tok(tkColon),
        ident("tranquil.farm/tranquil-pds"), tok(tkEof)]
    var toks: seq[Token]
    var err: LexError
    check not tokenize("@alone", toks, err)
    check err.message == "unexpected character '@'"
    check err.position == 0

suite "parser":
  test "ssh git url glue":
    check argsOf("git clone git@tangled.org:tranquil.farm/tranquil-pds") ==
      @[strArg("clone"), strArg("git@tangled.org:tranquil.farm/tranquil-pds")]

  test "flake ref":
    check argsOf("nix shell nixpkgs#cowsay") == @[strArg("shell"), strArg("nixpkgs#cowsay")]

  test "bare double dash":
    check argsOf("nix run . -- chadfowler.com yolo") ==
      @[strArg("run"), strArg("."), strArg("--"), strArg("chadfowler.com"), strArg("yolo")]

  test "ls dotfile":
    check argsOf("ls .jj") == @[strArg(".jj")]

  test "port spec args":
    check argsOf("lsof -i :4004") == @[flagArg("i"), strArg(":4004")]
    check argsOf("lsof -i:4004") == @[flagArg("i"), strArg(":4004")]
    check argsOf("echo host:4004 http://example.com") ==
      @[strArg("host:4004"), strArg("http://example.com")]

  test "pipeline":
    let st = parseOk("ls | first 3")
    check st.pipeline.commands.len == 2
    check st.pipeline.commands[0].name == "ls"
    check st.pipeline.commands[1].args == @[valueArg(lit(intV(3)))]

  test "let":
    let st = parseOk("let x = echo 1")
    check st.kind == stLet
    check st.name == "x"
    check st.pipeline.commands[0].args == @[valueArg(lit(intV(1)))]

  test "where ops":
    check argsOf("where type == file") == @[strArg("type"), strArg("=="), strArg("file")]

  test "list and record":
    check argsOf("echo [1 2] {a: true}") == @[
      valueArg(Expr(kind: exList, items: @[lit(intV(1)), lit(intV(2))])),
      valueArg(Expr(kind: exRecord, fields: @[("a", lit(boolV(true)))]))]

  test "env assign":
    let st = parseOk("$env.FOO = hello")
    check st.kind == stEnvAssign
    check st.name == "FOO"
    check st.pipeline.commands[0].name == "__value__"
    check st.pipeline.commands[0].args == @[strArg("hello")]
    let p = parseOk("$PATH = $PATH | append /x")
    check p.kind == stEnvAssign and p.name == "PATH"

suite "values":
  test "table from records":
    let t = tableFromRecords(@[
      recordV(@[("name", strV("a")), ("n", intV(1))]),
      recordV(@[("name", strV("b")), ("n", intV(2))])])
    check t == tableV(@["name", "n"], @[@[strV("a"), intV(1)], @[strV("b"), intV(2)]])

  test "nothing is falsey":
    check not isTruthy(nothing())
    check isTruthy(intV(1))

suite "eval":
  test "echo and range":
    check evalOk("range 3") == listV(@[intV(0), intV(1), intV(2)])
    check evalOk("echo hello") == strV("hello")

  test "reverse | first":
    check evalOk("range 3 | reverse | first") == intV(2)

  test "pipeline stdin to external":
    let a = evalOk("let n = echo hello | ^wc -c")
    check a.kind == vkString and "5" in a.s
    let b = evalOk("let m = echo ab|^wc -c")
    check b.kind == vkString and "2" in b.s

  test "external argv keeps short vs long flag dashes":
    let v = evalOk("^printf '%s,' -fr --force -x --y target")
    check v.kind == vkString and v.s.strip == "-fr,--force,-x,--y,target,"
    check lexOk("rm -fr x")[1].short
    check not lexOk("rm --fr x")[1].short

  test "let and var":
    let (e2, v) = evalEnv("let n = echo 7")
    check v == intV(7)
    check evalOk("echo $n", e2) == intV(7)

  test "env var get":
    let home = getEnv("HOME")
    check evalOk("echo $env.HOME") == strV(home)
    check evalOk("$env.HOME") == strV(home)

  test "get dotted path":
    check evalOk("echo {user: {name: \"ada\"}} | get user.name") == strV("ada")
    check evalOk("echo {a: {b: {c: 42}}} | get a.b.c") == intV(42)
    check evalOk("echo {items: [{n: \"x\"}, {n: \"y\"}]} | get items.n") ==
      listV(@[strV("x"), strV("y")])
    let f = evalOk("echo {a: 1} | get a.b")
    check f.kind == vkFail and "get:" in f.msg

  test "env record":
    let r = evalOk("$env")
    check r.kind == vkRecord
    check field(r, "HOME").kind == vkString
    check field(r, "PATH").kind == vkList
    check evalOk("$env | get HOME").s.len > 0

  test "env assign":
    let (e2, v) = evalEnv("$env.NIMSHELL_TEST_VAR = nimshell-test-val")
    check v == strV("nimshell-test-val")
    check evalOk("$env.NIMSHELL_TEST_VAR", e2) == strV("nimshell-test-val")
    check getEnv("NIMSHELL_TEST_VAR") == "nimshell-test-val"

  test "PATH is a list":
    let saved = getEnv("PATH")
    putEnv("PATH", "/usr/bin:/bin")
    check evalOk("$env.PATH") == listV(@[strV("/usr/bin"), strV("/bin")])
    check evalOk("$PATH") == evalOk("$env.PATH")
    check evalOk("$env | get PATH | length") == intV(2)
    let (_, v) = evalEnv("$env.PATH = $env.PATH | append ~/nimshell-bin")
    check v.kind == vkList
    check getEnv("PATH") == "/usr/bin:/bin:" & (getHomeDir() / "nimshell-bin")
    discard evalEnv("$PATH = $PATH | prepend /opt/x")
    check getEnv("PATH").startsWith("/opt/x:/usr/bin:")
    discard evalEnv("$env.PATH = \"/a:/b\"")
    check evalOk("$PATH") == listV(@[strV("/a"), strV("/b")])
    let rows = evalOk("env | where name == PATH | get value")
    check rows == listV(@[strV("/a:/b")])
    putEnv("PATH", saved)

  test "add-path / remove-path edit config.kdl":
    let savedPath = getEnv("PATH")
    let savedCfg = getEnv("XDG_CONFIG_HOME")
    let tmp = getTempDir() / "nimshell-addpath-test"
    removeDir(tmp)
    createDir(tmp / "bin")
    createDir(tmp / "bin2")
    createDir(tmp / "cfg" / "nimshell")
    putEnv("XDG_CONFIG_HOME", tmp / "cfg")
    let cfg = configFile()
    writeFile(cfg, "// keep me\npath {\n    append \"/opt/x\"\n}\n")
    putEnv("PATH", "/usr/bin:/bin")
    let v = evalOk("add_to_path " & (tmp / "bin"))
    check v.kind == vkList and v.items[0] == strV(tmp / "bin")
    check getEnv("PATH") == (tmp / "bin") & ":/usr/bin:/bin"
    check readFile(cfg) == "// keep me\npath {\n    append \"/opt/x\"\n}\npath \"" &
      (tmp / "bin") & "\"\n"
    # already saved: no duplicate line
    discard evalOk("add-path " & (tmp / "bin"))
    check configPathDirs() == @["/opt/x", tmp / "bin"]
    # --no-save changes PATH only
    discard evalOk("add-path --no-save " & (tmp / "bin2"))
    check getEnv("PATH").startsWith((tmp / "bin2") & ":")
    check configPathDirs() == @["/opt/x", tmp / "bin"]
    check evalOk("add-path " & (tmp / "missing")).kind == vkFail
    # removal drops the line and the dir inside the block
    discard evalOk("remove-path " & (tmp / "bin") & " /opt/x")
    check (tmp / "bin") notin getEnv("PATH").split(':')
    check readFile(cfg) == "// keep me\npath {\n}\n"
    # legacy `paths` file migrates into config.kdl
    writeFile(tmp / "cfg" / "nimshell" / "paths", (tmp / "bin2") & "\n")
    check loadConfig().len == 0
    check not fileExists(tmp / "cfg" / "nimshell" / "paths")
    check configPathDirs() == @[tmp / "bin2"]
    putEnv("PATH", savedPath)
    putEnv("XDG_CONFIG_HOME", savedCfg)
    removeDir(tmp)

  test "where + select":
    let r = evalOk("echo [{name: a, n: 1} {name: b, n: 2} {name: c, n: 3}] | table | where n > 1 | select name")
    check r == tableV(@["name"], @[@[strV("b")], @[strV("c")]])

  test "length":
    check evalOk("range 4 | length") == intV(4)

  test "about":
    let t = evalOk("about").s
    for needle in ["nimshell", "nandi.uk", "NaNdi", "did:plc:ngokl2gnmpbvuvrfckja3g7p", "latha.org"]:
      check needle in t
    check evalOk("which about") == strV("builtin: about")

  test "help covers all builtins":
    check missingHelp().len == 0
    check evalOk("which table") == strV("builtin: table")
    let h = evalOk("help table").s
    check "table" in h and "coerce" in h
    check "json" in evalOk("help to").s
    check "json" in evalOk("help from").s
    let hh = evalOk("help http").s
    check "get" in hh and "post" in hh
    let all = evalOk("help").s
    for n in names(): check n in all
    let (e2, f) = evalEnv("help not-a-real-cmd")
    check f.kind == vkFail and "unknown command" in f.msg
    check e2.lastExit == 1

  test "from json":
    let r = evalOk("echo \"{\\\"x\\\": 1}\" | from json")
    check field(r, "x") == intV(1)

  test "from jwt":
    let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    let r = evalOk("echo \"" & token & "\" | from jwt")
    check field(field(r, "header"), "alg") == strV("HS256")
    check field(field(r, "header"), "typ") == strV("JWT")
    check field(field(r, "payload"), "sub") == strV("1234567890")
    check field(field(r, "payload"), "name") == strV("John Doe")
    check field(field(r, "payload"), "iat") == intV(1516239022)
    check field(r, "signature") == strV("SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c")
    check evalOk("from jwt \"Bearer " & token & "\"").kind == vkRecord
    check evalOk("echo \"" & token & "\" | from jwt | get header | get alg") == strV("HS256")
    check evalOk("echo \"" & token & "\" | from jwt | get header.alg") == strV("HS256")
    let (e2, bad) = evalEnv("echo not-a-jwt | from jwt")
    check bad.kind == vkFail and ("segments" in bad.msg or "base64" in bad.msg)
    check e2.lastExit == 1
    let empty = evalOk("echo \"\" | from jwt")
    check empty.kind == vkFail and "empty" in empty.msg
    check "jwt" in evalOk("help from").s

  test "to json":
    let pretty = evalOk("echo [1 2 3] | to json").s
    check "\n" in pretty and "1" in pretty
    check evalOk("echo [1 2 3] | to json --raw") == strV("[1,2,3]")
    let (e2, f) = evalEnv("echo 1 | to")
    check f.kind == vkFail and "subcommand" in f.msg
    check e2.lastExit == 1
    check "unknown subcommand" in evalOk("echo 1 | to yaml").msg
    let raw = evalOk("echo {a: 1, b: true} | to json -r").s
    check "\"a\":1" in raw and "\"b\":true" in raw

  test "http subcommand errors":
    let (e2, f) = evalEnv("http")
    check f.kind == vkFail and "subcommand" in f.msg
    check e2.lastExit == 1
    check "unknown subcommand" in evalOk("http foo").msg
    let m3 = evalOk("http get").msg
    check "URL" in m3 or "url" in m3
    check "invalid URL" in evalOk("http get not-a-url").msg
    check evalOk("which http") == strV("builtin: http")

  test "ps":
    let t = evalOk("ps")
    check t.kind == vkTable
    check t.columns == @["pid", "ppid", "name", "status", "cpu", "mem", "virtual"]
    check t.rows.len > 0
    when defined(linux):
      check evalOk("ps | where pid == 1").rows.len > 0
    let long = evalOk("ps --long")
    check "command" in long.columns and "start_time" in long.columns and "cwd" in long.columns
    check long.columns.len > t.columns.len
    check evalOk("which ps") == strV("builtin: ps")
    check "--long" in evalOk("help ps").s

  test "whyport":
    check evalOk("whyport 1").columns == @["protocol", "local_address", "local_port", "pid", "name"]
    let allCols = evalOk("whyport --all 1").columns
    check "state" in allCols and "remote_port" in allCols and "command" notin allCols
    let longCols = evalOk("whyport --long 1").columns
    check "command" in longCols and "family" in longCols and "state" notin longCols
    check evalOk("whyport 1").rows.len == 0
    check evalOk("whyport :22").kind == vkTable
    check evalOk("echo 22 | whyport").kind == vkTable
    check evalOk("whyport --all 22").kind == vkTable
    check "port" in evalOk("whyport").msg
    let bad = evalOk("whyport notaport").msg
    check "invalid" in bad or "port" in bad
    check "range" in evalOk("whyport 99999").msg
    check evalOk("which whyport") == strV("builtin: whyport")
    let h = evalOk("help whyport").s
    check "--all" in h and "--long" in h

  test "now":
    let secs = evalOk("now").i
    let wall = unixNow()
    check secs > 1_700_000_000
    check secs <= wall + 2 and secs >= wall - 5
    check evalOk("now | typeof") == strV("int")
    let text = renderWith(false, intV(secs))
    check $secs notin text
    check ":" in text
    check " AM" in text or " PM" in text
    check "42" in renderWith(false, intV(42))
    check evalOk("which now") == strV("builtin: now")

  test "input":
    check evalOk("which input") == strV("builtin: input")
    check "Ctrl+D" in evalOk("help input").s
    check evalOk("input too many args").kind == vkFail

  test "which":
    check evalOk("which ls") == strV("builtin: ls")
    let all = evalOk("which -a ls")
    check all.kind == vkList and all.items[0] == strV("builtin: ls")
    let sh = evalOk("which sh")
    check sh.kind == vkString and sh.s.endsWith("/sh")
    let followed = evalOk("which -f sh")
    check followed.kind == vkString and followed.s.startsWith("/")

suite "find":
  test "list":
    check evalOk("echo [moe larry curly] | find l") == listV(@[strV("larry"), strV("curly")])
    check evalOk("echo [a.toml b.md c.rs] | find toml md") == listV(@[strV("a.toml"), strV("b.md")])
    check evalOk("echo [1 5 3 4 35] | find 5") == listV(@[intV(5)])

  test "ignore case / invert":
    let want = listV(@[strV("Hello"), strV("HELLO")])
    check evalOk("echo [Hello world HELLO] | find hello -i") == want
    check evalOk("echo [Hello world HELLO] | find -i hello") == want
    check evalOk("echo [ab cd] | find --invert a") == listV(@[strV("cd")])

  test "table and string":
    let t = evalOk("echo [{name: Cargo.toml} {name: README.md}] | table | find toml")
    check t.kind == vkTable and t.rows.len == 1
    check evalOk("echo Cargo.toml | find Cargo") == strV("Cargo.toml")
    check evalOk("echo Cargo.toml | find zz") == nothing()
    check evalOk("echo \"hi\nbye\nhi there\" | find hi") == listV(@[strV("hi"), strV("hi there")])

  test "regex":
    check evalOk("echo [abc odb arc abf] | find --regex \"b.\"") == listV(@[strV("abc"), strV("abf")])
    check evalOk("echo [abc] | find --regex \"b.\" x").kind == vkFail

suite "display":
  test "plain has no ansi":
    check '\e' notin renderWith(false, boolV(true))
  test "colored has ansi":
    check '\e' in renderWith(true, boolV(true))
  test "preserves external ansi":
    let app = "\e[31mred\e[0m"
    check renderWith(true, strV(app)) == app
  test "multiline string not recolored":
    check renderWith(true, strV("a\nb")) == "a\nb"
  test "table headers colored":
    check "\e[1;32m" in renderWith(true, tableV(@["name"], @[@[strV("x")]]))
  test "filesize units":
    check formatFilesize(0) == "0 B"
    check formatFilesize(512) == "512 B"
    check formatFilesize(1023) == "1023 B"
    check formatFilesize(1024) == "1 KB"
    check formatFilesize(1536) == "1.5 KB"
    check formatFilesize(1_048_576) == "1 MB"
    check formatFilesize(1_048_576 + 524_288) == "1.5 MB"
    check formatFilesize(1_073_741_824) == "1 GB"
  test "size column humanized":
    check "1.5 KB" in renderWith(false, tableV(@["size"], @[@[intV(1536)]]))
  test "datetime shape":
    let t = formatDatetime(1_700_000_000)
    check ":" in t and (" AM" in t or " PM" in t)
  test "ls includes modified":
    let r = evalOk("ls | first 1")
    check r.kind == vkRecord
    check field(r, "modified").kind == vkInt

suite "pager":
  test "visible length strips ansi":
    check visibleLength("\e[31mabc\e[0m") == 3
  test "wrap respects ansi width":
    let lines = wrapLine("\e[31mabcdefgh\e[0m", 4)
    check lines.len == 2
    check stripAnsi(lines[0]) == "abcd"
    check stripAnsi(lines[1]) == "efgh"
  test "display lines split newlines":
    check displayLines("a\nb\nc", 80) == @["a", "b", "c"]
  test "strip ansi":
    check stripAnsi("\e[1;32mhi\e[0m there") == "hi there"
  test "line matches":
    let painted = "\e[31mneedle\e[0m"
    check lineMatches(painted, "needle")
    check lineMatches(painted, "eed")
    check lineMatches(painted, "NEEDLE")
    check lineMatches(painted, "NeEd")
    check not lineMatches(painted, "")
    check not lineMatches(painted, "[31m")
  test "find after / before":
    let lines = @["alpha", "beta", "alpha two", "gamma"]
    check findAfter(lines, "alpha", -1) == some((0, false))
    check findAfter(lines, "alpha", 0) == some((2, false))
    check findAfter(lines, "alpha", 2) == some((0, true))
    check findAfter(lines, "zzz", -1).isNone
    check findAfter(lines, "ALPHA", -1) == some((0, false))
    check findBefore(lines, "alpha", 3) == some((2, false))
    check findBefore(lines, "alpha", 2) == some((0, false))
    check findBefore(lines, "alpha", 0) == some((2, true))
    check findAfter(lines, "", -1).isNone
    check findBefore(lines, "", 2).isNone
  test "live search preview":
    let lines = @["zero", "alpha", "beta", "alpha again"]
    check liveSearchPreview(lines, "", 2) == (2, none(string), none(string))
    check liveSearchPreview(lines, "alpha", 0) == (1, some("alpha"), none(string))
    check liveSearchPreview(lines, "alpha", 2) == (3, some("alpha"), none(string))
    check liveSearchPreview(lines, "zzz", 1) == (1, some("zzz"), some("not found"))
  test "highlight matches":
    let o = highlightMatches("hello world", "world")
    check "\e[30;103m" in o and stripAnsi(o) == "hello world"
    check "\e[30;103m" in highlightMatches("Hello World", "WORLD")
    check highlightMatches("nope", "zzz") == "nope"
    check highlightMatches("x", "") == "x"
    check highlightMatches("aa x aa", "aa").count("\e[30;103m") == 2
    let hi = highlightMatches("\e[32mbcde\e[0m", "bcde")
    check stripAnsi(hi) == "bcde"
  test "less passthrough":
    check evalOk("echo hello | less") == strV("hello")
    check evalOk("which less") == strV("builtin: less")
    let colored = "\e[31mred\e[0m"
    check evalOk("less", setInput(newEnv(), strV(colored))).kind == vkFail
    let (e2, f) = evalEnv("less")
    check f.kind == vkFail and e2.lastExit == 1
    check "/pattern" in evalOk("help less").s

suite "highlight":
  test "plain when off":
    check highlight(false, "ls | first 3") == "ls | first 3"
  test "pipeline shapes":
    let t = highlight(true, "ls | first 3")
    check "\e[1;36mls" in t and "\e[1;35m|" in t and "\e[1;35m3" in t
  test "string and flag":
    let t = highlight(true, "echo \"hi\" --raw")
    check "\e[32m\"hi\"" in t and "\e[1;34m--raw" in t
  test "variable and let":
    let t = highlight(true, "let x = $in")
    check "\e[1;36mlet" in t and "\e[35m$in" in t
  test "incomplete string":
    check "\e[32m\"hel" in highlight(true, "echo \"hel")
  test "path arg not garbage":
    check "41m" notin highlight(true, "ls .jj ./src /tmp ~/code")

suite "syntax":
  test "language from path":
    check languageFromPath("data/foo.json") == Json
    check languageFromPath("src/main.gleam") == Gleam
    check languageFromPath("src/main.nim") == Nim
    check languageFromPath("gleam.toml") == Toml
    check languageFromPath("README.md") == Markdown
    check languageFromPath("notes.txt") == Plain
    check languageFromPath("Makefile") == Plain
  test "detect sniff":
    check detect("data", "{\"a\": 1}") == Json
    check detect("notes", "# Title\n\nbody") == Markdown
    check detect("x", "just words") == Plain
    check detect("x.toml", "{\"a\": 1}") == Toml
  test "is binary":
    check not isBinary("hello\nworld\t!")
    check isBinary("a\0b")
  test "paint json":
    let src = "{\"a\": 1, \"b\": true}"
    check paint(false, Json, src) == src
    let p = paint(true, Json, src)
    check '\e' in p and stripAnsi(p) == src
  test "paint nim":
    let src = "proc add(a: int): int = a + 1 # sum"
    let p = paint(true, Nim, src)
    check stripAnsi(p) == src
    check "\e[1;38;2;203;166;247mproc" in p
  test "paint toml / markdown":
    let t = "[package]\nname = \"x\""
    check stripAnsi(paint(true, Toml, t)) == t
    let m = "# Title\n\n- item **bold** `code`"
    check stripAnsi(paint(true, Markdown, m)) == m
  test "frame gutter":
    let f = frame("src/demo.nim", Nim, "a\nb\n")
    check "demo.nim" in f and "│" in f
    check stripAnsi(f).count("│") == 2
  test "cat raw and language":
    let path = getTempDir() / "nimshell_cat_test.json"
    writeFile(path, "{\"a\": 1}\n")
    check evalOk("cat " & path & " --raw") == strV("{\"a\": 1}\n")
    check evalOk("cat " & path & " --language plain").kind == vkString
    check "unknown language" in evalOk("cat " & path & " --language cobol").msg
    removeFile(path)

suite "completion and history":
  test "command builtins":
    let (m, k) = completeWord("", "ech")
    check k == "command" and "echo" in m
    let (m2, k2) = completeWord("ls | ", "wher")
    check k2 == "command" and "where" in m2
    check "from" in completeWord("", "fro")[0]
    check "let" in completeWord("", "le")[0]
  test "after assign":
    let (m, k) = completeWord("let x = ", "ran")
    check k == "command" and "range" in m
  test "path for args":
    check completeWord("echo ", "ech")[1] == "path"
  test "path-like command":
    check completeWord("", "./ec")[1] == "path"
    check completeWord("", "/us")[1] == "path"
  test "path executables":
    let (m, k) = completeWord("", "s")
    check k == "command" and "sh" in m
  test "history hint":
    let hist = @["ls | where type == file", "echo hi"]
    check historyHint(hist, "ls") == " | where type == file"
    check historyHint(@["ls | first 3", "ls | where x"], "ls") == " | first 3"
    check historyHint(hist, "ls | where") == " type == file"
    check historyHint(hist, "echo") == " hi"
    check historyHint(hist, "cd") == ""
    check historyHint(@["ls"], "ls") == ""
    check historyHint(hist, "") == ""
  test "history search":
    let hist = @["ls | first 3", "echo hi", "cd src"]
    check historySearch(hist, "") == hist
    check historySearch(hist, "   ") == hist
    check historySearch(@["echo a", "ls", "echo a", "cd"], "") == @["echo a", "ls", "cd"]
    let h2 = @["gleam test", "ls", "gleam build", "git status"]
    let hits = historySearch(h2, "gleam")
    check hits.len == 2 and "gleam test" in hits
    check "gleam test" in historySearch(h2, "gts")
    check "gleam test" in historySearch(h2, "GLEAM")
    check historySearch(hist, "zzzz-nope").len == 0

suite "prompt":
  test "git status parsing":
    let s = parseGitStatus("## main...origin/main [ahead 2, behind 1]\n M a.nim\nA  b.nim\n?? c.nim\n")
    check s.modified and s.staged and s.untracked and not s.conflicted
    check s.ahead == 2 and s.behind == 1
    check gitStatusText(s) == "[!+?] ⇡2⇣1"
    check gitStatusText(parseGitStatus("## main...origin/main\n")) == ""
    check gitStatusText(parseGitStatus("## main\nUU x\n")) == "[=]"
  test "duration":
    check formatDuration(850) == "850ms"
    check formatDuration(3000) == "3s"
    check formatDuration(3250) == "3.2s"
    check formatDuration(65_000) == "1m5s"
    check formatDuration(7_380_000) == "2h3m"
  test "status line":
    let home = getEnv("HOME")
    check statusLine(false, home / "code", "main", "[!]", 0, 0, false) == "~/code on main [!]"
    check statusLine(false, "/tmp", "", "", 1, 3200, false) == "/tmp took 3.2s ✘ 1"
    check statusLine(false, "/tmp", "dev", "", 0, 500, true) == "/tmp on  dev"
  test "prompt char":
    check promptChar(false, 0, false) == "❯ "
    check promptChar(false, 1, false) == "❯ "
    check "32m❯" in promptChar(true, 0, false)
    check "31m❯" in promptChar(true, 2, false)
    check promptChar(false, 0, true) == "  "

suite "terminal title":
  test "sanitize":
    check sanitizeTitle("ls | first 3") == "ls | first 3"
    check sanitizeTitle("echo \e[31mred\e[0m") == "echo red"
    check sanitizeTitle("a\x07b\nc  d ") == "a b c d"
    let long = sanitizeTitle("x".repeat(100), 10)
    check long == "xxxxxxxxx…"
  test "sequence":
    check titleSequence("vim notes.md") == "\e]0;vim notes.md\a"
  test "idle title":
    check idleTitle(getEnv("HOME") / "code") == "~/code"

suite "fit to terminal width":
  test "truncate visible":
    check truncateVisible("hello", 10) == "hello"
    check truncateVisible("hello world", 6) == "hello…"
    check truncateVisible("\e[31mhello world\e[0m", 6) == "\e[31mhello…\e[0m"
    check visibleLength(truncateVisible("\e[31mhello world\e[0m", 6)) == 6
  test "fit columns shrinks free text first":
    # name(40) type(4) size(4) modified(23): natural total 84
    let (w, shown) = fitColumns(@[40, 4, 4, 23], @[4, 4, 4, 8], 60, @[false, false, true, true])
    check shown == 4
    check w == @[16, 4, 4, 23]
  test "fit columns drops columns when too narrow":
    let (w, shown) = fitColumns(@[40, 4, 4, 23], @[4, 4, 4, 8], 20)
    check shown == 2
    check w[0 ..< 2] == @[5, 4] # 1 + (5+3) + (4+3) + marker 4 = 20
  test "unlimited width keeps natural widths":
    check fitColumns(@[40, 4], @[4, 4], 0) == (@[40, 4], 2)
  test "render fits every line":
    let t = tableV(@["name", "size", "note"], @[
      @[strV("x".repeat(80)), intV(1536), strV("y".repeat(50))],
      @[strV("short"), intV(0), strV("z")]])
    for width in [80, 50, 30, 16]:
      for line in renderWith(false, t, width).splitLines:
        check visibleLength(line) <= width
    check "…" in renderWith(false, t, 50)
    # unlimited (pipes / tests) keeps the full data
    check "x".repeat(80) in renderWith(false, t)
  test "records and lists truncate long values":
    let r = recordV(@[("k", strV("v".repeat(100)))])
    for line in renderWith(false, r, 40).splitLines: check visibleLength(line) <= 40
    let l = listV(@[strV("w".repeat(100))])
    for line in renderWith(false, l, 40).splitLines: check visibleLength(line) <= 40
  test "embedded newlines stay on one row":
    let t = tableV(@["a"], @[@[strV("one\ntwo")]])
    check renderWith(false, t).splitLines.len == 5

suite "pager chop mode (less -S)":
  test "logical lines":
    check logicalLines("a\r\nb\rc\nd") == @["a", "b", "c", "d"]
  test "slice visible":
    check sliceVisible("abcdefgh", 0, 3) == "abc"
    check sliceVisible("abcdefgh", 2, 3) == "cde"
    check sliceVisible("abcdefgh", 6, 5) == "gh"
    check sliceVisible("abc", 5, 3) == ""
    # color opened left of the window still applies; reset appended
    let s = sliceVisible("\e[32mabcdef\e[0m", 2, 2)
    check s.startsWith("\e[32m") and stripAnsi(s) == "cd" and s.endsWith("\e[0m")
  test "match column":
    check matchColumn("\e[31mhello\e[0m world", "WORLD") == 6
    check matchColumn("hello", "zzz") == -1
    check matchColumn("hello", "") == -1
  test "scroll to show match":
    let line = "x".repeat(100) & "needle"
    check hoffShowing(line, "needle", 0, 40) == 90   # 100 - 40 div 4
    check hoffShowing(line, "needle", 80, 40) == 80  # already visible
    check hoffShowing(line, "nope", 7, 40) == 7
  test "less -S flag":
    check evalOk("echo hello | less -S") == strV("hello")
    let path = getTempDir() / "nimshell_less_s.txt"
    writeFile(path, "short\n")
    check evalOk("less -S " & path) == strV("short\n")
    removeFile(path)
    check "--chop-long-lines" in evalOk("help less").s

suite "self-update":
  test "version comparison":
    check parseVersion("v1.2.3") == @[1, 2, 3]
    check parseVersion("0.2.0-rc1") == @[0, 2, 0]
    check isNewer("v0.2.0", "0.1.0")
    check isNewer("v0.10.0", "0.9.9")
    check isNewer("1.0", "0.9.9")
    check not isNewer("v0.2.0", "0.2.0")
    check not isNewer("v0.1.9", "0.2.0")
    check not isNewer("v0.2.0", "0.2.0-dev") # pre-release suffix ignored
  test "release tag from redirect":
    check tagFromLocation("https://github.com/o/r/releases/tag/v1.2.3") == "v1.2.3"
    check tagFromLocation("https://github.com/o/r/releases") == ""
    check tagFromLocation("") == ""
  test "asset name":
    check assetName("x86_64") == "nimshell-x86_64.AppImage"
  test "AppImage magic check":
    let path = getTempDir() / "nimshell_fake.AppImage"
    writeFile(path, "\x7fELF\x02\x01\x01\x00AI\x02rest")
    check looksLikeAppImage(path)
    writeFile(path, "<html>not found</html>")
    check not looksLikeAppImage(path)
    removeFile(path)
    check not looksLikeAppImage(path)
  test "not running from an AppImage":
    if getEnv("APPIMAGE") == "":
      check appImagePath() == ""
      check not autoUpdateEnabled()
    let v = evalOk("version")
    check field(v, "version") == strV(NimshellVersion)
    check evalOk("which self-update") == strV("builtin: self-update")
    check "--check" in evalOk("help self-update").s
  test "proxy from environment":
    let saved = (getEnv("HTTPS_PROXY"), getEnv("https_proxy"), getEnv("NO_PROXY"),
                 getEnv("no_proxy"), getEnv("ALL_PROXY"), getEnv("all_proxy"))
    for n in ["HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy", "ALL_PROXY", "all_proxy"]:
      delEnv(n)
    check proxyFromEnv("https://github.com/x").isNil
    putEnv("HTTPS_PROXY", "127.0.0.1:3128")
    check not proxyFromEnv("https://github.com/x").isNil
    putEnv("NO_PROXY", "localhost,.github.com")
    check proxyFromEnv("https://api.github.com/x").isNil
    check not proxyFromEnv("https://example.com/").isNil
    for (n, v) in [("HTTPS_PROXY", saved[0]), ("https_proxy", saved[1]), ("NO_PROXY", saved[2]),
                   ("no_proxy", saved[3]), ("ALL_PROXY", saved[4]), ("all_proxy", saved[5])]:
      if v == "": delEnv(n) else: putEnv(n, v)

suite "kdl":
  test "nodes, args, props, children":
    let doc = parseKdl("""
      // comment
      title "hello world" count=3
      bare foo #true null /* inline */ 0x1F 1_000.5
      parent {
        child "a"; child r"raw\n" #"also raw"#
      }
      /-skipped "gone"
      kept /-"gone" "stays" \
        "continued"
      "quoted name" (u8)7
    """)
    check doc.len == 5
    check doc[0].name == "title"
    check $doc[0].args[0] == "hello world"
    check doc[0].props[0][0] == "count" and doc[0].props[0][1].num == 3
    check doc[1].args.len == 5
    check doc[1].args[0].kind == kkString and doc[1].args[1].b
    check doc[1].args[2].kind == kkNull
    check doc[1].args[3].num == 31 and doc[1].args[4].num == 1000.5
    check doc[2].children.len == 2
    check doc[2].children[1].args[0].str == "raw\\n"
    check doc[2].children[1].args[1].str == "also raw"
    check doc[3].name == "kept"
    check doc[3].args.len == 2 and $doc[3].args[1] == "continued"
    check doc[4].name == "quoted name" and doc[4].args[0].num == 7
  test "escapes":
    check parseKdl("n \"a\\tb\\u{1F600}\\\"\"")[0].args[0].str == "a\tb😀\""
  test "errors carry line numbers":
    expect KdlError: discard parseKdl("a {\n b")
    try:
      discard parseKdl("ok\nbad \"unterminated")
      check false
    except KdlError as e:
      check e.msg.startsWith("line 2")

suite "config":
  test "path and env":
    let saved = getEnv("PATH")
    putEnv("PATH", "/usr/bin:/bin:/opt/x")
    putEnv("NIMSHELL_CFG_BASE", "/base")
    let warnings = applyConfig("""
      env {
        NIMSHELL_CFG_A "hello"
        NIMSHELL_CFG_B "${NIMSHELL_CFG_BASE}/sub"
        NIMSHELL_CFG_N 42
        NIMSHELL_CFG_BASE null
      }
      path "/first" "$NIMSHELL_CFG_A/bin"
      path {
        prepend "/opt/x"
        append "/last" "/bin"
      }
    """)
    check warnings.len == 0
    check getEnv("NIMSHELL_CFG_A") == "hello"
    check getEnv("NIMSHELL_CFG_B") == "/base/sub"
    check getEnv("NIMSHELL_CFG_N") == "42"
    check not existsEnv("NIMSHELL_CFG_BASE")
    check getEnv("PATH") == "/opt/x:/first:hello/bin:/usr/bin:/last:/bin"
    putEnv("PATH", saved)
    for n in ["NIMSHELL_CFG_A", "NIMSHELL_CFG_B", "NIMSHELL_CFG_N"]: delEnv(n)
  test "tilde expansion":
    check expandValue("~/bin") == getHomeDir().strip(leading = false, chars = {'/'}) & "/bin"
    check expandValue("a~b") == "a~b"
  test "warnings":
    let saved = getEnv("PATH")
    check applyConfig("nope 1").len == 1
    check applyConfig("path { middle \"/x\" }").len == 1
    check applyConfig("env { PATH \"/x\" }").len == 1
    check applyConfig("oops {")[0].startsWith("line ")
    check getEnv("PATH") == saved
  test "config file location":
    let saved = getEnv("XDG_CONFIG_HOME")
    putEnv("XDG_CONFIG_HOME", "/cfg")
    check configFile() == "/cfg/nimshell/config.kdl"
    if saved == "": delEnv("XDG_CONFIG_HOME") else: putEnv("XDG_CONFIG_HOME", saved)

suite "prompt config":
  teardown: promptConfig = defaultPromptConfig()
  test "styles":
    var code: string
    check parseStyle("bold cyan", code) and code == "\e[1;36m"
    check parseStyle("bright-magenta", code) and code == "\e[95m"
    check parseStyle("italic #ff8800", code) and code == "\e[3;38;2;255;136;0m"
    check parseStyle("none", code) and code == ""
    check not parseStyle("sparkly", code)
  test "cwd truncation":
    check truncateCwd("~/a/b/c", 2) == "…/b/c"
    check truncateCwd("/a/b/c", 3) == "/a/b/c"
    check truncateCwd("~/a", 2) == "~/a"
    check truncateCwd("/x/y", 0) == "/x/y"
  test "defaults unchanged":
    check applyConfig("").len == 0
    check promptChar(false, 0, false) == "❯ "
    check statusLine(false, "/tmp", "", "", 1, 3200, false) == "/tmp took 3.2s ✘ 1"
  test "prompt block":
    let warnings = applyConfig("""
      prompt {
        character "λ"
        error-character "✗"
        nerd-font #false
        single-line #true
        blank-line #false
        git-status #false
        min-duration 500
        cwd-depth 1
        colors { character "bold blue"; error "#ff0000" }
      }
    """)
    check warnings.len == 0
    let c = promptConfig
    check c.singleLine and not c.blankLine and not c.gitStatus and c.git
    check c.nerdFont == 0 and not nerdFont()
    check promptChar(false, 0, false) == "λ "
    check promptChar(false, 1, false) == "✗ "
    check promptChar(true, 0, true) == "\e[1;34mλ\e[0m "
    check statusLine(false, "/a/b", "", "", 0, 600, false) == "…/b took 600ms"
    check "\e[38;2;255;0;0m✘ 1" in statusLine(true, "/a", "", "", 1, 0, false)
  test "prompt warnings":
    check applyConfig("prompt { sparkle #true }").len == 1
    check applyConfig("prompt { single-line \"yes\" }").len == 1
    check applyConfig("prompt { colors { cwd \"sparkly\" } }").len == 1
    check applyConfig("prompt { colors { nope \"red\" } }").len == 1

suite "aliases":
  teardown: clearAliases()
  test "config block and one-liner":
    let warnings = applyConfig("""
      aliases {
        five "range 5"
        top3 "range 10 | reverse | first 3"
      }
      alias two "five | first 2"
    """)
    check warnings.len == 0
    check aliasNames() == @["five", "top3", "two"]
    check evalOk("top3") == evalOk("range 10 | reverse | first 3")
    # alias of an alias, and use mid-pipeline
    check evalOk("two") == evalOk("range 5 | first 2")
    check evalOk("five | first 1") == evalOk("range 5 | first 1")
  test "extra words go to the last command":
    check defineAlias("rev", "range 10 | first") == ""
    check evalOk("rev 2") == evalOk("range 10 | first 2")
  test "an alias can wrap the name it shadows":
    check defineAlias("range", "range 3") == ""
    check evalOk("range") == evalOk("echo [0 1 2]")
  test "in let and which":
    check defineAlias("five", "range 5") == ""
    let (e, _) = evalEnv("let x = five")
    check getVar(e, "x") == evalOk("range 5")
    check evalOk("which five") == strV("alias: five = range 5")
    check evalOk("aliases").kind == vkTable
  test "applyConfig replaces aliases":
    check applyConfig("alias a \"range 1\"").len == 0
    check applyConfig("").len == 0
    check not isAlias("a")
  test "bad aliases warn":
    check defineAlias("bad name", "ls") != ""
    check defineAlias("let", "ls") != ""
    check defineAlias("x", "let y = 1") != ""
    check defineAlias("x", "ls |") != ""
    check applyConfig("aliases { x 1 }").len == 1
    check applyConfig("alias x").len == 1
    check not isAlias("x")

## Test suite — ported from gleshell's gleeunit tests.

import std/[options, os, strutils, unittest]
import ../src/nimshell/[builtins, color, display, env, eval, highlight, lexer,
                        lineedit, pager, parser, syntax, sys, value]

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
    check field(r, "PATH").kind == vkString
    check evalOk("$env | get HOME").s.len > 0

  test "env assign":
    let (e2, v) = evalEnv("$env.NIMSHELL_TEST_VAR = nimshell-test-val")
    check v == strV("nimshell-test-val")
    check evalOk("$env.NIMSHELL_TEST_VAR", e2) == strV("nimshell-test-val")
    check getEnv("NIMSHELL_TEST_VAR") == "nimshell-test-val"

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

# nimshell

A **structured-data shell** written in [Nim](https://nim-lang.org), inspired by
[Nushell](https://www.nushell.sh). It is a port of
[gleshell](https://github.com/codegod100/gleshell) (the same shell written in Gleam).

Instead of piping opaque text between programs, nimshell pipelines pass typed
values: strings, numbers, lists, records, and tables. Built-in commands like
`ls`, `where`, and `select` work on that structure.

```text
~/code/nimshell on main [!?] ⇡1 took 3.2s
❯ ls | where type == file | select name size | first 5
╭──────┬──────╮
│ name │ size │
├──────┼──────┤
│ …    │ …    │
╰──────┴──────╯
```

The interactive prompt is zero-config and Starship-inspired:

- full path with `~`
- git branch (read from `.git`) plus status from `git status`:
  `=` conflicts, `!` modified, `+` staged, `?` untracked, `⇡n`/`⇣n` ahead/behind
- `took 3.2s` when the last command ran for 2 seconds or more
- `✘ <code>` and a red `❯` after a non-zero exit

The terminal tab/window title shows the current directory (e.g. `~/code/project`) at the prompt and the
running command line while a command runs (the previous title is restored on
exit). Set `NIMSHELL_NO_TITLE=1` to leave the title alone.

It uses plain Unicode, so it renders in any terminal. With a
[Nerd Font](https://www.nerdfonts.com) installed, set `NIMSHELL_NERD_FONT=1` for a
branch icon and the `` terminal prompt character.

## Quick start

### AppImage (self-updating)

Download `nimshell-x86_64.AppImage` from the
[latest release](https://github.com/codegod100/nimshell/releases/latest), then:

```bash
chmod +x nimshell-x86_64.AppImage
./nimshell-x86_64.AppImage                 # interactive REPL
./nimshell-x86_64.AppImage -c 'ls | first 3'
```

The AppImage bundles its runtime libraries (PCRE, OpenSSL) and keeps itself up
to date:

- The interactive shell checks for a newer release **at most once a day**, in a
  detached background process. If there is one, it downloads it, checks that it
  is a valid AppImage and that it reports the new version (`--version`), then
  atomically replaces the AppImage file. The next launch runs the new version
  and prints `✨ nimshell updated a → b` once.
- `self-update` (builtin) or `nimshell --self-update` updates right away;
  add `--check` to only report whether an update exists.
- `version` shows the running version and whether auto-update is active.
- Set `NIMSHELL_NO_UPDATE=1` to turn off the background check.
- The image also carries standard AppImage update information
  (`gh-releases-zsync`), so AppImageUpdate / `appimageupdatetool` can do delta
  updates with the published `.zsync` file.

Update checks use the `github.com/…/releases/latest` redirect, not the GitHub
API, so they are not subject to API rate limits; `HTTPS_PROXY` / `NO_PROXY` are
honored.

### From source

Requires Nim ≥ 1.6 (tested with 1.6 and 2.2). The `find --regex` builtin uses
PCRE (`libpcre3`), and `http` uses OpenSSL; both are loaded at runtime.

```bash
nimble build                     # produces ./nimshell
./nimshell                       # interactive REPL
./nimshell -c 'ls | first 3'     # one-shot
nimble test                      # run the test suite
packaging/build-appimage.sh      # dist/nimshell-<arch>.AppImage (+ .zsync)
```

### Releasing

Releases are automatic. Every push to `main` (other than docs-only changes)
runs the tests, builds the AppImage on Ubuntu 22.04 (for broad glibc
compatibility), smoke-tests it, and publishes it with its `.zsync` as a new
GitHub release. Installed AppImages pick it up on their next daily check or
`self-update`.

Versions are `<major>.<minor>` from `nimshell.nimble` plus the CI run number as
the patch (e.g. `v0.2.14`); bump `version` in `nimshell.nimble` to start a new
minor/major series. To publish an exact version instead, push a tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

Pull requests build the AppImage as a workflow artifact without publishing.
Only the 5 newest releases are kept; older releases and their tags are deleted
after each publish (`KEEP_RELEASES` in the workflow).

### REPL editing

On a TTY the interactive REPL uses a **raw-mode line editor** with
**Nushell-style syntax highlighting** as you type (commands cyan, strings
green, numbers purple, pipes purple, flags blue, variables purple, …).

| Key | Action |
|-----|--------|
| ↑ / ↓ | History |
| **Tab** | Command completion (builtins + `PATH`) at the start of a pipeline stage; filename completion for arguments (common prefix; list matches if ambiguous) |
| **→ / Ctrl+F / End / Ctrl+E** (at end of line) | Accept greyed-out history suggestion (full) |
| **Alt+F** (at end of line) | Accept one word of the history suggestion |
| **Ctrl+R** | Fuzzy history search (stinkpot-style list; ↑/↓ move, Enter/Tab accept onto the line, Esc cancel) |
| Ctrl+A / Ctrl+E | Beginning / end of line (Ctrl+E at end also accepts a history hint) |
| Ctrl+W | Delete previous word |
| Ctrl+U / Ctrl+K | Kill to start / end of line |
| Ctrl+L | Clear screen |
| **Ctrl+C** | Cancel current line at the prompt; while an external command runs, it interrupts that process (does not exit the shell) |
| Ctrl+D | EOF (empty line) or delete under cursor |

As you type, the **newest matching history line** is shown in grey after the
cursor (Nushell/fish-style hints).

History is persisted under `$XDG_CACHE_HOME/nimshell-history/lines`
(default `~/.cache/nimshell-history/lines`). Non-TTY input falls back to plain
line reads.

### Config

Optional; nimshell reads `$XDG_CONFIG_HOME/nimshell/config.kdl` (default
`~/.config/nimshell/config.kdl`) at startup, for both the REPL and `-c`:

```kdl
env {
    EDITOR "nvim"
    GOPATH "~/go"
    SOME_VAR null          // null unsets
}

path {
    prepend "~/.local/bin" "$GOPATH/bin"
    append "/opt/tools/bin"
}
```

- `path "a" "b"` is shorthand for `path { prepend "a" "b" }`. An entry that is
  already on `PATH` moves instead of being duplicated.
- Values expand a leading `~` and `$VAR` / `${VAR}`. Nodes apply in file
  order, so `path` can use variables set by an earlier `env`.
- Mistakes (bad KDL, unknown settings) print a warning to stderr; the shell
  still starts.

## Examples

```nu
# list files as a table, filter, project columns
ls | where type == file | select name size
ls | find toml md
echo [moe larry curly] | find l

# ranges and list ops
range 10 | reverse | first 3
range 5 | length

# records and JSON
echo {name: "nimshell", cool: true}
echo "{\"a\": 1}" | from json | get a
open data.json | get users | first
echo "{\"user\": {\"name\": \"ada\"}}" | from json | get user.name
range 3 | to json

# JWT (parse only — does not verify signature)
echo $token | from jwt | get payload
echo $token | from jwt | get header.alg

# paste multi-line text into a pipeline (finish with Ctrl+D)
input | from json
input "Paste notes:" | lines | find TODO
# or pipe data into a one-shot: printf '{"a":1}' | nimshell -c 'input | from json'

# variables
let n = range 3 | length
echo $n

# process environment (Nushell-style)
$env.HOME
$env | get PATH
$env.MY_VAR = hello
echo $env.MY_VAR

# external programs (stdout captured as a string)
^uname -a
which ls
which -a ls
which -f sh

# processes (Nushell-style table)
ps
ps | sort-by mem | last 5
ps --long | where name == nimshell

# who is bound to a port (listeners by default; --all ≈ lsof -i)
whyport 22
whyport --all 4004

# current time (Unix epoch seconds; prints like ls modified)
now
```

## Language sketch

| Feature | Syntax |
|--------|--------|
| Pipeline | `cmd \| cmd \| cmd` |
| Strings | `"hello"` or bare words `hello` |
| Numbers | `42`, `3.14` |
| Bools | `true` / `false` |
| Nothing | `null` / `nothing` |
| Lists | `[1 2 3]` |
| Records | `{name: alice, age: 30}` |
| Variables | `let x = …` then `$x` (pipeline input is `$in`) |
| Env | `$env`, `$env.HOME`, `$env.FOO = value` |
| Flags | `--flag` / `--flag value` |
| Force external | `^command args…` |
| Comments | `# …` (word-boundary only; mid-token `#` is fine — `nixpkgs#pkg`) |

## Built-ins

Filesystem: `ls`, `cd`, `pwd`, `cat` (extension/content detect + syntax color on
TTY for json, nim, gleam, toml, markdown; `--raw` for plain pipelines), `open`, `save`

Table/list: `where`/`filter`, `find`, `select`, `get`, `first`, `last`, `take`,
`skip`, `sort-by`, `reverse`, `length`, `columns`, `table`, `flatten`, `uniq`,
`wrap`, `unwrap`, `keys`, `values`, `append`, `prepend`, `is-empty`

Data: `echo`, `range`, `lines`, `input` (multi-line paste / stdin until Ctrl+D),
`to`/`from` (subcommands `json`, `jwt`), `type`, `describe`, `env`, `sys`, `ps`,
`whyport`, `now`, `which`, `help`, `about`, `exit`

HTTP: `http get|post|put|delete|patch|head` — fetch/send with structured JSON
bodies and responses (`http get https://example.com`, `http post URL {a: 1}`,
`--full`, `-H` headers, `--raw`, `--allow-errors`)

Pager: `less` — builtin color-aware pager for pipeline input or files
(`ls | less`, `less README.md`). ANSI from tables and external tools is kept;
short output is printed without an interactive session. The mouse wheel
scrolls (hold Shift to select text). Interactive keys include live `/` search
(case-insensitive, finds as you type) and `n`/`N` next/previous match.
Long lines soft-wrap by default; `less -S` (or pressing `S` in the pager)
switches to chop mode like `less -S`: lines are cut at the window edge, `←`/`→`
scroll sideways by half a screen, `0`/`$` jump to the left/right edge, and
search scrolls sideways to bring the match into view. `^less` still runs the
external binary.

External commands inherit the live TTY so long-lived processes (dev servers,
builds) stream output as they run. Tools that would spawn system `less`
(`systemctl`, `journalctl`, `git`, `man`, `info`) are captured with nested
pagers forced to `cat` (plus `FORCE_COLOR` / `CLICOLOR_FORCE` and a git
`GIT_CONFIG_*` overlay so they keep their colors), then shown through the
**same builtin pager** when the text does not fit on one screen.

Unknown command names fall through to external executables on `PATH`.

## Layout

```text
src/
  nimshell.nim            # entry + REPL + prompt
  nimshell/
    value.nim             # structured Value type
    lexer.nim / parser.nim
    eval.nim              # pipeline evaluator
    builtins.nim          # Nu-inspired commands
    pager.nim             # color-aware builtin less
    display.nim           # table pretty-printer
    color.nim             # Nushell-style ANSI colors
    highlight.nim         # live input syntax highlighting
    lineedit.nim          # raw line editor, history, completion, Ctrl+R
    syntax.nim            # file language detect + cat highlighters
    prompt.nim            # Starship-inspired prompt (git status, duration)
    update.nim            # AppImage self-update
    netclient.nim         # HTTP client setup (TLS, proxies)
    config.nim / kdl.nim  # config.kdl loader + minimal KDL parser
    env.nim / sys.nim / term.nim
packaging/
  build-appimage.sh       # AppDir + bundled libs + appimagetool
tests/
  test_nimshell.nim       # ported from gleshell's test suite
```

On a terminal, tables, lists and records are fitted to the window width like
Nushell: free-text columns (names, commands, paths) shrink first and long
cells end in `…`; numbers, sizes and dates are cut only as a last resort; if
the table still doesn't fit, columns are dropped from the right and a `…`
column marks the hidden ones. Pipes and redirects always get the full data.

Output is colorized on a TTY (headers bold green, numbers purple, bools cyan,
dirs blue, errors red, …). Pre-colored text from external tools is not
re-painted. Disable with `NO_COLOR=1`; force with `FORCE_COLOR=1`.

## Differences from gleshell

- Native binary instead of the BEAM: externals are plain `fork`/`exec` children
  sharing the terminal, so Ctrl+C reaches them directly (no PTY relay).
- Captured stages use pipes with color-forcing env vars rather than a
  throwaway PTY via `script(1)`.
- `find --regex` uses PCRE syntax (was Erlang `re`, also PCRE-flavored).
- `cat` also highlights Nim sources.

## Status

Early but usable: core pipeline model, tables, filters, JSON, and external
commands work. Not a full Nushell clone (no closures/plugins yet).

## License

Apache-2.0, same as gleshell.

## Command aliases (`alias` builtin, usually in config.ns). An alias names a pipeline; words typed
## after the alias are appended to its last command, like shell aliases:
## with `ll` = `ls -l`, `ll src` runs `ls -l src`.

import std/[algorithm, sets, tables]
import parser

type Alias* = object
  source*: string     ## as written in the config
  pipeline*: Pipeline

var aliases*: OrderedTable[string, Alias]

proc defineAlias*(name, source: string): string =
  ## Add or replace an alias. Returns an error message, or "".
  var stmt: Statement
  var msg: string
  # The name must lex as one plain command word, or it could never be typed.
  if not parse(name, stmt, msg) or stmt.kind != stExpr or
      stmt.pipeline.commands.len != 1 or stmt.pipeline.commands[0].name != name or
      stmt.pipeline.commands[0].external or stmt.pipeline.commands[0].args.len != 0:
    return "invalid alias name `" & name & "`"
  if name == "let": return "`let` cannot be an alias"
  if not parse(source, stmt, msg): return msg
  if stmt.kind != stExpr: return "an alias must be a pipeline, not an assignment"
  aliases[name] = Alias(source: source, pipeline: stmt.pipeline)
  ""

proc clearAliases*() = aliases.clear()

proc isAlias*(name: string): bool = aliases.hasKey(name)

proc aliasNames*(): seq[string] =
  for k in aliases.keys: result.add k
  result.sort()

proc expand(p: Pipeline, seen: HashSet[string]): Pipeline =
  for cmd in p.commands:
    if cmd.external or not aliases.hasKey(cmd.name) or cmd.name in seen:
      result.commands.add cmd
      continue
    # An alias may use other aliases, or wrap the command it shadows
    # (`ls` = `ls -l`): a name is never expanded inside its own expansion.
    var inner = seen
    inner.incl cmd.name
    var sub = expand(aliases[cmd.name].pipeline, inner)
    sub.commands[^1].args.add cmd.args
    result.commands.add sub.commands

proc expandAliases*(p: Pipeline): Pipeline =
  ## Replace alias commands with their pipelines. `^name` is never expanded.
  if aliases.len == 0: p else: expand(p, initHashSet[string]())

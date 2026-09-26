## Shell environment: cwd, variables, last exit status.
##
## Nushell-style process env lives under `$env` / `$env.VAR`.

import std/[tables, strutils]
import sys, value

type
  Env* = object
    cwd*: string
    vars*: Table[string, Value]
    lastExit*: int

proc newEnv*(): Env =
  let (ok, cwd) = getCwd()
  Env(cwd: if ok: cwd else: ".", lastExit: 0)

proc envRecord*(env: Env): Value =
  ## Process environment as a record (Nushell `$env`). `PWD` always reflects
  ## the shell cwd.
  var pairs: seq[(string, Value)]
  var hasPwd = false
  for (k, v) in listEnv():
    if k == "PWD":
      hasPwd = true
      pairs.add(("PWD", strV(env.cwd)))
    else:
      pairs.add((k, strV(v)))
  if not hasPwd: pairs.add(("PWD", strV(env.cwd)))
  recordV(pairs)

proc getOsEnv(env: Env, key: string): Value =
  case key
  of "": nothing()
  of "PWD", "pwd": strV(env.cwd)
  else:
    let (ok, s) = getenvOpt(key)
    if ok: strV(s) else: nothing()

proc getVar*(env: Env, name: string): Value =
  case name
  of "PWD", "pwd": strV(env.cwd)
  of "in": env.vars.getOrDefault("in", nothing())
  # `$env` — full process environment as a record
  of "env": envRecord(env)
  else:
    if name.startsWith("env."):
      # `$env.VAR` — one OS environment variable
      getOsEnv(env, name[4 .. ^1])
    elif env.vars.hasKey(name):
      env.vars[name]
    else:
      let (ok, s) = getenvOpt(name)
      if ok: strV(s) else: nothing()

proc setVar*(env: Env, name: string, value: Value): Env =
  result = env
  result.vars[name] = value

proc setInput*(env: Env, input: Value): Env = setVar(env, "in", input)

proc setExit*(env: Env, code: int): Env =
  result = env
  result.lastExit = code

proc setCwd*(env: Env, path: string): (bool, Env, string) =
  let (ok, err) = sys.setCwd(path)
  if not ok: return (false, env, err)
  let (ok2, cwd) = getCwd()
  var e = env
  e.cwd = if ok2: cwd else: path
  # Keep process PWD in sync (Nushell does this for `$env.PWD`)
  setenv("PWD", e.cwd)
  (true, e, "")

proc setOsEnv*(env: Env, name: string, value: Value): (bool, Env, string) =
  ## Set a process environment variable (`$env.NAME = …`).
  ## Setting `PWD` changes the shell working directory.
  case name
  of "": (false, env, "empty environment variable name")
  of "PWD", "pwd": setCwd(env, asString(value))
  else:
    setenv(name, asString(value))
    (true, env, "")

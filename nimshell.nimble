# Package

version       = "0.1.0"
author        = "codegod100"
description   = "A structured-data shell in Nim, inspired by Nushell (port of gleshell)"
license       = "Apache-2.0"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["nimshell"]

# Dependencies

requires "nim >= 1.6.0"

task test, "Run the test suite":
  exec "nim c -r --hints:off tests/test_nimshell.nim"

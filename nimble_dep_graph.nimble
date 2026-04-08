# Package

version       = "0.1.0"
author        = "litlighilit"
description   = "draw nimble dep graph"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["nimble_dep_graph"]
binDir        = "bin"


# Dependencies

requires "nim > 2.0.8"
when not defined(js):
  requires "cligen"

template buildJsWith(flags) =
  selfExec "js -d:release " & flags & " -o:" & binDir & '/' & bin[0] & ".js " & srcDir & '/' & bin[0]
task buildJs, "build for js used in browser":
  buildJsWith ""
task buildCfJs, "build for js used in cf":
  buildJsWith "-d:jsCf"


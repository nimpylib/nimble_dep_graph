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

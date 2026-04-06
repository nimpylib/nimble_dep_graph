import nimble_dep_graph/core

export core

when isMainModule and not defined(js):
  import pkg/cligen
  dispatch(runApp)


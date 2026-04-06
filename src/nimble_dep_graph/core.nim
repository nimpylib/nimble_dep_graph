import std/[algorithm, json, logging, options, os, sequtils, strformat, strutils, tables]

when not defined(js):
  import std/osproc

import ./[fetch, graph, crawl]

proc depToJson(dep: DependencySpec): JsonNode =
  %*{
    "repo": dep.repo,
    "version": dep.version,
    "source_file": dep.sourceFile
  }

proc repoMetadataToJson(meta: RepoMetadata): JsonNode =
  result = newJObject()
  result["repo"] = %meta.repo
  if meta.nimbleFile.isSome:
    result["nimble_file"] = %meta.nimbleFile.get()
  else:
    result["nimble_file"] = newJNull()

  var depsNode = newJArray()
  for dep in meta.deps:
    depsNode.add(depToJson(dep))
  result["deps"] = depsNode

when defined(js):
  proc writeOutputs(
    outputDir: string,
    entryRepos: seq[string],
    graph: Graph,
    metadata: Table[string, RepoMetadata],
    errors: Table[string, string],
    renderSvg: bool
  ) =
    discard outputDir
    discard entryRepos
    discard graph
    discard metadata
    discard errors
    discard renderSvg
    warn("File output is unavailable on JS backend.")
else:
  proc writeOutputs(
    outputDir: string,
    entryRepos: seq[string],
    graph: Graph,
    metadata: Table[string, RepoMetadata],
    errors: Table[string, string],
    renderSvg: bool
  ) =
    discard existsOrCreateDir(outputDir)

    let jsonPath = outputDir / "deps.graph.json"
    let dotPath = outputDir / "deps.graph.dot"
    let mermaidPath = outputDir / "deps.graph.mmd"
    let svgPath = outputDir / "deps.graph.svg"

    var payload = newJObject()

    var entryReposNode = newJArray()
    for repo in entryRepos:
      entryReposNode.add(%repo)
    payload["entry_repos"] = entryReposNode
    if entryRepos.len > 0:
      payload["entry_repo"] = %entryRepos[0]
    else:
      payload["entry_repo"] = newJNull()

    payload["summary"] = %*{
      "nodes": graph.nodes.len,
      "edges": graph.edges.len,
      "errors": errors.len
    }

    var reposNode = newJObject()
    var repos = toSeq(metadata.keys)
    repos.sort(system.cmp[string])
    for repo in repos:
      reposNode[repo] = repoMetadataToJson(metadata[repo])
    payload["repos"] = reposNode

    var edgesNode = newJArray()
    for edge in graph.edges:
      edgesNode.add(%*{
        "from": edge.src,
        "to": edge.dst,
        "version": edge.version,
        "source_file": edge.sourceFile
      })
    payload["edges"] = edgesNode

    var errorsNode = newJObject()
    var errRepos = toSeq(errors.keys)
    errRepos.sort(system.cmp[string])
    for repo in errRepos:
      errorsNode[repo] = %errors[repo]
    payload["errors"] = errorsNode

    writeFile(jsonPath, payload.pretty(2) & "\n")
    writeFile(dotPath, toDot(graph))
    writeFile(mermaidPath, toMermaid(graph))

    if renderSvg:
      let command = "dot -Tsvg " & quoteShell(dotPath) & " -o " & quoteShell(svgPath)
      let (output, exitCode) = execCmdEx(command)
      if exitCode == 0:
        logging.log(lvlInfo, &"Rendered SVG graph to {svgPath}")
      else:
        let msg = if output.strip().len > 0: output.strip() else: "unknown error"
        logging.log(lvlWarn, &"Graphviz render failed: {msg}")

proc parseLogLevel(value: string): Level =
  case value.toUpperAscii()
  of "DEBUG": lvlDebug
  of "INFO": lvlInfo
  of "WARNING", "WARN": lvlWarn
  of "ERROR": lvlError
  else:
    raise newException(ValueError, "--log-level must be one of: DEBUG, INFO, WARNING, ERROR")

proc defaultPkgs2Dir(): string =
  when defined(js):
    ".nimble/pkgs2"
  else:
    getHomeDir() / ".nimble" / "pkgs2"

proc runApp*(
  entryRepos: seq[string] = @[DefPackage],
  maxRepos = 200,
  token = "",
  outputDir = "./out",
  noSvg = false,
  logLevel = "INFO",
  nimblePkgs2Dir = "",
  noLocalPkgs2 = false
): int =
  result = try:
    addHandler(newConsoleLogger(levelThreshold = parseLogLevel(logLevel), fmtStr = "$levelname $msg"))

    var validatedRepos: seq[string]
    for repo in entryRepos:
      validatedRepos.add(validateRepo(repo))

    if validatedRepos.len == 0:
      raise newException(ValueError, "At least one entry repo is required")
    if maxRepos <= 0:
      raise newException(ValueError, "--max-repos must be > 0")

    let resolvedToken =
      when defined(js):
        token
      else:
        if token.len > 0: token else: getEnv("GITHUB_TOKEN", "")
    let resolvedPkgs2Dir = if nimblePkgs2Dir.len > 0: nimblePkgs2Dir else: defaultPkgs2Dir()
    let tokenOpt = if resolvedToken.len > 0: some(resolvedToken) else: none(string)
    let pkgs2Dir =
      when defined(js):
        if noLocalPkgs2: none(string) else: some(resolvedPkgs2Dir)
      else:
        if noLocalPkgs2: none(string) else: some(expandTilde(resolvedPkgs2Dir))
    if pkgs2Dir.isSome:
      info &"Local pkgs2 metadata enabled: {pkgs2Dir.get()}"

    let client = ApiClient(token: tokenOpt, timeoutMs: 20_000)
    let (graph, metadata, errors) = crawlDependencyGraph(
      client = client,
      entryRepos = validatedRepos,
      maxRepos = maxRepos,
      pkgs2Dir = pkgs2Dir
    )

    writeOutputs(
      outputDir = outputDir,
      entryRepos = validatedRepos,
      graph = graph,
      metadata = metadata,
      errors = errors,
      renderSvg = not noSvg
    )

    echo "Entry repos: " & validatedRepos.join(", ")
    echo "Graph nodes: " & $graph.nodes.len
    echo "Graph edges: " & $graph.edges.len
    echo "Errors: " & $errors.len
    when defined(js):
      echo "Outputs: " & outputDir
    else:
      echo "Outputs: " & absolutePath(outputDir)
    if errors.len > 0:
      echo ""
      echo "[WARN] Repos with errors:"
      var keys = toSeq(errors.keys)
      keys.sort(system.cmp[string])
      for repo in keys:
        echo "  - " & repo & ": " & errors[repo]

    0
  except ValueError as exc:
    when defined(js):
      echo "ERROR " & exc.msg
    else:
      stderr.writeLine("ERROR " & exc.msg)
    2
  except CatchableError as exc:
    when defined(js):
      echo "ERROR " & exc.msg
    else:
      stderr.writeLine("ERROR " & exc.msg)
    1

proc runAppJs*(
  entryReposCsv = DefPackage,
  maxRepos = 200,
  token = "",
  outputDir = "./out",
  noSvg = false,
  logLevel = "INFO",
  nimblePkgs2Dir = "",
  noLocalPkgs2 = false
): cint {.exportc.} =
  let repos = entryReposCsv
    .split(',')
    .mapIt(it.strip())
    .filterIt(it.len > 0)
  let resolvedPkgs2 = if nimblePkgs2Dir.len > 0: nimblePkgs2Dir else: defaultPkgs2Dir()
  result = cint(runApp(
    entryRepos = if repos.len > 0: repos else: @[DefPackage],
    maxRepos = maxRepos,
    token = token,
    outputDir = outputDir,
    noSvg = noSvg,
    logLevel = logLevel,
    nimblePkgs2Dir = resolvedPkgs2,
    noLocalPkgs2 = noLocalPkgs2
  ))

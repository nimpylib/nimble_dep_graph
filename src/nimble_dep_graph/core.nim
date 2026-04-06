import std/[algorithm, json, logging, options, sequtils, strformat, strutils, tables]

when not defined(js):
  import std/[os, osproc]

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

proc getOutputs(
  entryRepos: seq[string],
  graph: Graph,
  metadata: Table[string, RepoMetadata],
  errors: Table[string, string],
): tuple[json, dot, mermaid: string] =

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

  (
    payload.pretty(2) & "\n",
    toDot(graph),
    toMermaid(graph)
  )


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

const
  MaxRepos = 200
  OutputDir = "./out"
  LogLevel = "INFO"

type Tup3 = tuple[
  json: string,
  dot: string,
  mermaid: string
]
proc runAppAync*[R: int|Tup3 =Tup3](
  entryRepos: seq[string] = @[DefPackage],
  maxRepos = MaxRepos,
  token = "",
  outputDir = OutputDir,
  noSvg = false,
  logLevel = LogLevel,
  nimblePkgs2Dir = "",
  noLocalPkgs2 = false
): Future[R]{.async.} =
  template reti(i) =
    when R is int:
      return i
  try:
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

    let client = ApiClient(token: tokenOpt)
    let (graph, metadata, errors) = await crawlDependencyGraph(
      client = client,
      entryRepos = validatedRepos,
      maxRepos = maxRepos,
      pkgs2Dir = pkgs2Dir
    )

    let tup = getOutputs(
      entryRepos = validatedRepos,
      graph = graph,
      metadata = metadata,
      errors = errors,
    )
    when R is_not int:
      return tup
    else:
      discard existsOrCreateDir(outputDir)

      let jsonPath = outputDir / "deps.graph.json"
      let dotPath = outputDir / "deps.graph.dot"
      let mermaidPath = outputDir / "deps.graph.mmd"
      let svgPath = outputDir / "deps.graph.svg"

      writeFile(jsonPath, tup.json)
      writeFile(dotPath, tup.dot)
      writeFile(mermaidPath, tup.mermaid)
      if not noSvg:
        let command = "dot -Tsvg " & quoteShell(dotPath) & " -o " & quoteShell(svgPath)
        let (output, exitCode) = execCmdEx(command)
        if exitCode == 0:
          info &"Rendered SVG graph to {svgPath}"
        else:
          let msg = if output.strip().len > 0: output.strip() else: "unknown error"
          warn &"Graphviz render failed: {msg}"


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

      reti 0
  except ValueError as exc:
    when defined(js):
      echo "ERROR " & exc.msg
    else:
      stderr.writeLine("ERROR " & exc.msg)
    reti 2
  except CatchableError as exc:
    when defined(js):
      echo "ERROR " & exc.msg
    else:
      stderr.writeLine("ERROR " & exc.msg)
    reti 1

when not defined(js):
  proc runCliApp*(
    entryRepos: seq[string] = @[DefPackage],
    maxRepos = 200,
    token = "",
    outputDir = "./out",
    noSvg = false,
    logLevel = "INFO",
    nimblePkgs2Dir = "",
    noLocalPkgs2 = false
  ): int =
    waitFor runAppAync[int](
      entryRepos = entryRepos,
      maxRepos = maxRepos,
      token = token,
      outputDir = outputDir,
      noSvg = noSvg,
      logLevel = logLevel,
      nimblePkgs2Dir = nimblePkgs2Dir,
      noLocalPkgs2 = noLocalPkgs2
    )

proc runApp*(
  outputType: cstring,
  entryReposCsv = DefPackage,
  maxRepos = MaxRepos,
  token = "",
  outputDir = OutputDir,
  logLevel = LogLevel,
  nimblePkgs2Dir = "",
  noLocalPkgs2 = false
): Future[cstring] {.async, exportc.} =
  let repos = entryReposCsv
    .split(',')
    .mapIt(it.strip())
    .filterIt(it.len > 0)
  let resolvedPkgs2 = if nimblePkgs2Dir.len > 0: nimblePkgs2Dir else: defaultPkgs2Dir()
  let res = await runAppAync[](
    entryRepos = if repos.len > 0: repos else: @[DefPackage],
    maxRepos = maxRepos,
    token = token,
    outputDir = outputDir,
    noSvg = true,
    logLevel = logLevel,
    nimblePkgs2Dir = resolvedPkgs2,
    noLocalPkgs2 = noLocalPkgs2
  )
  for t, v in res.fieldPairs:
    if t == outputType:
      return v.cstring
  raise newException(ValueError, &"Invalid output type: {outputType}. Expected one of: json, dot, mermaid.")

proc runAppWithDefaults*(outputType: cstring): Future[cstring] {.async, exportc.} = return await runApp(outputType)

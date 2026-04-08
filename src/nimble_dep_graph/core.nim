import std/[algorithm, json, logging, options, sequtils, strformat, strutils, tables]

when not defined(js):
  import std/[os, osproc]
else:
  import std/jsffi

import ./[fetch, graph, crawl, dailycache]

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
  entryRepos: openArray[string],
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

proc toUpperAscii(s: cstring): string =
  result = newString(s.len)
  for i, c in s: result[i] = c.toUpperAscii
  
proc parseLogLevel(value: cstring|string): Level =
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
  entryRepos: seq[string] = @DefPackages,
  maxRepos = MaxRepos,
  token = "",
  outputDir = OutputDir,
  noSvg = false,
  logLevel: cstring|string = LogLevel,
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
      if noLocalPkgs2: none(string) else: some(when defined(js):
        resolvedPkgs2Dir
      else:
        expandTilde(resolvedPkgs2Dir)
      )
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
      createDir(outputDir)

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


      info "Entry repos: " & validatedRepos.join(", ")
      info "Graph nodes: " & $graph.nodes.len
      info "Graph edges: " & $graph.edges.len
      info "Errors: " & $errors.len
      when defined(js):
        info "Outputs: " & outputDir
      else:
        info "Outputs: " & absolutePath(outputDir)
      if errors.len > 0:
        var errs = ""
        template addLine(s: string) =
          errs.add(s)
          errs.add '\n'
        addLine "Repos with errors:"
        var keys = toSeq(errors.keys)
        keys.sort(system.cmp[string])
        for repo in keys:
          addLine "  - " & repo & ": " & errors[repo]
        error errs

      reti 0
  except ValueError as exc:
    error "ERROR " & exc.msg
    reti 2
  except CatchableError as exc:
    error "ERROR " & exc.msg
    reti 1

when not defined(js):
  proc runCliApp*(
    entryRepos: seq[string] = @DefPackages,
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

proc toKey(outputType: cstring, entryRepos: seq[string], maxRepos: int, nimblePkgs2Dir: string, noLocalPkgs2: bool): string =
  let reposPart = entryRepos.mapIt(it.strip()).filterIt(it.len > 0).sorted().join("_AND-")
  let localPkgs2Part = if noLocalPkgs2: "" else: "_AT-" & nimblePkgs2Dir
  result = &"{reposPart}_N-{maxRepos}{localPkgs2Part}.{outputType}"
  result = result.replace("/", "_SEP-")

var cache: CacheBackendAbc
type CfEnv*{.pure, exportc.} = object
  CF_ACCOUNT_ID*: cstring
  CF_NAMESPACE_ID*: cstring
  CF_API_KEY*: cstring

proc newCfKvApiCacheBackendFrom*(env: CfEnv): CfApiCacheBackend =
  newCfKvApiCacheBackend(
    account_id=   $env.CF_ACCOUNT_ID,
    namespace_id= $env.CF_NAMESPACE_ID,
    api_key=      $env.CF_API_KEY
  )
proc initCfCacheFrom(env: CfEnv){.exportc.} =
  for i, v in env.fieldPairs:
    when defined(js):
      assert not v.isUndefined
    assert v.isNil.not and v.len != 0
  cache = newCfKvApiCacheBackendFrom(env)

when defined(nimble_dep_graph_cacheEnv):
  import std/os
  const fn = currentSourcePath() /../ "cacheEnv.json"
  const s = staticRead(fn)
  proc initFromJson(dst: var cstring; jsonNode: JsonNode; jsonPath: var string) =
    #verifyJsonKind(jsonNode, {JString, JNull}, jsonPath)
    # since strings don't have a nil state anymore, this mapping of
    # JNull to the default string is questionable. `none(string)` and
    # `some("")` have the same potentional json value `JNull`.
    if jsonNode.kind == JNull:
      dst = ""
    else:
      dst = cstring jsonNode.str
  when s.len > 0:
    const env = parseJson(s).to CfEnv
    initCfCacheFrom(env)

proc runApp*(
  outputType: cstring,
  entryReposCsv = DefPackages.join(","),
  maxRepos = MaxRepos,
  token = "",
  outputDir = OutputDir,
  logLevel = cstring LogLevel,
  nimblePkgs2Dir = cstring"",
  noLocalPkgs2 = false
): Future[cstring] {.async, exportc.} =
  let repos = entryReposCsv
    .split(',')
    .mapIt(it.strip())
    .filterIt(it.len > 0)
  let resolvedPkgs2 = if nimblePkgs2Dir.len > 0: $nimblePkgs2Dir else: defaultPkgs2Dir()
  proc getter(): Future[string] {.async.} =
    let res = await runAppAync[](
      entryRepos = if repos.len > 0: repos else: @DefPackages,
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
        return v
    raise newException(ValueError, &"Invalid output type: {outputType}. Expected one of: json, dot, mermaid.")
  if not cache.isNil:
    let key = toKey(outputType, repos, maxRepos, resolvedPkgs2, noLocalPkgs2)
    let cached = await cache.getDailyCachedOr(key, getter)
    return cstring(cached)
  else:
    info "No cache backend configured. Skipping cache."
    let res = await getter()
    return cstring res

proc runAppWithDefaults*(outputType: cstring, logLevel: cstring): Future[cstring] {.async, exportc.} = return await runApp(outputType, logLevel = logLevel)

when defined(jsCf):
  ## generate cloudflare worker compatible module export
  {.emit: """
export default {
  async fetch(request, env, ctx) {
    const headers = {
      "Content-Type": "application/plain",
    };
    const setOrigin = (ori) => headers["Access-Control-Allow-Origin"] = ori;
    /*const origin = request.headers.host;
    if (origin && (origin.endswith(".nimpylib.org") || origin.endswith("nimpylib.org"))) {
      // Only allow CORS requests from our own domain to prevent abuse of the cache API from other origins.
      // This is a bit tricky because we want to allow subdomains, but Cloudflare Workers doesn't support
      // wildcard values in Access-Control-Allow-Origin. So we have to check the origin against the allowed pattern
      // and then echo it back in the header if it matches.
      setOrigin("https://" + origin);
    } else {} */
    setOrigin("*");
    initCfCacheFrom(env);
    return new Response(await runAppWithDefaults("mermaid", "INFO"), {
      headers: headers
    });
  },
};
""".}


import std/[json, logging, options, strformat, tables, times]
import ./[cache, types, graph, fetch]

const
  ## The leading `~` puts this dependency-entry cache object after existing
  ## `nimpylib_...` keys when Cloudflare KV keys are listed in lexical order.
  DepGraphEntryCacheKeyPrefix* = "~"
  EntryCacheDateFormat = "yyyy-MM-dd"
  ## Leaves enough of Cloudflare's 50 subrequests for reading and checkpointing
  ## the cache object, assuming metadata normally takes two GitHub requests.
  MaxFetchedEntriesPerWorkerInvocation* = 20
  UnfetchedEntryCacheValue = "unfetched"

type
  CachedEntryKind = enum
    cekUnfetched, cekMetadata
  CachedEntry = object
    kind: CachedEntryKind
    metadata: RepoMetadata
    cachedOn: string
  CrawlResult* = tuple[
    graph: Graph,
    metadata: Table[string, RepoMetadata],
    errors: Table[string, string],
    isComplete: bool
  ]

proc metadataToJson(meta: RepoMetadata): JsonNode =
  result = newJObject()
  result["repo"] = %meta.repo
  result["nimble_file"] = if meta.nimbleFile.isSome: %meta.nimbleFile.get() else: newJNull()
  result["deps"] = newJArray()
  for dep in meta.deps:
    result["deps"].add(%*{
      "repo": dep.repo,
      "version": dep.version,
      "source_file": dep.sourceFile
    })

proc metadataFromJson(node: JsonNode): RepoMetadata =
  result.repo = node["repo"].getStr()
  result.nimbleFile =
    if node["nimble_file"].kind == JNull: none(string) else: some(node["nimble_file"].getStr())
  for depNode in node["deps"]:
    result.deps.add(DependencySpec(
      repo: depNode["repo"].getStr(),
      version: depNode["version"].getStr(),
      sourceFile: depNode["source_file"].getStr()
    ))

proc entryCacheToJson(entries: Table[string, CachedEntry]): string =
  var entriesNode = newJObject()
  for repo, entry in entries:
    if entry.kind == cekUnfetched:
      entriesNode[repo] = %UnfetchedEntryCacheValue
    else:
      entriesNode[repo] = %*{
        "cached_on": entry.cachedOn,
        "metadata": metadataToJson(entry.metadata)
      }
  $(%*{"entries": entriesNode})

proc entryCacheFromJson(value: string): Table[string, CachedEntry] =
  try:
    let entriesNode = parseJson(value)["entries"]
    for repo, entryNode in entriesNode:
      if entryNode.kind == JString and entryNode.getStr() == UnfetchedEntryCacheValue:
        result[repo] = CachedEntry(kind: cekUnfetched)
      else:
        result[repo] = CachedEntry(
          kind: cekMetadata,
          cachedOn: entryNode["cached_on"].getStr(),
          metadata: metadataFromJson(entryNode["metadata"])
        )
  except JsonParsingError, KeyError, ValueError:
    warn "Ignoring invalid dependency-graph entry cache."
    result = initTable[string, CachedEntry]()

proc isFresh(entry: CachedEntry): bool =
  entry.kind == cekMetadata and entry.cachedOn == now().utc.format(EntryCacheDateFormat)

proc crawlDependencyGraph*(
  client: ApiClient,
  entryRepos: seq[string],
  maxRepos: int,
  pkgs2Dir: Option[string],
  cache: CacheBackendAbc = nil
): Future[CrawlResult]{.async.} =
  var graph = initGraph()
  var metadata = initTable[string, RepoMetadata]()
  var errors = initTable[string, string]()
  var visited = initTable[string, bool]()
  var stoppedBySubrequestLimit = false
  var fetchedEntries = 0
  var cachedEntries = initTable[string, CachedEntry]()
  var entryCacheChanged = false

  if not cache.isNil:
    let cached = await cache.get(DepGraphEntryCacheKeyPrefix)
    if cached.isSome:
      cachedEntries = entryCacheFromJson(cached.get())

  proc saveEntryCache() {.async.} =
    if cache.isNil or not entryCacheChanged:
      return
    await cache.set(DepGraphEntryCacheKeyPrefix, entryCacheToJson(cachedEntries))

  info &"Starting crawl with entry repos: {entryRepos}, maxRepos: {maxRepos}"

  proc visit(repo: string, depth: int){.async.} =
    if stoppedBySubrequestLimit:
      return
    if visited.hasKey(repo):
      return
    if visited.len >= maxRepos:
      warn &"Reached --max-repos limit ({maxRepos}). Stopping recursion."
      return

    info &"Visiting repo: {repo} (depth={depth})"
    visited[repo] = true
    graph.addNode(repo)

    try:
      var repoMeta: RepoMetadata
      var needsFetch = true
      if repo in cachedEntries:
        let cachedEntry = cachedEntries[repo]
        if cachedEntry.isFresh:
          repoMeta = cachedEntry.metadata
          needsFetch = false
          info &"Using cached dependency metadata for {repo}"
        elif cachedEntry.kind == cekUnfetched:
          info &"Resuming previously unfetched dependency metadata for {repo}"
      if needsFetch:
        when defined(js):
          if fetchedEntries >= MaxFetchedEntriesPerWorkerInvocation:
            stoppedBySubrequestLimit = true
            errors[repo] = "Worker subrequest budget reserved for dependency-graph checkpointing."
            cachedEntries[repo] = CachedEntry(kind: cekUnfetched)
            entryCacheChanged = true
            return
        repoMeta = await fetchRepoMetadata(client, repo, pkgs2Dir)
        inc fetchedEntries
        if not cache.isNil:
          cachedEntries[repo] = CachedEntry(
            kind: cekMetadata,
            metadata: repoMeta,
            cachedOn: now().utc.format(EntryCacheDateFormat)
          )
          entryCacheChanged = true
      metadata[repo] = repoMeta

      for dep in repoMeta.deps:
        graph.addEdge(Edge(src: repo, dst: dep.repo, version: dep.version, sourceFile: dep.sourceFile))
        await visit(dep.repo, depth + 1)
    except TooManySubRequestsError as exc:
      stoppedBySubrequestLimit = true
      errors[repo] = "Cloudflare subrequest limit reached: " & exc.msg
      warn &"Returning partial graph after reaching the subrequest limit at {repo}."
      cachedEntries[repo] = CachedEntry(kind: cekUnfetched)
      entryCacheChanged = true
    except ValueError as exc:
      errors[repo] = "Parse error: " & exc.msg
      warn &"Failed to parse {repo}: {errors[repo]}"
    except OSError as exc:
      errors[repo] = "Local file error: " & exc.msg
      warn &"Failed to read local metadata for {repo}: {errors[repo]}"
    except CatchableError as exc:
      errors[repo] = "Network/API error: " & exc.msg
      warn &"Failed to fetch {repo}: {errors[repo]}"

  for entryRepo in entryRepos:
    await visit(entryRepo, 0)

  if not cache.isNil:
    try:
      await saveEntryCache()
    except TooManySubRequestsError:
      warn "Could not save dependency-graph progress because the subrequest limit is exhausted."

  result = (graph, metadata, errors, not stoppedBySubrequestLimit)

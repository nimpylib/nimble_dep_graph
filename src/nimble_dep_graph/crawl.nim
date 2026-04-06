
import std/[logging, options, strformat, tables]
import ./[types, graph, fetch]

proc crawlDependencyGraph*(
  client: ApiClient,
  entryRepos: seq[string],
  maxRepos: int,
  pkgs2Dir: Option[string]
): (Graph, Table[string, RepoMetadata], Table[string, string]) =
  var graph = initGraph()
  var metadata = initTable[string, RepoMetadata]()
  var errors = initTable[string, string]()
  var visited = initTable[string, bool]()

  info &"Starting crawl with entry repos: {entryRepos}, maxRepos: {maxRepos}"

  proc visit(repo: string, depth: int) =
    if visited.hasKey(repo):
      return
    if visited.len >= maxRepos:
      warn &"Reached --max-repos limit ({maxRepos}). Stopping recursion."
      return

    info &"Visiting repo: {repo} (depth={depth})"
    visited[repo] = true
    graph.addNode(repo)

    try:
      let repoMeta = fetchRepoMetadata(client, repo, pkgs2Dir)
      metadata[repo] = repoMeta

      for dep in repoMeta.deps:
        graph.addEdge(Edge(src: repo, dst: dep.repo, version: dep.version, sourceFile: dep.sourceFile))
        visit(dep.repo, depth + 1)
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
    visit(entryRepo, 0)

  result = (graph, metadata, errors)

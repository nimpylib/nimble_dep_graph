import std/[strformat, strutils, tables]
import ./defaults

type
  Edge* = object
    src*, dst*: string
    version*: string
    sourceFile*: string

  Graph* = object
    nodes*: seq[string]
    nodeSet: Table[string, bool]
    edges*: seq[Edge]
    edgeIndex: Table[(string, string), int]

proc initGraph*(): Graph =
  Graph(nodes: @[], nodeSet: initTable[string, bool](), edges: @[], edgeIndex: initTable[(string, string), int]())

proc addNode*(graph: var Graph, repo: string) =
  if not graph.nodeSet.hasKey(repo):
    graph.nodeSet[repo] = true
    graph.nodes.add(repo)

proc addEdge*(graph: var Graph, edge: Edge) =
  let key = (edge.src, edge.dst)
  if graph.edgeIndex.hasKey(key):
    let idx = graph.edgeIndex[key]
    graph.edges[idx] = edge
  else:
    graph.edgeIndex[key] = graph.edges.len
    graph.edges.add(edge)


proc simplify(repo: string): string =
  if repo.startsWith(DefOrg):
    return repo[DefOrg.len .. ^1]
  repo

proc toMermaid*(graph: Graph): string =
  var lines = @["graph TD"]
  if graph.edges.len == 0:
    for node in graph.nodes:
      lines.add("  " & simplify(node))
  else:
    for edge in graph.edges:
      lines.add(&"  {simplify(edge.src)} --> {simplify(edge.dst)}")
  lines.join("\n") & '\n'

proc escapeDot(s: string): string =
  s.multiReplace(
    ("\\", "\\\\"),
    ("\"", "\\\""),
  ).simplify

proc toDot*(graph: Graph): string =
  var lines = @["digraph deps {", "  rankdir=LR;"]
  for node in graph.nodes:
    lines.add(&"  \"{escapeDot(node)}\";")

  for edge in graph.edges:
    if edge.version.len > 0:
      lines.add(&"  \"{escapeDot(edge.src)}\" -> \"{escapeDot(edge.dst)}\" [label=\"{escapeDot(edge.version)}\"];")
    else:
      lines.add(&"  \"{escapeDot(edge.src)}\" -> \"{escapeDot(edge.dst)}\";")

  lines.add("}")
  lines.join("\n") & "\n"

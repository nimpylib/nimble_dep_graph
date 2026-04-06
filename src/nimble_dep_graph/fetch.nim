import std/[json, logging, options, strformat, strutils]

when not defined(js):
  import std/[os, times, algorithm]

import ./[types, defaults, parserepo, remoteContent]
export types, defaults, parserepo, ApiClient

proc findNimbleFile(client: ApiClient, repo: string): Option[string] =
  let apiUrl = &"https://api.github.com/repos/{repo}/contents"
  let payload = getJson(client, apiUrl)

  if payload.kind != JArray:
    info &"GitHub contents payload for {repo} is not a list, but {payload.kind}"
    return none(string)

  for item in payload.items:
    if item.kind != JObject:
      continue
    let itemType = if item.hasKey("type"): item["type"].getStr() else: ""
    let name = if item.hasKey("name"): item["name"].getStr() else: ""
    if itemType == "file" and name.endsWith(".nimble") and item.hasKey("download_url"):
      let downloadUrl = item["download_url"].getStr()
      if downloadUrl.len > 0:
        debug &"Found nimble file for {repo}: {name}"
        return some(downloadUrl)

  info &"No .nimble file found in repo root: {repo}"

when not defined(js):
  proc selectLocalNimbleFile(pkgDir: string, repoName: string): Option[string] =
    let preferred = pkgDir / (&"{repoName}.nimble")
    if fileExists(preferred):
      return some(preferred)

    var nimbleFiles: seq[string]
    for kind, path in walkDir(pkgDir):
      if kind == pcFile and path.endsWith(".nimble"):
        nimbleFiles.add(path)

    nimbleFiles.sort(system.cmp[string])
    if nimbleFiles.len > 0:
      return some(nimbleFiles[0])

  proc findLocalNimbleFile(pkgs2Dir: string, repo: string): Option[string] =
    let parts = repo.split('/', maxsplit = 1)
    let repoName = parts[1]

    if not dirExists(pkgs2Dir):
      debug &"Local pkgs2 dir does not exist: {pkgs2Dir}"
      return none(string)

    var candidates: seq[string]
    for kind, path in walkDir(pkgs2Dir):
      if kind != pcDir:
        continue
      let base = splitPath(path).tail
      if base.startsWith(repoName & "-"):
        candidates.add(path)

    if candidates.len == 0:
      debug &"No local pkgs2 match for {repo} under {pkgs2Dir}"
      return none(string)

    candidates.sort(proc(a, b: string): int = cmp(getLastModificationTime(b), getLastModificationTime(a)))

    for candidate in candidates:
      let nimblePath = selectLocalNimbleFile(candidate, repoName)
      if nimblePath.isSome:
        info &"Using local nimble metadata for {repo}: {nimblePath.get()}"
        return nimblePath

    info &"Matched local dirs for {repo} but found no .nimble file"
    none(string)

proc fetchRepoMetadata*(client: ApiClient, repo: string, pkgs2Dir: Option[string]): RepoMetadata =
  when not defined(js):
    if pkgs2Dir.isSome:
      let localNimble = findLocalNimbleFile(pkgs2Dir.get(), repo)
      if localNimble.isSome:
        let nimblePath = localNimble.get()
        let nimbleText = readFile(nimblePath)
        let deps = parsePylibDeps(nimbleText, repo, splitPath(nimblePath).tail)
        info &"Parsed {deps.len} direct deps from local {nimblePath}"
        return RepoMetadata(repo: repo, nimbleFile: some(nimblePath), deps: deps)

  let nimbleUrl = findNimbleFile(client, repo)
  if nimbleUrl.isNone:
    info &"Skipping deps parse for {repo} because no nimble file was found."
    return RepoMetadata(repo: repo, nimbleFile: none(string), deps: @[])

  let url = nimbleUrl.get()
  let nimbleText = getText(client, url)
  let parts = url.rsplit('/', maxsplit = 1)
  let fileName = parts[^1]
  let deps = parsePylibDeps(nimbleText, repo, fileName)
  info &"Parsed {deps.len} direct deps from {repo}/{fileName}"
  result = RepoMetadata(repo: repo, nimbleFile: some(fileName), deps: deps)


import std/[strformat, strutils, options, strscans]
import ./[types, defaults]

proc validateRepo*(repo: string): string =
  let trimmed = repo.strip(chars = {' ', '/'})
  let parts = trimmed.split('/')
  if parts.len != 2 or parts[0].len == 0 or parts[1].len == 0:
    raise newException(ValueError, &"Invalid repo '{repo}'. Expected format 'owner/name', e.g. {DefPackage}.")
  &"{parts[0]}/{parts[1]}"

proc normalizeDepRepo(depValue: string, owner: string): string =
  let dep = depValue.strip(chars = {' ', '/'})
  if dep.len == 0:
    raise newException(ValueError, "Dependency name is empty in nimble metadata.")
  if '/' in dep:
    return validateRepo(dep)
  &"{owner}/{dep}"

const depStmtScans{.strdefine.} = "$spylib$s\"$+\"$s,$s\"$+\""
proc parsePylibLine(line: string): Option[(string, string)] =
  var depName, version: string
  if scanf(line, depStmtScans, depName, version):
    return some((depName, version))

proc parsePylibDeps*(nimbleText: string, currentRepo: string, sourceFile: string): seq[DependencySpec] =
  let owner = currentRepo.split('/')[0]
  for rawLine in nimbleText.splitLines():
    let parsed = parsePylibLine(rawLine)
    if parsed.isNone:
      continue

    let (depName, version) = parsed.get()
    let depRepo = normalizeDepRepo(depName, owner)
    result.add(DependencySpec(repo: depRepo, version: version.strip(), sourceFile: sourceFile))

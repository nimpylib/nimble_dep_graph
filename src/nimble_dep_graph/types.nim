
import std/options
export options

type
  DependencySpec* = object
    repo*: string
    version*: string
    sourceFile*: string

  RepoMetadata* = object
    repo*: string
    nimbleFile*: Option[string]
    deps*: seq[DependencySpec]

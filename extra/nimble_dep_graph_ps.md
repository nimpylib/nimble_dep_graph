

## Error Handling

- Never write bare `except:`.
- Catch specific exceptions such as `ValueError`, or other concrete types as needed.
- use logging library when needed

## What to do
- write program to "./nimble_dep_graph.py"
- this repo are expected to accept a cli argument, defaults to nimpylib/nimpylib, as entry repo
- all repo are assumed to be on github.com
- direct deps are described under repo's /XXX.nimble, in format of `pylib "DEP", "VERSION"`



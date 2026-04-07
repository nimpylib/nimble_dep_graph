

proc unreachable*{.noReturn.} =
  doAssert false, "This code should be unreachable"

template never*[T](res: T; exc: typedesc[CatchableError]): T =
  bind unreachable
  try: res
  except exc:
    unreachable()

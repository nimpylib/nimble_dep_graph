
import std/[times, logging]
import ./[cache, utils]
export cache

proc eqDate(d1, d2: DateTime): bool =
  (d1.year == d2.year) and (d1.yearday() == d2.yearday())

proc getDailyCachedOr*[T](cache: CacheBackendAbc, key: string, getter: proc(): Future[T]): Future[T] {.async.} =
  let datekey = key & "-date"
  let opt = await cache.get(datekey)
  let cur = now().utc
  if opt.isSome:
    let dateStr = opt.unsafeGet
    let date = parse(dateStr, "yyyy-MM-dd", utc()).never TimeParseError
    if eqDate(cur, date):
      let valOpt = await cache.get(key)
      assert valOpt.isSome, "Cache date is valid but value is missing"
      info &"Cache hit for key: {key}"
      let val = valOpt.unsafeGet()
      return val
    else:
      info &"Cache stale for key: {key}"
  else:
    info &"Cache miss for key: {key}"
  await cache.set(datekey, cur.format("yyyy-MM-dd"))
  let res = await getter()
  await cache.set(key, res)
  result = res

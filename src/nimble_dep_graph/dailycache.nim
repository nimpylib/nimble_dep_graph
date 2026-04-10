
import std/[times, logging]
import ./[types, cache, utils]
export cache

proc eqDate(d1, d2: DateTime): bool =
  (d1.year == d2.year) and (d1.yearday() == d2.yearday())

proc getDailyCachedOr*[T](cache: CacheBackendAbc, key: string, getter: proc(): Future[T]): Future[T] {.async.} =
  let datekey = key & "-date"
  let opt = await cache.get(datekey)
  let cur = now().utc
  proc updateCache: Future[T]{.async.} =
    let res = await getter()
    await cache.set(datekey, cur.format("yyyy-MM-dd"))
    await cache.set(key, res)
    return res
  if opt.isSome:
    let dateStr = opt.unsafeGet
    let date = parse(dateStr, "yyyy-MM-dd", utc()).never TimeParseError
    proc viaCache: Future[T]{.async.} =
      let valOpt = await cache.get(key)
      assert valOpt.isSome, "Cache date is valid but value is missing"
      let val = valOpt.unsafeGet()
      return val
    if eqDate(cur, date):
      info &"Cache hit for key: {key}"
      return await viaCache()
    else:
      info &"Cache stale for key: {key}"
      try:
        return await updateCache()
      except ApiRateLimitError:
        # rate limit is temporary, so we can still use the stale cache value if it exists,
        #  and the data requested here is not very time-sensitive,
        #  we leave latter requests trying again to update the cache
        warn &"Cache stale for key: {key}, but API rate limit was hit when trying to update. Returning stale cache value."
        return await viaCache()
  else:
    info &"Cache miss for key: {key}"
  return await updateCache()
  # here we raise ApiRateLimitError if the getter fails, and callers handle it

# cache.nim
# Simple string cache with pluggable backend (e.g., in-memory, Cloudflare KV)

import std/[strutils, options, tables, strformat, json]
export options, json

when not defined(js):
  import std/envvars

import ./remoteContent
import ./utils
export remoteContent
# CacheBackend interface
# Implementations must provide get and set

type
  CacheBackendAbc* = ref object of RootObj
  MemCacheBackend* = ref object of CacheBackendAbc
    cache: Table[string, string]

template notImpl = raise newException(Defect, "This method must be implemented by the cache backend.")
method get*(backend: CacheBackendAbc, key: string): Future[Option[string]]{.async, base.} = notImpl
method set*(backend: CacheBackendAbc, key, value: string){.async, base.} = notImpl

# In-memory cache implementation (default)
method get*(backend: MemCacheBackend, key: string): Future[Option[string]]{.async.} =
  if key in backend.cache:
    return some(backend.cache[key])
method set*(backend: MemCacheBackend, key, value: string){.async.} =
  backend.cache[key] = value
proc newMemoryCache*(): MemCacheBackend = MemCacheBackend(cache: initTable[string, string]())

# Cloudflare KV (JS only, stub)

type
  ApiCacheBackend* = ref object of CacheBackendAbc
    ## add header `Authorization: Bearer $api_key`
    api_key: string

  PreUrlApiCacheBackend* = ref object of ApiCacheBackend
    preUrl: string
  CfApiCacheBackend* = ref object of PreUrlApiCacheBackend

proc newCfKvApiCacheBackend*(account_id, namespace_id, api_key: string): CfApiCacheBackend =
  CfApiCacheBackend(
    api_key: api_key,
    preUrl:
      &"https://api.cloudflare.com/client/v4/accounts/{account_id}/storage/kv/namespaces/{namespace_id}/values/"
      #&"http://localhost:8000/"
  )

when declared(getEnv):
  proc getEnvNonEmpty(key: string): string =
    result = getEnv(key)
    if result.len == 0:
      raise newException(ValueError, &"Environment variable '{key}' is not set or empty")
  
  proc `or`(a: string, b: string): string =
    if a.len > 0: a else: b

  proc newCfKvApiCacheBackendFromEnv*(): CfApiCacheBackend =
    newCfKvApiCacheBackend(
      account_id=   getEnvNonEmpty("CF_ACCOUNT_ID"),
      namespace_id= getEnvNonEmpty("CF_NAMESPACE_ID"),
      api_key=      getEnv("CF_API_KEY").strip() or getEnvNonEmpty("CF_API_KEY_FILE").readFile.strip()
    )

proc getFut(backend: PreUrlApiCacheBackend, key: string, httpMethod = HttpGet, body = ""): Future[string] =
  let url = backend.preUrl & key
  let fut = newApiClient(backend.api_key).getText(url, httpMethod, body)
  fut

method get*(backend: PreUrlApiCacheBackend, key: string): Future[Option[string]]{.async.} =
  let fut = backend.getFut(key)
  return some(await fut)

const Typed = true

when Typed:
  type
    Error = object
      code: int
      message: string
    Result = object
      result: string  # may be `null` on Json
      errors: seq[Error]
      messages: seq[string]
      success: bool

method get*(backend: CfApiCacheBackend, key: string): Future[Option[string]]{.async.} =
  let fut = backend.getFut(key)
  let s = await fut
  if s.startsWith('{') and s.endsWith('}'):
    let j = try: parseJson(s)
    except IOError, OSError, JsonParsingError, ValueError: unreachable()

    var
      errMsg: string
      errCode: int
    when not Typed:
      assert j.kind == JObject and (
        assert "success" in j;
        not j{"success"}.getBool
      )
      let errs = j{"errors"}
      assert errs.len == 1
      let err = errs[0]
      errCode = err{"code"}.getInt
    else:
      let res = j.to Result
      assert not res.success
      let errs = res.errors
      let err = errs[0]
      assert errs.len == 1
      errCode = err.code
    if errCode != 10009:
      when not Typed:
        errMsg = err{"message"}.getStr()
      else:
        errMsg = err.message
      let exc = newException(HttpRequestError , &"""Error fetching cache key '{key}' with remote error: {errMsg}""")
      raise exc
    return none(string)
  return some s

method set*(backend: CfApiCacheBackend, key, value: string){.async.} =
  let fut = backend.getFut(key, HttpPut, value)
  let j = parseJson(await fut)
  if j{"success"}.getBool:
    return
  else:
    let errs = j{"errors"}
    assert errs.len == 1
    let err = errs[0]
    let errMsg = err{"message"}.getStr()
    let exc = newException(HttpRequestError , &"""Error setting cache key '{key}' with remote error: {errMsg}""")
    raise exc


when isMainModule:
  let cache = newCfKvApiCacheBackendFromEnv()
  waitFor cache.set("t", "hello world")
  echo waitFor cache.get"t"
  echo waitFor cache.get"d"


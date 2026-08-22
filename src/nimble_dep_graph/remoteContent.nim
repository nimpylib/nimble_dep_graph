
import std/[options, json, strutils]
import std/[httpcore,]
export httpcore

when defined(js):
  import std/[jsfetch, jsheaders, asyncjs, jsffi]
  export asyncjs
  type HttpRequestError* = object of IOError
else:
  import std/[
    httpclient,
    asyncdispatch
  ]
  export asyncdispatch
  export httpclient.HttpRequestError

type
  ApiClient* = object
    token*: Option[string]

func newApiClient*(token: string): ApiClient = ApiClient(token: some token)

template buildHeadersCommon(T) =
  if token.isSome:
    result["Authorization"] = T("Bearer " & token.get())
  # Browser fetch to raw.githubusercontent.com is sensitive to preflight.
  # Keep headers CORS-simple there to avoid OPTIONS failures.
  
  # ref https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS/Errors#client-side_considerations
  if url.startsWith("https://raw.githubusercontent.com") or url.startsWith("https://api.cloudflare.com"):
    result["Accept"] = "text/plain"
    return

  result["Accept"] = "application/vnd.github+json"
  result["User-Agent"] = "nimble-dep-graph"

type TooManySubRequestsError* = object of IOError  ## Cloudflare Worker \
  ## https://developers.cloudflare.com/workers/wrangler/configuration/#limits
when not defined(js):
  proc buildHeaders(token: Option[string], url: string): HttpHeaders =
    result = newHttpHeaders()
    buildHeadersCommon(`$`)

  proc getText(client: ApiClient, url: string, httpMethod = HttpGet, body = ""): Future[string]{.async.} =
    var http = newAsyncHttpClient(headers = buildHeaders(client.token, url))
    defer: http.close()
    var res: AsyncResponse = await http.request(url, httpMethod, body)
    result = await res.body

else:
  proc buildHeaders(token: Option[string], url: string): Headers =
    result = newHeaders()
    buildHeadersCommon(cstring)

  proc getText(client: ApiClient, url: string, httpMethod = HttpGet, body = ""): Future[string]{.async.} =
    let h = buildHeaders(client.token, url)
    var nbody: cstring = nil
    if body.len > 0:
      nbody = cstring body
    let opt = newfetchOptions(httpMethod, headers = h,
      cache = fchNoStore,
      referrer = cstring"about:client",
      body = nbody,
    )
    discard jsDelete opt.cache  # The 'cache' field on 'RequestInitializerDict' is not implemented.
    let fut = fetch(url.cstring, opt)
    await fut.catch do (e: Error):
      proc startsWith(s, pre: cstring): bool {.importcpp.}
      if e.message.startsWith "Too many subrequests by single Worker invocation.":
        raise newException(TooManySubRequestsError, $e.message)
      else:
        {.emit: ["throw ", e].}
    result = $(await (await fut).text())

export getText
proc getJson*(client: ApiClient, url: string): Future[JsonNode] {.async.} =
  result = parseJson(await getText(client, url))


import std/[options, json, strutils]

when defined(js):
  import std/[jsfetch, jsheaders, asyncjs]
  export asyncjs
else:
  import std/[
    httpclient,
    httpcore,
    asyncdispatch
  ]
  export asyncdispatch

type
  ApiClient* = object
    token*: Option[string]

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

when not defined(js):
  proc buildHeaders(token: Option[string], url: string): HttpHeaders =
    result = newHttpHeaders()
    buildHeadersCommon(`$`)

  proc getText(client: ApiClient, url: string): Future[string]{.async.} =
    var http = newAsyncHttpClient(headers = buildHeaders(client.token, url))
    defer: http.close()
    result = await http.getContent(url)

else:
  proc buildHeaders(token: Option[string], url: string): Headers =
    result = newHeaders()
    buildHeadersCommon(cstring)

  proc getText(client: ApiClient, url: string): Future[string]{.async.} =
    let h = buildHeaders(client.token, url)
    let opt = newfetchOptions(headers = h)
    result = $(await (await fetch(url.cstring, opt)).text())

export getText
proc getJson*(client: ApiClient, url: string): Future[JsonNode] {.async.} =
  result = parseJson(await getText(client, url))

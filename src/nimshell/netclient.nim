## Shared HTTP client setup: TLS verification, timeouts, and the standard
## proxy environment variables (Nim's httpclient ignores them by default).

import std/[httpclient, net, os, strutils, uri]

proc proxyFromEnv*(url: string): Proxy =
  ## `HTTPS_PROXY` / `HTTP_PROXY` (either case) for `url`, honoring
  ## `NO_PROXY` host suffixes. nil when no proxy applies.
  let u = parseUri(url)
  let host = u.hostname.toLowerAscii
  for name in ["NO_PROXY", "no_proxy"]:
    for entry in getEnv(name).split(','):
      let e = entry.strip.toLowerAscii.strip(chars = {'.'}, trailing = false)
      if e == "": continue
      if e == "*" or host == e or host.endsWith("." & e): return nil
  let names = if u.scheme == "https": ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]
              else: ["HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
  for name in names:
    let p = getEnv(name)
    if p != "":
      return newProxy(if "://" in p: p else: "http://" & p)
  nil

proc newShellClient*(url: string, timeoutMs: int, headers: HttpHeaders = nil,
                     insecure = false, maxRedirects = 5): HttpClient =
  let hdrs = if headers.isNil: newHttpHeaders() else: headers
  when defined(ssl):
    let ctx = newContext(verifyMode = if insecure: CVerifyNone else: CVerifyPeer)
    newHttpClient(timeout = timeoutMs, sslContext = ctx, headers = hdrs,
                  proxy = proxyFromEnv(url), maxRedirects = maxRedirects)
  else:
    newHttpClient(timeout = timeoutMs, headers = hdrs, proxy = proxyFromEnv(url),
                  maxRedirects = maxRedirects)

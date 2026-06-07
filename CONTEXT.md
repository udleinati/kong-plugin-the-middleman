# the-middleman

Domain language for the `the-middleman` Kong plugin: a forward-auth that makes an
extra HTTP call before proxying, caches it, and folds the answer back into the
request as headers. This file is the project glossary — name things with these
words in code, comments, commits, and architecture reviews.

## Language

**the-middle-request**:
The extra HTTP request the plugin makes to your service *before* proxying the
original request. The whole plugin exists to make, cache, and apply this one call.
_Avoid_: auth request, sub-request, pre-request.

**Middle-service**:
Your service that answers **the-middle-request** (`config.url` + `config.path`).
Distinct from the **upstream**.
_Avoid_: auth service, backend.

**Upstream**:
The real destination app the request was headed to — what Kong proxies to *after*
the-middleman is done. Receives the injected headers and trusts them.
_Avoid_: using "upstream" to mean the middle-service.

**Resolver**:
The module that resolves **the-middle-request** — from the cache when enabled,
otherwise by calling the **middle-service** — and decides the **cache-status**. It
holds the HIT/MISS/REFRESH/STALE/BYPASS state machine, the stampede lock, and the
serve-stale fallback. Pure of `kong`/`ngx`/`resty`: every effect is injected.
_Avoid_: cache, fetcher (the cache is the **policy**; the fetch is one injected dep).

**Cache-status**:
The outcome label for a resolved the-middle-request, reported on the
`x-middleman-cache-status` header. One of: `HIT` (fresh, no call made), `MISS` (not
cached, called), `REFRESH` (stale re-validated by a fresh call), `STALE`
(middle-service unreachable, stale copy served), `BYPASS` (client `Cache-Control`
forbade the cache).
_Avoid_: cache state, cache result.

**Policy**:
A cache-storage adapter behind a common `probe` / `set` / `invalidate` interface.
Two exist: `local` (per-node, in-memory) and `redis` (shared).
_Avoid_: store, backend, cache (the cache is *what* a policy holds).

**Injection**:
Folding the middle-service's answer onto **the-middle-request**'s upstream request
as `x-…` headers — the JSON body keys (dasherized) and/or named response headers —
so the **upstream** can just trust them.
_Avoid_: header copy, header mapping.

**Streamup / Streamdown**:
Direction words. *Streamup* = toward the **upstream**/app (e.g.
`cache_invalidate_when_streamup_path`). *Streamdown* = back toward the client (e.g.
`streamdown_injected_headers` mirrors the injected headers onto the client
response).
_Avoid_: inbound/outbound, request-side/response-side.

**Serve-stale**:
Returning a stale cached the-middle-request (kept alive by `cache_storage_ttl`
beyond its freshness window) when the middle-service is unreachable — trading
freshness for resilience. Surfaces as cache-status `STALE`.
_Avoid_: fallback cache, grace mode.

**Gate / deny**:
When the middle-service answers `>= 400`, that status/body is replayed to the
client and the upstream is never reached — the request is *denied*.
_Avoid_: block, reject.

## Flagged ambiguities

- **"upstream"** is overloaded in gateway-speak. Here it means *only* the real
  destination app. The service answering the-middle-request is always the
  **middle-service**, never "the upstream".
- **"cache"** vs **"policy"** vs **"resolver"**: the *policy* is the storage, the
  *resolver* is the decision logic over it. Neither is "the cache" — that word
  refers loosely to the stored entries, not a module.

## Example dialogue

> **Dev:** A request comes in — does the-middleman always call the middle-service?
>
> **Maintainer:** No. The **resolver** tries the **policy** first. If there's a
> fresh entry it's a `HIT` and the **middle-service** is never touched. On a miss
> it calls, gets the answer, and that's a `MISS`.
>
> **Dev:** And if the middle-service is down?
>
> **Maintainer:** If we have a stale copy within `cache_storage_ttl`, we
> **serve-stale** — cache-status `STALE`. If the answer were `>= 400` instead, that's
> not an outage, that's a **gate**: we *deny* and replay it to the client.
>
> **Dev:** Where do the `x-role` / `x-user-id` headers come from?
>
> **Maintainer:** **Injection.** The resolver hands the response to `access`, which
> folds the JSON body and named response headers onto the **streamup** request so the
> **upstream** can trust them. Turn on `streamdown_injected_headers` and they're
> mirrored back to the client too.

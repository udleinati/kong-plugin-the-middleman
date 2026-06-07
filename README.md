# The Middleman

A Kong plugin that makes an extra HTTP request — **`the-middle-request`** — to a
service of yours *before* proxying the original request, and folds that service's
answer back into the request. Think of it as a **forward-auth** with first-class
**caching** and **header injection**.

> **Requires Kong 3.6+** (it uses Kong's shared `kong.tools.redis.schema`).

## What it does

For every incoming request, `the-middleman` can:

- **Forward** the `path`, `host`, `query`, `headers` and/or `body` to your service.
- **Gate** the request — a `>= 400` answer from your service is replayed to the
  client (deny); anything `< 400` proceeds.
- **Inject** your service's JSON response (and/or named response headers) onto the
  upstream request as `x-…` headers, so the destination service can just trust them.
- **Cache** the middle-request (in-memory `local` or shared `redis`) with a
  freshness window, serve-stale on outages, `Cache-Control` support, configurable
  cacheable status codes, and stampede protection — so you don't pay the extra
  round-trip on every request.

Inspired by [kong-external-auth](https://github.com/jcramalho/kong-external-auth "kong-external-auth")
and [kong-middleman-plugin](https://github.com/pantsel/kong-middleman-plugin "kong-middleman-plugin").

## How it works

1. A request hits a route that has `the-middleman` enabled.
2. The plugin resolves `the-middle-request` — from cache when possible, otherwise
   by calling your service (`config.url` + `config.path`).
3. If the service answers `>= 400`, that status/body is returned to the client and
   the upstream is never reached (request denied).
4. Otherwise the service's JSON body (and any `forward_response_headers`) are
   injected onto the upstream request as headers.
5. Kong proxies to the real upstream, which can rely on the injected headers.

## Installation

```bash
luarocks install kong-plugin-the-middleman
```

Add it to Kong's `plugins` list:

```
plugins = bundled,the-middleman
```

## Configuration

Enable it on a service (or route) via the Kong 3.x Admin API:

```bash
curl -X POST http://localhost:8001/services/{service}/plugins \
  --data name=the-middleman \
  --data config.url=http://my-middle-service:8080
```

…or declaratively in `kong.yml` — see the
[playground](https://github.com/udleinati/kong-plugin-the-middleman/tree/master/playground "playground")
for a runnable, db-less example.

### Request & middle-service call

| Parameter | default | description |
| --- | --- | --- |
| `config.url` | *(required)* | The middle-service base URL. |
| `config.path` | `/auth` | Path on the middle-service the request is sent to. |
| `config.method` | `POST` | Allowed values: `POST` and `GET`. |
| `config.connect_timeout` | `5000` | Connect timeout (in ms). Must be `> 0`. |
| `config.send_timeout` | `10000` | Send timeout (in ms). Must be `> 0`. |
| `config.read_timeout` | `10000` | Read timeout (in ms). Must be `> 0`. |

### Forwarding the incoming request to the middle-service

| Parameter | default | description |
| --- | --- | --- |
| `config.forward_path` | `false` | Forward the request path. |
| `config.forward_query` | `false` | Forward the request query. |
| `config.forward_headers` | `false` | Forward the request headers. |
| `config.forward_body` | `false` | Forward the request body. |
| `config.forward_headers_allow` | `[]` | When set, restrict the forwarded headers to these names (only applies when `forward_headers` is on). Empty = forward all. |

### Injecting the middle-service answer onto the upstream request

| Parameter | default | description |
| --- | --- | --- |
| `config.inject_body_response_into_header` | `true` | Inject the middle-service JSON body into the request headers. Keys are dasherized (kebab-case); a JSON `null` is skipped, `false`/`0` are injected. |
| `config.injected_header_prefix` | `X-` | Prefix for the injected headers. |
| `config.forward_response_headers` | `[]` | Names of the middle-service **response** headers to copy onto the upstream request (auth services often return identity in headers, not the JSON body). |
| `config.streamdown_injected_headers` | `false` | Also mirror the injected headers (and the cache-status headers) onto the **client response**. |

### Caching

| Parameter | default | description |
| --- | --- | --- |
| `config.cache_enabled` | `false` | Cache the middle-request. Adds `x-middleman-cache-status` and `x-middleman-cache-key` headers. |
| `config.cache_policy` | `local` | `local` (per-node, in-memory) or `redis` (shared). |
| `config.cache_based_on` | `host` | What the cache key varies on: `host`, `host-path`, `host-path-query` or `header`. |
| `config.cache_based_on_headers` | `authorization` | Comma-separated header names used as the key when `cache_based_on=header`. The first present header wins (so `header1,header2` prioritises `header1`). |
| `config.cache_ttl` | `60` | Freshness window (seconds). Must be a positive integer. |
| `config.cache_storage_ttl` | `0` | Seconds an entry is retained **beyond** `cache_ttl`, so a stale copy can be served while the middle-service is unreachable. `0` disables serve-stale. |
| `config.cache_response_codes` | `[]` | Which middle-service status codes are cacheable. Empty = any non-error (`status < 400`). |
| `config.cache_control` | `false` | Honour RFC7234 `Cache-Control` (`no-store`/`no-cache`/`max-age`) from the client request and the middle-service response. |
| `config.cache_invalidate_when_streamup_path` | `[]` | Request paths that invalidate the cached entry when hit (regardless of status code). |

The `x-middleman-cache-status` header reports what happened:

| Status | Meaning |
| --- | --- |
| `HIT` | Served from a fresh cache entry (no middle-request made). |
| `MISS` | Not cached; the middle-service was called. |
| `REFRESH` | A stale entry was re-validated by a fresh middle-request. |
| `STALE` | The middle-service was unreachable; a stale copy was served (needs `cache_storage_ttl`). |
| `BYPASS` | The client sent `Cache-Control: no-store`/`no-cache` (needs `cache_control`). |

### Redis (when `cache_policy = redis`)

| Parameter | default | description |
| --- | --- | --- |
| `config.redis.host` |  | Mandatory when `cache_policy` is `redis`. |
| `config.redis.port` | `6379` | |
| `config.redis.password` | | Referenceable (vault). |
| `config.redis.username` | | Referenceable (vault). Requires Redis 6.0.0+. |
| `config.redis.ssl` | `false` | |
| `config.redis.ssl_verify` | `false` | |
| `config.redis.server_name` | | SNI used for the TLS handshake. |
| `config.redis.timeout` | `2000` | |
| `config.redis.database` | `0` | |

> The Redis config uses Kong's shared `config.redis.*` record (Kong 3.6+). The
> legacy flat fields (`config.redis_host`, `config.redis_port`, …) are still
> accepted for backwards compatibility and are folded into `config.redis.*`.

## Use cases

Check the [playground](https://github.com/udleinati/kong-plugin-the-middleman/tree/master/playground "playground")
to see `the-middleman` working.

### Host offloading

You might need to identify your client by `host` with some custom logic and add
information to the request header. I call this process `host-offloading`:

1. Receive requests from www.domain1.com and www.domain2.com;
2. `the-middleman` sends `the-middle-request` to some service;
3. The service checks the `x-forwarded-host` header and returns a JSON with a `domainId` property;
4. `the-middleman` adds the `domainId` to the original header: `x-domain-id`;
5. The destination service doesn't need to offload the host — it just reads the data it needs from the header.

### Inject user data into the header

1. Request comes in with some JWT;
2. `the-middleman` sends `the-middle-request` to some service;
3. The service validates the JWT, performs some custom logic and returns a JSON with `role` and `userId` properties;
4. `the-middleman` adds `role` and `userId` to the original header: `x-role` and `x-user-id`;
5. The destination service doesn't need to validate the JWT — it just relies on the headers `x-role` and `x-user-id`.

## Development & Testing

The plugin is covered by two test suites under `spec/`:

- `spec/01-unit` — fast, fully-mocked unit tests for every module
  (`utils`, `access`, `policies`, `handler`). No Kong/network needed.
- `spec/02-integration` — end-to-end tests that boot a real Kong, validate the
  schema and exercise the full request flow (header injection, cache
  HIT/MISS/REFRESH/STALE/BYPASS, response-header forwarding, error passthrough).

Tests run inside [Pongo](https://github.com/Kong/kong-pongo), Kong's official
test runner (requires Docker). The provided `Makefile` vendors Pongo locally on
first use:

```bash
make test                  # luacheck + the whole suite
make unit                  # only spec/01-unit
make integration           # only spec/02-integration
make lint                  # luacheck only
make test KONG_VERSION=3.9.2   # pin a specific Kong version
```

CI runs the same suite across several Kong versions (see
`.github/workflows/test.yml`).

## Author

Udlei Nati - [GitHub](https://github.com/udleinati "GitHub") - [LinkedIn](https://www.linkedin.com/in/udleinati/ "LinkedIn")

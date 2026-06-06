# The Middleman Playground

A self-contained, **db-less** Docker Compose stack that boots Kong with
`the-middleman` already configured, so you can see the plugin working and
inspect exactly how Kong is set up — no database, no GUI required.

The whole configuration lives in a single declarative file: [`kong.yml`](./kong.yml).

## What's in the stack

| Service | Image | Role |
|---|---|---|
| `playground-kong` | `kong:3.9.2` | The gateway (db-less), with `the-middleman` mounted |
| `playground-redis` | `redis:8-alpine` | Cache backend for the `redis` policy |
| `playground-middle-service` | `denoland/deno:2.8.2` | `the-middle-request` target; returns the identity JSON |
| `playground-destination-service` | `denoland/deno:2.8.2` | Upstream that echoes the injected `x-*` headers |

No PostgreSQL and no migrations: Kong runs in db-less mode
(`KONG_DATABASE=off`) and loads `kong.yml` at boot.

## Requirements

- Docker + Docker Compose
- `jq` (optional — only for a prettier `show-config.sh`; it falls back to raw JSON)

## Quick start

```bash
docker-compose up -d
```

Kong loads `kong.yml`, which declares **two scenarios** that coexist:

| Route | Cache strategy | Redis DB |
|---|---|---|
| `/cache-host` | `cache_based_on=host` | 0 |
| `/cache-header` | `cache_based_on=header` (`authorization`) | 1 |

Both use `cache_policy=redis` and inject the middle-service identity into the
upstream request as `x-tenant-id`, `x-role` and `x-account-id`. A
`x-middleman-cache-status` header (`HIT`/`MISS`) is added on every request. The
destination service echoes all of these in its response body.

Try it:

```bash
curl -s http://localhost:8000/cache-host        # first call: MISS
curl -s http://localhost:8000/cache-host        # second call: HIT
```

## Changing the configuration

Edit [`kong.yml`](./kong.yml), then either restart Kong or hot-reload it:

```bash
docker-compose restart playground-kong   # reload from the mounted file
# or, without a restart:
./reload.sh                              # POSTs kong.yml to the Admin API /config
```

> In db-less mode the Admin API is **read-only** for entities (you can't
> `POST/PUT` services/routes/plugins). The source of truth is `kong.yml`.

## Scripts

All scripts default to the host-published Admin API (`http://localhost:8001`)
and proxy (`http://localhost:8000`). They are POSIX sh.

| Script | What it does |
|---|---|
| `show-config.sh` | Prints how Kong is configured (services / routes / plugins) from the Admin API. |
| `reload.sh` | Re-applies `kong.yml` to a running Kong via `POST /config` (no restart). |
| `test-host.sh` | Step-by-step test of the host scenario: `MISS → HIT → invalidate → MISS`. |
| `test-header.sh` | Step-by-step test of the header scenario: `token-1 MISS → HIT`, `token-2 MISS`. |
| `test.sh` | Runs both test scripts and exits non-zero if anything fails. |

### Inspect the configuration

```bash
./show-config.sh
```

Example output (with `jq`):

```
== SERVICES ==
- destination-service -> http://playground-destination-service:3200

== ROUTES ==
- cache-host    paths=["/cache-host"]
- cache-header  paths=["/cache-header"]

== PLUGINS (the-middleman) ==
- route=...  cache_policy=redis  based_on=host    redis_db=0  url=http://playground-middle-service:3400
- route=...  cache_policy=redis  based_on=header  redis_db=1  url=http://playground-middle-service:3400
```

### Run the tests

```bash
./test.sh
```

Expected (abridged):

```
Cenario: cache por HOST   (http://localhost:8000/cache-host)
[1/4] Primeira requisicao (espera MISS + headers injetados)
  PASS  1a requisicao = MISS
  PASS  header injetado x-tenant-id: 123
  ...
[2/4] Repete a mesma requisicao (espera HIT)
  PASS  2a requisicao = HIT
...
RESULTADO: 6 passou, 0 falhou

Cenario: cache por HEADER (authorization)  (http://localhost:8000/cache-header)
  PASS  token-1 1a vez = MISS
  PASS  token-1 2a vez = HIT
  PASS  token-2 = MISS
RESULTADO: 6 passou, 0 falhou

==> TODOS OS TESTES PASSARAM
```

## Teardown

```bash
docker-compose down
```

## Author

Udlei Nati - [GitHub](https://github.com/udleinati "GitHub") - [LinkedIn](https://www.linkedin.com/in/udleinati/ "LinkedIn")

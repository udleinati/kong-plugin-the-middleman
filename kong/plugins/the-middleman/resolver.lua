-- The Resolver: resolves the-middle-request through the cache.
--
-- It owns the cache-status state machine (HIT/MISS/REFRESH/STALE/BYPASS), the
-- stampede lock and the serve-stale fallback. It is deliberately pure of
-- `kong`/`ngx`/`resty`: every effect is injected via `deps` and every fact about
-- the current request is pre-computed by the caller (access.lua) into `request`.
-- That keeps the whole decision tree testable with plain Lua functions — see
-- spec/01-unit/resolver_spec.lua.

local utils = require "kong.plugins.the-middleman.utils"

local parse_cache_control = utils.parse_cache_control
local get_header_ci = utils.get_header_ci
local EMPTY_CACHE_CONTROL = utils.EMPTY_CACHE_CONTROL

local M = {}

-- True when a cached entry is still within its freshness window. Entries with no
-- deadline (legacy) are treated as fresh; the backend expires them anyway.
local function is_fresh(value, now)
  if not value.fresh_until then
    return true
  end
  return now <= value.fresh_until
end

-- Whether a middle-service response status is eligible for caching.
local function is_cacheable_status(conf, status)
  local codes = conf.cache_response_codes
  if codes and #codes > 0 then
    for _, code in ipairs(codes) do
      if code == status then
        return true
      end
    end
    return false
  end
  -- Default: cache any non-error response.
  return status < 400
end

-- Persist a fresh response, honouring the cacheable-status list and (optionally)
-- Cache-Control. `fresh_until` marks the freshness window; the backend TTL can
-- be longer (cache_storage_ttl) so a stale copy survives for serve-on-error.
local function store_response(conf, policy, cache_key, response, req_no_store, now)
  if req_no_store or not is_cacheable_status(conf, response.status) then
    return
  end

  local resp_cc = conf.cache_control
    and parse_cache_control(get_header_ci(response.headers, "cache-control"))
    or EMPTY_CACHE_CONTROL
  if resp_cc.no_store then
    return
  end

  local fresh_ttl = conf.cache_ttl
  if conf.cache_control and resp_cc.max_age then
    fresh_ttl = resp_cc.max_age
  end
  if fresh_ttl <= 0 then
    return
  end

  local store_ttl = fresh_ttl
  if conf.cache_storage_ttl and conf.cache_storage_ttl > fresh_ttl then
    store_ttl = conf.cache_storage_ttl
  end

  response.fresh_until = now + fresh_ttl
  policy.set(conf, cache_key, response, { ttl = store_ttl })
end

-- Resolve the middle-request response, going through the cache.
--
-- request: facts about THIS request, pre-computed by access.lua from kong globals
--   { cache_key  = <final, hashed string key>,
--     invalidate = <bool: this path invalidates the entry>,
--     skip_read  = <bool: client Cache-Control forbids reading the cache>,
--     no_store   = <bool: client Cache-Control forbids storing> }
-- deps: injected behaviours
--   { policy = <local|redis adapter: probe/set/invalidate>,
--     fetch  = function() -> response, err   (the middle-request call),
--     lock   = function(key) -> unlock_fn | nil   (stampede lock; nil = fail-open),
--     now    = function() -> seconds }
--
-- returns: response, status, err
--   status is one of HIT|MISS|REFRESH|STALE|BYPASS.
--   On an unrecoverable fetch error with no stale fallback: nil, nil, err.
function M.resolve(conf, request, deps)
  local policy = deps.policy
  local now = deps.now()
  local cache_key = request.cache_key
  local invalidate = request.invalidate
  local skip_read = request.skip_read

  -- 1) Serve a fresh cache entry, unless the client forbids reading the cache.
  local cached, probe_err
  if not skip_read then
    cached, probe_err = policy.probe(conf, cache_key)
  end
  if cached and is_fresh(cached, now) then
    if invalidate then policy.invalidate(conf, cache_key) end
    return cached, "HIT"
  end

  -- 2) Cache backend unreachable on the read: fail open, fetch once, no re-touch
  -- (a second connection would just time out too, doubling outage latency).
  if probe_err then
    local response, err = deps.fetch()
    if err then
      return nil, nil, err
    end
    return response, "MISS"
  end

  -- 3) We must fetch. Serialize with a lock to avoid a stampede; keep a stale
  -- `cached` entry (within the storage window) as a fallback on failure.
  local unlock = deps.lock(cache_key)

  if unlock and not skip_read then
    -- A peer may have refreshed the entry while we waited for the lock.
    local refreshed = policy.probe(conf, cache_key)
    if refreshed and is_fresh(refreshed, now) then
      unlock()
      if invalidate then policy.invalidate(conf, cache_key) end
      return refreshed, "HIT"
    end
    if refreshed then
      cached = refreshed
    end
  end

  local response, err = deps.fetch()

  if err then
    if unlock then unlock() end
    -- Serve a stale copy if we have one (resilience), else propagate the error.
    if cached then
      if invalidate then policy.invalidate(conf, cache_key) end
      return cached, "STALE"
    end
    return nil, nil, err
  end

  local status = (skip_read and "BYPASS") or (cached and "REFRESH") or "MISS"

  if not invalidate then
    store_response(conf, policy, cache_key, response, request.no_store, now)
  end

  if unlock then
    unlock()
  end
  if invalidate then
    policy.invalidate(conf, cache_key)
  end

  return response, status
end

return M

local policies = require "kong.plugins.the-middleman.policies"
local utils = require "kong.plugins.the-middleman.utils"

local _M = {}
local http = require "resty.http"
local json = require "cjson"
local resty_lock = require "resty.lock"
local sha256 = require "resty.sha256"
local to_hex = require("resty.string").to_hex

-- resty.lock keys live in Kong's bundled `kong_locks` shared dict; prefix them
-- so they can't collide with other users of that dict.
local LOCK_PREFIX = "the-middleman:"

local kong = kong
local ngx = ngx
local error = error
local dasherize = utils.dasherize

local CACHE_STATUS_HEADER = "X-Middleman-Cache-Status"
local CACHE_KEY_HEADER = "X-Middleman-Cache-Key"

-- cjson decodes a JSON `null` to this sentinel (a userdata), which is truthy in
-- Lua, so it must be checked explicitly before injecting it as a header.
local JSON_NULL = json.null

-- A SHA-256 hex digest. Resists the collision attacks MD5 is vulnerable to when
-- the cache key derives from client-controlled input (e.g. a header value).
local function hash(value)
  local digest = sha256:new()
  digest:update(value)
  return to_hex(digest:final())
end

-- Case-insensitive lookup over a resty.http response-headers table.
local function get_header_ci(headers, name)
  if not headers then return nil end
  name = string.lower(name)
  for k, v in pairs(headers) do
    if string.lower(k) == name then
      return v
    end
  end
  return nil
end

-- Minimal RFC7234 parse for the Cache-Control directives we honour.
local EMPTY_CACHE_CONTROL = { no_store = false, no_cache = false }
local function parse_cache_control(header)
  if not header then
    return EMPTY_CACHE_CONTROL
  end
  if type(header) == "table" then
    header = table.concat(header, ",")
  end
  local cc = { no_store = false, no_cache = false, max_age = nil }
  for directive in header:gmatch("[^,]+") do
    directive = string.lower((directive:gsub("%s", "")))
    if directive == "no-store" then
      cc.no_store = true
    elseif directive == "no-cache" then
      cc.no_cache = true
    else
      local age = directive:match("^max%-age=(%d+)$")
      if age then
        cc.max_age = tonumber(age)
      end
    end
  end
  return cc
end

-- True when a cached entry is still within its freshness window. Entries with no
-- deadline (legacy) are treated as fresh; the backend expires them anyway.
local function is_fresh(value)
  if not value.fresh_until then
    return true
  end
  return ngx.now() <= value.fresh_until
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

-- Middle-service response headers that must NOT be replayed verbatim onto the
-- client response: they describe the middle-service's own framing/connection
-- and would corrupt the body Kong actually sends.
local UNSAFE_REPLAY_HEADERS = {
  ["content-length"] = true,
  ["transfer-encoding"] = true,
  ["connection"] = true,
  ["keep-alive"] = true,
}

local function safe_replay_headers(headers)
  if not headers then
    return nil
  end
  local out = {}
  for name, value in pairs(headers) do
    if not UNSAFE_REPLAY_HEADERS[string.lower(name)] then
      out[name] = value
    end
  end
  return out
end

-- Set the cache-status + cache-key headers on the upstream request and, when
-- configured, mirror them onto the downstream response.
local function set_cache_status(conf, cache_key, status)
  kong.service.request.set_header(CACHE_STATUS_HEADER, status)
  kong.service.request.set_header(CACHE_KEY_HEADER, cache_key)

  if conf.streamdown_injected_headers then
    kong.response.set_header(CACHE_STATUS_HEADER, status)
    kong.response.set_header(CACHE_KEY_HEADER, cache_key)
  end
end

-- Build the (unhashed) cache key based on the configured strategy.
local function build_cache_key(conf)
  local cache_based_on = conf.cache_based_on

  if cache_based_on == "host-path" then
    return kong.request.get_host() .. kong.request.get_path()

  elseif cache_based_on == "host-path-query" then
    return kong.request.get_host() .. kong.request.get_path_with_query()

  elseif cache_based_on == "header" then
    -- Use the first present header from the prioritized, comma-separated list.
    -- Whitespace around each name is trimmed so "h1, h2" works like "h1,h2".
    for header_name in (conf.cache_based_on_headers .. ","):gmatch("%s*(.-)%s*,") do
      local header_value = kong.request.get_header(header_name)
      if header_value then
        return header_value
      end
    end
    -- No configured header present: fall back to the host so we still cache.
    return kong.request.get_host()
  end

  -- default: "host"
  return kong.request.get_host()
end

-- True when the current request path is one of the configured
-- cache-invalidation paths.
local function should_invalidate_cache(conf)
  local paths = conf.cache_invalidate_when_streamup_path
  if not paths then
    return false
  end

  local request_path = kong.request.get_path()
  for _, path in ipairs(paths) do
    if request_path == path then
      return true
    end
  end

  return false
end

local function external_request(conf, version)
  local httpc = http.new()
  httpc:set_timeouts(conf.connect_timeout, conf.send_timeout, conf.read_timeout)

  local body = {}

  if conf.forward_path then
    body["path"] = kong.request.get_path()
  end

  if conf.forward_query then
    body["query"] = kong.request.get_query()
  end

  if conf.forward_headers then
    local headers = kong.request.get_headers()
    local allow = conf.forward_headers_allow
    if allow and #allow > 0 then
      -- get_headers() keys are already lower-cased.
      local filtered = {}
      for _, name in ipairs(allow) do
        local lname = string.lower(name)
        if headers[lname] ~= nil then
          filtered[lname] = headers[lname]
        end
      end
      headers = filtered
    end
    body["headers"] = headers
  end

  if conf.forward_body then
    body["body"] = kong.request.get_body()
  end

  local response, err = httpc:request_uri(conf.url, {
    method = conf.method,
    path = conf.path,
    body = json.encode(body),
    headers = {
      ["User-Agent"] = "the-middleman/" .. version,
      ["Content-Type"] = "application/json",
      ["X-Forwarded-Host"] = kong.request.get_host(),
      ["X-Forwarded-Path"] = kong.request.get_path(),
      ["X-Forwarded-Query"] = kong.request.get_query(),
    }
  })

  if err then
    return nil, err
  end

  return { status = response.status, body = response.body, headers = response.headers }
end

local function inject_body_response_into_header(conf, response)
  if not conf.inject_body_response_into_header then
    return
  end

  local ok, decoded_body = pcall(json.decode, response.body)
  if not ok or type(decoded_body) ~= "table" then
    kong.log.err("the-middleman: middle-request response body is not valid JSON; skipping header injection")
    return
  end

  for key, value in pairs(decoded_body) do
    -- Skip only absent values (Lua nil / JSON null). `false` and `0` ARE
    -- injected so the downstream can tell them apart from "missing".
    if value ~= nil and value ~= JSON_NULL then
      local header_name = dasherize(conf.injected_header_prefix .. key)
      local header_value = value

      if type(header_value) == "table" then
        header_value = json.encode(header_value)
      elseif type(header_value) == "boolean" then
        header_value = tostring(header_value)
      end

      kong.service.request.set_header(header_name, header_value)

      -- stream down the headers
      if conf.streamdown_injected_headers then
        kong.response.set_header(header_name, header_value)
      end
    end
  end
end

-- Copy the configured middle-service RESPONSE headers onto the upstream request.
-- Auth services often return identity/credentials as headers, not a JSON body.
local function forward_response_headers(conf, response)
  local names = conf.forward_response_headers
  if not names or #names == 0 then
    return
  end
  for _, name in ipairs(names) do
    local value = get_header_ci(response.headers, name)
    if value ~= nil then
      kong.service.request.set_header(name, value)
      if conf.streamdown_injected_headers then
        kong.response.set_header(name, value)
      end
    end
  end
end

-- Persist a fresh response, honouring the cacheable-status list and (optionally)
-- Cache-Control. `fresh_until` marks the freshness window; the backend TTL can
-- be longer (cache_storage_ttl) so a stale copy survives for serve-on-error.
local function store_response(conf, policy, cache_key, response, req_no_store)
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

  response.fresh_until = ngx.now() + fresh_ttl
  policy.set(conf, cache_key, response, { ttl = store_ttl })
end

-- Resolve the middle-request response, going through the cache when enabled.
local function resolve_response(conf, version)
  if not conf.cache_enabled then
    return external_request(conf, version)
  end

  -- Namespace the key by the middle-service endpoint so two plugin instances
  -- pointing at different middle-services never share a cache entry (which would
  -- leak one route's response into another). The same endpoint still shares a
  -- key, which is what cross-route invalidation relies on.
  local cache_key = hash(conf.url .. "|" .. (conf.path or "") .. "|" .. build_cache_key(conf))
  local invalidate = should_invalidate_cache(conf)
  local policy = policies[conf.cache_policy]

  local req_cc = conf.cache_control
    and parse_cache_control(kong.request.get_header("cache-control"))
    or EMPTY_CACHE_CONTROL
  local skip_read = req_cc.no_cache or req_cc.no_store

  -- 1) Serve a fresh cache entry, unless the client forbids reading the cache.
  local cached, probe_err
  if not skip_read then
    cached, probe_err = policy.probe(conf, cache_key)
  end
  if cached and is_fresh(cached) then
    set_cache_status(conf, cache_key, "HIT")
    if invalidate then policy.invalidate(conf, cache_key) end
    return cached
  end

  -- 2) Cache backend unreachable on the read: fail open, fetch once, no re-touch
  -- (a second connection would just time out too, doubling outage latency).
  if probe_err then
    set_cache_status(conf, cache_key, "MISS")
    return external_request(conf, version)
  end

  -- 3) We must fetch. Serialize with a per-node lock to avoid a stampede; keep a
  -- stale `cached` entry (within the storage window) as a fallback on failure.
  local lock = resty_lock:new("kong_locks")
  local locked = lock and lock:lock(LOCK_PREFIX .. cache_key)

  if locked and not skip_read then
    -- A peer may have refreshed the entry while we waited for the lock.
    local refreshed = policy.probe(conf, cache_key)
    if refreshed and is_fresh(refreshed) then
      lock:unlock()
      set_cache_status(conf, cache_key, "HIT")
      if invalidate then policy.invalidate(conf, cache_key) end
      return refreshed
    end
    if refreshed then
      cached = refreshed
    end
  end

  local response, err = external_request(conf, version)

  if err then
    if locked then lock:unlock() end
    -- Serve a stale copy if we have one (resilience), else propagate the error.
    if cached then
      set_cache_status(conf, cache_key, "STALE")
      if invalidate then policy.invalidate(conf, cache_key) end
      return cached
    end
    return nil, err
  end

  local status = (skip_read and "BYPASS") or (cached and "REFRESH") or "MISS"
  set_cache_status(conf, cache_key, status)

  if not invalidate then
    store_response(conf, policy, cache_key, response, req_cc.no_store)
  end

  if locked then
    lock:unlock()
  end
  if invalidate then
    -- Delegate to the configured policy; the local policy already wraps
    -- kong.cache:invalidate, the redis policy deletes the key from Redis.
    policy.invalidate(conf, cache_key)
  end

  return response
end

function _M.execute(conf, version)
  local response, err = resolve_response(conf, version)

  -- unexpected error
  if err then
    return error(err)
  end

  -- http error: replay the middle-request status/body/headers to the client
  if response.status >= 400 then
    return kong.response.exit(response.status, response.body, safe_replay_headers(response.headers))
  end

  -- inject the middle-request response (body keys + configured response headers)
  -- into the upstream request
  inject_body_response_into_header(conf, response)
  forward_response_headers(conf, response)
end

return _M

local policies = require "kong.plugins.the-middleman.policies"
local resolver = require "kong.plugins.the-middleman.resolver"
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
local get_header_ci = utils.get_header_ci
local parse_cache_control = utils.parse_cache_control
local EMPTY_CACHE_CONTROL = utils.EMPTY_CACHE_CONTROL

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

-- The single home for the "inject + maybe streamdown" rule: set a header on the
-- upstream request and, when streamdown_injected_headers is on, mirror it onto
-- the client response.
local function set_injected_header(conf, name, value)
  kong.service.request.set_header(name, value)
  if conf.streamdown_injected_headers then
    kong.response.set_header(name, value)
  end
end

-- Set the cache-status + cache-key headers on the upstream request and, when
-- configured, mirror them onto the downstream response.
local function set_cache_status(conf, cache_key, status)
  set_injected_header(conf, CACHE_STATUS_HEADER, status)
  set_injected_header(conf, CACHE_KEY_HEADER, cache_key)
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

-- Per-node stampede lock factory injected into the resolver. Hides resty.lock,
-- the `kong_locks` dict and the key prefix; returns an unlock function on
-- success or nil to fail open (lock construction or acquisition failed).
local function make_lock(cache_key)
  local lock = resty_lock:new("kong_locks")
  local locked = lock and lock:lock(LOCK_PREFIX .. cache_key)
  if not locked then
    return nil
  end
  return function()
    lock:unlock()
  end
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

-- A JSON object decodes to a table with string keys; a JSON array decodes to one
-- with integer keys. Only an object maps to headers: an array would inject
-- meaningless numbered headers (X-1, X-2, ...), so it is skipped like a scalar.
local function is_json_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    n = n + 1
  end
  return n > 0
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

  if is_json_array(decoded_body) then
    kong.log.err("the-middleman: middle-request response body is a JSON array, not an object; skipping header injection")
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

      set_injected_header(conf, header_name, header_value)
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
      set_injected_header(conf, name, value)
    end
  end
end

-- Resolve the middle-request, through the cache when enabled, and report the
-- resulting cache-status. Returns the same (response, err) contract regardless.
local function resolve(conf, version)
  if not conf.cache_enabled then
    return external_request(conf, version)
  end

  -- Namespace the key by the middle-service endpoint so two plugin instances
  -- pointing at different middle-services never share a cache entry (which would
  -- leak one route's response into another). The same endpoint still shares a
  -- key, which is what cross-route invalidation relies on.
  local cache_key = hash(conf.url .. "|" .. (conf.path or "") .. "|" .. build_cache_key(conf))

  local req_cc = conf.cache_control
    and parse_cache_control(kong.request.get_header("cache-control"))
    or EMPTY_CACHE_CONTROL

  local request = {
    cache_key = cache_key,
    invalidate = should_invalidate_cache(conf),
    skip_read = req_cc.no_cache or req_cc.no_store,
    no_store = req_cc.no_store,
  }

  local response, status, err = resolver.resolve(conf, request, {
    policy = policies[conf.cache_policy],
    fetch = function() return external_request(conf, version) end,
    lock = make_lock,
    now = ngx.now,
  })

  if status then
    set_cache_status(conf, cache_key, status)
  end

  return response, err
end

function _M.execute(conf, version)
  local response, err = resolve(conf, version)

  -- unexpected error
  if err then
    return error(err)
  end

  -- Non-2xx: replay the middle-request status/body/headers to the client. A 3xx
  -- is the middle-service redirecting the caller (forward-auth -> login); a
  -- >= 400 is a deny. Both must be returned (preserving e.g. Location), never run
  -- through injection and proxied upstream.
  if response.status >= 300 then
    return kong.response.exit(response.status, response.body, safe_replay_headers(response.headers))
  end

  -- inject the middle-request response (body keys + configured response headers)
  -- into the upstream request
  inject_body_response_into_header(conf, response)
  forward_response_headers(conf, response)
end

return _M

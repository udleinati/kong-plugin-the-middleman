local policies = require "kong.plugins.the-middleman.policies"
local utils = require "kong.plugins.the-middleman.utils"

local _M = {}
local http = require "resty.http"
local json = require "cjson"

local kong = kong
local error = error
local md5 = ngx.md5
local dasherize = utils.dasherize

local CACHE_STATUS_HEADER = "X-Middleman-Cache-Status"

-- cjson decodes a JSON `null` to this sentinel (a userdata), which is truthy in
-- Lua, so it must be checked explicitly before injecting it as a header.
local JSON_NULL = json.null

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

-- Set the cache-status header on the upstream request and, when configured,
-- mirror it onto the downstream response.
local function set_cache_status(conf, status)
  kong.service.request.set_header(CACHE_STATUS_HEADER, status)

  if conf.streamdown_injected_headers then
    kong.response.set_header(CACHE_STATUS_HEADER, status)
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
    for header_name in (conf.cache_based_on_headers .. ","):gmatch("(.-),") do
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
    body["headers"] = kong.request.get_headers()
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

-- Resolve the middle-request response, going through the cache when enabled.
local function resolve_response(conf, version)
  if not conf.cache_enabled then
    return external_request(conf, version)
  end

  -- Namespace the key by the middle-service endpoint so two plugin instances
  -- pointing at different middle-services never share a cache entry (which would
  -- leak one route's response into another). The same endpoint still shares a
  -- key, which is what cross-route invalidation relies on.
  local cache_key = md5(conf.url .. "|" .. (conf.path or "") .. "|" .. build_cache_key(conf))
  local invalidate = should_invalidate_cache(conf)
  local policy = policies[conf.cache_policy]

  local response, err
  local value = policy.probe(conf, cache_key)

  if value then
    set_cache_status(conf, "HIT")
    response = value
  else
    set_cache_status(conf, "MISS")
    response, err = external_request(conf, version)
    if err then
      return nil, err
    end

    -- Skip persisting when we are about to invalidate this key anyway, and never
    -- cache an error response: a transient 4xx/5xx from the middle-service must
    -- not poison subsequent good requests for the whole TTL.
    if not invalidate and response.status < 400 then
      policy.set(conf, cache_key, response, { ttl = conf.cache_ttl })
    end
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

  -- inject the body response into the header
  inject_body_response_into_header(conf, response)
end

return _M

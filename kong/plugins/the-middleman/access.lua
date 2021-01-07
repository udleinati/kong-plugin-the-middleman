local _M = {}
local http = require "resty.http"
local json = require "cjson"
local kong = kong
local error = error
local str_gsub = string.gsub
local str_lower = string.lower
local md5 = ngx.md5

local function dasherize(str)
  local new_str = str_gsub(str, '(%l)(%u)', '%1-%2')
  new_str = str_gsub(new_str, '%W+', '-')
  new_str = str_lower(new_str)
  return new_str
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
    return error(err)
  end

  return { status = response.status, body = response.body }
end

local function inject_body_response_into_header(conf, response)
  if not conf.inject_body_response_into_header then
    return nil
  end

  local decoded_body = json.decode(response.body)
  for key, value in pairs(decoded_body) do
    if not value then goto continue end

    local header_name = conf.injected_header_prefix .. dasherize(key)
    local header_value = value

    if type(header_value) == "table" then
      header_value = json.encode(header_value)
    end

    kong.service.request.set_header(header_name, header_value)

    -- stream down the header
    if conf.streamdown_injected_headers then
      kong.response.add_header(header_name, header_value)
    end

    :: continue ::
  end
end

function _M.execute(conf, version)
  local response, err;

  if conf.cache_enabled then
    local cache_key = kong.request.get_header("host")

    if conf.cache_based_on == "host-path" then
      cache_key = cache_key .. kong.request.get_path()

    elseif conf.cache_based_on == "host-path-query" then
      cache_key = cache_key .. kong.request.get_path_with_query()

    elseif conf.cache_based_on == "header" then
      cache_key = kong.request.get_header(conf.cache_based_on_header) or "empty"

    end

    local cache_ttl = { ttl = conf.cache_ttl }
    response, err = kong.cache:get(md5(cache_key), cache_ttl, external_request, conf, version)

  else
    response, err = external_request(conf, version)
  end

  -- unexpected error
  if err then
    return error(err)
  end

  -- inject the body response into the header
  inject_body_response_into_header(conf, response)

end

return _M

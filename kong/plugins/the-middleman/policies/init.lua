local reports = require "kong.reports"
local redis = require "resty.redis"
local cjson = require "cjson"
local fmt = string.format

local redis_prefix = 'kong:the-middleman:'

local function is_present(str)
  return str ~= nil and str ~= "" and str ~= ngx.null
end

-- Build the namespaced Redis key, optionally scoped by username.
local function redis_key(conf, key)
  local username_scope = is_present(conf.redis_username)
    and (conf.redis_username .. '::')
    or ''
  return username_scope .. redis_prefix .. key
end

-- Guard helper shared by every policy entry point.
local function assert_string_key(key)
  if type(key) ~= "string" then
    error("key must be a string", 3)
  end
end

local function release_redis_connection(red)
  local ok, err = red:set_keepalive(10000, 100)
  if not ok then
    kong.log.err("failed to set Redis keepalive: ", err)
  end
end

local function get_redis_connection(conf)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)

  -- `sock_opts` is intentionally a per-call local: a module-level table would
  -- be shared across concurrent requests and could be clobbered when different
  -- routes use different Redis configs.
  local sock_opts = {
    ssl = conf.redis_ssl,
    ssl_verify = conf.redis_ssl_verify,
    server_name = conf.redis_server_name,
  }

  -- use a special pool name only if redis_database is set to non-zero
  -- otherwise use the default pool name host:port
  if conf.redis_database ~= 0 then
    sock_opts.pool = fmt("%s:%d;%d",
                         conf.redis_host,
                         conf.redis_port,
                         conf.redis_database)
  end

  local ok, err = red:connect(conf.redis_host, conf.redis_port, sock_opts)
  if not ok then
    kong.log.err("failed to connect to Redis: ", err)
    return nil, err
  end

  local times, err = red:get_reused_times()
  if err then
    kong.log.err("failed to get connect reused times: ", err)
    return nil, err
  end

  if times == 0 then
    if is_present(conf.redis_password) then
      local ok, err
      if is_present(conf.redis_username) then
        ok, err = red:auth(conf.redis_username, conf.redis_password)
      else
        ok, err = red:auth(conf.redis_password)
      end
      if not ok then
        kong.log.err("failed to auth Redis: ", err)
        return nil, err
      end
    end

    if conf.redis_database ~= 0 then
      -- Only call select first time, since we know the connection is shared
      -- between instances that use the same redis database

      local ok, err = red:select(conf.redis_database)
      if not ok then
        kong.log.err("failed to change Redis database: ", err)
        return nil, err
      end
    end
  end

  return red
end

return {
  ["local"] = {
    set = function(conf, key, value, opts)
      assert_string_key(key)

      local cacheCb = function(cached)
        return cached
      end

      local response, err = kong.cache:get(key, opts, cacheCb, value)

      if err then
        return nil, err
      end

      return response
    end,
    probe = function(conf, key)
      assert_string_key(key)

      local _, err, response = kong.cache:probe(key)

      if err then
        return nil, err
      end

      return response
    end,
    invalidate = function(conf, key)
      assert_string_key(key)

      local _, err = kong.cache:invalidate(key)

      if err then
        return nil, err
      end

      return true
    end
  },
  ["redis"] = {
    set = function(conf, key, value, opts)
      assert_string_key(key)

      local red, err = get_redis_connection(conf)
      if not red then
        return nil, err
      end

      reports.retrieve_redis_version(red)

      -- the usage of redis command incr instead of get is to avoid race conditions in concurrent calls
      local response, err = red:eval([[
        local cache_key, cache_value, expiration = KEYS[1], ARGV[1], ARGV[2]
        redis.call("set", cache_key, cache_value)
        redis.call("expire", cache_key, expiration)
        return true
      ]], 1, redis_key(conf, key), cjson.encode(value), opts.ttl)

      if err then
        return nil, err
      end

      release_redis_connection(red)

      return response
    end,
    probe = function(conf, key)
      assert_string_key(key)

      local red, err = get_redis_connection(conf)
      if not red then
        return nil, err
      end

      reports.retrieve_redis_version(red)

      local response, err = red:get(redis_key(conf, key))
      if err then
        return nil, err
      end

      release_redis_connection(red)

      if response == ngx.null then
        return nil
      else
        return cjson.decode(response)
      end
    end,
    invalidate = function(conf, key)
      assert_string_key(key)

      local red, err = get_redis_connection(conf)
      if not red then
        return nil, err
      end

      reports.retrieve_redis_version(red)

      local _, err = red:del(redis_key(conf, key))
      if err then
        return nil, err
      end

      release_redis_connection(red)

      return true
    end
  }
}

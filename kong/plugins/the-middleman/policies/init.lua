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
  local username_scope = is_present(conf.redis.username)
    and (conf.redis.username .. '::')
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
  -- `conf.redis` is the shared kong.tools.redis config record (host, port,
  -- ssl, timeout, ...). It is always present when this policy runs because the
  -- schema requires config.redis.host when cache_policy = "redis".
  local redis_conf = conf.redis

  local red = redis:new()
  red:set_timeout(redis_conf.timeout)

  -- `sock_opts` is intentionally a per-call local: a module-level table would
  -- be shared across concurrent requests and could be clobbered when different
  -- routes use different Redis configs.
  local sock_opts = {
    ssl = redis_conf.ssl,
    ssl_verify = redis_conf.ssl_verify,
    server_name = redis_conf.server_name,
  }

  -- use a special pool name only if redis database is set to non-zero
  -- otherwise use the default pool name host:port
  if redis_conf.database ~= 0 then
    sock_opts.pool = fmt("%s:%d;%d",
                         redis_conf.host,
                         redis_conf.port,
                         redis_conf.database)
  end

  local ok, err = red:connect(redis_conf.host, redis_conf.port, sock_opts)
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
    if is_present(redis_conf.password) then
      local ok, err
      if is_present(redis_conf.username) then
        ok, err = red:auth(redis_conf.username, redis_conf.password)
      else
        ok, err = red:auth(redis_conf.password)
      end
      if not ok then
        kong.log.err("failed to auth Redis: ", err)
        return nil, err
      end
    end

    if redis_conf.database ~= 0 then
      -- Only call select first time, since we know the connection is shared
      -- between instances that use the same redis database

      local ok, err = red:select(redis_conf.database)
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

      -- Store the value and its TTL atomically in a single round-trip
      -- (SET key value EX ttl), avoiding a separate EXPIRE call.
      local response, err = red:set(redis_key(conf, key), cjson.encode(value), "EX", opts.ttl)

      if err then
        -- The connection state is unknown after an error; close it rather than
        -- returning a possibly-broken socket to the keepalive pool.
        red:close()
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
        red:close()
        return nil, err
      end

      release_redis_connection(red)

      if response == ngx.null then
        return nil
      end

      -- A corrupt / non-JSON cached value must not crash the request; treat it
      -- as a miss so the middle-service is re-queried (and the bad entry
      -- overwritten).
      local ok, decoded = pcall(cjson.decode, response)
      if not ok then
        kong.log.err("the-middleman: failed to decode cached value, treating as miss: ", decoded)
        return nil
      end

      return decoded
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
        red:close()
        return nil, err
      end

      release_redis_connection(red)

      return true
    end
  }
}

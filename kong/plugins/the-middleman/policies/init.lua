local reports = require "kong.reports"
local redis = require "resty.redis"
local cjson = require "cjson"

local redis_prefix = 'kong:themiddleman:'

local function is_present(str)
  return str and str ~= "" and str ~= null
end

local sock_opts = {}

local function get_redis_connection(conf)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout)

  sock_opts.ssl = conf.redis_ssl
  sock_opts.ssl_verify = conf.redis_ssl_verify
  sock_opts.server_name = conf.redis_server_name

  -- use a special pool name only if redis_database is set to non-zero
  -- otherwise use the default pool name host:port
  if conf.redis_database ~= 0 then
    sock_opts.pool = fmt( "%s:%d;%d",
                          conf.redis_host,
                          conf.redis_port,
                          conf.redis_database)
  end

  local ok, err = red:connect(conf.redis_host, conf.redis_port,
                              sock_opts)
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
        ok, err = kong.vault.try(function(cfg)
          return red:auth(cfg.redis_username, cfg.redis_password)
        end, conf)
      else
        ok, err = kong.vault.try(function(cfg)
          return red:auth(cfg.redis_password)
        end, conf)
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
      if type(key) ~= "string" then
          error("key must be a string", 2)
      end

      local cacheCb = function(_value)
        return _value;
      end

      local response, err = kong.cache:get(key, opts, cacheCb, value)

      if err then
        return nil, err
      end

      return response
    end,
    probe = function(conf, key)
      if type(key) ~= "string" then
          error("key must be a string", 2)
      end

      local ttl, err, response = kong.cache:probe(key)

      if err then
        return nil, err
      end

      return response
    end,
    invalidate = function(conf, key)
      if type(key) ~= "string" then
          error("key must be a string", 2)
      end

      local ok, err = kong.cache:invalidate(key)

      if err then
        return nil, err
      end

      return true
    end
  },
  ["redis"] = {
    set = function(conf, key, value, opts)
      if type(key) ~= "string" then
          error("key must be a string", 2)
      end

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
      ]], 1, redis_prefix .. key, cjson.encode(value), opts.ttl)

      if err then
        return nil, err
      end

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
      end

      return response
    end,
    probe = function(conf, key)
      if type(key) ~= "string" then
          error("key must be a string", 2)
      end

      local red, err = get_redis_connection(conf)
      if not red then
        return nil, err
      end

      reports.retrieve_redis_version(red)

      local response, err = red:get(redis_prefix .. key)
      if err then
        return nil, err
      end

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
      end

      if response == ngx.null then
        return nil
      else
        return cjson.decode(response)
      end
    end,
    invalidate = function(conf, key)
      if type(key) ~= "string" then
          error("key must be a string", 2)
      end

      local red, err = get_redis_connection(conf)
      if not red then
        return nil, err
      end

      reports.retrieve_redis_version(red)

      local response, err = red:del(redis_prefix .. key)
      if err then
        return nil, err
      end

      local ok, err = red:set_keepalive(10000, 100)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
      end

      return true
    end
  }
}

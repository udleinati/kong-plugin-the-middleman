local helpers = require "spec.helpers"
local redis = require "resty.redis"

local PLUGIN_NAME = "the-middleman"
local REDIS_HOST = helpers.redis_host
local REDIS_PORT = helpers.redis_port
local REDIS_DATABASE = 0

-- Same JSON document the (mocked) middle-service replies with in 02-access_spec.
local MIDDLE_BODY = '{"tenantId":"123","role":"admin"}'

-- Mirror the namespacing done in policies/init.lua so we can assert on the
-- exact key the plugin writes.
local function cache_key(host)
  return "kong:the-middleman:" .. ngx.md5(host)
end

local function redis_connect()
  local red = redis:new()
  red:set_timeout(2000)
  assert(red:connect(REDIS_HOST, REDIS_PORT))
  assert(red:select(REDIS_DATABASE))
  return red
end

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": (redis cache) [#" .. strategy .. "]", function()
    local proxy_client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "routes", "services", "plugins" }, { PLUGIN_NAME })

      -- The middle-service is faked with the bundled request-termination plugin,
      -- reached by looping back through Kong's own proxy port.
      local middle_service = bp.services:insert({
        name = "redis-middle-service",
        url = "http://127.0.0.1:1", -- never reached; request-termination short-circuits
      })
      local middle_ok_route = bp.routes:insert({
        service = middle_service,
        paths = { "/__redis_middle_ok" },
      })
      bp.plugins:insert({
        name = "request-termination",
        route = middle_ok_route,
        config = {
          status_code = 200,
          content_type = "application/json",
          body = MIDDLE_BODY,
        },
      })

      local middle_url = "http://" .. helpers.get_proxy_ip(false) .. ":" .. helpers.get_proxy_port(false)

      -- Protected service: Kong's built-in mock upstream echoing the request.
      local echo_service = bp.services:insert({
        name = "redis-echo-service",
        url = "http://" .. helpers.mock_upstream_host .. ":" .. helpers.mock_upstream_port .. "/request",
      })

      -- Cached route backed by the redis policy.
      local cache_route = bp.routes:insert({
        service = echo_service,
        paths = { "/redis-cached" },
      })
      bp.plugins:insert({
        name = PLUGIN_NAME,
        route = cache_route,
        config = {
          url = middle_url,
          path = "/__redis_middle_ok",
          method = "POST",
          cache_enabled = true,
          cache_policy = "redis",
          cache_based_on = "host",
          cache_ttl = 60,
          redis = {
            host = REDIS_HOST,
            port = REDIS_PORT,
            database = REDIS_DATABASE,
          },
        },
      })

      -- Same redis cache, but this route invalidates the key when hit.
      local invalidate_route = bp.routes:insert({
        service = echo_service,
        paths = { "/redis-invalidate" },
      })
      bp.plugins:insert({
        name = PLUGIN_NAME,
        route = invalidate_route,
        config = {
          url = middle_url,
          path = "/__redis_middle_ok",
          method = "POST",
          cache_enabled = true,
          cache_policy = "redis",
          cache_based_on = "host",
          cache_ttl = 60,
          cache_invalidate_when_streamup_path = { "/redis-invalidate" },
          redis = {
            host = REDIS_HOST,
            port = REDIS_PORT,
            database = REDIS_DATABASE,
          },
        },
      })

      assert(helpers.start_kong({
        database = strategy,
        plugins = "bundled," .. PLUGIN_NAME,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      -- Start each test from a clean Redis so the first request is always a MISS.
      local red = redis_connect()
      assert(red:flushall())
      red:close()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then proxy_client:close() end
    end)

    it("reports MISS then HIT and injects the cached headers", function()
      local res1 = proxy_client:get("/redis-cached", { headers = { host = "rc1.test" } })
      assert.response(res1).has.status(200)
      local json1 = assert.response(res1).has.jsonbody()
      assert.equal("MISS", json1.headers["x-middleman-cache-status"])
      assert.equal("admin", json1.headers["x-role"])
      proxy_client:close()

      proxy_client = helpers.proxy_client()
      local res2 = proxy_client:get("/redis-cached", { headers = { host = "rc1.test" } })
      assert.response(res2).has.status(200)
      local json2 = assert.response(res2).has.jsonbody()
      assert.equal("HIT", json2.headers["x-middleman-cache-status"])
      assert.equal("admin", json2.headers["x-role"])
    end)

    it("persists the namespaced key in Redis with a TTL", function()
      local res = proxy_client:get("/redis-cached", { headers = { host = "rc2.test" } })
      assert.response(res).has.status(200)

      local red = redis_connect()
      local key = cache_key("rc2.test")

      local value = red:get(key)
      assert.not_equal(ngx.null, value, "the redis policy should have stored the key")

      local ttl = red:ttl(key)
      assert.is_true(ttl > 0 and ttl <= 60, "the key should carry the configured ttl")
      red:close()
    end)

    it("deletes the key from Redis on an invalidation path", function()
      -- Populate the key (same host => same host-based cache key).
      assert.response(
        proxy_client:get("/redis-cached", { headers = { host = "rc3.test" } })
      ).has.status(200)
      proxy_client:close()

      local red = redis_connect()
      local key = cache_key("rc3.test")
      assert.not_equal(ngx.null, red:get(key))

      -- Hitting the invalidation route must remove it.
      proxy_client = helpers.proxy_client()
      assert.response(
        proxy_client:get("/redis-invalidate", { headers = { host = "rc3.test" } })
      ).has.status(200)

      assert.equal(ngx.null, red:get(key), "the key should have been deleted from redis")
      red:close()
    end)
  end)
end

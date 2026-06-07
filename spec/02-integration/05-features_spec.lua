-- Integration coverage for the cache feature additions (configurable cacheable
-- response codes, and the X-Middleman-Cache-Key header) against a real Kong.
-- Setup mirrors 03-redis_spec: the middle-service is faked with request-termination
-- and the protected upstream is the mock echo endpoint.
local helpers = require "spec.helpers"
local redis = require "resty.redis"

local PLUGIN_NAME = "the-middleman"
local REDIS_HOST = helpers.redis_host
local REDIS_PORT = helpers.redis_port
local REDIS_DATABASE = 0

local MIDDLE_BODY = '{"role":"admin"}'

local function redis_connect()
  local red = redis:new()
  red:set_timeout(2000)
  assert(red:connect(REDIS_HOST, REDIS_PORT))
  assert(red:select(REDIS_DATABASE))
  return red
end

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": (cache features) [#" .. strategy .. "]", function()
    local proxy_client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "routes", "services", "plugins" }, { PLUGIN_NAME })

      local middle = bp.services:insert({ name = "feat-middle", url = "http://127.0.0.1:1" })
      local middle_route = bp.routes:insert({ service = middle, paths = { "/__feat_ok" } })
      bp.plugins:insert({
        name = "request-termination",
        route = middle_route,
        config = { status_code = 200, content_type = "application/json", body = MIDDLE_BODY },
      })

      local middle_url = "http://" .. helpers.get_proxy_ip(false) .. ":" .. helpers.get_proxy_port(false)
      local echo = bp.services:insert({
        name = "feat-echo",
        url = "http://" .. helpers.mock_upstream_host .. ":" .. helpers.mock_upstream_port .. "/request",
      })

      -- The middle replies 200, but only 201 is cacheable here -> never cached.
      local uncacheable = bp.routes:insert({ service = echo, paths = { "/feat-uncacheable" } })
      bp.plugins:insert({
        name = PLUGIN_NAME,
        route = uncacheable,
        config = {
          url = middle_url, path = "/__feat_ok", method = "POST",
          cache_enabled = true, cache_policy = "redis", cache_based_on = "host", cache_ttl = 60,
          cache_response_codes = { 201 },
          redis = { host = REDIS_HOST, port = REDIS_PORT, database = REDIS_DATABASE },
        },
      })

      -- A normally-cacheable route used to assert the X-Cache-Key header.
      local keyed = bp.routes:insert({ service = echo, paths = { "/feat-key" } })
      bp.plugins:insert({
        name = PLUGIN_NAME,
        route = keyed,
        config = {
          url = middle_url, path = "/__feat_ok", method = "POST",
          cache_enabled = true, cache_policy = "redis", cache_based_on = "host", cache_ttl = 60,
          redis = { host = REDIS_HOST, port = REDIS_PORT, database = REDIS_DATABASE },
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
      local red = redis_connect()
      assert(red:flushall())
      red:close()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then proxy_client:close() end
    end)

    it("does not cache a response whose status is not in cache_response_codes", function()
      -- The middle replies 200, but only 201 is cacheable, so every request misses.
      local res1 = proxy_client:get("/feat-uncacheable", { headers = { host = "fc1.test" } })
      assert.equal("MISS", (assert.response(res1).has.jsonbody()).headers["x-middleman-cache-status"])
      proxy_client:close()

      proxy_client = helpers.proxy_client()
      local res2 = proxy_client:get("/feat-uncacheable", { headers = { host = "fc1.test" } })
      assert.equal("MISS", (assert.response(res2).has.jsonbody()).headers["x-middleman-cache-status"],
        "200 is not in cache_response_codes, so it must never be cached")

      local red = redis_connect()
      assert.equal(0, tonumber(red:dbsize()), "nothing should have been stored")
      red:close()
    end)

    it("exposes the SHA-256 cache key in X-Middleman-Cache-Key", function()
      local res = proxy_client:get("/feat-key", { headers = { host = "fk1.test" } })
      local body = assert.response(res).has.jsonbody()
      local key = body.headers["x-middleman-cache-key"]
      assert.is_string(key)
      assert.equal(64, #key, "a SHA-256 hex digest is 64 chars")
    end)

    it("reports MISS then HIT for a cacheable status", function()
      local res1 = proxy_client:get("/feat-key", { headers = { host = "fk2.test" } })
      assert.equal("MISS", (assert.response(res1).has.jsonbody()).headers["x-middleman-cache-status"])
      proxy_client:close()

      proxy_client = helpers.proxy_client()
      local res2 = proxy_client:get("/feat-key", { headers = { host = "fk2.test" } })
      assert.equal("HIT", (assert.response(res2).has.jsonbody()).headers["x-middleman-cache-status"])
    end)
  end)
end

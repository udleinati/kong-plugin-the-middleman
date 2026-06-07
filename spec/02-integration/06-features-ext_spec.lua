-- Behavioural integration coverage for the feature gaps that the unit tests
-- already check: forward_response_headers, Cache-Control (request + response),
-- and serve-stale. The middle-service is faked with request-termination (status
-- + body) plus response-transformer (to attach custom RESPONSE headers, which
-- request-termination alone cannot do). Serve-stale is driven by injecting a
-- stale entry straight into Redis and pointing the plugin at a dead URL.
local helpers = require "spec.helpers"
local redis = require "resty.redis"
local sha256 = require "resty.sha256"
local to_hex = require("resty.string").to_hex

local PLUGIN_NAME = "the-middleman"
local REDIS_HOST = helpers.redis_host
local REDIS_PORT = helpers.redis_port

local MIDDLE_BODY = '{"role":"admin"}'

local function redis_connect(db)
  local red = redis:new()
  red:set_timeout(2000)
  assert(red:connect(REDIS_HOST, REDIS_PORT))
  assert(red:select(db or 0))
  return red
end

local function cache_key(url, path, host)
  local digest = sha256:new()
  digest:update(url .. "|" .. path .. "|" .. host)
  return "kong:the-middleman:" .. to_hex(digest:final())
end

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": (forwarding & cache-control) [#" .. strategy .. "]", function()
    local proxy_client
    local MIDDLE_URL

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "routes", "services", "plugins" }, { PLUGIN_NAME })

      MIDDLE_URL = "http://" .. helpers.get_proxy_ip(false) .. ":" .. helpers.get_proxy_port(false)

      -- Middle-service: request-termination (status+body) + response-transformer
      -- (custom response header), one loopback route per header variant.
      local middle = bp.services:insert({ name = "ext-middle", url = "http://127.0.0.1:1" })

      local function middle_mock(path, add_header)
        local route = bp.routes:insert({ service = middle, paths = { path } })
        bp.plugins:insert({
          name = "request-termination",
          route = route,
          config = { status_code = 200, content_type = "application/json", body = MIDDLE_BODY },
        })
        bp.plugins:insert({
          name = "response-transformer",
          route = route,
          config = { add = { headers = { add_header } } },
        })
      end

      middle_mock("/__m_hdr", "X-Auth-User:alice")
      middle_mock("/__m_maxage", "Cache-Control:max-age=42")
      middle_mock("/__m_nostore", "Cache-Control:no-store")

      local echo = bp.services:insert({
        name = "ext-echo",
        url = "http://" .. helpers.mock_upstream_host .. ":" .. helpers.mock_upstream_port .. "/request",
      })

      local function protected(path, conf)
        local route = bp.routes:insert({ service = echo, paths = { path } })
        bp.plugins:insert({ name = PLUGIN_NAME, route = route, config = conf })
      end

      -- forward_response_headers (no cache needed)
      protected("/cc-hdr", {
        url = MIDDLE_URL, path = "/__m_hdr", method = "POST",
        forward_response_headers = { "x-auth-user" },
      })

      -- response Cache-Control: max-age=42 -> TTL honoured
      protected("/cc-maxage", {
        url = MIDDLE_URL, path = "/__m_maxage", method = "POST",
        cache_enabled = true, cache_policy = "redis", cache_based_on = "host", cache_ttl = 60,
        cache_control = true,
        redis = { host = REDIS_HOST, port = REDIS_PORT, database = 0 },
      })

      -- response Cache-Control: no-store -> never cached
      protected("/cc-nostore", {
        url = MIDDLE_URL, path = "/__m_nostore", method = "POST",
        cache_enabled = true, cache_policy = "redis", cache_based_on = "host", cache_ttl = 60,
        cache_control = true,
        redis = { host = REDIS_HOST, port = REDIS_PORT, database = 0 },
      })

      -- request Cache-Control: no-store -> BYPASS, nothing stored
      protected("/cc-req-nostore", {
        url = MIDDLE_URL, path = "/__m_hdr", method = "POST",
        cache_enabled = true, cache_policy = "redis", cache_based_on = "host", cache_ttl = 60,
        cache_control = true,
        redis = { host = REDIS_HOST, port = REDIS_PORT, database = 1 },
      })

      -- serve-stale: dead middle URL + a stale entry injected straight into Redis
      protected("/cc-stale", {
        url = "http://127.0.0.1:1", path = "/auth", method = "POST", connect_timeout = 1000,
        cache_enabled = true, cache_policy = "redis", cache_based_on = "host", cache_ttl = 1,
        cache_storage_ttl = 600,
        redis = { host = REDIS_HOST, port = REDIS_PORT, database = 2 },
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

    it("forwards a middle-service response header onto the upstream request", function()
      local res = proxy_client:get("/cc-hdr", { headers = { host = "fh.test" } })
      local body = assert.response(res).has.jsonbody()
      assert.equal("alice", body.headers["x-auth-user"],
        "the middle-service's X-Auth-User header must reach the upstream")
    end)

    it("honours the middle-service Cache-Control max-age as the TTL", function()
      assert.response(
        proxy_client:get("/cc-maxage", { headers = { host = "ma.test" } })
      ).has.status(200)

      local red = redis_connect(0)
      local key = cache_key(MIDDLE_URL, "/__m_maxage", "ma.test")
      local ttl = red:ttl(key)
      red:close()
      assert.is_true(ttl > 0 and ttl <= 42, "max-age=42 must cap the TTL (got " .. tostring(ttl) .. ")")
    end)

    it("does not cache when the middle-service responds Cache-Control: no-store", function()
      assert.response(
        proxy_client:get("/cc-nostore", { headers = { host = "ns.test" } })
      ).has.status(200)

      local red = redis_connect(0)
      local size = tonumber(red:dbsize())
      red:close()
      assert.equal(0, size, "a no-store response must not be cached")
    end)

    it("bypasses the cache on a client Cache-Control: no-store", function()
      local res = proxy_client:get("/cc-req-nostore", {
        headers = { host = "rns.test", ["cache-control"] = "no-store" },
      })
      assert.equal("BYPASS", (assert.response(res).has.jsonbody()).headers["x-middleman-cache-status"])

      local red = redis_connect(1)
      assert.equal(0, tonumber(red:dbsize()), "no-store must not write to the cache")
      red:close()
    end)

    it("serves a stale cached entry when the middle-service is unreachable", function()
      -- Inject a stale entry (fresh_until in the past) for the exact key the
      -- plugin will look up; the middle URL is dead, so the fetch fails.
      local red = redis_connect(2)
      local key = cache_key("http://127.0.0.1:1", "/auth", "stale.test")
      assert(red:set(key, '{"status":200,"body":"{\\"role\\":\\"stale\\"}","headers":{},"fresh_until":1}'))
      red:close()

      local res = proxy_client:get("/cc-stale", { headers = { host = "stale.test" } })
      local body = assert.response(res).has.jsonbody()
      assert.equal("STALE", body.headers["x-middleman-cache-status"])
      assert.equal("stale", body.headers["x-role"], "the stale cached identity must be served")
    end)
  end)
end

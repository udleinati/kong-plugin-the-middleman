-- Regression tests that pin down bugs found while stress-testing the plugin.
-- These are written RED on purpose: every `it` below fails against the current
-- code and encodes the intended (fixed) behaviour, so they go green once the
-- corresponding bug is fixed. See each test's comment for the "why".
--
-- Setup mirrors 02-access_spec / 03-redis_spec: the middle-service is faked with
-- the bundled `request-termination` plugin (reached by looping back through
-- Kong's own proxy port), and the protected upstream is Kong's mock_upstream
-- `/request` echo endpoint, which returns the received headers as JSON.
local helpers = require "spec.helpers"
local redis = require "resty.redis"

local PLUGIN_NAME = "the-middleman"
local REDIS_HOST = helpers.redis_host
local REDIS_PORT = helpers.redis_port
local REDIS_DATABASE = 0

local function redis_connect()
  local red = redis:new()
  red:set_timeout(2000)
  assert(red:connect(REDIS_HOST, REDIS_PORT))
  assert(red:select(REDIS_DATABASE))
  return red
end

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": (known bugs) [#" .. strategy .. "]", function()
    local proxy_client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "routes", "services", "plugins" }, { PLUGIN_NAME })

      -- ---- mocked middle-service responses (request-termination) -----------
      local middle_service = bp.services:insert({
        name = "bugs-middle-service",
        url = "http://127.0.0.1:1", -- never reached; request-termination short-circuits
      })

      local function middle_mock(path, status, body)
        local route = bp.routes:insert({ service = middle_service, paths = { path } })
        bp.plugins:insert({
          name = "request-termination",
          route = route,
          config = { status_code = status, content_type = "application/json", body = body },
        })
      end

      middle_mock("/__mid_500", 503, '{"error":"mock"}')         -- Bug 1
      middle_mock("/__mid_a", 200, '{"tenantId":"AAA"}')          -- Bug 2
      middle_mock("/__mid_b", 200, '{"tenantId":"BBB"}')          -- Bug 2
      middle_mock("/__mid_null", 200, '{"value":null}')           -- Bug 3
      middle_mock("/__mid_false", 200, '{"isAdmin":false}')       -- Bug 4
      middle_mock("/__mid_302", 302, '{"go":"login"}')            -- Bug 5
      middle_mock("/__mid_array", 200, '["a","b"]')               -- Bug 6

      local middle_url = "http://" .. helpers.get_proxy_ip(false) .. ":" .. helpers.get_proxy_port(false)

      -- ---- protected upstream (mock echo) ----------------------------------
      local echo_service = bp.services:insert({
        name = "bugs-echo-service",
        url = "http://" .. helpers.mock_upstream_host .. ":" .. helpers.mock_upstream_port .. "/request",
      })

      local function protected(path, conf)
        local route = bp.routes:insert({ service = echo_service, paths = { path } })
        conf.url = middle_url
        bp.plugins:insert({ name = PLUGIN_NAME, route = route, config = conf })
      end

      -- Bug 1: error responses must not be cached.
      protected("/bug-error-cache", {
        path = "/__mid_500", method = "POST",
        cache_enabled = true, cache_policy = "redis", cache_based_on = "host", cache_ttl = 60,
        redis = { host = REDIS_HOST, port = REDIS_PORT, database = REDIS_DATABASE },
      })

      -- Bug 2: two plugin instances sharing a Redis db must not share entries.
      protected("/bug-leak-a", {
        path = "/__mid_a", method = "POST",
        cache_enabled = true, cache_policy = "redis", cache_based_on = "host", cache_ttl = 60,
        redis = { host = REDIS_HOST, port = REDIS_PORT, database = REDIS_DATABASE },
      })
      protected("/bug-leak-b", {
        path = "/__mid_b", method = "POST",
        cache_enabled = true, cache_policy = "redis", cache_based_on = "host", cache_ttl = 60,
        redis = { host = REDIS_HOST, port = REDIS_PORT, database = REDIS_DATABASE },
      })

      -- Bug 3: a JSON null in the middle response must not crash the request.
      protected("/bug-null", { path = "/__mid_null", method = "POST" })

      -- Bug 4: a boolean false must be injected, not silently dropped.
      protected("/bug-false", { path = "/__mid_false", method = "POST" })

      -- Bug 5: a 3xx from the middle-service is replayed, not proxied upstream.
      protected("/bug-redirect", { path = "/__mid_302", method = "POST" })

      -- Bug 6: a JSON array body must not inject numbered headers.
      protected("/bug-array", { path = "/__mid_array", method = "POST" })

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

    -- Bug 1 -----------------------------------------------------------------
    it("does NOT cache an error (5xx) response from the middle-service", function()
      -- Why: a transient 5xx must not be persisted, otherwise it poisons every
      -- subsequent good request for the whole cache_ttl, even after the
      -- middle-service has recovered.
      local res = proxy_client:get("/bug-error-cache", { headers = { host = "err.test" } })
      assert.response(res).has.status(503)

      -- before_each flushes Redis, so a wrongly-cached error would leave exactly
      -- one key behind. The db must stay empty.
      local red = redis_connect()
      local size = red:dbsize()
      red:close()

      assert.equal(0, tonumber(size),
        "an error response must not be stored in the cache")
    end)

    -- Bug 2 -----------------------------------------------------------------
    it("does NOT leak cached entries between distinct plugin instances", function()
      -- Why: /bug-leak-a and /bug-leak-b are different routes/plugins pointing at
      -- different middle-services. Sharing a Redis db (same host-based key) must
      -- not make one serve the other's cached identity.
      local res_a = proxy_client:get("/bug-leak-a", { headers = { host = "leak.test" } })
      assert.response(res_a).has.status(200)
      assert.equal("AAA", (assert.response(res_a).has.jsonbody()).headers["x-tenant-id"])
      proxy_client:close()

      proxy_client = helpers.proxy_client()
      local res_b = proxy_client:get("/bug-leak-b", { headers = { host = "leak.test" } })
      assert.response(res_b).has.status(200)
      local json_b = assert.response(res_b).has.jsonbody()

      assert.equal("BBB", json_b.headers["x-tenant-id"],
        "route B must see its own middle-service identity, not route A's cached one")
    end)

    -- Bug 3 -----------------------------------------------------------------
    it("does NOT 500 when the middle-service response contains a JSON null", function()
      -- Why: optional fields are commonly null; a null value must be skipped
      -- during header injection (which is on by default), not crash the request.
      local res = proxy_client:get("/bug-null", { headers = { host = "null.test" } })
      assert.response(res).has.status(200)
    end)

    -- Bug 4 -----------------------------------------------------------------
    it("injects a boolean false instead of dropping it", function()
      -- Why: `if value then` drops false but keeps 0, so a downstream service
      -- cannot tell "false" from "absent" — dangerous for auth decisions.
      local res = proxy_client:get("/bug-false", { headers = { host = "false.test" } })
      assert.response(res).has.status(200)
      local json = assert.response(res).has.jsonbody()

      assert.equal("false", json.headers["x-is-admin"],
        "a false field must be injected, not silently dropped")
    end)

    -- Bug 5 -----------------------------------------------------------------
    it("replays a 3xx redirect to the client instead of proxying upstream", function()
      -- Why: a 3xx is the middle-service redirecting the caller; proxying upstream
      -- would silently swallow the redirect. The echo upstream returns 200, so a
      -- 302 coming back proves the upstream was never reached.
      local res = proxy_client:get("/bug-redirect", { headers = { host = "redirect.test" } })
      assert.response(res).has.status(302)
    end)

    -- Bug 6 -----------------------------------------------------------------
    it("does NOT inject numbered headers from a JSON array body", function()
      -- Why: a JSON array decodes to integer keys; injecting it would yield
      -- meaningless X-1/X-2 headers. The protected upstream must receive none.
      local res = proxy_client:get("/bug-array", { headers = { host = "array.test" } })
      assert.response(res).has.status(200)
      local json = assert.response(res).has.jsonbody()
      assert.is_nil(json.headers["x-1"])
      assert.is_nil(json.headers["x-2"])
    end)
  end)
end

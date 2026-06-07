local helpers = require "spec.helpers"

local PLUGIN_NAME = "the-middleman"

-- The JSON document the (mocked) middle-service replies with. The plugin should
-- dasherize each key into a header injected onto the upstream request.
local MIDDLE_BODY = '{"tenantId":"123","role":"admin","data":{"a":1}}'

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
    local proxy_client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "routes", "services", "plugins" }, { PLUGIN_NAME })

      -- The middle-service is faked with the bundled request-termination plugin:
      -- it returns a fixed JSON body without needing a real upstream. The plugin
      -- reaches it by looping back through Kong's own proxy port.
      local middle_service = bp.services:insert({
        name = "middle-service",
        url = "http://127.0.0.1:1", -- never reached; request-termination short-circuits
      })
      local middle_ok_route = bp.routes:insert({
        service = middle_service,
        paths = { "/__middle_ok" },
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

      local middle_deny_route = bp.routes:insert({
        service = middle_service,
        paths = { "/__middle_deny" },
      })
      bp.plugins:insert({
        name = "request-termination",
        route = middle_deny_route,
        config = {
          status_code = 401,
          content_type = "application/json",
          body = '{"error":"denied"}',
        },
      })

      local middle_url = "http://" .. helpers.get_proxy_ip(false) .. ":" .. helpers.get_proxy_port(false)

      -- Protected service: Kong's built-in mock upstream, whose /request endpoint
      -- echoes the received request (headers included) back as JSON. Each route
      -- strips its own path so the upstream always sees /request.
      local echo_service = bp.services:insert({
        name = "echo-service",
        url = "http://" .. helpers.mock_upstream_host .. ":" .. helpers.mock_upstream_port .. "/request",
      })

      -- 1) happy path: inject the middle-service response into the headers
      local inject_route = bp.routes:insert({
        service = echo_service,
        paths = { "/inject" },
      })
      bp.plugins:insert({
        name = PLUGIN_NAME,
        route = inject_route,
        config = {
          url = middle_url,
          path = "/__middle_ok",
          method = "POST",
          inject_body_response_into_header = true,
          streamdown_injected_headers = true,
        },
      })

      -- 2) cached path: first call MISS, second call HIT (local policy)
      local cache_route = bp.routes:insert({
        service = echo_service,
        paths = { "/cached" },
      })
      bp.plugins:insert({
        name = PLUGIN_NAME,
        route = cache_route,
        config = {
          url = middle_url,
          path = "/__middle_ok",
          method = "POST",
          cache_enabled = true,
          cache_policy = "local",
          cache_based_on = "host",
          cache_ttl = 60,
        },
      })

      -- 3) denied path: the 4xx from the middle-service is replayed to the client
      local deny_route = bp.routes:insert({
        service = echo_service,
        paths = { "/denied" },
      })
      bp.plugins:insert({
        name = PLUGIN_NAME,
        route = deny_route,
        config = {
          url = middle_url,
          path = "/__middle_deny",
          method = "POST",
        },
      })

      assert(helpers.start_kong({
        database = strategy,
        plugins = "bundled," .. PLUGIN_NAME,
        -- Kong's own fixture; provides the mock upstream listener used above.
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then proxy_client:close() end
    end)

    it("injects dasherized headers onto the upstream request", function()
      local res = proxy_client:get("/inject", { headers = { host = "inject.test" } })
      assert.response(res).has.status(200)

      -- the mock upstream echoes the headers it received
      local json = assert.response(res).has.jsonbody()
      assert.equal("123", json.headers["x-tenant-id"])
      assert.equal("admin", json.headers["x-role"])
      assert.equal('{"a":1}', json.headers["x-data"])

      -- streamdown also mirrors them onto the client response
      assert.equal("123", res.headers["X-Tenant-Id"])
    end)

    it("reports MISS then HIT when caching is enabled", function()
      local res1 = proxy_client:get("/cached", { headers = { host = "cache.test" } })
      assert.response(res1).has.status(200)
      local json1 = assert.response(res1).has.jsonbody()
      assert.equal("MISS", json1.headers["x-middleman-cache-status"])
      -- the cached document is still injected on a MISS
      assert.equal("admin", json1.headers["x-role"])
      proxy_client:close()

      proxy_client = helpers.proxy_client()
      local res2 = proxy_client:get("/cached", { headers = { host = "cache.test" } })
      assert.response(res2).has.status(200)
      local json2 = assert.response(res2).has.jsonbody()
      assert.equal("HIT", json2.headers["x-middleman-cache-status"])
      assert.equal("admin", json2.headers["x-role"])
    end)

    it("replays a 4xx from the middle-service to the client", function()
      local res = proxy_client:get("/denied", { headers = { host = "deny.test" } })
      assert.response(res).has.status(401)
      local body = assert.response(res).has.jsonbody()
      assert.equal("denied", body.error)
    end)
  end)
end

local mocks = require "spec.01-unit.support.mocks"
local cjson = require "cjson"

local VERSION = "1.1.1"
local CACHE_HEADER = "X-Middleman-Cache-Status"

-- A config with the schema defaults; specs override what they exercise.
local function default_conf(overrides)
  local conf = {
    method = "POST",
    url = "http://middle.test",
    path = "/auth",
    connect_timeout = 5000,
    send_timeout = 10000,
    read_timeout = 10000,
    forward_path = false,
    forward_query = false,
    forward_headers = false,
    forward_body = false,
    inject_body_response_into_header = true,
    injected_header_prefix = "X-",
    streamdown_injected_headers = false,
    cache_enabled = false,
    cache_policy = "local",
    cache_based_on = "host",
    cache_based_on_headers = "authorization",
    cache_invalidate_when_streamup_path = {},
    cache_ttl = 60,
  }
  for k, v in pairs(overrides or {}) do
    conf[k] = v
  end
  return conf
end

-- Build a fully-mocked access module plus handles to assert against.
local function build(opts)
  opts = opts or {}
  local ngx_mock = mocks.fake_ngx()
  local kong_mock, recorded = mocks.fake_kong({ request = opts.request })
  local http_module, http_client = mocks.fake_http_module()
  local policies, policy_calls, policy_state = mocks.fake_policies()

  if opts.http_response then http_client.response = opts.http_response end
  if opts.http_err then http_client.err = opts.http_err end
  if opts.probe_return ~= nil then policy_state.probe_return = opts.probe_return end

  local access = mocks.load_with("kong.plugins.the-middleman.access", {
    kong = kong_mock,
    ngx = ngx_mock,
    packages = {
      ["resty.http"] = http_module,
      ["kong.plugins.the-middleman.policies"] = policies,
    },
  })

  return {
    access = access,
    recorded = recorded,
    http = http_client,
    policy_calls = policy_calls,
    policy_state = policy_state,
  }
end

describe("the-middleman access", function()

  describe("external request building", function()
    it("sends method, path and url with the version'd User-Agent", function()
      local ctx = build({ request = { host = "api.test", path = "/v1/x" } })
      ctx.access.execute(default_conf(), VERSION)

      local req = ctx.http.requests[1]
      assert.equal("http://middle.test", req.url)
      assert.equal("POST", req.params.method)
      assert.equal("/auth", req.params.path)
      assert.equal("the-middleman/" .. VERSION, req.params.headers["User-Agent"])
      assert.equal("application/json", req.params.headers["Content-Type"])
      assert.equal("api.test", req.params.headers["X-Forwarded-Host"])
      assert.equal("/v1/x", req.params.headers["X-Forwarded-Path"])
    end)

    it("applies the configured timeouts", function()
      local ctx = build()
      ctx.access.execute(default_conf({
        connect_timeout = 11, send_timeout = 22, read_timeout = 33,
      }), VERSION)
      assert.same({ connect = 11, send = 22, read = 33 }, ctx.http.timeouts)
    end)

    it("only forwards the parts that are enabled", function()
      local ctx = build({
        request = {
          path = "/p",
          query = { a = "1" },
          headers = { ["x-test"] = "h" },
          body = { field = "v" },
        },
      })
      ctx.access.execute(default_conf({
        forward_path = true,
        forward_query = true,
        forward_headers = true,
        forward_body = true,
      }), VERSION)

      local body = cjson.decode(ctx.http.requests[1].params.body)
      assert.equal("/p", body.path)
      assert.same({ a = "1" }, body.query)
      assert.same({ ["x-test"] = "h" }, body.headers)
      assert.same({ field = "v" }, body.body)
    end)

    it("forwards nothing by default", function()
      local ctx = build({ request = { path = "/p", body = { field = "v" } } })
      ctx.access.execute(default_conf(), VERSION)
      local body = cjson.decode(ctx.http.requests[1].params.body)
      assert.is_nil(body.path)
      assert.is_nil(body.body)
    end)

    it("raises when the upstream call errors", function()
      local ctx = build({ http_err = "connection refused" })
      assert.has_error(function()
        ctx.access.execute(default_conf(), VERSION)
      end)
    end)
  end)

  describe("header injection", function()
    it("injects dasherized headers from the JSON response", function()
      local ctx = build({
        http_response = { status = 200, body = '{"tenantId":"123","role":"admin"}', headers = {} },
      })
      ctx.access.execute(default_conf(), VERSION)

      assert.equal("123", ctx.recorded.upstream_headers["X-Tenant-Id"])
      assert.equal("admin", ctx.recorded.upstream_headers["X-Role"])
    end)

    it("json-encodes table values", function()
      local ctx = build({
        http_response = { status = 200, body = '{"data":{"a":1}}', headers = {} },
      })
      ctx.access.execute(default_conf(), VERSION)
      assert.same({ a = 1 }, cjson.decode(ctx.recorded.upstream_headers["X-Data"]))
    end)

    it("skips falsy values", function()
      local ctx = build({
        http_response = { status = 200, body = '{"role":false,"ok":"yes"}', headers = {} },
      })
      ctx.access.execute(default_conf(), VERSION)
      assert.is_nil(ctx.recorded.upstream_headers["X-Role"])
      assert.equal("yes", ctx.recorded.upstream_headers["X-Ok"])
    end)

    it("honors a custom injected_header_prefix", function()
      local ctx = build({
        http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
      })
      ctx.access.execute(default_conf({ injected_header_prefix = "Z-" }), VERSION)
      assert.equal("admin", ctx.recorded.upstream_headers["Z-Role"])
    end)

    it("does not inject when disabled", function()
      local ctx = build({
        http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
      })
      ctx.access.execute(default_conf({ inject_body_response_into_header = false }), VERSION)
      assert.is_nil(ctx.recorded.upstream_headers["X-Role"])
    end)

    it("does not crash on a non-JSON body and logs the problem", function()
      local ctx = build({
        http_response = { status = 200, body = "this is not json", headers = {} },
      })
      assert.has_no.errors(function()
        ctx.access.execute(default_conf(), VERSION)
      end)
      assert.is_true(#ctx.recorded.logs > 0)
    end)

    it("does not inject when the body is valid JSON but not an object", function()
      local ctx = build({
        http_response = { status = 200, body = "123", headers = {} },
      })
      assert.has_no.errors(function()
        ctx.access.execute(default_conf(), VERSION)
      end)
      assert.is_true(#ctx.recorded.logs > 0)
    end)
  end)

  describe("upstream error responses", function()
    it("replays status/body/headers and skips injection", function()
      local ctx = build({
        http_response = { status = 403, body = "denied", headers = { ["x-a"] = "b" } },
      })
      ctx.access.execute(default_conf(), VERSION)

      assert.equal(403, ctx.recorded.exit.status)
      assert.equal("denied", ctx.recorded.exit.body)
      assert.same({ ["x-a"] = "b" }, ctx.recorded.exit.headers)
      assert.is_nil(ctx.recorded.upstream_headers["X-Role"])
    end)
  end)

  describe("cache disabled", function()
    it("calls upstream and sets no cache-status header", function()
      local ctx = build({
        http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
      })
      ctx.access.execute(default_conf({ cache_enabled = false }), VERSION)

      assert.equal(1, #ctx.http.requests)
      assert.equal(0, #ctx.policy_calls.probe)
      assert.is_nil(ctx.recorded.upstream_headers[CACHE_HEADER])
    end)
  end)

  describe("cache enabled", function()
    it("serves a HIT without calling upstream", function()
      local ctx = build({ probe_return = { status = 200, body = '{"role":"admin"}', headers = {} } })
      ctx.access.execute(default_conf({ cache_enabled = true }), VERSION)

      assert.equal(0, #ctx.http.requests)
      assert.equal(0, #ctx.policy_calls.set)
      assert.equal("HIT", ctx.recorded.upstream_headers[CACHE_HEADER])
      assert.equal("admin", ctx.recorded.upstream_headers["X-Role"])
    end)

    it("fetches and stores on a MISS", function()
      local ctx = build({
        probe_return = nil,
        http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
      })
      ctx.access.execute(default_conf({ cache_enabled = true }), VERSION)

      assert.equal(1, #ctx.http.requests)
      assert.equal(1, #ctx.policy_calls.set)
      assert.equal("MISS", ctx.recorded.upstream_headers[CACHE_HEADER])
      assert.equal(60, ctx.policy_calls.set[1].opts.ttl)
    end)

    describe("cache key strategy", function()
      local function probed_key(ctx)
        return ctx.policy_calls.probe[1].key
      end

      it("uses the host by default", function()
        local ctx = build({ request = { host = "api.test" } })
        ctx.access.execute(default_conf({ cache_enabled = true, cache_based_on = "host" }), VERSION)
        assert.equal("md5(api.test)", probed_key(ctx))
      end)

      it("uses host + path", function()
        local ctx = build({ request = { host = "api.test", path = "/x" } })
        ctx.access.execute(default_conf({ cache_enabled = true, cache_based_on = "host-path" }), VERSION)
        assert.equal("md5(api.test/x)", probed_key(ctx))
      end)

      it("uses host + path + query", function()
        local ctx = build({ request = { host = "api.test", path_with_query = "/x?a=1" } })
        ctx.access.execute(default_conf({ cache_enabled = true, cache_based_on = "host-path-query" }), VERSION)
        assert.equal("md5(api.test/x?a=1)", probed_key(ctx))
      end)

      it("uses the first present header from the prioritized list", function()
        local ctx = build({ request = { header_values = { ["x-tenant"] = "t-2" } } })
        ctx.access.execute(default_conf({
          cache_enabled = true,
          cache_based_on = "header",
          cache_based_on_headers = "x-missing,x-tenant",
        }), VERSION)
        assert.equal("md5(t-2)", probed_key(ctx))
      end)

      it("falls back to host when no configured header is present", function()
        local ctx = build({ request = { host = "api.test", header_values = {} } })
        ctx.access.execute(default_conf({
          cache_enabled = true,
          cache_based_on = "header",
          cache_based_on_headers = "authorization",
        }), VERSION)
        assert.equal("md5(api.test)", probed_key(ctx))
      end)
    end)

    describe("invalidation", function()
      it("skips the cache store and invalidates on a matching path (MISS)", function()
        local ctx = build({
          request = { path = "/logout" },
          probe_return = nil,
          http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
        })
        ctx.access.execute(default_conf({
          cache_enabled = true,
          cache_invalidate_when_streamup_path = { "/logout" },
        }), VERSION)

        assert.equal(1, #ctx.http.requests)
        assert.equal(0, #ctx.policy_calls.set, "should not persist a key it is about to invalidate")
        assert.equal(1, #ctx.policy_calls.invalidate)
        assert.equal(1, #ctx.recorded.invalidated, "kong.cache:invalidate should also be called")
      end)

      it("does not invalidate on a non-matching path", function()
        local ctx = build({
          request = { path = "/other" },
          probe_return = nil,
          http_response = { status = 200, body = "{}", headers = {} },
        })
        ctx.access.execute(default_conf({
          cache_enabled = true,
          cache_invalidate_when_streamup_path = { "/logout" },
        }), VERSION)

        assert.equal(1, #ctx.policy_calls.set)
        assert.equal(0, #ctx.policy_calls.invalidate)
      end)
    end)

    describe("streamdown", function()
      it("mirrors cache-status and injected headers onto the response", function()
        local ctx = build({
          probe_return = nil,
          http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
        })
        ctx.access.execute(default_conf({
          cache_enabled = true,
          streamdown_injected_headers = true,
        }), VERSION)

        assert.equal("MISS", ctx.recorded.response_headers[CACHE_HEADER])
        assert.equal("admin", ctx.recorded.response_headers["X-Role"])
      end)
    end)
  end)
end)

local mocks = require "spec.01-unit.support.mocks"
local cjson = require "cjson"

local VERSION = "2.0.0"
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
    cache_response_codes = {},
    cache_storage_ttl = 0,
    cache_control = false,
    forward_headers_allow = {},
    forward_response_headers = {},
  }
  for k, v in pairs(overrides or {}) do
    conf[k] = v
  end
  return conf
end

-- Build a fully-mocked access module plus handles to assert against.
local function build(opts)
  opts = opts or {}
  local ngx_mock = mocks.fake_ngx({ now = opts.now })
  local kong_mock, recorded = mocks.fake_kong({ request = opts.request })
  local http_module, http_client = mocks.fake_http_module()
  local policies, policy_calls, policy_state = mocks.fake_policies()
  local lock_module, lock_calls = mocks.fake_lock({ lock_fail = opts.lock_fail, new_fail = opts.new_fail })

  if opts.http_response then http_client.response = opts.http_response end
  if opts.http_err then http_client.err = opts.http_err end
  if opts.probe_return ~= nil then policy_state.probe_return = opts.probe_return end
  if opts.probe_err ~= nil then policy_state.probe_err = opts.probe_err end
  if opts.probe_fill ~= nil then policy_state.probe_fill = opts.probe_fill end

  local access = mocks.load_with("kong.plugins.the-middleman.access", {
    kong = kong_mock,
    ngx = ngx_mock,
    packages = {
      ["resty.http"] = http_module,
      ["resty.lock"] = lock_module,
      ["resty.sha256"] = mocks.fake_sha256(),
      ["resty.string"] = mocks.fake_resty_string(),
      ["kong.plugins.the-middleman.policies"] = policies,
    },
  })

  return {
    access = access,
    recorded = recorded,
    http = http_client,
    policy_calls = policy_calls,
    policy_state = policy_state,
    lock = lock_calls,
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

    it("injects boolean false as a string instead of dropping it", function()
      -- A false field is meaningful (e.g. {"isAdmin":false}); dropping it would
      -- make it indistinguishable from "absent" downstream.
      local ctx = build({
        http_response = { status = 200, body = '{"role":false,"ok":"yes"}', headers = {} },
      })
      ctx.access.execute(default_conf(), VERSION)
      assert.equal("false", ctx.recorded.upstream_headers["X-Role"])
      assert.equal("yes", ctx.recorded.upstream_headers["X-Ok"])
    end)

    it("skips a JSON null without crashing", function()
      -- cjson decodes null to a userdata sentinel; injecting it would raise an
      -- "invalid header value" error and 500 the whole request.
      local ctx = build({
        http_response = { status = 200, body = '{"role":null,"ok":"yes"}', headers = {} },
      })
      assert.has_no.errors(function()
        ctx.access.execute(default_conf(), VERSION)
      end)
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

    it("does not inject numbered headers from a JSON array body", function()
      -- A JSON array decodes to integer keys; injecting it would produce
      -- meaningless X-1/X-2 headers, so it must be skipped like invalid JSON.
      local ctx = build({
        http_response = { status = 200, body = '["a","b"]', headers = {} },
      })
      assert.has_no.errors(function()
        ctx.access.execute(default_conf(), VERSION)
      end)
      assert.is_nil(ctx.recorded.upstream_headers["X-1"])
      assert.is_nil(ctx.recorded.upstream_headers["X-2"])
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

    it("strips connection/length headers when replaying an error", function()
      -- Replaying the middle-service's own Content-Length/Transfer-Encoding onto
      -- the client response would corrupt the body Kong actually sends.
      local ctx = build({
        http_response = {
          status = 502, body = "boom",
          headers = { ["Content-Length"] = "3", ["Transfer-Encoding"] = "chunked", ["X-Keep"] = "v" },
        },
      })
      ctx.access.execute(default_conf(), VERSION)

      assert.equal(502, ctx.recorded.exit.status)
      assert.is_nil(ctx.recorded.exit.headers["Content-Length"])
      assert.is_nil(ctx.recorded.exit.headers["Transfer-Encoding"])
      assert.equal("v", ctx.recorded.exit.headers["X-Keep"])
    end)
  end)

  describe("redirect responses", function()
    it("replays a 3xx to the client instead of proxying upstream", function()
      -- A 3xx is the middle-service redirecting the caller (forward-auth ->
      -- login). It must be replayed with its Location, not run through injection
      -- and proxied upstream (which silently drops the redirect).
      local ctx = build({
        http_response = { status = 302, body = "", headers = { ["Location"] = "/login" } },
      })
      ctx.access.execute(default_conf(), VERSION)

      assert.equal(302, ctx.recorded.exit.status)
      assert.equal("/login", ctx.recorded.exit.headers["Location"])
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
        assert.equal("sha256(http://middle.test|/auth|api.test)", probed_key(ctx))
      end)

      it("uses host + path", function()
        local ctx = build({ request = { host = "api.test", path = "/x" } })
        ctx.access.execute(default_conf({ cache_enabled = true, cache_based_on = "host-path" }), VERSION)
        assert.equal("sha256(http://middle.test|/auth|api.test/x)", probed_key(ctx))
      end)

      it("uses host + path + query", function()
        local ctx = build({ request = { host = "api.test", path_with_query = "/x?a=1" } })
        ctx.access.execute(default_conf({ cache_enabled = true, cache_based_on = "host-path-query" }), VERSION)
        assert.equal("sha256(http://middle.test|/auth|api.test/x?a=1)", probed_key(ctx))
      end)

      it("uses the first present header from the prioritized list", function()
        local ctx = build({ request = { header_values = { ["x-tenant"] = "t-2" } } })
        ctx.access.execute(default_conf({
          cache_enabled = true,
          cache_based_on = "header",
          cache_based_on_headers = "x-missing,x-tenant",
        }), VERSION)
        assert.equal("sha256(http://middle.test|/auth|t-2)", probed_key(ctx))
      end)

      it("trims whitespace around header names in the prioritized list", function()
        local ctx = build({ request = { header_values = { ["x-tenant"] = "t-2" } } })
        ctx.access.execute(default_conf({
          cache_enabled = true,
          cache_based_on = "header",
          cache_based_on_headers = "x-missing, x-tenant",
        }), VERSION)
        assert.equal("sha256(http://middle.test|/auth|t-2)", probed_key(ctx))
      end)

      it("falls back to host when no configured header is present", function()
        local ctx = build({ request = { host = "api.test", header_values = {} } })
        ctx.access.execute(default_conf({
          cache_enabled = true,
          cache_based_on = "header",
          cache_based_on_headers = "authorization",
        }), VERSION)
        assert.equal("sha256(http://middle.test|/auth|api.test)", probed_key(ctx))
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
        assert.equal(1, #ctx.policy_calls.invalidate, "invalidation is delegated to the policy")
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

    describe("stampede / backend-down handling", function()
      it("acquires and releases the per-node lock on a MISS", function()
        local ctx = build({
          probe_return = nil,
          http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
        })
        ctx.access.execute(default_conf({ cache_enabled = true }), VERSION)

        assert.equal("kong_locks", ctx.lock.dict)
        assert.equal(1, #ctx.lock.locked)
        assert.equal(1, ctx.lock.unlocked)
        assert.equal(1, #ctx.http.requests)
      end)

      it("re-probes under the lock and serves a peer's fill without refetching", function()
        local ctx = build({
          probe_return = nil,  -- first probe: MISS
          probe_fill = { status = 200, body = '{"role":"admin"}', headers = {} }, -- re-probe: HIT
        })
        ctx.access.execute(default_conf({ cache_enabled = true }), VERSION)

        assert.equal(0, #ctx.http.requests, "must not refetch when a peer already filled the cache")
        assert.equal(0, #ctx.policy_calls.set)
        assert.equal("HIT", ctx.recorded.upstream_headers[CACHE_HEADER])
        assert.equal(1, ctx.lock.unlocked, "the lock must be released")
      end)

      it("fails open and fetches when the lock cannot be acquired", function()
        local ctx = build({
          probe_return = nil,
          lock_fail = true,
          http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
        })
        ctx.access.execute(default_conf({ cache_enabled = true }), VERSION)

        assert.equal(1, #ctx.http.requests)
        assert.equal("MISS", ctx.recorded.upstream_headers[CACHE_HEADER])
        assert.equal(0, ctx.lock.unlocked, "nothing to unlock when acquisition failed")
      end)

      it("fails open without re-touching the cache when the backend is unreachable", function()
        local ctx = build({
          probe_err = "connection refused",
          http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
        })
        ctx.access.execute(default_conf({ cache_enabled = true }), VERSION)

        assert.equal(1, #ctx.http.requests)
        assert.equal("MISS", ctx.recorded.upstream_headers[CACHE_HEADER])
        assert.equal(1, #ctx.policy_calls.probe, "only one probe; no re-probe when the backend is down")
        assert.equal(0, #ctx.policy_calls.set, "must not write to a down backend")
        assert.equal(0, #ctx.lock.locked, "no lock attempt when the backend is down")
      end)
    end)
  end)

  describe("response codes, headers and cache-control", function()
    local CACHE_KEY = "X-Middleman-Cache-Key"

    it("sets the cache-key header alongside the cache status", function()
      local ctx = build({
        request = { host = "api.test" },
        http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
      })
      ctx.access.execute(default_conf({ cache_enabled = true, cache_based_on = "host" }), VERSION)
      assert.equal("sha256(http://middle.test|/auth|api.test)",
        ctx.recorded.upstream_headers[CACHE_KEY])
    end)

    it("does not cache a status outside cache_response_codes", function()
      local ctx = build({
        http_response = { status = 201, body = '{"role":"admin"}', headers = {} },
      })
      ctx.access.execute(default_conf({ cache_enabled = true, cache_response_codes = { 200 } }), VERSION)
      assert.equal(0, #ctx.policy_calls.set, "201 is not in the cacheable list")
    end)

    it("caches a status that is in cache_response_codes", function()
      local ctx = build({
        http_response = { status = 201, body = '{"role":"admin"}', headers = {} },
      })
      ctx.access.execute(default_conf({ cache_enabled = true, cache_response_codes = { 201 } }), VERSION)
      assert.equal(1, #ctx.policy_calls.set)
    end)

    it("forwards configured middle-service response headers onto the upstream request", function()
      local ctx = build({
        http_response = {
          status = 200, body = "{}",
          headers = { ["X-Auth-User"] = "alice", ["X-Other"] = "ignored" },
        },
      })
      ctx.access.execute(default_conf({ forward_response_headers = { "x-auth-user" } }), VERSION)
      assert.equal("alice", ctx.recorded.upstream_headers["x-auth-user"])
      assert.is_nil(ctx.recorded.upstream_headers["x-other"])
    end)

    it("forwards only the allow-listed client headers to the middle-service", function()
      local ctx = build({ request = { headers = { ["x-a"] = "1", ["x-b"] = "2" } } })
      ctx.access.execute(default_conf({
        forward_headers = true,
        forward_headers_allow = { "x-a" },
      }), VERSION)
      local body = cjson.decode(ctx.http.requests[1].params.body)
      assert.same({ ["x-a"] = "1" }, body.headers)
    end)

    it("bypasses the cache and does not store on Cache-Control: no-store", function()
      local ctx = build({
        request = { host = "api.test", header_values = { ["cache-control"] = "no-store" } },
        http_response = { status = 200, body = '{"role":"admin"}', headers = {} },
      })
      ctx.access.execute(default_conf({ cache_enabled = true, cache_control = true }), VERSION)
      assert.equal("BYPASS", ctx.recorded.upstream_headers[CACHE_HEADER])
      assert.equal(0, #ctx.policy_calls.probe, "no-store skips the cache read")
      assert.equal(0, #ctx.policy_calls.set, "no-store skips the cache write")
    end)

    it("revalidates on Cache-Control: no-cache even with a cached value", function()
      local ctx = build({
        request = { host = "api.test", header_values = { ["cache-control"] = "no-cache" } },
        probe_return = { status = 200, body = '{"role":"cached"}', headers = {} },
        http_response = { status = 200, body = '{"role":"fresh"}', headers = {} },
      })
      ctx.access.execute(default_conf({ cache_enabled = true, cache_control = true }), VERSION)
      assert.equal(1, #ctx.http.requests, "no-cache must fetch fresh despite a cached value")
      assert.equal("BYPASS", ctx.recorded.upstream_headers[CACHE_HEADER])
      assert.equal("fresh", ctx.recorded.upstream_headers["X-Role"])
      assert.equal(1, #ctx.policy_calls.set, "no-cache still stores the fresh result")
    end)

    it("uses the middle-service max-age as the TTL when cache_control is on", function()
      local ctx = build({
        request = { host = "api.test" },
        http_response = { status = 200, body = "{}", headers = { ["Cache-Control"] = "max-age=5" } },
      })
      ctx.access.execute(default_conf({ cache_enabled = true, cache_control = true }), VERSION)
      assert.equal(1, #ctx.policy_calls.set)
      assert.equal(5, ctx.policy_calls.set[1].opts.ttl)
    end)

    it("does not cache when the middle-service responds Cache-Control: no-store", function()
      local ctx = build({
        request = { host = "api.test" },
        http_response = { status = 200, body = "{}", headers = { ["Cache-Control"] = "no-store" } },
      })
      ctx.access.execute(default_conf({ cache_enabled = true, cache_control = true }), VERSION)
      assert.equal(0, #ctx.policy_calls.set)
    end)

    it("serves a stale cached entry when the middle-service fails", function()
      local ctx = build({
        request = { host = "api.test" },
        probe_return = { status = 200, body = '{"role":"stale"}', headers = {}, fresh_until = 1 },
        http_err = "connection refused",
      })
      ctx.access.execute(default_conf({ cache_enabled = true, cache_storage_ttl = 600 }), VERSION)
      assert.equal("STALE", ctx.recorded.upstream_headers[CACHE_HEADER])
      assert.equal("stale", ctx.recorded.upstream_headers["X-Role"])
    end)

    it("refreshes a stale entry when the middle-service succeeds", function()
      local ctx = build({
        request = { host = "api.test" },
        probe_return = { status = 200, body = '{"role":"stale"}', headers = {}, fresh_until = 1 },
        http_response = { status = 200, body = '{"role":"fresh"}', headers = {} },
      })
      ctx.access.execute(default_conf({ cache_enabled = true, cache_storage_ttl = 600 }), VERSION)
      assert.equal("REFRESH", ctx.recorded.upstream_headers[CACHE_HEADER])
      assert.equal("fresh", ctx.recorded.upstream_headers["X-Role"])
      assert.equal(1, #ctx.policy_calls.set, "the refreshed value is re-stored")
    end)
  end)
end)

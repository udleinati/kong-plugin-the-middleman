local mocks = require "spec.01-unit.support.mocks"
local cjson = require "cjson"

-- Fake kong.cache (the "local" backend) plus a logger.
local function fake_kong()
  local recorded = { invalidated = {}, logs = {} }
  local state = { probe_return = nil }
  local kong = {
    log = { err = function() recorded.logs[#recorded.logs + 1] = true end },
    cache = {
      -- methods invoked with `:` in policies/init.lua
      get = function(_, key, opts, cb, value)
        return cb(value)
      end,
      probe = function(_, key)
        return 30, nil, state.probe_return
      end,
      invalidate = function(_, key)
        recorded.invalidated[#recorded.invalidated + 1] = key
        return true
      end,
    },
  }
  return kong, recorded, state
end

-- Configurable fake resty.redis client.
local function fake_redis(opts)
  opts = opts or {}
  local red = {
    calls = {
      connect = {}, auth = {}, select = {}, set = {},
      get = {}, del = {}, keepalive = {}, timeout = {},
    },
  }
  function red:set_timeout(t) self.calls.timeout[#self.calls.timeout + 1] = t end
  function red:connect(host, port, sock_opts)
    self.calls.connect[#self.calls.connect + 1] = { host = host, port = port, sock_opts = sock_opts }
    if opts.connect_fail then return nil, "connect failed" end
    return 1
  end
  function red:get_reused_times() return opts.reused_times or 0 end
  function red:auth(...)
    self.calls.auth[#self.calls.auth + 1] = { ... }
    return 1
  end
  function red:select(db)
    self.calls.select[#self.calls.select + 1] = db
    return 1
  end
  function red:set(key, value, ex_flag, ttl)
    self.calls.set[#self.calls.set + 1] = { key = key, value = value, ex = ex_flag, ttl = ttl }
    return "OK"
  end
  function red:get(key)
    self.calls.get[#self.calls.get + 1] = key
    return opts.get_return
  end
  function red:del(key)
    self.calls.del[#self.calls.del + 1] = key
    return 1
  end
  function red:set_keepalive(a, b)
    self.calls.keepalive[#self.calls.keepalive + 1] = { a, b }
    return 1
  end

  local module = { new = function() return red end }
  return module, red
end

-- conf.redis is the shared kong.tools.redis config record (Kong 3.6+).
local function redis_conf(overrides)
  local redis = {
    host = "127.0.0.1",
    port = 6379,
    timeout = 2000,
    database = 0,
    ssl = false,
    ssl_verify = false,
    server_name = nil,
    password = nil,
    username = nil,
  }
  for k, v in pairs(overrides or {}) do redis[k] = v end
  return { redis = redis }
end

-- Load policies fresh with all collaborators mocked.
local function build(opts)
  opts = opts or {}
  local ngx_mock = mocks.fake_ngx()
  local kong_mock, recorded, state = fake_kong()
  if opts.probe_return ~= nil then state.probe_return = opts.probe_return end

  -- resty-redis returns ngx.null (never Lua nil) for a missing key; default the
  -- fake to that so probe() exercises the real "no value" branch.
  if opts.get_return == "NULL" or opts.get_return == nil then
    opts.get_return = ngx_mock.null
  end

  local redis_module, red = fake_redis(opts)
  local reports = { retrieve_redis_version = function() end }

  local policies = mocks.load_with("kong.plugins.the-middleman.policies", {
    kong = kong_mock,
    ngx = ngx_mock,
    packages = {
      ["resty.redis"] = redis_module,
      ["kong.reports"] = reports,
    },
  })

  return {
    policies = policies,
    recorded = recorded,
    state = state,
    red = red,
    ngx = ngx_mock,
  }
end

describe("the-middleman policies", function()

  describe("argument guard", function()
    it("rejects non-string keys", function()
      local ctx = build()
      assert.has_error(function() ctx.policies["local"].probe({}, 123) end)
      assert.has_error(function() ctx.policies["redis"].probe(redis_conf(), {}) end)
    end)
  end)

  describe("local policy", function()
    it("set() stores via kong.cache and returns the value", function()
      local ctx = build()
      local value = { status = 200, body = "{}" }
      local result = ctx.policies["local"].set({}, "k", value, { ttl = 60 })
      assert.same(value, result)
    end)

    it("probe() returns the cached value", function()
      local ctx = build({ probe_return = { status = 200, body = "cached" } })
      local result = ctx.policies["local"].probe({}, "k")
      assert.same({ status = 200, body = "cached" }, result)
    end)

    it("probe() returns nil on a miss", function()
      local ctx = build({ probe_return = nil })
      assert.is_nil(ctx.policies["local"].probe({}, "k"))
    end)

    it("invalidate() delegates to kong.cache and returns true", function()
      local ctx = build()
      assert.is_true(ctx.policies["local"].invalidate({}, "k"))
      assert.equal("k", ctx.recorded.invalidated[1])
    end)
  end)

  describe("redis policy", function()
    it("set() writes the namespaced key with the ttl", function()
      local ctx = build()
      ctx.policies["redis"].set(redis_conf(), "abc", { body = "x" }, { ttl = 42 })

      local call = ctx.red.calls.set[1]
      assert.equal("kong:the-middleman:abc", call.key)
      assert.equal("EX", call.ex)
      assert.equal(42, call.ttl)
      assert.same({ body = "x" }, cjson.decode(call.value))
      assert.equal(1, #ctx.red.calls.keepalive)
    end)

    it("scopes the key by username when set", function()
      local ctx = build()
      ctx.policies["redis"].set(redis_conf({ username = "alice" }), "abc", {}, { ttl = 1 })
      assert.equal("alice::kong:the-middleman:abc", ctx.red.calls.set[1].key)
    end)

    it("probe() decodes a stored value", function()
      local ctx = build({ get_return = cjson.encode({ role = "admin" }) })
      local result = ctx.policies["redis"].probe(redis_conf(), "abc")
      assert.same({ role = "admin" }, result)
      assert.equal("kong:the-middleman:abc", ctx.red.calls.get[1])
    end)

    it("probe() returns nil when redis has no value (ngx.null)", function()
      local ctx = build({ get_return = "NULL" })
      assert.is_nil(ctx.policies["redis"].probe(redis_conf(), "abc"))
    end)

    it("invalidate() deletes the namespaced key", function()
      local ctx = build()
      assert.is_true(ctx.policies["redis"].invalidate(redis_conf(), "abc"))
      assert.equal("kong:the-middleman:abc", ctx.red.calls.del[1])
    end)

    it("authenticates with username + password when both are set", function()
      local ctx = build()
      ctx.policies["redis"].probe(redis_conf({ username = "u", password = "p" }), "abc")
      assert.same({ "u", "p" }, ctx.red.calls.auth[1])
    end)

    it("authenticates with password only when no username", function()
      local ctx = build()
      ctx.policies["redis"].probe(redis_conf({ password = "p" }), "abc")
      assert.same({ "p" }, ctx.red.calls.auth[1])
    end)

    it("does not authenticate when no password is configured", function()
      local ctx = build()
      ctx.policies["redis"].probe(redis_conf(), "abc")
      assert.equal(0, #ctx.red.calls.auth)
    end)

    it("selects the database and uses a scoped pool when redis database is non-zero", function()
      local ctx = build()
      ctx.policies["redis"].probe(redis_conf({ database = 3 }), "abc")
      assert.equal(3, ctx.red.calls.select[1])
      assert.equal("127.0.0.1:6379;3", ctx.red.calls.connect[1].sock_opts.pool)
    end)

    it("returns the error when the connection fails", function()
      local ctx = build({ connect_fail = true })
      local result, err = ctx.policies["redis"].probe(redis_conf(), "abc")
      assert.is_nil(result)
      assert.is_string(err)
    end)

    it("passes ssl options through to connect()", function()
      local ctx = build()
      ctx.policies["redis"].probe(redis_conf({ ssl = true, ssl_verify = true }), "abc")
      local sock_opts = ctx.red.calls.connect[1].sock_opts
      assert.is_true(sock_opts.ssl)
      assert.is_true(sock_opts.ssl_verify)
    end)
  end)
end)

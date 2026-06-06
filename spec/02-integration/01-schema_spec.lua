local PLUGIN_NAME = "the-middleman"

-- Validate a plugin config against the schema, the way Kong's Admin API does.
local validate
do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local plugin_schema = require("kong.plugins." .. PLUGIN_NAME .. ".schema")

  function validate(config)
    return validate_entity(config, plugin_schema)
  end
end

describe(PLUGIN_NAME .. ": schema", function()
  it("accepts a minimal config with only the required url", function()
    local ok, err = validate({ url = "http://middle.test" })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)

  it("requires url", function()
    local ok, err = validate({})
    assert.is_falsy(ok)
    assert.is_not_nil(err)
  end)

  it("applies the documented defaults", function()
    local ok = validate({ url = "http://middle.test" })
    assert.equal("POST", ok.config.method)
    assert.equal("/auth", ok.config.path)
    assert.equal(5000, ok.config.connect_timeout)
    assert.equal(10000, ok.config.send_timeout)
    assert.equal(10000, ok.config.read_timeout)
    assert.is_false(ok.config.forward_headers)
    assert.is_true(ok.config.inject_body_response_into_header)
    assert.equal("X-", ok.config.injected_header_prefix)
    assert.is_false(ok.config.cache_enabled)
    assert.equal("local", ok.config.cache_policy)
    assert.equal("host", ok.config.cache_based_on)
    assert.equal(60, ok.config.cache_ttl)
  end)

  it("rejects an unsupported method", function()
    local ok, err = validate({ url = "http://middle.test", method = "PUT" })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.method)
  end)

  it("accepts GET as a method", function()
    local ok = validate({ url = "http://middle.test", method = "GET" })
    assert.is_truthy(ok)
  end)

  it("rejects an unsupported cache_policy", function()
    local ok, err = validate({ url = "http://middle.test", cache_policy = "memcached" })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.cache_policy)
  end)

  it("rejects an unsupported cache_based_on", function()
    local ok, err = validate({ url = "http://middle.test", cache_based_on = "body" })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.cache_based_on)
  end)

  it("requires redis.host when cache_policy is redis", function()
    local ok, err = validate({
      url = "http://middle.test",
      cache_policy = "redis",
    })
    assert.is_falsy(ok)
    assert.is_not_nil(err)
  end)

  it("accepts a complete redis config (nested config.redis.*)", function()
    local ok = validate({
      url = "http://middle.test",
      cache_enabled = true,
      cache_policy = "redis",
      redis = {
        host = "127.0.0.1",
        port = 6379,
        timeout = 2000,
      },
    })
    assert.is_truthy(ok)
    assert.equal("127.0.0.1", ok.config.redis.host)
  end)

  it("applies redis defaults from the shared schema", function()
    local ok = validate({
      url = "http://middle.test",
      cache_enabled = true,
      cache_policy = "redis",
      redis = { host = "127.0.0.1" },
    })
    assert.is_truthy(ok)
    assert.equal(6379, ok.config.redis.port)
    assert.equal(0, ok.config.redis.database)
    assert.is_false(ok.config.redis.ssl)
  end)

  it("still accepts the legacy flat redis_* config and folds it into config.redis", function()
    local ok = validate({
      url = "http://middle.test",
      cache_enabled = true,
      cache_policy = "redis",
      redis_host = "127.0.0.1",
      redis_port = 6380,
      redis_timeout = 2000,
    })
    assert.is_truthy(ok)
    assert.equal("127.0.0.1", ok.config.redis.host)
    assert.equal(6380, ok.config.redis.port)
  end)

  -- G1: a non-positive / fractional cache_ttl breaks the redis policy
  -- (SET ... EX <ttl>), so the schema must reject it up front.
  it("rejects a non-positive cache_ttl", function()
    local ok, err = validate({ url = "http://middle.test", cache_ttl = 0 })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.cache_ttl)
  end)

  it("rejects a fractional cache_ttl", function()
    local ok, err = validate({ url = "http://middle.test", cache_ttl = 1.5 })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.cache_ttl)
  end)

  -- G8: a non-positive timeout would reach resty with undefined behaviour.
  it("rejects a non-positive timeout", function()
    local ok, err = validate({ url = "http://middle.test", connect_timeout = 0 })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.connect_timeout)
  end)
end)

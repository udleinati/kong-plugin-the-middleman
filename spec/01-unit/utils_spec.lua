local utils = require "kong.plugins.the-middleman.utils"

describe("the-middleman utils", function()
  describe("capitalize()", function()
    it("uppercases a lowercase-leading word", function()
      assert.equal("Foo", utils.capitalize("foo"))
    end)

    it("leaves an already-capitalized word untouched", function()
      assert.equal("Foo", utils.capitalize("Foo"))
    end)

    it("only touches the first character", function()
      assert.equal("FooBar", utils.capitalize("fooBar"))
    end)

    it("handles an empty string", function()
      assert.equal("", utils.capitalize(""))
    end)
  end)

  describe("dasherize()", function()
    it("splits camelCase into kebab segments and capitalizes them", function()
      assert.equal("Tenant-Id", utils.dasherize("tenantId"))
      assert.equal("Account-Id", utils.dasherize("accountId"))
    end)

    it("keeps a single lowercase word capitalized", function()
      assert.equal("Role", utils.dasherize("role"))
    end)

    it("collapses non-word separators into a single dash", function()
      assert.equal("X-User-Id", utils.dasherize("X-user id"))
      assert.equal("Foo-Bar", utils.dasherize("foo  bar"))
      assert.equal("Foo-Bar", utils.dasherize("foo.bar"))
    end)

    it("dasherizes a prefixed key the way the plugin injects headers", function()
      -- injected_header_prefix ("X-") .. key ("userId")
      assert.equal("X-User-Id", utils.dasherize("X-" .. "userId"))
      assert.equal("X-Tenant-Id", utils.dasherize("X-" .. "tenantId"))
    end)

    it("is idempotent on already-dasherized input", function()
      assert.equal("X-Role", utils.dasherize(utils.dasherize("X-role")))
    end)
  end)

  describe("get_header_ci()", function()
    it("matches a header name regardless of case", function()
      local h = { ["Cache-Control"] = "no-store" }
      assert.equal("no-store", utils.get_header_ci(h, "cache-control"))
      assert.equal("no-store", utils.get_header_ci(h, "CACHE-CONTROL"))
    end)

    it("returns nil for a missing header", function()
      assert.is_nil(utils.get_header_ci({ ["x-a"] = "1" }, "x-b"))
    end)

    it("returns nil when there are no headers", function()
      assert.is_nil(utils.get_header_ci(nil, "x-a"))
    end)
  end)

  describe("parse_cache_control()", function()
    it("returns the empty result for a nil header", function()
      local cc = utils.parse_cache_control(nil)
      assert.is_false(cc.no_store)
      assert.is_false(cc.no_cache)
    end)

    it("recognises no-store and no-cache", function()
      assert.is_true(utils.parse_cache_control("no-store").no_store)
      assert.is_true(utils.parse_cache_control("no-cache").no_cache)
    end)

    it("parses max-age into a number", function()
      assert.equal(30, utils.parse_cache_control("max-age=30").max_age)
    end)

    it("ignores surrounding whitespace and combines directives", function()
      local cc = utils.parse_cache_control(" no-cache , max-age=10 ")
      assert.is_true(cc.no_cache)
      assert.equal(10, cc.max_age)
    end)

    it("accepts resty's array-of-values form", function()
      local cc = utils.parse_cache_control({ "no-store", "max-age=5" })
      assert.is_true(cc.no_store)
      assert.equal(5, cc.max_age)
    end)
  end)
end)

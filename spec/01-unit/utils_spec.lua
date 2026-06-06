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
end)

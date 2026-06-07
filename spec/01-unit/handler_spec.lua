local mocks = require "spec.01-unit.support.mocks"

local function build()
  local calls = {}
  local fake_access = {
    execute = function(conf, version)
      calls[#calls + 1] = { conf = conf, version = version }
    end,
  }

  local handler = mocks.load_with("kong.plugins.the-middleman.handler", {
    kong = nil,
    ngx = nil,
    packages = {
      ["kong.plugins.the-middleman.access"] = fake_access,
    },
  })

  return handler, calls
end

describe("the-middleman handler", function()
  it("runs before the auth-style bundled plugins (priority 900)", function()
    local handler = build()
    assert.equal(900, handler.PRIORITY)
  end)

  it("reports a version that matches the rockspec", function()
    local handler = build()
    assert.equal("2.0.0", handler.VERSION)
  end)

  it("delegates :access() to access.execute with the conf and version", function()
    local handler, calls = build()
    local conf = { url = "http://x" }
    handler:access(conf)

    assert.equal(1, #calls)
    assert.equal(conf, calls[1].conf)
    assert.equal(handler.VERSION, calls[1].version)
  end)
end)

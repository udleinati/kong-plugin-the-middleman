local access = require "kong.plugins.the-middleman.access"
local TheMiddlemanHandler = {}

TheMiddlemanHandler.PRIORITY = 900
TheMiddlemanHandler.VERSION = "1.0.4"

function TheMiddlemanHandler:access(conf)
  access.execute(conf, TheMiddlemanHandler.VERSION)
end

return TheMiddlemanHandler

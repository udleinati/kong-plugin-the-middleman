local access = require "kong.plugins.the-middleman.access"
local TheMiddlemanHandler = {}

TheMiddlemanHandler.PRIORITY = 900
TheMiddlemanHandler.VERSION = "2.0.0"

function TheMiddlemanHandler:access(conf)
  access.execute(conf, TheMiddlemanHandler.VERSION)
end

return TheMiddlemanHandler

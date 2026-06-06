local typedefs = require "kong.db.schema.typedefs"
local redis_schema = require "kong.tools.redis.schema"

-- Map a legacy flat `redis_*` config value onto the shared `config.redis.*`
-- record. Keeps configs written for the pre-3.6 schema working.
local function redis_shorthand(field, extra)
  local def = {
    type = extra and extra.type or "string",
    func = function(value)
      return { redis = { [field] = value } }
    end,
  }
  if extra then
    def.referenceable = extra.referenceable
    def.len_min = extra.len_min
  end
  return { ["redis_" .. field] = def }
end

return {
  name = "the-middleman",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
      type = "record",
      fields = {
        { method = { type = "string", default = "POST", one_of = { "POST", "GET", }, }, },
        { url = typedefs.url({ required = true }) },
        { path = { type = "string", default = "/auth", }, },

        { connect_timeout = { type = "number", default = 5000, gt = 0, }, },
        { send_timeout = { type = "number", default = 10000, gt = 0, }, },
        { read_timeout = {  type = "number", default = 10000, gt = 0, }, },

        { forward_path = { type = "boolean", default = false, }, },
        { forward_query = { type = "boolean", default = false, }, },
        { forward_headers = { type = "boolean", default = false, }, },
        { forward_body = { type = "boolean", default = false, }, },

        { inject_body_response_into_header = { type = "boolean", default = true, }, },
        { injected_header_prefix = { type = "string", default = 'X-', }, },
        { streamdown_injected_headers = { type = "boolean", default = false, }, },

        { cache_enabled = { type = "boolean", default = false, }, },
        { cache_policy = { type = "string", default = "local", one_of = { "local", "redis" }, }, },
        { cache_based_on = { type = "string", default = "host", one_of = { "host", "host-path", "host-path-query", "header" }, }, },
        { cache_based_on_headers = { type = "string", default = "authorization", }, },
        { cache_invalidate_when_streamup_path = { type = "array", elements = { type = "string" } } },
        -- Must be a positive integer: the redis policy uses `SET ... EX <ttl>`,
        -- which rejects 0 / negative / fractional values.
        { cache_ttl = { type = "integer", default = 60, gt = 0, }, },

        -- Shared Kong Redis config record (Kong 3.6+): exposes config.redis.host,
        -- config.redis.port, config.redis.ssl, etc.
        { redis = redis_schema.config_schema },
      },
      -- Backwards compatibility: accept the legacy flat redis_* keys and fold
      -- them into the config.redis.* record above.
      shorthand_fields = {
        redis_shorthand("host"),
        redis_shorthand("port", { type = "integer" }),
        redis_shorthand("password", { referenceable = true, len_min = 0 }),
        redis_shorthand("username", { referenceable = true }),
        redis_shorthand("ssl", { type = "boolean" }),
        redis_shorthand("ssl_verify", { type = "boolean" }),
        redis_shorthand("server_name"),
        redis_shorthand("timeout", { type = "number" }),
        redis_shorthand("database", { type = "integer" }),
      },
    }, },
  },
  entity_checks = {
    { conditional = {
      if_field = "config.cache_policy", if_match = { eq = "redis" },
      then_field = "config.redis.host", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.cache_policy", if_match = { eq = "redis" },
      then_field = "config.redis.port", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.cache_policy", if_match = { eq = "redis" },
      then_field = "config.redis.timeout", then_match = { required = true },
    } },
  },
}

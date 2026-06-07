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
        -- When non-empty, restrict the forwarded client headers to these names
        -- (only applies when forward_headers is true). Empty = forward all.
        { forward_headers_allow = { type = "array", elements = { type = "string" }, default = {} }, },
        { forward_body = { type = "boolean", default = false, }, },

        { inject_body_response_into_header = { type = "boolean", default = true, }, },
        { injected_header_prefix = { type = "string", default = 'X-', }, },
        -- Middle-service RESPONSE headers to copy onto the upstream request
        -- (in addition to the JSON-body injection above).
        { forward_response_headers = { type = "array", elements = { type = "string" }, default = {} }, },
        { streamdown_injected_headers = { type = "boolean", default = false, }, },

        { cache_enabled = { type = "boolean", default = false, }, },
        { cache_policy = { type = "string", default = "local", one_of = { "local", "redis" }, }, },
        { cache_based_on = { type = "string", default = "host", one_of = { "host", "host-path", "host-path-query", "header" }, }, },
        { cache_based_on_headers = { type = "string", default = "authorization", }, },
        { cache_invalidate_when_streamup_path = { type = "array", elements = { type = "string" } } },
        -- Must be a positive integer: the redis policy uses `SET ... EX <ttl>`,
        -- which rejects 0 / negative / fractional values.
        { cache_ttl = { type = "integer", default = 60, gt = 0, }, },
        -- Which middle-service response codes are cacheable. Empty = the default
        -- (any non-error response, i.e. status < 400).
        { cache_response_codes = { type = "array", elements = { type = "integer", between = { 100, 599 } }, default = {} }, },
        -- How long (seconds) an entry is retained beyond cache_ttl so a stale copy
        -- can be served if the middle-service is unreachable. 0 disables this.
        { cache_storage_ttl = { type = "integer", default = 0, between = { 0, 2147483646 }, }, },
        -- Honour RFC7234 Cache-Control directives (no-store/no-cache/max-age) from
        -- the client request and the middle-service response.
        { cache_control = { type = "boolean", default = false, }, },

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

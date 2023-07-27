local typedefs = require "kong.db.schema.typedefs"

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

        { connect_timeout = { type = "number", default = 5000, }, },
        { send_timeout = { type = "number", default = 10000, }, },
        { read_timeout = {  type = "number", default = 10000, }, },

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
        { cache_ttl = { type = "number", default = 60, }, },

        { redis_host = typedefs.host },
        { redis_port = typedefs.port({ default = 6379 }), },
        { redis_password = { type = "string", len_min = 0, referenceable = true }, },
        { redis_username = { type = "string", referenceable = true }, },
        { redis_ssl = { type = "boolean", required = true, default = false, }, },
        { redis_ssl_verify = { type = "boolean", required = true, default = false }, },
        { redis_server_name = typedefs.sni },
        { redis_timeout = { type = "number", default = 2000, }, },
        { redis_database = { type = "integer", default = 0 }, },
      },
    }, },
  },
  entity_checks = {
    { conditional = {
      if_field = "config.cache_policy", if_match = { eq = "redis" },
      then_field = "config.redis_host", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.cache_policy", if_match = { eq = "redis" },
      then_field = "config.redis_port", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.cache_policy", if_match = { eq = "redis" },
      then_field = "config.redis_timeout", then_match = { required = true },
    } },
  },
}

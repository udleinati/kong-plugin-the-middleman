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
        { cache_based_on = { type = "string", default = "host", one_of = { "host", "host-path", "host-path-query", "header" }, }, },
        { cache_based_on_headers = { type = "string", default = "authorization", }, },
        { cache_ttl = { type = "number", default = 60, }, },
      },
    }, },
  }
}

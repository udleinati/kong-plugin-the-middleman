-- Pure helper functions for the-middleman.
-- Kept free of any `kong`/`ngx` dependency so they can be unit-tested in
-- isolation (see spec/01-unit/utils_spec.lua).

local str_gsub, str_upper, str_lower = string.gsub, string.upper, string.lower
local str_match, str_concat = string.match, table.concat

local _M = {}

-- Uppercase the first letter of a lowercase-leading word: "foo" -> "Foo"
function _M.capitalize(str)
  return (str_gsub(str, '^%l', str_upper))
end

-- Turn an arbitrary key into a dasherized / kebab-cased header segment:
--   "tenantId"   -> "Tenant-Id"
--   "X-user id"  -> "X-User-Id"
function _M.dasherize(str)
  local new_str = str_gsub(str, '(%l)(%u)', '%1-%2')
  new_str = str_gsub(new_str, '%W+', '-')
  new_str = str_lower(new_str)
  new_str = str_gsub(new_str, '[^-]+', _M.capitalize)
  return new_str
end

-- Case-insensitive lookup over a resty.http response-headers table.
function _M.get_header_ci(headers, name)
  if not headers then return nil end
  name = str_lower(name)
  for k, v in pairs(headers) do
    if str_lower(k) == name then
      return v
    end
  end
  return nil
end

-- The "no directives" Cache-Control result. Shared, read-only: callers must not
-- mutate it (it stands in for "Cache-Control handling disabled / header absent").
_M.EMPTY_CACHE_CONTROL = { no_store = false, no_cache = false }

-- Minimal RFC7234 parse for the Cache-Control directives we honour
-- (no-store / no-cache / max-age). Accepts a string or resty's array-of-values.
function _M.parse_cache_control(header)
  if not header then
    return _M.EMPTY_CACHE_CONTROL
  end
  if type(header) == "table" then
    header = str_concat(header, ",")
  end
  local cc = { no_store = false, no_cache = false, max_age = nil }
  for directive in header:gmatch("[^,]+") do
    directive = str_lower((str_gsub(directive, "%s", "")))
    if directive == "no-store" then
      cc.no_store = true
    elseif directive == "no-cache" then
      cc.no_cache = true
    else
      local age = str_match(directive, "^max%-age=(%d+)$")
      if age then
        cc.max_age = tonumber(age)
      end
    end
  end
  return cc
end

return _M

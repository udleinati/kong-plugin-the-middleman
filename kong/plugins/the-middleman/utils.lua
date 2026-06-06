-- Pure helper functions for the-middleman.
-- Kept free of any `kong`/`ngx` dependency so they can be unit-tested in
-- isolation (see spec/01-unit/utils_spec.lua).

local str_gsub, str_upper, str_lower = string.gsub, string.upper, string.lower

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

return _M

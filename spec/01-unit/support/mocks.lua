-- Lightweight mocks so the plugin's Lua modules can be unit-tested without a
-- running Kong / OpenResty. Each builder records the side effects we care about
-- (headers set, cache calls, logs) so specs can assert on them.

local M = {}

-- ---------------------------------------------------------------------------
-- ngx
-- ---------------------------------------------------------------------------
-- `md5` is wrapped so specs can assert on the *pre-hash* cache key content.
function M.fake_ngx()
  return {
    null = setmetatable({}, { __tostring = function() return "ngx.null" end }),
    md5 = function(str) return "md5(" .. tostring(str) .. ")" end,
  }
end

-- ---------------------------------------------------------------------------
-- kong PDK
-- ---------------------------------------------------------------------------
-- opts.request describes the incoming request:
--   host, path, path_with_query, query (table), headers (table),
--   header_values (table keyed by exact header name), body
function M.fake_kong(opts)
  opts = opts or {}
  local req = opts.request or {}

  local recorded = {
    upstream_headers = {}, -- kong.service.request.set_header
    response_headers = {},  -- kong.response.set_header
    invalidated = {},       -- kong.cache:invalidate
    logs = {},              -- kong.log.err
    exit = nil,             -- kong.response.exit args
  }

  local kong = {
    service = {
      request = {
        set_header = function(name, value)
          recorded.upstream_headers[name] = value
        end,
      },
    },
    response = {
      set_header = function(name, value)
        recorded.response_headers[name] = value
      end,
      exit = function(status, body, headers)
        recorded.exit = { status = status, body = body, headers = headers }
      end,
    },
    request = {
      get_host = function() return req.host or "example.com" end,
      get_path = function() return req.path or "/" end,
      get_path_with_query = function()
        return req.path_with_query or (req.path or "/")
      end,
      get_query = function() return req.query or {} end,
      get_headers = function() return req.headers or {} end,
      get_header = function(name) return (req.header_values or {})[name] end,
      get_body = function() return req.body end,
    },
    cache = {
      -- called as `kong.cache:invalidate(key)` (method syntax) in access.lua
      invalidate = function(_, key)
        recorded.invalidated[#recorded.invalidated + 1] = key
        return true
      end,
    },
    log = {
      err = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
          parts[i] = tostring(select(i, ...))
        end
        recorded.logs[#recorded.logs + 1] = table.concat(parts)
      end,
    },
  }

  return kong, recorded
end

-- ---------------------------------------------------------------------------
-- resty.http
-- ---------------------------------------------------------------------------
-- The returned client records every request_uri call in `client.requests` and
-- replies with whatever you assign to `client.response` / `client.err`.
function M.fake_http_module()
  local client = {
    timeouts = nil,
    requests = {},
    response = { status = 200, body = "{}", headers = {} },
    err = nil,
  }

  function client:set_timeouts(connect, send, read)
    self.timeouts = { connect = connect, send = send, read = read }
  end

  function client:request_uri(url, params)
    self.requests[#self.requests + 1] = { url = url, params = params }
    if self.err then
      return nil, self.err
    end
    return self.response
  end

  local module = { new = function() return client end }
  return module, client
end

-- ---------------------------------------------------------------------------
-- policies table (the cache backends)
-- ---------------------------------------------------------------------------
-- Records every probe/set/invalidate so specs can assert the cache flow.
-- `probe_return` controls what a probe yields (nil = MISS).
function M.fake_policies()
  local calls = { probe = {}, set = {}, invalidate = {} }
  local state = { probe_return = nil, probe_err = nil, probe_fill = nil }

  local policy = {
    probe = function(conf, key)
      calls.probe[#calls.probe + 1] = { conf = conf, key = key }
      if state.probe_err then
        return nil, state.probe_err
      end
      -- probe_fill simulates a peer filling the cache between the first probe
      -- and the re-probe taken under the stampede lock.
      if state.probe_fill ~= nil and #calls.probe > 1 then
        return state.probe_fill
      end
      return state.probe_return
    end,
    set = function(conf, key, value, opts)
      calls.set[#calls.set + 1] = { conf = conf, key = key, value = value, opts = opts }
      return value
    end,
    invalidate = function(conf, key)
      calls.invalidate[#calls.invalidate + 1] = { conf = conf, key = key }
      return true
    end,
  }

  -- Both policy names point at the same recorder for convenience.
  local policies = { ["local"] = policy, ["redis"] = policy }
  return policies, calls, state
end

-- ---------------------------------------------------------------------------
-- resty.lock
-- ---------------------------------------------------------------------------
-- Records lock/unlock calls. `opts.lock_fail` makes acquisition fail and
-- `opts.new_fail` makes construction fail, so specs can exercise fail-open.
function M.fake_lock(opts)
  opts = opts or {}
  local calls = { dict = nil, locked = {}, unlocked = 0 }

  local lock = {}
  function lock:lock(key)
    calls.locked[#calls.locked + 1] = key
    if opts.lock_fail then return nil, "timeout" end
    return 0
  end
  function lock:unlock()
    calls.unlocked = calls.unlocked + 1
    return 1
  end

  local module = {
    new = function(_, dict)
      calls.dict = dict
      if opts.new_fail then return nil, "no shared dict" end
      return lock
    end,
  }
  return module, calls
end

-- ---------------------------------------------------------------------------
-- Module loading with mocks installed
-- ---------------------------------------------------------------------------
-- Installs the given globals/package mocks and freshly loads the requested
-- module. The `kong` / `ngx` globals stay installed after returning because the
-- plugin's modules (like the official Kong policies) read them lazily at call
-- time rather than capturing them at load. Busted insulates each spec file, so
-- these fakes never leak into the integration suite; for safety, specs should
-- re-install via a fresh build per test.
function M.load_with(modpath, env)
  local prev_loaded = {}

  _G.kong = env.kong
  _G.ngx = env.ngx

  for name, mod in pairs(env.packages or {}) do
    prev_loaded[name] = package.loaded[name]
    package.loaded[name] = mod
  end

  -- force a fresh load of the module under test
  local prev_self = package.loaded[modpath]
  package.loaded[modpath] = nil

  local ok, result = pcall(require, modpath)

  -- keep the module-under-test unloaded so the next build re-requires it with
  -- its own mocks; restore unrelated package.loaded entries
  package.loaded[modpath] = prev_self
  for name, mod in pairs(prev_loaded) do
    package.loaded[name] = mod
  end

  if not ok then
    error(result)
  end

  return result
end

return M

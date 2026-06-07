-- The whole point of the Resolver seam: the cache-status state machine is
-- exercised here with plain Lua functions. No `kong`, no `ngx`, no `resty`, no
-- `package.loaded` monkeypatching -- the resolver only requires the (pure)
-- utils module, so it loads as-is. Compare with access_spec's 7-fake build().

local resolver = require "kong.plugins.the-middleman.resolver"

local NOW = 1000

-- A config carrying only the cache knobs resolve() reads.
local function conf(overrides)
  local c = {
    cache_ttl = 60,
    cache_storage_ttl = 0,
    cache_response_codes = {},
    cache_control = false,
  }
  for k, v in pairs(overrides or {}) do c[k] = v end
  return c
end

-- Cache entries relative to NOW.
local function fresh_entry() return { status = 200, body = '{"ok":1}', headers = {}, fresh_until = NOW + 100 } end
local function stale_entry() return { status = 200, body = '{"old":1}', headers = {}, fresh_until = NOW - 100 } end

-- A recording policy. `probe_seq` scripts successive probe() results by call
-- number (nil for any call past the end); `probe_err` makes the first probe fail.
local function fake_policy(opts)
  opts = opts or {}
  local calls = { probe = 0, set = {}, invalidate = {} }
  return {
    probe = function(_, key)
      calls.probe = calls.probe + 1
      if opts.probe_err and calls.probe == 1 then
        return nil, opts.probe_err
      end
      return opts.probe_seq and opts.probe_seq[calls.probe]
    end,
    set = function(_, key, value, o)
      calls.set[#calls.set + 1] = { key = key, value = value, opts = o }
    end,
    invalidate = function(_, key)
      calls.invalidate[#calls.invalidate + 1] = key
    end,
  }, calls
end

-- Drive one resolve() call with scripted dependencies.
local function run(opts)
  opts = opts or {}
  local policy, pcalls = fake_policy(opts)

  local fetch_calls = 0
  local fetch = function()
    fetch_calls = fetch_calls + 1
    if opts.fetch_err then return nil, opts.fetch_err end
    return opts.fetch_response or { status = 200, body = '{"fresh":1}', headers = {} }
  end

  local unlocks = 0
  local lock = function(_)
    if opts.lock_fail then return nil end
    return function() unlocks = unlocks + 1 end
  end

  local request = {
    cache_key = "k1",
    invalidate = opts.invalidate or false,
    skip_read = opts.skip_read or false,
    no_store = opts.no_store or false,
  }

  local response, status, err = resolver.resolve(conf(opts.conf), request, {
    policy = policy,
    fetch = fetch,
    lock = lock,
    now = function() return NOW end,
  })

  return {
    response = response, status = status, err = err,
    pcalls = pcalls,
    fetch_calls = fetch_calls,
    unlocks = unlocks,
  }
end

describe("resolver.resolve", function()

  it("HIT: a fresh entry is served without calling the middle-service", function()
    local fresh = fresh_entry()
    local r = run({ probe_seq = { fresh } })
    assert.equal("HIT", r.status)
    assert.equal(fresh, r.response)
    assert.equal(0, r.fetch_calls)
    assert.equal(0, #r.pcalls.set)
  end)

  it("MISS: no entry -> fetch once and store the fresh response", function()
    local r = run({ probe_seq = {} })
    assert.equal("MISS", r.status)
    assert.equal(1, r.fetch_calls)
    assert.equal(1, #r.pcalls.set)
    assert.equal("k1", r.pcalls.set[1].key)
  end)

  it("REFRESH: a stale entry plus a successful fetch revalidates", function()
    -- first probe stale; re-probe under the lock still finds nothing fresh.
    local r = run({ probe_seq = { stale_entry() } })
    assert.equal("REFRESH", r.status)
    assert.equal(1, r.fetch_calls)
    assert.equal(1, #r.pcalls.set)
  end)

  it("STALE: a stale entry is served when the fetch fails (serve-stale)", function()
    local stale = stale_entry()
    local r = run({ probe_seq = { stale }, fetch_err = "connection refused" })
    assert.equal("STALE", r.status)
    assert.equal(stale, r.response)
    assert.is_nil(r.err)
    assert.equal(0, #r.pcalls.set)   -- nothing new persisted on outage
    assert.equal(1, r.unlocks)       -- lock released even on the error path
  end)

  it("propagates the error when the fetch fails and there is no stale copy", function()
    local r = run({ probe_seq = {}, fetch_err = "connection refused" })
    assert.is_nil(r.response)
    assert.is_nil(r.status)
    assert.equal("connection refused", r.err)
    assert.equal(1, r.unlocks)
  end)

  it("BYPASS: skip_read forbids the read; fetch is made and labelled BYPASS", function()
    local r = run({ skip_read = true })
    assert.equal("BYPASS", r.status)
    assert.equal(1, r.fetch_calls)
    assert.equal(0, r.pcalls.probe)  -- the cache is never read
    assert.equal(1, #r.pcalls.set)   -- no-cache still allows storing
  end)

  it("fails open on a probe error: one fetch, no lock, no store", function()
    local r = run({ probe_err = "redis down" })
    assert.equal("MISS", r.status)
    assert.equal(1, r.fetch_calls)
    assert.equal(0, r.unlocks)       -- the lock branch is skipped entirely
    assert.equal(0, #r.pcalls.set)
  end)

  it("stampede: a peer refresh under the lock yields HIT with no fetch", function()
    -- first probe misses; the re-probe taken under the lock finds a fresh entry.
    local fresh = fresh_entry()
    local r = run({ probe_seq = { nil, fresh } })
    assert.equal("HIT", r.status)
    assert.equal(fresh, r.response)
    assert.equal(0, r.fetch_calls)   -- the peer already did the work
    assert.equal(2, r.pcalls.probe)  -- initial probe + re-probe under lock
    assert.equal(1, r.unlocks)
  end)

  it("invalidate: a fresh HIT still drops the entry and skips re-storing", function()
    local r = run({ probe_seq = { fresh_entry() }, invalidate = true })
    assert.equal("HIT", r.status)
    assert.equal(1, #r.pcalls.invalidate)
    assert.equal(0, r.fetch_calls)
  end)

  it("invalidate: a miss fetches, drops the entry, and does NOT store", function()
    local r = run({ probe_seq = {}, invalidate = true })
    assert.equal("MISS", r.status)
    assert.equal(1, r.fetch_calls)
    assert.equal(0, #r.pcalls.set)        -- invalidate wins over store
    assert.equal(1, #r.pcalls.invalidate)
  end)

  describe("cacheability", function()
    it("does not store a status outside cache_response_codes", function()
      local r = run({
        probe_seq = {},
        conf = { cache_response_codes = { 201 } },
        fetch_response = { status = 200, body = "{}", headers = {} },
      })
      assert.equal("MISS", r.status)
      assert.equal(0, #r.pcalls.set)
    end)

    it("stores a status listed in cache_response_codes", function()
      local r = run({
        probe_seq = {},
        conf = { cache_response_codes = { 200 } },
        fetch_response = { status = 200, body = "{}", headers = {} },
      })
      assert.equal(1, #r.pcalls.set)
    end)

    it("client no_store fetches but does not persist", function()
      local r = run({ skip_read = true, no_store = true })
      assert.equal("BYPASS", r.status)
      assert.equal(0, #r.pcalls.set)
    end)
  end)

  describe("serve-stale window", function()
    it("retains beyond cache_ttl when cache_storage_ttl is larger", function()
      local r = run({
        probe_seq = {},
        conf = { cache_ttl = 60, cache_storage_ttl = 600 },
      })
      assert.equal(600, r.pcalls.set[1].opts.ttl)
    end)

    it("stamps fresh_until at now + cache_ttl on the stored entry", function()
      local r = run({ probe_seq = {}, conf = { cache_ttl = 60 } })
      assert.equal(NOW + 60, r.pcalls.set[1].value.fresh_until)
    end)
  end)
end)

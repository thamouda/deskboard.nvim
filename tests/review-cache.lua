-- Persistent review snapshots only; all provider calls are mocked.
vim.opt.rtp:prepend(vim.fn.getcwd())
local views = require("deskboard.views")
local board = require("deskboard.board")
local sandbox = vim.fn.tempname() .. " review cache"
vim.fn.mkdir(sandbox, "p")
local cache_file = sandbox .. "/state/reviews.json"
local now, calls, passed = 1000, {}, 0
local function report(n)
  local rows = {}
  for i = 1, n do
    rows[i] = { iid = i, title = "Review " .. i, author = i % 2 == 0 and "alice" or "bob",
      project = "team/repo", web_url = "https://gitlab.example.invalid/team/repo/-/merge_requests/" .. i,
      target_branch = "main", commits = vim.NIL, approved = 2, my_approved = false, other_approvals = 2,
      ci = "success", threads = { resolved = 1, total = 2 }, my_threads = vim.NIL }
  end
  return { version = 1, ok = true, rows = rows, user = { username = "me" }, warnings = { "Commit counts unavailable" } }
end
local function new(opts)
  return views.new(vim.tbl_extend("force", {
    host = "gitlab.example.invalid", project = "team/repo", cache_file = cache_file,
    page_size = 2, now = function() return now end, changed = function() end,
    fetch = function(_, done) calls[#calls + 1] = done; return function() end end,
  }, opts or {}))
end
local function contents() return table.concat(vim.fn.readfile(cache_file), "\n") end
local function save(value) vim.fn.writefile({ vim.json.encode(value) }, cache_file) end
local function test(name, fn)
  calls = {}
  fn()
  passed = passed + 1
  print("PASS: " .. name)
end

local ok, err = xpcall(function()
  test("successful reviews persist privately and restore immediately without a network call", function()
    local state = new({ token_command = { "SECRET helper", "SECRET entry" } })
    assert(#state.rows == 0 and not state.fetched_at)
    state:refresh()
    local payload = report(5)
    payload.token, payload.user.token, payload.rows[1].description = "SECRET", "SECRET", "SECRET"
    payload.rows[1].threads.token = "SECRET"
    calls[1](payload)
    assert(not state.loading and not state.from_cache and state.fetched_at == now)
    assert(vim.uv.fs_stat(cache_file).mode % 512 == 384, "Review metadata should be private (0600)")
    assert(not contents():find("SECRET", 1, true), "Do not persist credentials or arbitrary response fields")
    state:set_author("alice")
    state:dispose()
    now = 1010
    local restored = new()
    assert(#calls == 1 and #restored.rows == 5 and restored.totals.reviews == 5)
    assert(restored.user.username == "me" and restored.fetched_at == 1000 and restored.from_cache)
    assert(not restored.author and restored.pages.reviews == 1, "Filters/pages belong to the buffer, not the snapshot")
    assert(restored.rows[1].commits == vim.NIL and restored.rows[1].my_threads == vim.NIL)
    assert(restored.warning == "Commit counts unavailable")
    local _, page, notice = board.render_reviews({ state = restored, width = 124 })
    assert(page.total == 5 and notice.text:find("cached", 1, true))
    restored:switch("reviews")
    assert(#calls == 2 and restored.loading and #restored.rows == 5, "First visit refreshes without clearing cached rows")
    calls[2](report(3))
    assert(not restored.from_cache and #restored.rows == 3 and restored.fetched_at == 1010)
    restored:dispose()
  end)

  test("GitLab failures and invalid reports never replace the last successful snapshot", function()
    local previous = contents()
    local state = new()
    state:refresh(); calls[1](nil, "GitLab authentication failed (HTTP 401)")
    assert(#state.rows == 3 and state.fetched_at == 1010 and contents() == previous)
    local _, _, notice = board.render_reviews({ state = state, width = 124 })
    assert(notice.text:find("Sign-in needed", 1, true) and notice.text:find("cached", 1, true))
    state:refresh()
    local malformed = report(1); malformed.rows[1].threads = { resolved = 3, total = 1 }
    calls[2](malformed)
    assert(state.error and #state.rows == 3 and contents() == previous)
    state:dispose()
    assert(#new().rows == 3, "The offline list must survive another restart")
  end)

  test("a successful empty queue replaces cached assignments across restarts", function()
    local state = new()
    now = 1020
    state:refresh(); calls[1](report(0)); state:dispose()
    local restored = new()
    assert(#restored.rows == 0 and restored.fetched_at == 1020 and restored.user.username == "me")
    local _, _, notice = board.render_reviews({ state = restored, width = 124 })
    assert(notice.text:find("cached", 1, true), "An empty successful snapshot is still a cached snapshot")
  end)

  test("cached queues never leak between GitLab hosts/projects or disabled providers", function()
    assert(#new({ host = "other.example.invalid" }).rows == 0)
    assert(not new({ project = "other/repo" }).fetched_at)
    -- Without a fetch override, disabled providers must not even load metadata.
    local reads, readfile = 0, vim.fn.readfile
    vim.fn.readfile = function(...) reads = reads + 1; return readfile(...) end
    local disabled = views.new({ host = "gitlab.example.invalid", project = "team/repo",
      cache_file = cache_file, changed = function() end })
    vim.fn.readfile = readfile
    assert(not disabled.fetched_at and not disabled:refresh() and reads == 0)
  end)

  test("missing, corrupt, invalid and incompatible snapshots are ignored safely", function()
    local valid = vim.json.decode(contents())
    local variants = {
      { version = 999 }, { fetched_at = 0 }, { fetched_at = "yesterday" },
      { ok = false }, { user = {} }, { rows = { "invalid row" } },
      { rows = { { iid = 0 } } }, { rows = { report(1).rows[1] } },
    }
    variants[#variants].rows[1].commits = -1
    for _, changes in ipairs(variants) do
      save(vim.tbl_extend("force", valid, changes))
      local state = new()
      assert(#state.rows == 0 and not state.fetched_at and not state.error)
    end
    vim.fn.writefile({ "{broken json" }, cache_file)
    assert(not new().fetched_at)
    assert(not new({ cache_file = sandbox .. "/missing.json" }).fetched_at)
    save(valid)
  end)

  test("failed atomic writes preserve disk cache without invalidating live results", function()
    local previous = contents()
    local state = new()
    state:refresh()
    local fs_write = vim.uv.fs_write
    vim.uv.fs_write = function() return nil, "fixture write failure" end
    calls[1](report(2))
    vim.uv.fs_write = fs_write
    assert(#state.rows == 2 and not state.error and not state.from_cache)
    assert(contents() == previous and #new().rows == 0)
    assert(#vim.fn.glob(sandbox .. "/state/.reviews-*", false, true) == 0, "Clean up failed temporary writes")
    local blocked = new({ cache_file = sandbox .. "/state" })
    blocked:refresh(); calls[2](report(1))
    assert(#blocked.rows == 1 and not blocked.error, "An unwritable cache must not turn refresh into failure")
    assert(contents() == previous)
  end)

  test("disposed requests cannot overwrite persistent snapshots", function()
    local previous = contents()
    local state = new()
    state:refresh(); state:dispose(); calls[1](report(4))
    assert(contents() == previous and #state.rows == 0)
  end)
end, debug.traceback)
vim.fn.delete(sandbox, "rf")
assert(ok, err)
print(string.format("%d persistent review cache tests passed", passed))

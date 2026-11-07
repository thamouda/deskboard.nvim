-- GitHub UI/preview/cache routing; no real gh, Jira or GitLab requests.
vim.opt.rtp:prepend(vim.fn.getcwd())
local views, board, preview = require("deskboard.views"), require("deskboard.board"), require("deskboard.preview")
local sandbox = vim.fn.tempname() .. " github fixture"
vim.fn.mkdir(sandbox, "p")
require("deskboard.config").set({ providers = { github = { enabled = true, project = "team/repo",
  cache_file = sandbox .. "/reviews.json", issues_cache_file = sandbox .. "/issues.json" } } })
local count = 0
local function test(name, fn) fn(); count = count + 1; print("PASS: " .. name) end
local function report()
  return { version = 1, ok = true, user = { username = "me" }, rows = {
    { iid = 12, title = string.rep("長い title ", 15), author = "other", project = "team/repo", state = "open", labels = "bug, feature",
      target_branch = "main", web_url = "https://github.com/team/repo/issues/12", commits = vim.NIL, my_approved = vim.NIL },
  } }
end
local function text(item)
  if type(item.text) == "string" then return item.text end
  local result = {}; for _, part in ipairs(item.text or {}) do result[#result + 1] = part[1] end
  return table.concat(result)
end
local ok, err = xpcall(function()
  test("GitHub queues select the correct backend kind and never pass GitLab credentials", function()
    for _, kind in ipairs({ "issues", "reviews" }) do
      local command, callback, result
      views.fetch({ provider = "github", kind = kind, host = "github.com", project = "team/repo", token_command = { "SECRET" },
        run = function(cmd, opts, done) command, callback = cmd, done; assert(opts.timeout == 90000); return { kill = function() end } end },
        function(value) result = value end)
      assert(command[2]:match("github%-sync%.py$") and command[3] == "--kind" and command[4] == kind)
      assert(not table.concat(command, " "):find("SECRET", 1, true))
      callback({ code = 0, stdout = vim.json.encode(report()) })
      assert(vim.wait(100, function() return result ~= nil end) and #result.rows == 1)
    end
  end)
  test("GitHub issues paginate and retain only read-only issue actions at all widths", function()
    local state = views.new({ provider = "github", enabled = true, host = "github.com", project = "team/repo",
      issues_config = { provider = "github", enabled = true, host = "github.com", project = "team/repo" } })
    state.issues:set_report(report(), os.time(), true)
    for _, width in ipairs({ 16, 24, 60, 124 }) do
      local opened
      local frame = board.frame({ width = width, page_size = state.size })
      local items, page, notice = board.render_issues({ state = state, width = width, frame = frame, on_open = function(url) opened = url end })
      assert(page.total == 1 and notice.text:find("cached", 1, true))
      assert(#items == #board.render_reviews({ state = state, width = width, frame = frame }))
      local issue
      for _, item in ipairs(items) do
        assert(vim.fn.strdisplaywidth(text(item)) <= width)
        if item.issue_number then issue = item end
      end
      assert(issue and issue.provider == "github" and issue.project == "team/repo" and issue.issue_number == "12")
      assert(not issue.ticket and not issue.mr_iid and not issue.review, "GitHub issues must not enable Jira or checkout actions")
      issue.action(); assert(opened == report().rows[1].web_url)
    end
  end)
  test("review rows use PR numbers and preserve GitHub provider identity", function()
    local state = views.new({ provider = "github" })
    state:set_report(report(), os.time(), false)
    local items = board.render_reviews({ state = state, width = 124 })
    for _, item in ipairs(items) do
      if item.review then
        assert(item.provider == "github" and item.mr_iid == "12" and not item.ticket)
        assert(item.id == "github:team/repo#12" and text(item):find("#12", 1, true))
      end
    end
  end)
  test("disk caches cannot be shared across providers or issue/review kinds", function()
    local opts = { provider = "github", kind = "issues", enabled = true, host = "github.com", project = "team/repo", cache_file = sandbox .. "/shared.json" }
    local state = views.new(opts); state:set_report(report(), os.time(), false); state:save_cache()
    assert(#views.new(opts).rows == 1)
    assert(#views.new(vim.tbl_extend("force", opts, { kind = "reviews" })).rows == 0)
    assert(#views.new(vim.tbl_extend("force", opts, { provider = "gitlab" })).rows == 0)
  end)
  test("issue and PR previews call only bounded gh GET requests and preserve Markdown", function()
    for _, issue in ipairs({ true, false }) do
      local callback, command, result, killed
      local opts = { provider = "github", host = "github.com", project = "team/repo", issue_number = issue and "12" or nil,
        mr_iid = not issue and "12" or nil, run = function(cmd, options, done)
          callback, command = done, cmd; assert(options.timeout == 15000 and options.text)
          return { kill = function() killed = true end }
        end }
      local cancel = preview.fetch(opts, function(value) result = value end)
      assert(command[1] == "gh" and command[6] == "GET" and command[7] == "repos/team/repo/" .. (issue and "issues" or "pulls") .. "/12")
      callback({ code = 0, stdout = vim.json.encode({ number = 12, title = "Details", state = "open", body = "**Markdown**\n```lua\nreturn true\n```" }) })
      assert(vim.wait(100, function() return result ~= nil end))
      local lines = table.concat(preview.lines(result, opts), "\n")
      assert(lines:find(issue and "GitHub Issue" or "GitHub Pull Request", 1, true) and lines:find("return true", 1, true))
      assert(not lines:find("Jira", 1, true) and not lines:find("Merge Request Details", 1, true))
      cancel(); assert(killed)
    end
  end)
  test("GitHub preview failures hide raw output and reject wrong item identities", function()
    local callback, result
    local opts = { provider = "github", host = "github.com", project = "team/repo", issue_number = "12",
      run = function(_, _, done) callback = done; return { kill = function() end } end }
    preview.fetch(opts, function(value) result = value end)
    callback({ code = 1, stdout = "SECRET", stderr = "401 SECRET" })
    assert(vim.wait(100, function() return result ~= nil end))
    assert(result.errors[1]:find("401", 1, true) and not table.concat(preview.lines(result, opts), "\n"):find("SECRET", 1, true))
    result = nil
    preview.fetch(opts, function(value) result = value end)
    callback({ code = 0, stdout = vim.json.encode({ number = 13, title = "Wrong issue", state = "open" }) })
    assert(vim.wait(100, function() return result ~= nil end) and not result.github and #result.errors == 1)
  end)
  test("popup preview caching distinguishes an issue from a PR with the same number", function()
    local calls = 0
    local owner = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win() }
    local pane = preview.attach(owner, { provider = "github", host = "github.com", project = "team/repo", glow = false,
      run = function(command, _, done)
        calls = calls + 1
        done({ code = 0, stdout = vim.json.encode({ number = 12, title = command[7], state = "open", body = "body" }) })
        return { kill = function() end }
      end })
    pane:show({ provider = "github", project = "team/repo", issue_number = "12" })
    assert(vim.wait(500, function() return calls == 1 and not pane.loading end))
    assert(table.concat(vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false), "\n"):find("GitHub Issue", 1, true))
    pane:show({ provider = "github", mr_project = "team/repo", mr_iid = "12" })
    assert(vim.wait(500, function() return calls == 2 and not pane.loading end))
    pane:show({ provider = "github", project = "team/repo", issue_number = "12" })
    assert(calls == 2)
    pane:close()
  end)
end, debug.traceback)
preview.dispose()
vim.fn.delete(sandbox, "rf")
assert(ok, err)
print(string.format("%d GitHub UI/preview/cache tests passed", count))

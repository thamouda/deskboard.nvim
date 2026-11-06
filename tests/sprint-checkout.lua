dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/sprint-checkout.lua
-- Uses disposable Git repositories only; never touches a user's real worktree.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
local checkout = require("workbench.checkout")
local root = vim.fn.tempname() .. " sprint checkout"
local messages, count = {}, 0
vim.notify = function(message)
  messages[#messages + 1] = message
end

local function git(repo, ...)
  local cmd = { "git", "-C", repo }
  vim.list_extend(cmd, { ... })
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, table.concat(cmd, " ") .. "\n" .. (result.stderr or ""))
  return vim.trim(result.stdout)
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function fixture(branches)
  count = count + 1
  local repo = root .. "/repo " .. count
  vim.fn.mkdir(repo, "p")
  git(repo, "init", "--quiet", "--initial-branch=previous")
  git(repo, "config", "user.name", "Sprint Test")
  git(repo, "config", "user.email", "sprint@example.invalid")
  write(repo .. "/tracked", { "initial" })
  git(repo, "add", ".")
  git(repo, "commit", "--quiet", "-m", "initial")
  for _, branch in ipairs(branches or { "feature/TEST-42_example" }) do
    git(repo, "branch", branch)
  end
  return repo
end

local function run(repo, ticket, select)
  messages = {}
  local done, refreshed
  local original = vim.ui.select
  vim.ui.select = select or function()
    error("Unexpected branch picker")
  end
  checkout.checkout(ticket or "TEST-42", {
    repo = repo,
    on_done = function(ok) done = ok end,
    on_success = function() refreshed = true end,
  })
  local finished = vim.wait(15000, function() return done ~= nil end, 10)
  vim.ui.select = original
  assert(finished, "Checkout did not finish")
  return done, refreshed
end

local function has_message(text)
  return table.concat(messages, "\n"):find(text, 1, true) ~= nil
end

local function test(name, fn)
  fn()
  print("PASS: " .. name)
end

local ok, err = xpcall(function()
  test("clean checkout, already-current no-op, dashboard refresh", function()
    local repo = fixture()
    local switched, refreshed = run(repo)
    assert(switched and refreshed)
    assert(git(repo, "branch", "--show-current") == "feature/TEST-42_example")
    assert(git(repo, "stash", "list") == "")
    assert(run(repo))
    assert(has_message("Already on"))
    assert(git(repo, "stash", "list") == "")
  end)

  test("staged, unstaged and untracked changes stashed under previous branch", function()
    local repo = fixture()
    write(repo .. "/tracked", { "staged" })
    git(repo, "add", "tracked")
    write(repo .. "/tracked", { "unstaged" })
    write(repo .. "/new file", { "untracked" })
    assert(run(repo))
    assert(git(repo, "status", "--porcelain") == "")
    assert(git(repo, "stash", "list"):find("[wip] previous — sprint board checkout", 1, true))
    assert(git(repo, "show", "stash@{0}:tracked") == "unstaged")
    assert(git(repo, "show", "stash@{0}^2:tracked") == "staged")
    assert(git(repo, "show", "stash@{0}^3:new file") == "untracked")
    assert(has_message("Saving changes from previous"))
    assert(has_message("not applied"))
  end)

  test("ticket boundaries and local/remote deduplication", function()
    local repo = fixture({ "feature/TEST-420_wrong", "feature/TEST-42_right", "feature/TEST-42abc_wrong" })
    git(repo, "update-ref", "refs/remotes/origin/feature/TEST-42_right", "HEAD")
    assert(run(repo))
    assert(git(repo, "branch", "--show-current") == "feature/TEST-42_right")
  end)

  test("remote-only branch creates a tracking branch without fetching", function()
    local repo = fixture({})
    git(repo, "remote", "add", "origin", "https://example.invalid/repo.git")
    git(repo, "update-ref", "refs/remotes/origin/feature/TEST-42_remote", "HEAD")
    assert(run(repo))
    assert(git(repo, "branch", "--show-current") == "feature/TEST-42_remote")
    assert(git(repo, "rev-parse", "--abbrev-ref", "@{upstream}") == "origin/feature/TEST-42_remote")
  end)

  test("multiple branches prompt; cancellation leaves changes alone", function()
    local repo = fixture({ "feature/TEST-42_a", "fix/TEST-42_b" })
    write(repo .. "/tracked", { "dirty" })
    assert(not run(repo, nil, function(items, _, done)
      assert(#items == 2)
      done(nil)
    end))
    assert(git(repo, "branch", "--show-current") == "previous")
    assert(git(repo, "stash", "list") == "")
    assert(run(repo, nil, function(items, _, done) done(items[2]) end))
    assert(git(repo, "branch", "--show-current") == "fix/TEST-42_b")
  end)

  test("missing branch never stashes", function()
    local repo = fixture({ "feature/TEST-420_other" })
    write(repo .. "/tracked", { "dirty" })
    assert(not run(repo))
    assert(has_message("No local or fetched remote branch"))
    assert(git(repo, "stash", "list") == "")
    assert(git(repo, "branch", "--show-current") == "previous")
  end)

  test("unsaved buffers prevent checkout and stashing", function()
    local repo = fixture()
    local buf = vim.fn.bufadd(repo .. "/tracked")
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    assert(not run(repo))
    assert(has_message("unsaved buffer"))
    assert(git(repo, "branch", "--show-current") == "previous")
    assert(git(repo, "stash", "list") == "")
    assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  test("stash failure prevents switching and preserves disk changes", function()
    local repo = fixture()
    write(repo .. "/tracked", { "dirty" })
    write(repo .. "/.git/index.lock", { "" })
    assert(not run(repo))
    vim.fn.delete(repo .. "/.git/index.lock")
    assert(git(repo, "branch", "--show-current") == "previous")
    assert(vim.fn.readfile(repo .. "/tracked")[1] == "dirty")
    assert(git(repo, "stash", "list") == "")
  end)

  test("checkout failure keeps the named stash and reports recovery", function()
    local repo = fixture()
    git(repo, "worktree", "add", "--quiet", root .. "/other worktree", "feature/TEST-42_example")
    write(repo .. "/tracked", { "safe in stash" })
    assert(not run(repo))
    assert(git(repo, "branch", "--show-current") == "previous")
    assert(git(repo, "show", "stash@{0}:tracked") == "safe in stash")
    assert(has_message("changes remain safe in stash"))
  end)

  test("detached HEAD stash uses its previous commit", function()
    local repo = fixture()
    git(repo, "switch", "--detach", "HEAD")
    write(repo .. "/tracked", { "detached changes" })
    assert(run(repo))
    assert(git(repo, "stash", "list"):find("[wip] detached-", 1, true))
  end)

  test("repeat Enter is guarded while checkout is running", function()
    local repo = fixture()
    local done
    checkout.checkout("TEST-42", { repo = repo, on_done = function(result) done = result end })
    checkout.checkout("TEST-42", { repo = repo })
    assert(has_message("already in progress"))
    assert(vim.wait(15000, function() return done ~= nil end, 10))
    assert(done)
  end)

  test("dashboard ticket action checks out; o still opens Jira", function()
    local reminder = root .. "/reminder.md"
    write(reminder, { "- [ ] TEST-42|In Progress|Task|1d|–|–" })
    local open, systemlist, jobstart = io.open, vim.fn.systemlist, vim.fn.jobstart
    local snacks, lazyvim_config = _G.Snacks, package.loaded["lazyvim.config"]
    package.loaded["lazyvim.config"] = { icons = { kinds = {} } }
    local selected, opened, refreshed
    io.open = function(path, mode)
      return open(path == require("workbench.config").get().reminders.path and reminder or path, mode)
    end
    vim.fn.systemlist = function() return { "previous" } end
    vim.fn.jobstart = function(cmd) opened = cmd end
    _G.Snacks = { dashboard = { update = function() refreshed = true end } }
    package.loaded["workbench.checkout"] = {
      checkout = function(ticket, opts)
        selected = ticket
        assert(opts.repo == require("workbench.config").get().actions.repo)
        opts.on_success()
      end,
    }
    local integrated, integration_err = xpcall(function()
      local sections = require("workbench.adapter").sections
      assert(sections)
      local self = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win() }
      local items = sections(self)
      local ticket_item
      for _, item in ipairs(items) do
        if item.ticket == "TEST-42" then ticket_item = item end
      end
      assert(ticket_item and ticket_item.action)
      ticket_item.action()
      assert(selected == "TEST-42" and refreshed)
      self.find = function() return ticket_item end
      vim.fn.maparg("o", "n", false, true).callback()
      assert(vim.deep_equal(opened, { "jira", "open", "TEST-42" }))
      assert(vim.fn.maparg("K", "n", false, true).desc == "Preview ticket and MR")
      assert(vim.fn.maparg("P", "n", false, true).desc == "Toggle sprint preview")
      assert(vim.fn.maparg("R", "n", false, true).desc == "Refresh sprint board")
      -- First render has no selected ticket yet. Header items have positions
      -- but no ticket; restoring selection must never try string.find(nil).
      self.items = { { _ = { row = 1, col = 0 } }, ticket_item }
      self.lines = { "Header" }
      self._sprint_selected = nil
      local previous_error = vim.v.errmsg
      vim.api.nvim_exec_autocmds("User", { pattern = "SnacksDashboardUpdatePost" })
      vim.wait(20, function() return false end, 5)
      assert(vim.v.errmsg == previous_error, vim.v.errmsg)
      assert(self._sprint_selected == "TEST-42")
    end, debug.traceback)
    io.open, vim.fn.systemlist, vim.fn.jobstart = open, systemlist, jobstart
    _G.Snacks = snacks
    package.loaded["lazyvim.config"] = lazyvim_config
    package.loaded["workbench.checkout"] = checkout
    assert(integrated, integration_err)
  end)
end, debug.traceback)
vim.fn.delete(root, "rf")
assert(ok, err)
print("All sprint checkout tests passed")

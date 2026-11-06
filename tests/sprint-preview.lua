dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/sprint-preview.lua
-- Mocked Jira/GitLab responses only; uses real scratch buffers/windows.
vim.opt.rtp:prepend(vim.fn.getcwd())
local preview = require("deskboard.preview")
local count = 0
vim.notify = function() end
local function test(name, fn)
  fn()
  count = count + 1
  print("PASS: " .. name)
end
local jira = {
  key = "TEST-42",
  fields = {
    summary = "Fix review board",
    status = { name = "To review" },
    assignee = { displayName = "Reviewer" },
    description = "Ticket description",
  },
}
local mr = {
  iid = 502,
  title = "Improve the board",
  state = "opened",
  draft = false,
  source_branch = "feature/TEST-42",
  target_branch = "main",
  changes_count = "12",
  description = "MR description",
  head_pipeline = { id = 100, status = "success" },
}
local approvals = { approved_by = { { user = { name = "Alice" } } }, approvals_left = 1 }

local function harness(overrides)
  local calls, result, completed = {}, nil, 0
  local opts = vim.tbl_extend("force", {
    ticket = "TEST-42",
    mr_iid = "502",
    host = "gitlab.example.invalid",
    project = "team/repo",
    now = function()
      return 1000
    end,
    run = function(cmd, options, done)
      local call = { cmd = cmd, options = options, done = done, killed = false }
      calls[#calls + 1] = call
      return {
        kill = function()
          call.killed = true
        end,
      }
    end,
  }, overrides or {})
  local cancel = preview.fetch(opts, function(data)
    result = data
    completed = completed + 1
  end)
  return {
    calls = calls,
    opts = opts,
    cancel = cancel,
    result = function()
      return result
    end,
    completed = function()
      return completed
    end,
    respond = function(index, value, code, stderr)
      calls[index].done({
        code = code or 0,
        stdout = type(value) == "string" and value or vim.json.encode(value),
        stderr = stderr,
      })
      vim.wait(20, function()
        return false
      end, 5)
    end,
  }
end

local function output(data, opts)
  return table.concat(
    preview.lines(data, opts or {
      ticket = "TEST-42",
      mr_iid = "502",
      now = function()
        return 1000
      end,
    }),
    "\n"
  )
end

test("parallel read-only requests use exact host/project, timeouts, and argv", function()
  local h = harness()
  assert(#h.calls == 3)
  assert(vim.deep_equal(h.calls[1].cmd, { "jira", "issue", "view", "TEST-42", "--raw" }))
  assert(
    vim.deep_equal(
      h.calls[2].cmd,
      { "glab", "api", "--hostname", "gitlab.example.invalid", "-X", "GET", "projects/team%2Frepo/merge_requests/502" }
    )
  )
  assert(h.calls[3].cmd[7]:find("/approvals", 1, true))
  for _, call in ipairs(h.calls) do
    assert(call.options.timeout == 15000)
  end
  h.respond(3, approvals)
  h.respond(1, jira)
  assert(not h.result())
  h.respond(2, mr)
  assert(h.completed() == 1)
  local text = output(h.result())
  for _, value in ipairs({
    "Fix review board",
    "Ticket description",
    "MR description",
    "Changed files: 12",
    "Pipeline: success (#100)",
    "Approved by: Alice",
    "Approvals still required: 1",
  }) do
    assert(text:find(value, 1, true), value)
  end
end)

test("tickets without MRs only request Jira", function()
  local h = harness({ mr_iid = false })
  assert(#h.calls == 1)
  h.respond(1, jira)
  assert(output(h.result(), {
    ticket = "TEST-42",
    now = function()
      return 1000
    end,
  }):find("No related MR", 1, true))
end)

test("partial failure preserves Jira and never invents approval or pipeline success", function()
  local h = harness()
  h.respond(1, jira)
  h.respond(2, "private secret should not be displayed", 1)
  h.respond(3, "{}", 124)
  local text = output(h.result())
  assert(text:find("Fix review board", 1, true))
  assert(text:find("partial data", 1, true))
  assert(text:find("request timed out", 1, true))
  assert(text:find("Approvals: unavailable", 1, true))
  assert(text:find("Pipeline: unavailable", 1, true))
  assert(not text:find("private secret", 1, true))
end)

test("missing CLIs, malformed JSON and wrong ticket responses are safe", function()
  local h = harness({
    run = function()
      error("CLI missing")
    end,
  })
  assert(h.completed() == 1 and #h.result().errors == 3)
  assert(output(h.result()):find("Ticket details unavailable", 1, true))
  local bad = harness()
  bad.respond(1, { key = "TEST-99", fields = {} })
  bad.respond(2, "not json")
  bad.respond(3, "null")
  assert(#bad.result().errors == 3)
end)

test("cancellation kills all jobs and ignores late responses", function()
  local h = harness()
  h.cancel()
  for i, call in ipairs(h.calls) do
    assert(call.killed)
    h.respond(i, {})
  end
  assert(h.completed() == 0)
end)

test("ADF descriptions, null fields and long descriptions render safely", function()
  local data = {
    fetched_at = 1000,
    errors = {},
    jira = {
      fields = {
        summary = "A\nsummary",
        assignee = vim.NIL,
        description = {
          type = "doc",
          content = { { type = "paragraph", content = { { type = "text", text = "ADF text" } } } },
        },
      },
    },
    mr = { head_pipeline = vim.NIL },
  }
  local text = output(data)
  assert(text:find("A summary", 1, true) and text:find("ADF text", 1, true))
  data.jira.fields.description = string.rep("line\n", 250)
  assert(output(data):find("description truncated", 1, true))
end)

test("truncated Jira code cannot consume Merge Request Details", function()
  local ticket = vim.deepcopy(jira)
  ticket.fields.description = "{code:perl}\n" .. string.rep("    print 1;\n", 300) .. "{code}"
  local data = { jira = ticket, mr = mr, approvals = approvals, errors = {}, fetched_at = 1000 }
  local value = output(data)
  local mr_start = assert(value:find("## Merge Request Details", 1, true))
  local ticket_text = value:sub(1, mr_start - 1)
  assert(ticket_text:find("**PERL**", 1, true))
  assert(ticket_text:find("description truncated", 1, true))
  local fences = 0
  for line in ticket_text:gmatch("[^\n]+") do
    if line:match("^```") then
      fences = fences + 1
    end
  end
  assert(fences == 2, "The code fence must close before MR metadata")
  assert(value:sub(mr_start):find("MR description", 1, true))
  assert(value:sub(mr_start):find("Pipeline: success", 1, true))
end)

test("Jira 401 is actionable, retains cached status, and never exposes raw errors", function()
  local h = harness({ jira_status = "To review" })
  h.respond(1, "", 1, "Login Required: HTTP 401 private-credential")
  h.respond(2, mr)
  h.respond(3, approvals)
  local value = output(h.result(), h.opts)
  assert(value:find("Status: To review (cached board value)", 1, true))
  assert(value:find("Assignee: Unavailable", 1, true))
  assert(value:find("Description unavailable", 1, true))
  assert(value:find("authentication failed (HTTP 401)", 1, true))
  assert(value:find("JIRA_API_TOKEN", 1, true))
  assert(not value:find("private-credential", 1, true))
  assert(value:find("Pipeline: success", 1, true))
end)

test("Ticket Details and Merge Request Details are separated Markdown sections", function()
  local h = harness()
  h.respond(1, jira)
  h.respond(2, mr)
  h.respond(3, approvals)
  local value = output(h.result())
  local ticket_start = assert(value:find("## Ticket Details", 1, true))
  local mr_start = assert(value:find("## Merge Request Details", 1, true))
  assert(ticket_start < mr_start)
  local ticket_text = value:sub(ticket_start, mr_start - 1)
  assert(ticket_text:find("- Status: To review\n- Assignee: Reviewer", 1, true))
  assert(ticket_text:find("Ticket description", 1, true))
  assert(ticket_text:find("\n---\n", 1, true))
  assert(value:sub(mr_start):find("MR description", 1, true))
end)

test("readiness and approver counts match the shared backend contract", function()
  local contract = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/sprint-review-state.json"), "\n"))
  for _, case in ipairs(contract.readiness) do
    local detail = vim.tbl_extend("force", {}, contract.base, case.mr)
    assert(preview.merge_readiness(detail, case.approvals) == case.expected, case.name)
  end
  for _, case in ipairs(contract.approval_counts) do
    local expected = case.expected
    if expected == vim.NIL then
      expected = nil
    end
    assert(preview.approved_count(case.data) == expected, case.name)
  end
end)

test("preview shows actual approval count, readiness and full merged source/target", function()
  local detail = vim.deepcopy(mr)
  detail.state, detail.detailed_merge_status = "opened", "mergeable"
  local policy =
    { approved_by = { { user = { id = 1, name = "Alice" } }, { user = { id = 2, name = "Bob" } } }, approvals_left = 0 }
  local data = { jira = jira, mr = detail, approvals = policy, errors = {}, fetched_at = 1000 }
  local value = output(data)
  assert(value:find("Approvals received: 2", 1, true))
  assert(value:find("Ready to merge: yes", 1, true))
  assert(value:find("Merged into: not merged", 1, true))
  detail.state, detail.detailed_merge_status = "merged", "not_open"
  detail.source_branch, detail.target_branch =
    "feature/TEST-42_fix", "feature/TEST-1824_dynamic_datasource_entry_set_relations"
  detail.merged_at = "2026-11-05T10:00:00Z"
  value = output(data)
  assert(value:find("Ready to merge: already merged", 1, true))
  assert(value:find("Branch: " .. detail.source_branch .. " → " .. detail.target_branch, 1, true))
  assert(value:find("Merged into: " .. detail.target_branch, 1, true))
  assert(value:find("Merged at: " .. detail.merged_at, 1, true))
end)

test("credential helper is bounded, in-memory cached, and never rendered", function()
  local executable = vim.fn.executable
  local original = { vim.env.GITLAB_TOKEN, vim.env.GITLAB_ACCESS_TOKEN, vim.env.GLAB_TOKEN }
  vim.env.GITLAB_TOKEN, vim.env.GITLAB_ACCESS_TOKEN, vim.env.GLAB_TOKEN = nil, nil, nil
  vim.fn.executable = function(cmd)
    return cmd == "fake-token-helper" and 1 or executable(cmd)
  end
  local ok, err = xpcall(function()
    local h = harness({ token_command = { "fake-token-helper", "test-key" }, proxy = "http://proxy.invalid:3128" })
    assert(#h.calls == 2 and h.calls[2].options.timeout == 5000)
    h.respond(2, "test-only-token\n")
    assert(#h.calls == 4)
    assert(h.calls[3].options.env.GITLAB_TOKEN == "test-only-token")
    assert(h.calls[3].options.env.https_proxy == "http://proxy.invalid:3128")
    h.respond(1, jira)
    h.respond(3, mr)
    h.respond(4, approvals)
    assert(not output(h.result()):find("test-only-token", 1, true))
    local cached = harness({ token_command = { "fake-token-helper", "test-key" } })
    assert(#cached.calls == 3 and cached.calls[2].cmd[1] == "glab")
    cached.cancel()
    local expired = harness({
      token_command = { "fake-token-helper", "test-key" },
      now = function()
        return 1400
      end,
    })
    assert(#expired.calls == 2 and expired.calls[2].cmd[1] == "fake-token-helper")
    expired.cancel()
  end, debug.traceback)
  vim.fn.executable = executable
  vim.env.GITLAB_TOKEN, vim.env.GITLAB_ACCESS_TOKEN, vim.env.GLAB_TOKEN = original[1], original[2], original[3]
  assert(ok, err)
end)

-- Lifecycle tests inject the loader, not the window APIs. Late callbacks and
-- rapid navigation must never overwrite details for a newer selection.
local original_fetch = preview.fetch
local loads = {}
preview.fetch = function(opts, done)
  local request = { opts = opts, done = done }
  loads[#loads + 1] = request
  return function()
    request.cancelled = true
  end
end
local board_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, board_buf)
local dashboard = { buf = board_buf, win = vim.api.nvim_get_current_win() }
local pane = preview.attach(dashboard, { host = "gitlab.example.invalid", project = "team/repo", glow = false })
local function wait_load(n)
  assert(
    vim.wait(1000, function()
      return #loads >= n
    end, 10),
    "Preview did not load"
  )
end
local function loaded(index, summary)
  local value = vim.deepcopy(jira)
  value.fields.summary = summary
  loads[index].done({ jira = value, errors = {}, fetched_at = os.time() })
end
local function pane_text()
  return table.concat(vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false), "\n")
end
local ok, err = xpcall(function()
  test("preview is lazy, debounced, closes cleanly, and follows selection", function()
    assert(#loads == 0)
    pane:show({ ticket = "TEST-41" })
    pane:update({ ticket = "TEST-42" })
    wait_load(1)
    assert(#loads == 1 and loads[1].opts.ticket == "TEST-42")
    assert(pane:is_open() and vim.bo[pane.buf].buftype == "nofile")
    assert(vim.api.nvim_win_get_config(pane.win).relative == "editor")
    pane:update({ ticket = "TEST-43" })
    wait_load(2)
    assert(loads[1].cancelled)
    loaded(1, "old result")
    assert(not pane_text():find("old result", 1, true))
    loaded(2, "new result")
    assert(pane_text():find("new result", 1, true))
    assert(not vim.bo[pane.buf].modifiable)
  end)

  test("fresh previews are cached and dashboard refresh invalidates them", function()
    pane:update({ ticket = "TEST-43" })
    vim.wait(200, function()
      return false
    end)
    assert(#loads == 2)
    assert(preview.attach(dashboard, { glow = false }) == pane)
    vim.api.nvim_exec_autocmds("User", { pattern = "SprintBoardRefreshPost" })
    wait_load(3)
    loaded(3, "refreshed result")
    assert(pane_text():find("refreshed result", 1, true))
    pane:close()
    assert(not pane:is_open())
    pane:show({ ticket = "TEST-43" })
    vim.wait(200, function()
      return false
    end)
    assert(#loads == 3 and pane_text():find("Cached preview", 1, true))
    local close = vim.fn.maparg("q", "n", false, true).callback
    assert(close)
    close()
    assert(not pane:is_open())
  end)

  test("wide-window preview is still a focused popup; q closes without resizing the board", function()
    local columns = vim.o.columns
    local board_width = vim.api.nvim_win_get_width(dashboard.win)
    vim.o.columns = 180
    vim.api.nvim_set_current_win(dashboard.win)
    pane:show({ ticket = "TEST-44" })
    vim.o.columns = columns
    assert(vim.api.nvim_win_get_config(pane.win).relative == "editor")
    assert(vim.api.nvim_get_current_win() == pane.win)
    assert(vim.api.nvim_win_get_width(dashboard.win) == board_width)
    vim.fn.maparg("q", "n", false, true).callback()
    assert(not pane:is_open())
    assert(vim.api.nvim_get_current_win() == dashboard.win)
    vim.wait(200, function()
      return false
    end)
    assert(#loads == 3)
  end)

  test("dashboard destruction cancels pending requests and removes lifecycle hooks", function()
    pane:show({ ticket = "TEST-45" })
    wait_load(4)
    local code = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(code, "sprint-preview-test.lua")
    vim.api.nvim_set_current_win(dashboard.win)
    vim.api.nvim_buf_delete(board_buf, { force = true })
    assert(vim.wait(1000, function()
      return not pane:is_open()
    end))
    assert(loads[4].cancelled and not vim.api.nvim_buf_is_valid(board_buf))
    loaded(4, "late after close")
    assert(not pcall(vim.api.nvim_get_autocmds, { group = "sprint_preview_" .. board_buf }))
  end)
end, debug.traceback)
pane:close()
preview.fetch = original_fetch
assert(ok, err)
print(("All %d sprint preview tests passed"):format(count))

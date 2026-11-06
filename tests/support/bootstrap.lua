-- Explicit permissive policy for isolated legacy regression fixtures only.
-- Runtime/default tests must NOT source this helper.
vim.opt.rtp:prepend(vim.fn.getcwd())
-- Synthetic optional manager stats for legacy section assertions.
package.loaded["lazy"] = { stats = function() return { count = 0, loaded = 0, startuptime = 0 } end }
local sandbox = vim.fn.tempname() .. " deskboard fixture"
vim.fn.mkdir(sandbox, "p")
require("deskboard.config").set({
  providers = { jira = { enabled = true, snapshot = sandbox .. "/reminder.md", state_file = sandbox .. "/sync.json" },
    gitlab = { enabled = true, host = "gitlab.example.invalid", project = "team/repo" } },
  reminders = { path = sandbox .. "/reminder.md" },
  notes = { enabled = true, allow_writes = true, roots = {}, legacy_globals = true, id_state_dir = sandbox .. "/ids" },
  actions = { checkout = true, jira_edit = true, pipeline = true, repo = sandbox .. "/repository" },
  compat_commands = true,
})

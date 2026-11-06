local M = {}
local defaults = {
  width = 124, page_size = 6, demo = false,
  providers = {
    jira = { enabled = false, auto_refresh = false, snapshot = nil, command = nil, state_file = nil },
    gitlab = { enabled = false, host = "gitlab.com", project = nil, proxy = nil, token_command = nil },
  },
  notes = { enabled = false, roots = {}, allow_writes = false, legacy_globals = false,
    review_days = 90, id_state_dir = nil, index_root = nil },
  reminders = { path = nil },
  actions = { repo = nil, checkout = false, pipeline = false, jira_edit = false },
  preview = { glow = false }, compat_commands = false, quit = "bd",
  refresh_interval = 60000,
}
local options = vim.deepcopy(defaults)
function M.get() return options end
local function boolean(value, name) assert(type(value) == "boolean", name .. " must be a boolean") end
local function argv(value, name)
  if value == nil then return end
  assert(type(value) == "table" and vim.islist(value) and #value > 0, name .. " must be argv")
  for _, part in ipairs(value) do assert(type(part) == "string" and part ~= "", name .. " must contain nonempty strings") end
end
function M.set(opts)
  local next_options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  assert(type(next_options.width) == "number" and next_options.width >= 16 and next_options.width < math.huge, "workbench.width must be >=16")
  assert(type(next_options.page_size) == "number" and next_options.page_size >= 1 and next_options.page_size < math.huge, "workbench.page_size must be >=1")
  assert(type(next_options.refresh_interval) == "number" and next_options.refresh_interval > 0 and next_options.refresh_interval < math.huge, "Invalid refresh_interval")
  for _, name in ipairs({ "jira", "gitlab" }) do boolean(next_options.providers[name].enabled, name .. ".enabled") end
  boolean(next_options.providers.jira.auto_refresh, "jira.auto_refresh")
  for _, name in ipairs({ "enabled", "allow_writes", "legacy_globals" }) do boolean(next_options.notes[name], "notes." .. name) end
  for _, name in ipairs({ "checkout", "pipeline", "jira_edit" }) do boolean(next_options.actions[name], "actions." .. name) end
  boolean(next_options.demo, "demo"); boolean(next_options.compat_commands, "compat_commands")
  assert(type(next_options.notes.roots) == "table", "notes.roots must be a scope/path table")
  for _, root in pairs(next_options.notes.roots) do assert(type(root) == "string" and root ~= "", "Invalid note root") end
  argv(next_options.providers.jira.command, "jira.command"); argv(next_options.providers.gitlab.token_command, "gitlab.token_command")
  next_options.page_size = math.floor(next_options.page_size)
  next_options.notes.id_state_dir = next_options.notes.id_state_dir or vim.fn.stdpath("state") .. "/workbench/note-ids"
  next_options.providers.jira.state_file = next_options.providers.jira.state_file or vim.fn.stdpath("state") .. "/workbench/sync.json"
  if next_options.demo then
    assert(not next_options.providers.jira.enabled and not next_options.providers.gitlab.enabled and not next_options.notes.allow_writes
      and not next_options.actions.checkout and not next_options.actions.pipeline and not next_options.actions.jira_edit, "Demo mode must remain offline/read-only")
  end
  if next_options.providers.jira.enabled then
    next_options.providers.jira.snapshot = next_options.providers.jira.snapshot or vim.fn.stdpath("state") .. "/workbench/snapshot.md"
  end
  if next_options.providers.gitlab.enabled then
    assert(type(next_options.providers.gitlab.project) == "string" and next_options.providers.gitlab.project ~= "", "GitLab project is required")
    assert(type(next_options.providers.gitlab.host) == "string" and next_options.providers.gitlab.host ~= "", "GitLab host is required")
  end
  options = next_options -- failed validation never installs a partially unsafe config
  return options
end
function M.root() return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h") end
function M.writable() return options.notes.enabled == true and options.notes.allow_writes == true end
return M

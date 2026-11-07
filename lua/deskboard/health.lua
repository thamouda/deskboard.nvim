local M = {}
function M.check()
  local h = vim.health
  h.start("Deskboard runtime")
  if vim.fn.has("nvim-0.11") == 1 then h.ok("Neovim 0.11+") else h.error("Neovim 0.11+ is required") end
  local cfg = require("deskboard.config").get()
  if vim.fn.exists(":Deskboard") == 2 then h.ok("setup() registered commands") else h.warn("Call require('deskboard').setup(opts)") end
  if #vim.api.nvim_get_runtime_file("lua/snacks/init.lua", false) > 0 then h.ok("Snacks available") else h.error("Install folke/snacks.nvim") end
  h.start("Optional providers (no API requests performed)")
  if cfg.repo_config.enabled then
    h.info(cfg.repo_config_path and ("Repository config: " .. cfg.repo_config_path) or "Repository config enabled")
    if cfg.repo_config_missing then h.info("No repository config: only Notes and Reminders are shown") end
    if cfg.repo_error then h.warn(cfg.repo_error) end
  end
  for name, executable in pairs({ jira = "jira", gitlab = "glab", github = "gh" }) do
    if cfg.providers[name].enabled then
      if vim.fn.executable(executable) == 1 then h.ok(name .. " CLI available") else h.error("Missing " .. executable) end
      if vim.fn.executable("python3") == 1 then h.ok("Python backend available") else h.error("Missing python3") end
    else h.ok(name .. " provider disabled") end
  end
  h.start("Local notes")
  h.info(cfg.notes.allow_writes and "Note writes explicitly enabled" or "Note writes disabled")
  if cfg.notes.enabled then
    for scope, root in pairs(require("deskboard.notes").roots()) do
      if vim.fn.isdirectory(root) == 1 then h.ok(scope .. " vault exists") else h.warn(scope .. " vault not created yet") end
    end
  else h.ok("Note indexing disabled") end
  for _, executable in ipairs({ "rg", "glow" }) do
    if vim.fn.executable(executable) == 1 then h.ok(executable .. " available") else h.info(executable .. " optional / not installed") end
  end
end
return M

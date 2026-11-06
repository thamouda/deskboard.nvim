-- Short, theme-aware panel notices. Full safe diagnostics stay in an explicit
-- read-only popup; never build a badge from raw CLI stdout/stderr.
local M = {}

local function clean(value)
  return vim.trim(tostring(value or ""):gsub("[%z\1-\31\127]", " "))
end

local function reason(value)
  value = clean(value):lower()
  if value:find("401", 1, true) or value:find("authentication", 1, true) or value:find("unauthorized", 1, true) or value:find("login", 1, true) then return "Sign-in needed" end
  if value:find("403", 1, true) or value:find("permission", 1, true) then return "Access denied" end
  if value:find("timeout", 1, true) or value:find("timed out", 1, true) then return "Timed out" end
  return "Refresh unavailable"
end

local function age(seconds)
  if seconds < 60 then return "just now" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
  return math.floor(seconds / 86400) .. "d ago"
end

function M.format(opts)
  opts = opts or {}
  local details = { "# " .. (opts.title or "Panel status"), "", "> Local diagnostics · R refreshes the active panel", "" }
  local messages = {}
  if opts.error then messages[#messages + 1] = opts.error end
  for _, value in ipairs(opts.warnings or {}) do if type(value) == "string" then messages[#messages + 1] = value end end
  for _, value in ipairs(messages) do details[#details + 1] = "- " .. clean(value) end
  local text, hl
  if opts.running then text, hl = "◷ Refreshing…", "Accent"
  elseif opts.error then text, hl = "! " .. reason(opts.error) .. (opts.cached and " · cached" or "") .. " · ! details", "Warning"
  elseif #messages > 0 then
    local specific = opts.local_only and "Refresh unavailable" or reason(messages[1])
    text, hl = "! " .. (specific ~= "Refresh unavailable" and specific or opts.warning_label or "Partial data")
      .. (opts.stale and " · cached" or "") .. " · ! details", "Warning"
  elseif opts.stale then text, hl = "! Stale data · cached · ! details", "Warning"
  elseif opts.local_only then text, hl = "● Local only · never published automatically", "Muted"
  elseif opts.age then text, hl = "✓ Updated " .. (opts.estimated and "~" or "") .. age(math.max(0, opts.age)), "Muted"
  else text, hl = "○ Not refreshed · R", "Muted" end
  if opts.stale then details[#details + 1] = "- The displayed data is cached/stale." end
  if opts.age then details[#details + 1] = "- Last successful/cached snapshot: " .. age(math.max(0, opts.age)) end
  if opts.sources then
    for _, name in ipairs({ "jira", "gitlab" }) do
      if opts.sources[name] == false then details[#details + 1] = "- " .. name .. ": cached, source unavailable" end
    end
  end
  if #messages == 0 then details[#details + 1] = opts.local_only and "- Notes stay on local disk. No Confluence client is configured." or "- No reported errors." end
  return { text = text, hl = hl, details = details }
end

function M.show(info, owner)
  if not info then return end
  local popup = require("workbench.preview").popup(owner, info.details, { title = " Panel status · q close ", glow = false })
  if popup then
    local group = vim.api.nvim_create_augroup("dashboard_status_" .. owner.buf, { clear = true })
    vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
      group = group, buffer = owner.buf, callback = function() vim.schedule(function() popup:close() end) end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = popup.buf, once = true,
      callback = function() pcall(vim.api.nvim_del_augroup_by_id, group) end })
  end
  return popup
end

return M

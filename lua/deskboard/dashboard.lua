-- Dashboard customization hooks and enhancements
-- Allows configuration of section titles, display formatting, and interactive features
-- like reminder toggling.
local M = {}

-- Customization options
M.customize = {
  -- Review title format: nil = default "Reviews for me", or a function/string
  -- Function signature: fn(count: number, state: table) -> string
  reviews_title = nil,
  
  -- Reminder title format: nil = default "Reminders", or a function/string
  -- Function signature: fn(open: number, done: number, state: table) -> string
  reminders_title = nil,
  
  -- Enable reminder toggle functionality (Space/x to toggle done/undone)
  enable_reminder_toggle = true,
  
  -- Reminder toggle keymaps (list of keys)
  reminder_toggle_keys = { "<Space>", "x" },
}

-- Apply customization to render_reviews
function M.customize_reviews_title(notice, state, count)
  if not M.customize.reviews_title then
    return
  end
  
  local custom_title
  if type(M.customize.reviews_title) == "function" then
    custom_title = M.customize.reviews_title(count, state)
  elseif type(M.customize.reviews_title) == "string" then
    custom_title = M.customize.reviews_title:format(count)
  end
  
  if custom_title then
    notice.title = custom_title
  end
end

-- Apply customization to render_reminders
function M.customize_reminders_title(notice, state)
  if not M.customize.reminders_title then
    return
  end
  
  local open, done = 0, 0
  if state and state.reminders then
    for _, row in ipairs(state.reminders) do
      if row.done then done = done + 1 else open = open + 1 end
    end
  end
  
  local custom_title
  if type(M.customize.reminders_title) == "function" then
    custom_title = M.customize.reminders_title(open, done, state)
  elseif type(M.customize.reminders_title) == "string" then
    custom_title = M.customize.reminders_title:format(open, done)
  end
  
  if custom_title then
    notice.title = custom_title
  end
end

-- Setup reminder toggle keymaps in the dashboard
function M.setup_reminder_toggle(config)
  if not M.customize.enable_reminder_toggle then
    return
  end
  
  local augroup = vim.api.nvim_create_augroup("deskboard_reminder_toggle", { clear = true })
  
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = "snacks_dashboard",
    once = false,
    callback = function(event)
      local buf = event.buf
      
      for _, key in ipairs(M.customize.reminder_toggle_keys) do
        vim.keymap.set("n", key, function()
          M.toggle_reminder_at_cursor(buf, config)
        end, {
          buffer = buf,
          silent = true,
          desc = "Toggle reminder done/undone",
          nowait = true,
        })
      end
    end,
  })
end

-- Toggle a reminder at the cursor line
function M.toggle_reminder_at_cursor(buf, config)
  local line_num = vim.fn.line(".")
  local line = vim.api.nvim_buf_get_lines(buf, line_num - 1, line_num, false)[1]
  
  if not line then
    return
  end
  
  -- Check if this is a reminder line (marker pattern)
  if not (line:match("^%s*[○✓]") or line:match("%[[ x]%]")) then
    return
  end
  
  -- Get reminder file path
  local cfg = config or require("deskboard.config").get()
  local reminder_path = cfg.reminders.path or cfg.providers.jira.snapshot
  
  if not reminder_path then
    return
  end
  
  reminder_path = vim.fn.expand(reminder_path)
  
  -- Read reminders file
  local ok, lines = pcall(vim.fn.readfile, reminder_path)
  if not ok or not lines then
    return
  end
  
  -- Extract title from display line (remove marker)
  local title = line:gsub("^%s*[○✓]%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
  
  if title == "" then
    return
  end
  
  -- Find and toggle the reminder in file
  local found = false
  for i, file_line in ipairs(lines) do
    if file_line:find(title, 1, true) then
      -- Toggle checkbox
      if file_line:match("%[%s%]") then
        lines[i] = file_line:gsub("%[%s%]", "[x]")
        found = true
      elseif file_line:match("%[x%]") then
        lines[i] = file_line:gsub("%[x%]", "[ ]")
        found = true
      end
      if found then
        break
      end
    end
  end
  
  if found then
    -- Write updated content
    local write_ok = pcall(vim.fn.writefile, lines, reminder_path)
    if write_ok then
      -- Refresh dashboard
      vim.schedule(function()
        local snacks = require("snacks")
        if snacks and snacks.dashboard then
          snacks.dashboard.open({
            width = require("deskboard.config").get().width,
            sections = require("deskboard").sections,
          })
        end
      end)
    end
  end
end

-- Configure customizations (call from your nvim config)
function M.setup(opts)
  opts = opts or {}
  
  -- Apply customizations
  if opts.reviews_title then
    M.customize.reviews_title = opts.reviews_title
  end
  if opts.reminders_title then
    M.customize.reminders_title = opts.reminders_title
  end
  if opts.enable_reminder_toggle ~= nil then
    M.customize.enable_reminder_toggle = opts.enable_reminder_toggle
  end
  if opts.reminder_toggle_keys then
    M.customize.reminder_toggle_keys = opts.reminder_toggle_keys
  end
  
  -- Setup keymaps if enabled
  if M.customize.enable_reminder_toggle then
    M.setup_reminder_toggle(opts.config)
  end
end

return M

-- Example: Customize Deskboard dashboard titles and add reminder toggle
--
-- Place this in your Neovim config after deskboard.setup()
-- Example: ~/.config/nvim/lua/config/deskboard-customization.lua
--
-- Then in your main deskboard plugin config:
-- require("config.deskboard-customization").setup()

local M = {}

function M.setup()
  local deskboard = require("deskboard")
  
  -- Customize review section title: show "My Reviews (count)"
  deskboard.dashboard.setup({
    reviews_title = function(count)
      return string.format("My Reviews (%d)", count)
    end,
    
    -- Customize reminders section: show count breakdown
    reminders_title = function(open, done)
      return string.format("📝 Reminders · %d open, %d done", open, done)
    end,
    
    -- Enable reminder toggle keymaps
    enable_reminder_toggle = true,
    
    -- Keymaps to toggle reminders (Space and x by default)
    reminder_toggle_keys = { "<Space>", "x" },
  })
end

return M

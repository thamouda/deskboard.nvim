-- Centered, theme-aware date and time for the Snacks dashboard.
-- Pure rendering: the existing dashboard minute refresh keeps the clock live.
local M = {}
local width = vim.api.nvim_strwidth
local prefix = "Deskboard"

local function chunk(text, hl)
  return { text, hl = prefix .. hl }
end

local function fit(text, limit)
  if limit < 1 then return "" end
  if width(text) <= limit then return text end
  local result = ""
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if width(result .. char) > limit - 1 then break end
    result = result .. char
  end
  return result .. "…"
end

function M.render(opts)
  opts = opts or {}
  local now = opts.now or os.time()
  local date = os.date("*t", now) --[[@as osdate]]
  local limit = math.max(1, math.min(44, opts.width or 44))
  local time = os.date("%H:%M", now)
  local zone = os.date("%Z", now)
  local full_date = os.date("%A", now) .. " · " .. date.day .. " " .. os.date("%B %Y", now)
  local inner = limit
  local date_label = full_date
  if width(date_label) > inner then date_label = os.date("%a", now) .. " · " .. date.day .. os.date(" %b %Y", now) end
  if width(date_label) > inner then date_label = os.date("%d/%m/%Y", now) end
  date_label = fit(date_label, inner)

  local clock = { chunk(fit(time, inner), "Accent") }
  if zone ~= "" and width(time .. " · " .. zone) <= inner then
    clock[#clock + 1] = chunk(" · " .. zone, "Muted")
  end
  return {
    { text = clock, align = "center", padding = { 1, 0 } },
    { text = { chunk(date_label, "Title") }, align = "center", padding = { 0, 1 } },
  }
end

-- A single compact component for the right side of a panel title bar.
function M.inline(opts)
  opts = opts or {}
  local now, limit = opts.now or os.time(), math.max(1, opts.width or 44)
  local time, zone = os.date("%H:%M", now), os.date("%Z", now)
  local date = os.date("%a %d %b %Y", now)
  local full = date .. " · " .. time .. (zone ~= "" and (" " .. zone) or "")
  if width(full) <= limit then
    return { chunk(date .. " · ", "Muted"), chunk(time, "Accent"), chunk(zone ~= "" and (" " .. zone) or "", "Muted") }
  end
  local short = os.date("%d/%m", now) .. " · "
  if width(short .. time) <= limit then return { chunk(short, "Muted"), chunk(time, "Accent") } end
  return { chunk(fit(time, limit), "Accent") }
end

return M

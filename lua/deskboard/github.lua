-- On-demand GitHub issue/PR details. Authentication belongs to gh, not the repo
-- config. Every operation is a bounded, read-only argv request.
local M = {}
local function scalar(value, fallback)
  return type(value) == "string" and value:gsub("[%z\1-\31\127]", " ") or fallback or "unknown"
end
function M.preview(opts, done)
  local number = opts.issue_number or opts.mr_iid
  local data = { errors = {}, fetched_at = (opts.now or os.time)() }
  local valid_project = pcall(require("deskboard.repo_config").validate, { version = 1,
    issues = { provider = "github", project = opts.project }, reviews = { provider = "github", project = opts.project, host = opts.host } })
  if not valid_project or opts.host ~= "github.com" or not tostring(number):match("^%d+$") or tonumber(number) < 1 then
    data.errors = { "Invalid GitHub project or item" }; done(data); return function() end
  end
  local kind = opts.issue_number and "issues" or "pulls"
  local command = { "gh", "api", "--hostname", "github.com", "--method", "GET", "repos/" .. opts.project .. "/" .. kind .. "/" .. number }
  local cancelled = false
  local function receive(result)
    if cancelled then return end
    local ok, value = pcall(vim.json.decode, result.stdout or "")
    if result.code == 0 and ok and type(value) == "table" and value.number == tonumber(number)
      and type(value.title) == "string" and type(value.state) == "string"
      and (value.body == nil or value.body == vim.NIL or type(value.body) == "string") then
      data.github = value
    else
      local detail = (result.stderr or ""):lower()
      data.errors = { result.code == 124 and "GitHub request timed out"
        or (detail:find("401", 1, true) or detail:find("login", 1, true)) and "GitHub authentication failed (HTTP 401)"
        or detail:find("403", 1, true) and "GitHub permission denied (HTTP 403)"
        or "GitHub details unavailable (CLI, authentication, or network)" }
    end
    data.fetched_at = (opts.now or os.time)()
    done(data)
  end
  local ok, job = pcall(opts.run or vim.system, command, { text = true, timeout = 15000 }, vim.schedule_wrap(receive))
  if not ok then receive({ code = -1 }) end
  return function() cancelled = true; if ok and job then pcall(function() job:kill(15) end) end end
end
function M.lines(data, opts)
  local item = type(data.github) == "table" and data.github or {}
  local number = opts.issue_number or opts.mr_iid
  local lines = { "# GitHub " .. (opts.issue_number and "Issue" or "Pull Request") .. " · #" .. tostring(number or "?"), "",
    scalar(item.title, "Details unavailable"), "", "- Repository: " .. scalar(opts.project), "- State: " .. scalar(item.state) }
  if type(item.user) == "table" then lines[#lines + 1] = "- Author: @" .. scalar(item.user.login) end
  if not opts.issue_number then
    local base, head = type(item.base) == "table" and item.base or {}, type(item.head) == "table" and item.head or {}
    lines[#lines + 1] = "- Branch: " .. scalar(head.ref) .. " → " .. scalar(base.ref)
    lines[#lines + 1] = "- Commits: " .. (type(item.commits) == "number" and tostring(item.commits) or "unknown")
  end
  for _, err in ipairs(data.errors or {}) do lines[#lines + 1] = "> " .. scalar(err) end
  vim.list_extend(lines, { "", "## Description", "" })
  local text = require("deskboard.markdown").to_markdown(item.body, "github")
  vim.list_extend(lines, text:match("^%s*$") and { "No description available." } or require("deskboard.markdown").excerpt(text, 200))
  vim.list_extend(lines, { "", "---", "q / Esc close · R on the board refreshes the list" })
  return lines
end
return M

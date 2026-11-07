-- Theme-aware Snacks dashboard cards. Rendering is side-effect free; ticket
-- actions are supplied by the dashboard so navigation/checkout stay unchanged.
local M = { width = 124, header_rows = 5 }
local H = "Deskboard"
-- Match Snacks' context-independent cell widths, including CJK characters.
local width = vim.api.nvim_strwidth
-- Keymap legends: {key, description} pairs. Rendered with the key in a
-- distinct accent colour and the description muted, so available keymaps
-- are readable at a glance instead of a flat wall of grey text.
local NAV_HELP = { { "Tab", "switch board" }, { "[p/]p", "page" }, { "!", "status" } }
local MINE_HELP = {
  { { "j/k", "move" }, { "Enter", "checkout (auto-stash)" }, { "K/P", "preview" } },
  { { "E", "edit ticket" }, { "o", "Jira" }, { "x", "MR" }, { "p", "pipeline" }, { "R", "refresh" }, { "N", "notes" } },
}
local REVIEW_HELP = { { "Enter/o/x", "open MR" }, { "K/P", "preview" }, { "R", "refresh" } }
local FILTER_HELP = { { "a", "filter author" }, { "A", "clear filter" } }
local NOTES_HELP = { { "Enter/o", "open" }, { "K/P", "details" }, { "R", "refresh" }, { "N", "back" } }
local NOTE_FILTER_HELP = { { "C", "category" }, { "S", "status" }, { "t", "tag" }, { "Q", "queue" }, { "A", "clear" } }
local NOTE_ACTION_HELP = {
  { "+", "new" }, { "M", "status" }, { "v", "reviewed" }, { "V", "visibility" },
  { "F", "search" }, { "D", "delete" }, { "B", "browser" },
}
local REMINDER_HELP = { { "Enter/o", "edit reminder source" }, { "R", "refresh" } }
local LEGEND_SEP = " · "

local function chunk(text, hl)
  return { text, hl = H .. (hl or "") }
end

local function text_width(chunks)
  local n = 0
  for _, part in ipairs(chunks) do
    n = n + width(part[1])
  end
  return n
end

-- Truncate by display cells, never by bytes (emoji/CJK/combining characters).
local function fit(text, limit)
  if width(text) <= limit then
    return text
  end
  local result = ""
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if width(result .. char) > limit - 1 then
      break
    end
    result = result .. char
  end
  return result .. "…"
end

local function wrap(text, limit)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    if width(word) > limit then
      if line ~= "" then
        lines[#lines + 1] = line
      end
      -- Long URLs/identifiers must not push the card beyond its border.
      local part = ""
      for char in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if width(part .. char) > limit and part ~= "" then
          lines[#lines + 1], part = part, ""
        end
        part = part .. char
      end
      line = part
    elseif line == "" then
      line = word
    elseif width(line .. " " .. word) <= limit then
      line = line .. " " .. word
    else
      lines[#lines + 1], line = line, word
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  return lines
end

-- Wrap {key, description} pairs onto lines that fit `limit` cells. A pair
-- is never split across lines; an oversized single pair is truncated by
-- display cells, same as free-text help used to be.
local function wrap_legend(pairs, limit)
  local lines, current, current_width = {}, {}, 0
  for _, pair in ipairs(pairs) do
    local pair_width = width(pair[1]) + 1 + width(pair[2])
    local add = pair_width + (#current > 0 and width(LEGEND_SEP) or 0)
    if #current > 0 and current_width + add > limit then
      lines[#lines + 1], current, current_width = current, {}, 0
      add = pair_width
    end
    current[#current + 1] = pair
    current_width = current_width + add
  end
  if #current > 0 then
    lines[#lines + 1] = current
  end
  return lines
end

-- Render one wrapped legend line: the key stands out (bold accent colour),
-- the description stays muted, pairs are separated by a clear middle dot.
local function legend_chunks(pairs, limit)
  local chunks, used = {}, 0
  for i, pair in ipairs(pairs) do
    if i > 1 then
      chunks[#chunks + 1] = chunk(LEGEND_SEP, "Muted")
      used = used + width(LEGEND_SEP)
    end
    local key = fit(pair[1], math.max(1, limit - used))
    used = used + width(key)
    chunks[#chunks + 1] = chunk(key, "Key")
    local desc = fit(" " .. pair[2], math.max(0, limit - used))
    used = used + width(desc)
    chunks[#chunks + 1] = chunk(desc, "Muted")
  end
  return chunks
end

local function parse_ts(ts)
  local y, mo, d, h, mi, s = (ts or ""):match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)$")
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
end

function M.setup_highlights()
  local function apply()
    local function color(group)
      return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
    end
    local bg = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg
    local groups = {
      [""] = { link = "Normal" },
      Border = { link = "FloatBorder" },
      Muted = { link = "Comment" },
      Title = { fg = color("Title") or color("Function"), bold = true },
      Accent = { fg = color("DiagnosticInfo"), bold = true },
      Success = { fg = color("DiagnosticOk") or color("String") },
      Warning = { fg = color("DiagnosticWarn") },
      Error = { fg = color("DiagnosticError"), bold = true },
      Key = { fg = color("Identifier"), bold = true },
      Cursor = { bg = bg, underline = bg == nil },
    }
    for suffix, attrs in pairs(groups) do
      vim.api.nvim_set_hl(0, H .. suffix, attrs)
    end
  end
  apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("deskboard_colors", { clear = true }),
    callback = apply,
    desc = "Refresh sprint board palette",
  })
end

local function strip_icon(text)
  -- The sync script prefixes status/type with an icon; keep the readable
  -- label and use highlight groups instead of a wall of multicolour emoji.
  text = vim.trim(text or "")
  for _, icon in ipairs({ "✅", "🚧", "📋", "👀", "🚫", "🐛", "🧩", "🔗", "📖", "📦", "▪" }) do
    if text:sub(1, #icon + 1) == icon .. " " then
      return vim.trim(text:sub(#icon + 1))
    end
  end
  return text
end

function M.project_label(project)
  if type(project) ~= "string" or project == "" then return "—" end
  return project:gsub("/+$", ""):match("([^/]+)$") or project
end

local function ticket_row(todo, project)
  local c = vim.split(todo.text, "|", { plain = true })
  local status = strip_icon(c[2])
  local status_lower = status:lower()
  local status_hl = todo.done and "Success"
    or (status_lower:find("review") and "Warning")
    or (status_lower:find("progress") and "Accent")
    or (status_lower:find("block") and "Error")
    or "Muted"
  local mr = c[5] or ""
  local ci, ci_hl = "", "Muted"
  if mr:find("[FAIL]", 1, true) or mr:find("❌", 1, true) then
    ci, ci_hl = " ✗", "Error"
  elseif mr:find("[OK]", 1, true) or mr:find("✅", 1, true) then
    ci, ci_hl = " ✓", "Success"
  elseif mr:find("[RUN]", 1, true) or mr:find("⏳", 1, true) then
    ci, ci_hl = " ◷", "Warning"
  elseif mr:find("[WAIT]", 1, true) or mr:find("⏸", 1, true) then
    ci, ci_hl = " ◷", "Warning"
  elseif mr:find("[SKIP]", 1, true) or mr:find("⏭", 1, true) then
    ci = " −"
  end
  local iid = mr:match("!(%d+)")
  local threads = (c[6] or ""):match("%d+/%d+")
  local resolved, total = (threads or ""):match("(%d+)/(%d+)")
  local threads_hl = resolved and tonumber(resolved) < tonumber(total) and "Warning" or "Success"
  if not threads then
    threads = (c[6] or ""):find("✅", 1, true) and "clear" or "—"
    threads_hl = threads == "clear" and "Success" or "Muted"
  end
  local unresolved = resolved and math.max(0, tonumber(total) - tonumber(resolved)) or 0
  local blocked = status_lower:find("block", 1, true) ~= nil
  local failed = ci_hl == "Error"
  local approved = iid and (c[7] or "?") or "—"
  if approved == "–" or approved == "" then
    approved = "—"
  end
  local count = tonumber(approved)
  local approved_hl = approved:sub(1, 1) == "~" and "Warning" or count and count > 0 and "Success" or "Muted"
  local ready = iid and (c[8] or "unknown") or "–"
  local ready_labels = {
    yes = "✓ yes",
    approvals = "appr.",
    threads = "threads",
    ci = "CI",
    conflict = "conflict",
    rebase = "rebase",
    draft = "draft",
    changes = "changes",
    scheduled = "later",
    checking = "check…",
    blocked = "blocked",
    permissions = "access",
    closed = "closed",
    merged = "—",
    unknown = "?",
    ["–"] = "—",
    ["—"] = "—",
  }
  local ready_hl = ready == "yes" and "Success"
    or (ready == "unknown" or ready == "merged" or ready == "–") and "Muted"
    or "Warning"
  local merged = iid and (c[9] or "?") or "–"
  local merged_known = merged ~= "–" and merged ~= "—" and merged ~= "?" and merged ~= ""
  local merged_branch = merged:match("^refs/heads/(.+)$") or merged
  local merged_short = merged_branch == "main" and "main" or merged_branch:match("(%u[%u%d]*%-%d+)") or merged_branch
  local merged_text = merged_known and merged_short or merged == "?" and "?" or "—"
  return {
    todo = todo,
    mr_iid = iid,
    project = todo.project or project,
    unresolved = unresolved,
    blocked = blocked,
    failed = failed,
    priority = failed and 1 or blocked and 2 or unresolved > 0 and 3 or status_lower:find("review", 1, true) and 4 or 5,
    cells = {
      key = { todo.ticket, todo.done and "Muted" or "Key" },
      project = { M.project_label(todo.project or project), "Muted" },
      status = { status ~= "" and status or (todo.done and "Done" or "To do"), status_hl },
      kind = { strip_icon(c[3]), "Muted" },
      time = { c[4] or "—", "Muted" },
      mr = { iid and ("!" .. iid .. ci) or "—", iid and "Accent" or "Muted" },
      threads = { threads, threads_hl },
      approved = { approved, approved_hl },
      ready = { ready_labels[ready] or "?", ready_hl },
      merged = { merged_text, merged_known and "Success" or "Muted" },
    },
    ci = ci,
    ci_hl = ci_hl,
  }
end

local function columns(rows, limit)
  local defs = {
    { key = "key", title = "TICKET", cap = 16 },
    { key = "project", title = "PROJECT", cap = 14 },
    { key = "status", title = "STATUS", cap = 16 },
    { key = "kind", title = "TYPE", cap = 9 },
    { key = "time", title = "TIME", cap = 10 },
    { key = "mr", title = "MR / CI", cap = 12 },
    { key = "threads", title = "THREADS", cap = 9 },
    { key = "approved", title = "APPROVED", cap = 8 },
    { key = "ready", title = "READY", cap = 8 },
    { key = "merged", title = "MERGED INTO", cap = 24 },
  }
  local has_project = false
  for _, row in ipairs(rows) do if type(row.project) == "string" and row.project ~= "" then has_project = true end end
  if not has_project then table.remove(defs, 2) end
  for _, col in ipairs(defs) do
    col.width = width(col.title)
    for _, row in ipairs(rows) do
      col.width = math.max(col.width, math.min(col.cap, width(row.cells[col.key][1])))
    end
  end
  local function total()
    local n = 2 -- current-branch marker
    for _, col in ipairs(defs) do
      n = n + col.width + 2
    end
    return n - 2
  end
  -- Drop secondary metadata first; never wrap a navigable ticket row.
  for _, key in ipairs({ "kind", "time", "status", "threads", "merged", "approved", "ready", "project", "mr" }) do
    if total() <= limit then
      break
    end
    for i, col in ipairs(defs) do
      if col.key == key then
        table.remove(defs, i)
        break
      end
    end
  end
  if total() > limit then
    defs[1].width = math.max(1, limit - 2)
  end
  return defs
end

-- A shared upper bound keeps width/height independent of view, data and page.
-- Reserve sprint metadata, both ticket groups, a full page, and wrapped help.
function M.frame(opts)
  opts = opts or {}
  local outer = math.max(16, opts.width or M.width)
  local inner = outer - 6
  local size = math.max(1, math.floor(tonumber(opts.page_size) or 6))
  local help = #wrap_legend(NAV_HELP, inner)
  for _, value in ipairs(MINE_HELP) do help = help + #wrap_legend(value, inner) end
  local groups = size > 1 and 6 or 3 -- rule, group label, column headings
  local mine = M.header_rows + groups + size + 1 + 1 + help
  local reviews = M.header_rows + 3 + size + 1 + 1 + #wrap_legend(NAV_HELP, inner) + #wrap_legend(REVIEW_HELP, inner) + #wrap_legend(FILTER_HELP, inner)
  local notes = M.header_rows + 3 + size + 1 + 1 + #wrap_legend(NAV_HELP, inner) + #wrap_legend(NOTES_HELP, inner)
    + #wrap_legend(NOTE_FILTER_HELP, inner) + #wrap_legend(NOTE_ACTION_HELP, inner)
  return { width = outer, height = math.max(mine, reviews, notes) + 2, now = opts.now }
end

local function card(title, content, outer_width, frame, now)
  outer_width = frame and frame.width or outer_width
  local limit = outer_width - 6
  local inner = frame and limit or math.min(limit, math.max(10, width(title)))
  -- Standalone cards hug their content. Dashboard cards instead keep the
  -- full shared frame width, independent of the visible rows.
  for _, row in ipairs(content) do
    if row.text then
      inner = math.max(inner, math.min(limit, text_width(row.text)))
    end
  end
  outer_width = inner + 6
  local result = {}
  local function add(parts, source)
    local item = { text = parts, align = "center" }
    if source then
      item.ticket, item.mr_iid, item.action = source.ticket, source.mr_iid, source.action
      item.jira_status = source.jira_status
      item.review, item.mr_project, item.web_url, item.id = source.review, source.mr_project, source.web_url, source.id
      item.review_label, item.review_metrics = source.review_label, source.review_metrics
      item.provider, item.project = source.provider, source.project
      item.issue_number, item.issue_title = source.issue_number, source.issue_title
      item.personal_note, item.note_title, item.note_data = source.personal_note, source.note_title, source.note_data
      item.reminder = source.reminder
      item.panel_header, item.header_slot, item.header_clock = source.panel_header, source.header_slot, source.header_clock
    end
    result[#result + 1] = item
  end
  local clock = require("deskboard.clock").inline({ width = math.max(5, outer_width - width(title) - 8), now = now or (frame and frame.now) })
  local clock_width = text_width(clock) + 2
  local label = " " .. fit(title, math.max(1, outer_width - clock_width - 6)) .. " "
  local top = { chunk("╭─" .. label .. string.rep("─", math.max(1, outer_width - width(label) - clock_width - 3)) .. " ", "Border") }
  vim.list_extend(top, clock)
  top[#top + 1] = chunk(" ╮", "Border")
  add(top, { header_clock = true, header_slot = 0 })
  local actual, has_spacer = 0, false
  for _, row in ipairs(content) do
    if row.spacer then has_spacer = true else actual = actual + 1 end
  end
  local padding = frame and math.max(0, frame.height - 2 - actual) or 0
  local function blank_rows()
    for _ = 1, padding do add({ chunk("│" .. string.rep(" ", outer_width - 2) .. "│", "Border") }) end
  end
  for _, row in ipairs(content) do
    if row.spacer then
      blank_rows()
    elseif row.rule then
      add({ chunk("├" .. string.rep("─", outer_width - 2) .. "┤", "Border") })
    else
      local text = row.text
      if row.progress then
        local filled = math.floor(inner * row.progress.pct + 0.5)
        text = { chunk(string.rep("━", filled), row.progress.hl), chunk(string.rep("─", inner - filled), "Muted") }
      end
      local left = row.center and math.max(0, math.floor((inner - text_width(text)) / 2)) or 0
      local parts = { chunk("│  " .. string.rep(" ", left), "Border") }
      vim.list_extend(parts, text)
      parts[#parts + 1] = chunk(string.rep(" ", math.max(0, inner - left - text_width(text))) .. "  │", "Border")
      add(parts, row)
    end
  end
  if not has_spacer then blank_rows() end
  add({ chunk("╰" .. string.rep("─", outer_width - 2) .. "╯", "Border") })
  result[#result].padding = { 0, 1 }
  return result
end

-- Five context/status rows are shared by all panels. The date/time is rendered
-- at the right of the title border, not as separate content rows.
local function panel_header(_opts, inner, slots, notice)
  local result = {}
  for i = 3, 6 do
    result[i - 2] = slots[i] or { text = {} }
    result[i - 2].panel_header, result[i - 2].header_slot = true, i - 2
  end
  result[5] = { text = { chunk(fit(notice.text, inner), notice.hl) }, panel_header = true, header_slot = 5 }
  return result
end

local function progress(sprint, now)
  local start, stop = parse_ts(sprint.start), parse_ts(sprint.stop)
  if not start or not stop or stop <= start then
    return nil, nil
  end
  local fmt = os.date("%Y", start) == os.date("%Y", stop) and "%d %b" or "%d %b %Y"
  local dates = os.date(fmt, start) .. " → " .. os.date(fmt, stop)
  local pct = math.max(0, math.min(1, (now - start) / (stop - start)))
  local days = math.ceil((stop - now) / 86400)
  local label = now < start and "not started"
    or now >= stop and "ended"
    or days == 1 and "1 day left"
    or (days .. " days left")
  local summary = ("Time · %d%% · %s"):format(math.floor(pct * 100), label)
  local hl = now >= stop and "Muted" or pct >= 0.75 and "Warning" or "Accent"
  return dates, { pct = pct, hl = hl }, { text = summary, hl = hl }
end

-- opts: sprint, heading, note_todos, ticket_todos, show_notes, current_ticket,
-- width, frame (shared fixed geometry), now, sync status, on_checkout(ticket).
function M.render(opts)
  local outer = math.max(16, opts.frame and opts.frame.width or opts.width or M.width)
  local inner, items = outer - 6, {}
  local function row(parts)
    return { text = parts }
  end
  local function line(text, hl)
    return row({ chunk(fit(text, inner), hl) })
  end
  local function append_card(title, content, frame)
    vim.list_extend(items, card(title, content, outer, frame, opts.now))
  end

  if opts.show_notes then
    local notes = {}
    if opts.heading then
      for _, text in ipairs(wrap(opts.heading, inner)) do
        notes[#notes + 1] = line(text)
      end
    end
    -- Keep open notes before completed ones, preserving order within each group.
    for _, completed in ipairs({ false, true }) do
      for _, todo in ipairs(opts.note_todos or {}) do
        if (not not todo.done) == completed then
          local prefix = todo.done and "✓ " or "○ "
          for i, text in ipairs(wrap(todo.text, inner - 2)) do
            notes[#notes + 1] = line((i == 1 and prefix or "  ") .. text, todo.done and "Muted" or "")
          end
        end
      end
    end
    if #notes > 0 then
      append_card("PERSONAL NOTES", notes)
    end
  end

  local todos = opts.ticket_todos or {}
  if not opts.sprint and #todos == 0 and not opts.sync and not opts.frame then
    return items
  end
  local content, rows, active, done = {}, {}, {}, {}
  for index, todo in ipairs(todos) do
    local ticket = ticket_row(todo, opts.project)
    ticket.index = index
    rows[#rows + 1] = ticket
    table.insert(todo.done and done or active, ticket)
  end
  -- Failed CI, blocked work, unresolved reviews, then review-ready tickets.
  -- Equal priorities retain source order; never reorder the caller's data.
  table.sort(active, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    elseif a.priority == 3 and a.unresolved ~= b.unresolved then
      return a.unresolved > b.unresolved
    end
    return a.index < b.index
  end)
  local active_page, done_page, page_info = active, done, nil
  if opts.page_size then
    local ordered = vim.list_extend(vim.list_extend({}, active), done)
    local visible
    visible, page_info = require("deskboard.views").paginate(ordered, opts.page, opts.page_size)
    active_page, done_page = {}, {}
    for _, ticket in ipairs(visible) do
      table.insert(ticket.todo.done and done_page or active_page, ticket)
    end
  end
  local slots, sync = {}, opts.sync or {}
  local sprint = opts.sprint
  if sprint then
    local dates, bar, summary = progress(sprint, opts.now or os.time())
    slots[3] = line(sprint.name .. (dates and (" · " .. dates) or ""), "Title")
    if dates then slots[4], slots[5] = line(summary.text, summary.hl), { progress = bar } end
  else slots[3] = line("MY TICKETS", "Title") end
  local failed, blocked, threads = 0, 0, 0
  for _, ticket in ipairs(active) do
    failed = failed + (ticket.failed and 1 or 0)
    blocked = blocked + (ticket.blocked and 1 or 0)
    threads = threads + ticket.unresolved
  end
  if #todos > 0 then
    local pct = math.floor(#done / #todos * 100 + 0.5)
    local summary = ("%d/%d complete · %d%% / %d active"):format(#done, #todos, pct, #active)
    if failed + blocked + threads > 0 then summary = summary .. (" · CI %d · blocked %d · threads %d"):format(failed, blocked, threads) end
    slots[6] = line(summary, failed + blocked + threads > 0 and "Warning" or "Success")
  else slots[6] = line("0 tickets", "Muted") end
  local stale = sync.stale or (sync.sources and (sync.sources.jira == false or sync.sources.gitlab == false))
  local notice = require("deskboard.status").format({ title = "My tickets", error = sync.error,
    warnings = sync.warnings, cached = #todos > 0, running = sync.running, age = sync.age,
    estimated = sync.estimated, stale = stale, sources = sync.sources })
  if sync.text then notice.details[#notice.details + 1] = "- " .. sync.text end
  if failed + blocked + threads > 0 then
    notice.details[#notice.details + 1] = ("- Attention: %d CI failing · %d blocked · %d open threads"):format(failed, blocked, threads)
  end
  content = panel_header(opts, inner, slots, notice)
  if #todos > 0 then
    local cols = columns(rows, inner)
    local function cells(ticket)
      local parts = { chunk(ticket and ticket.todo.ticket == opts.current_ticket and "▸ " or "  ", "Accent") }
      for i, col in ipairs(cols) do
        local cell = ticket and ticket.cells[col.key] or { col.title, "Muted" }
        local value = fit(cell[1], col.width)
        if ticket and col.key == "mr" and ticket.ci ~= "" and value == cell[1] then
          parts[#parts + 1] = chunk(value:sub(1, #value - #ticket.ci), cell[2])
          parts[#parts + 1] = chunk(ticket.ci, ticket.ci_hl)
        else
          parts[#parts + 1] = chunk(value, cell[2])
        end
        parts[#parts + 1] = chunk(string.rep(" ", col.width - width(value)) .. (i < #cols and "  " or ""))
      end
      return parts
    end
    local function group(title, list, total)
      if #list == 0 then
        return
      end
      content[#content + 1] = { rule = true }
      content[#content + 1] = line(title .. " · " .. #list .. (page_info and ("/" .. total) or ""), "Title")
      content[#content + 1] = row(cells())
      for _, ticket in ipairs(list) do
        local key = ticket.todo.ticket
        local item = row(cells(ticket))
        item.ticket, item.mr_iid, item.mr_project = key, ticket.mr_iid, ticket.project
        item.jira_status = ticket.cells.status[1]
        item.action = function()
          if opts.on_checkout then
            opts.on_checkout(key)
          end
        end
        content[#content + 1] = item
      end
    end
    group("IN FLIGHT", active_page, #active)
    group("COMPLETED", done_page, #done)
    content[#content + 1] = { spacer = true }
    content[#content + 1] = { rule = true }
    if page_info then
      content[#content + 1] = line(("Page %d/%d · %d–%d of %d"):format(
        page_info.page, page_info.pages, page_info.first, page_info.last, page_info.total), "Muted")
      for _, pairs in ipairs(wrap_legend(NAV_HELP, inner)) do
        content[#content + 1] = row(legend_chunks(pairs, inner))
      end
    end
    for _, help in ipairs(MINE_HELP) do
      for _, pairs in ipairs(wrap_legend(help, inner)) do
        content[#content + 1] = row(legend_chunks(pairs, inner))
      end
    end
  else
    content[#content + 1] = { rule = true }
    content[#content + 1] = line("MY TICKETS · 0", "Title")
    content[#content + 1] = line(opts.project and "TICKET  PROJECT  STATUS  MR / CI" or "TICKET  STATUS  MR / CI", "Muted")
    content[#content + 1] = line("No tickets synced yet", "Muted")
  end
  append_card("SPRINT REVIEW", content, opts.frame)
  return items, page_info, notice
end

function M.review_label(mr)
  if type(mr.ticket) == "string" and mr.ticket:match("^%u[%u%d]*%-%d+$") then return mr.ticket end
  for _, value in ipairs({ mr.title or "", mr.source_branch or "" }) do
    if type(value) == "string" then
      local ticket = value:match("%f[%w](%u[%u%d]*%-%d+)%f[^%w]")
      if ticket then return ticket end
    end
  end
  return "!" .. mr.iid
end

function M.target_label(branch)
  if type(branch) ~= "string" or branch == "" then return "?" end
  branch = branch:gsub("^refs/heads/", "")
  return branch == "main" and "main" or branch:match("%f[%w](%u[%u%d]*%-%d+)%f[^%w]") or branch
end

local function review_columns(inner)
  local names = { "MR", "TICKET", "PROJECT", "AUTHOR", "COMMITS", "TARGET", "THREADS", "CI", "APPROVED", "MY THREADS" }
  local short = { "MR", "KEY", "PRJ", "BY", "#C", "TO", "THR", "CI", "APPR", "MINE" }
  local sizes, minima = { 7, 12, 10, 16, 7, 12, 7, 8, 10, 10 }, { 3, 8, 4, 8, 3, 8, 3, 2, 6, 3 }
  local gap = inner >= 64 and 2 or inner >= 25 and 1 or 0
  local available = inner - gap * (#names - 1)
  local function total()
    local n = 0
    for _, size in ipairs(sizes) do n = n + size end
    return n
  end
  local order = { 4, 8, 10, 5, 9, 7, 3, 6, 2, 1 }
  for _, minimum in ipairs({ minima, { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 } }) do
    for _, i in ipairs(order) do
      sizes[i] = sizes[i] - math.min(sizes[i] - minimum[i], math.max(0, total() - available))
    end
  end
  for _, spec in ipairs({ { 1, 10 }, { 4, 26 }, { 6, 18 }, { 2, 18 }, { 8, 10 } }) do
    sizes[spec[1]] = sizes[spec[1]] + math.min(spec[2] - sizes[spec[1]], math.max(0, available - total()))
  end
  local labels = {}
  for i, name in ipairs(names) do labels[i] = sizes[i] >= width(name) and name or short[i] end
  return sizes, labels, gap
end

local function review_count(value)
  return type(value) == "number" and value >= 0 and value == math.floor(value) and tostring(value) or "?"
end

local function thread_cell(value)
  if type(value) ~= "table" or review_count(value.resolved) == "?" or review_count(value.total) == "?"
    or value.resolved > value.total then return { "?", "Muted" } end
  return { value.resolved .. "/" .. value.total,
    value.total == 0 and "Muted" or value.resolved < value.total and "Warning" or "Success" }
end

local REVIEW_CI = {
  success = { "✓ pass", "✓", "Success" }, failed = { "✗ fail", "✗", "Error" },
  running = { "◷ run", "◷", "Warning" }, pending = { "◷ wait", "◷", "Warning" },
  preparing = { "◷ prep", "◷", "Warning" }, created = { "◷ wait", "◷", "Warning" },
  waiting_for_resource = { "◷ wait", "◷", "Warning" }, scheduled = { "◷ sched", "◷", "Warning" },
  skipped = { "− skip", "−", "Muted" }, canceled = { "− cancel", "−", "Muted" },
  manual = { "◷ manual", "◷", "Warning" }, none = { "—", "—", "Muted" },
}

function M.render_issues(opts)
  local state, queue = opts.state, opts.state.issues
  local outer = math.max(16, opts.frame and opts.frame.width or opts.width or M.width)
  local inner = outer - 6
  local function line(value, hl) return { text = { chunk(fit(value, inner), hl or "Muted") } } end
  state:set_total("mine", #queue.rows)
  local notice = require("deskboard.status").format({ title = "My GitHub issues", error = queue.error,
    warnings = queue.warnings, running = queue.loading, cached = queue.fetched_at ~= nil,
    stale = queue.from_cache or queue.fetched_at ~= nil and queue.now() - queue.fetched_at >= 300,
    age = queue.fetched_at and math.max(0, queue.now() - queue.fetched_at) or nil })
  local content = panel_header(opts, inner, {
    [3] = line("GitHub · " .. queue.project, "Title"),
    [4] = line(queue.user and ("Assigned to @" .. queue.user.username) or "Assigned issues"),
    [6] = line(#queue.rows .. " open issues · R refresh"),
  }, notice)
  content[#content + 1] = { rule = true }
  content[#content + 1] = line("MY ISSUES · " .. #queue.rows, "Title")
  local id_width, status_width = math.min(8, math.max(2, math.floor(inner * 0.15))), inner >= 32 and 6 or 3
  local title_width = math.max(1, inner - id_width - status_width - 2)
  local function cells(id, status, title, header)
    return { chunk(fit(id, id_width) .. string.rep(" ", math.max(0, id_width - width(fit(id, id_width)))) .. " ", header and "Muted" or "Accent"),
      chunk(fit(status, status_width) .. string.rep(" ", math.max(0, status_width - width(fit(status, status_width)))) .. " ", "Muted"),
      chunk(fit(title, title_width), header and "Muted" or "") }
  end
  content[#content + 1] = { text = cells("ISSUE", "STATE", "TITLE / LABELS", true) }
  local visible, page = require("deskboard.views").paginate(queue.rows, state.pages.mine, state.size)
  if #visible == 0 then content[#content + 1] = line(queue.fetched_at and "No assigned issues" or "No issue data yet") end
  for _, issue in ipairs(visible) do
    content[#content + 1] = { text = cells("#" .. issue.iid, issue.state or "?", issue.title .. (issue.labels and issue.labels ~= "" and (" · " .. issue.labels) or "")),
      id = "github:" .. issue.project .. "#" .. issue.iid, provider = "github", project = issue.project,
      issue_number = tostring(issue.iid), issue_title = issue.title, web_url = issue.web_url,
      action = function() if opts.on_open then opts.on_open(issue.web_url) end end }
  end
  content[#content + 1] = { spacer = true }
  content[#content + 1] = { rule = true }
  content[#content + 1] = line(("Page %d/%d · %d–%d of %d"):format(page.page, page.pages, page.first, page.last, page.total))
  for _, help in ipairs({ NAV_HELP, { { "o / Enter", "open issue" }, { "K / P", "details" }, { "R", "refresh" } } }) do
    for _, pairs in ipairs(wrap_legend(help, inner)) do content[#content + 1] = { text = legend_chunks(pairs, inner) } end
  end
  return card("MY GITHUB ISSUES", content, outer, opts.frame, opts.now), page, notice
end

function M.render_reviews(opts)
  local state = opts.state
  local outer = math.max(16, opts.frame and opts.frame.width or opts.width or M.width)
  local inner, content = outer - 6, {}
  local function line(value, hl)
    content[#content + 1] = { text = { chunk(fit(value, inner), hl or "Muted") } }
  end
  local filtered = state:review_rows()
  local slots = {
    [3] = { text = { chunk(fit(state.user and ("Reviewer: @" .. state.user.username) or "Assigned reviews", inner), "Title") } },
    [4] = { text = { chunk(fit(state.author and ("Author: @" .. state.author) or "Author: all", inner), "Muted") } },
    [6] = { text = { chunk(fit(("%d/%d reviews · a filter · A clear"):format(#filtered, #state.rows), inner), "Muted") } },
  }
  local notice = require("deskboard.status").format({ title = "Reviews for me", error = state.error,
    warnings = state.warnings or (state.warning and { state.warning } or {}), warning_label = "Metadata incomplete",
    running = state.loading, cached = state.fetched_at ~= nil,
    stale = state.from_cache or state.fetched_at ~= nil and state.now() - state.fetched_at >= 300,
    age = state.fetched_at and math.max(0, state.now() - state.fetched_at) or nil })
  content = panel_header(opts, inner, slots, notice)
  local visible, page = require("deskboard.views").paginate(filtered, state.pages.reviews, state.size)
  -- All ten columns stay present; widths depend on the frame, not the page.
  local sizes, labels, gap = review_columns(inner)
  if state.provider == "github" then labels[1], labels[2] = "PR", sizes[2] >= 5 and "TITLE" or "TXT" end
    local function cells(values, header)
      local parts = {}
      for i, cell in ipairs(values) do
        local value = fit(header and cell or cell[1], sizes[i])
        parts[#parts + 1] = chunk(value, header and "Muted" or cell[2])
        parts[#parts + 1] = chunk(string.rep(" ", sizes[i] - width(value)) .. (i < #sizes and string.rep(" ", gap) or ""))
      end
      return parts
    end
    content[#content + 1] = { rule = true }
    line("ASSIGNED REVIEWS · " .. #filtered, "Title")
    content[#content + 1] = { text = cells(labels, true) }
    if #visible == 0 then
      line(state.author and "No matches · A clears filter" or state.fetched_at and "No assigned reviews" or "No review data yet")
    end
    for _, mr in ipairs(visible) do
      local label = state.provider == "github" and mr.title or M.review_label(mr)
      local prefix = state.provider == "github" and "#" or "!"
      local ci = REVIEW_CI[mr.ci] or { "?", "?", "Muted" }
      local ci_text = width(ci[1]) <= sizes[8] and ci[1] or ci[2]
      local mine = mr.my_approved == true and "✓" or mr.my_approved == false and "—" or "?"
      local approved = mine .. " (" .. review_count(mr.other_approvals) .. ")"
      content[#content + 1] = {
        text = cells({
          { prefix .. mr.iid, "Accent" }, { label, "Key" }, { M.project_label(mr.project), "Muted" },
          { mr.author ~= "" and ("@" .. mr.author) or "?", "" },
          { review_count(mr.commits), "Accent" }, { M.target_label(mr.target_branch), "" },
          thread_cell(mr.threads), { ci_text, ci[3] },
          { approved, mr.my_approved == true and "Success" or mr.my_approved == false and "Warning" or "Muted" }, thread_cell(mr.my_threads),
        }),
        id = (state.provider == "github" and "github:" or "") .. mr.project .. prefix .. mr.iid,
        provider = state.provider or "gitlab", review = true, mr_iid = tostring(mr.iid), mr_project = mr.project,
        review_label = label, web_url = mr.web_url,
        review_metrics = { threads = mr.threads, my_threads = mr.my_threads, fetched_at = state.fetched_at,
          my_approved = mr.my_approved, other_approvals = mr.other_approvals },
        action = function() if opts.on_open then opts.on_open(mr.web_url) end end,
      }
    end
  content[#content + 1] = { spacer = true }
  content[#content + 1] = { rule = true }
  line(("Page %d/%d · %d–%d of %d"):format(page.page, page.pages, page.first, page.last, page.total))
  local review_help = state.provider == "github" and { { "Enter/o/x", "open PR" }, { "K/P", "preview" }, { "R", "refresh" } } or REVIEW_HELP
  for _, help in ipairs({ NAV_HELP, review_help, FILTER_HELP }) do
    for _, pairs in ipairs(wrap_legend(help, inner)) do
      content[#content + 1] = { text = legend_chunks(pairs, inner) }
    end
  end
  return card("REVIEWS FOR ME", content, outer, opts.frame, opts.now), page, notice
end

function M.render_notes(opts)
  local state = opts.state
  local outer = math.max(16, opts.frame and opts.frame.width or opts.width or M.width)
  local inner, content = outer - 6, {}
  local function line(value, hl)
    content[#content + 1] = { text = { chunk(fit(value, inner), hl or "Muted") } }
  end
  local notes = require("deskboard.notes")
  local rows = state:note_rows()
  local summary = notes.summary(state.notes)
  local filters = {}
  for _, key in ipairs({ "queue", "category", "status", "tag" }) do
    if state.note_filter[key] then filters[#filters + 1] = key .. ": " .. state.note_filter[key] end
  end
  local warnings = {}
  for _, note in ipairs(state.notes) do
    if notes.needs_review(note) then
      warnings[#warnings + 1] = note.title .. ": " .. (note.metadata_error or "Review requested/due")
    end
  end
  local notice = require("deskboard.status").format({ title = "Notes", local_only = true,
    warnings = warnings, warning_label = summary.review .. (summary.review == 1 and " note needs review" or " notes need review") })
  local slots = {
    [3] = { text = { chunk(fit(("Inbox %d · Review %d · Ready %d · Overdue %d"):format(summary.inbox, summary.review, summary.ready, summary.overdue), inner), "Title") } },
    [4] = { text = { chunk(fit(#filters > 0 and table.concat(filters, " · ") or "All local notes · private by default", inner), "Muted") } },
    [6] = { text = { chunk(fit(("%d/%d notes"):format(#rows, #state.notes), inner), "Muted") } },
  }
  content = panel_header(opts, inner, slots, notice)
  local visible, page = require("deskboard.views").paginate(rows, state.pages.notes, state.size)
  local gap = inner >= 44 and 2 or inner >= 24 and 1 or 0
  local available = inner - gap * 4
  local sizes = { 12, 34, 10, 24, 24 }
  for _, minimum in ipairs({ { 8, 12, 7, 10, 8 }, { 1, 1, 1, 1, 1 } }) do
    for _, i in ipairs({ 5, 4, 2, 1, 3 }) do
      local total = sizes[1] + sizes[2] + sizes[3] + sizes[4] + sizes[5]
      sizes[i] = sizes[i] - math.min(sizes[i] - minimum[i], math.max(0, total - available))
    end
  end
  sizes[2] = sizes[2] + math.max(0, available - sizes[1] - sizes[2] - sizes[3] - sizes[4] - sizes[5])
  local function cells(values, colors)
    local parts = {}
    for i, value in ipairs(values) do
      value = fit(value, sizes[i])
      parts[#parts + 1] = chunk(value, colors[i])
      parts[#parts + 1] = chunk(string.rep(" ", sizes[i] - width(value)) .. (i < 5 and string.rep(" ", gap) or ""))
    end
    return parts
  end
  content[#content + 1] = { rule = true }
  line("NOTES · " .. #rows, "Title")
  content[#content + 1] = { text = cells({ "ID", "TITLE", "STATUS", "CATEGORY", "TAGS" }, { "Muted", "Muted", "Muted", "Muted", "Muted" }) }
  if #visible == 0 then line(#state.notes > 0 and "No notes match · A clears filters" or "No notes yet · + creates one") end
  for _, note in ipairs(visible) do
    local warning = note.metadata_error or notes.needs_review(note)
    local status = note.metadata_error and "! metadata" or note.status or "inbox"
    content[#content + 1] = {
      text = cells({ note.uid or "—", note.title, status, (note.scope or "personal") .. "/" .. (note.category or "general"),
        #(note.tags or {}) > 0 and table.concat(note.tags, ", ") or "—" },
        { "Key", note.done and "Muted" or "Title", warning and "Warning" or notes.ready(note) and "Success" or "Muted", "Muted", "Muted" }),
      personal_note = true, id = note.id, note_title = note.title, note_data = note,
      action = function() if opts.on_open then opts.on_open(note) end end,
    }
  end
  content[#content + 1] = { spacer = true }
  content[#content + 1] = { rule = true }
  line(("Page %d/%d · %d–%d of %d"):format(page.page, page.pages, page.first, page.last, page.total))
  for _, help in ipairs({ NAV_HELP, NOTES_HELP, NOTE_FILTER_HELP, NOTE_ACTION_HELP }) do
    for _, pairs in ipairs(wrap_legend(help, inner)) do
      content[#content + 1] = { text = legend_chunks(pairs, inner) }
    end
  end
  return card("LOCAL NOTES", content, outer, opts.frame, opts.now), page, notice
end

function M.render_reminders(opts)
  local state = opts.state
  local outer = math.max(16, opts.frame and opts.frame.width or opts.width or M.width)
  local inner, content = outer - 6, {}
  local done = 0
  for _, row in ipairs(state.reminders) do done = done + (row.done and 1 or 0) end
  local notice = require("deskboard.status").format({ title = "Reminders", local_only = true })
  content = panel_header(opts, inner, {
    [3] = { text = { chunk(fit("QUICK CAPTURES", inner), "Title") } },
    [4] = { text = { chunk(fit(("%d open · %d done"):format(#state.reminders - done, done), inner), "Muted") } },
    [6] = { text = { chunk(fit("Separate from knowledge notes · Enter edits source", inner), "Muted") } },
  }, notice)
  local visible, page = require("deskboard.views").paginate(state.reminders, state.pages.reminders, state.size)
  local function line(value, hl) content[#content + 1] = { text = { chunk(fit(value, inner), hl or "Muted") } } end
  content[#content + 1] = { rule = true }
  line("REMINDERS · " .. #state.reminders, "Title")
  line("TITLE")
  if #visible == 0 then line("No reminders yet") end
  for _, row in ipairs(visible) do
    local marker = row.done and "✓ " or "○ "
    content[#content + 1] = {
      text = { chunk(marker, row.done and "Success" or "Muted"), chunk(fit(row.title, inner - width(marker)), "Title") },
      reminder = true, id = row.id, note_title = row.title,
      action = function() if opts.on_open then opts.on_open(row) end end,
    }
  end
  content[#content + 1] = { spacer = true }
  content[#content + 1] = { rule = true }
  line(("Page %d/%d · %d–%d of %d"):format(page.page, page.pages, page.first, page.last, page.total))
  for _, help in ipairs({ NAV_HELP, REMINDER_HELP }) do
    for _, pairs in ipairs(wrap_legend(help, inner)) do
      content[#content + 1] = { text = legend_chunks(pairs, inner) }
    end
  end
  return card("REMINDERS", content, outer, opts.frame, opts.now), page, notice
end

return M

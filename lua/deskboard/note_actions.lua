-- Explicit, local-only note actions. No Confluence writes or automatic saves.
local M = {}
local meta = require("deskboard.note_metadata")
local uv = vim.uv or vim.loop
local registered = {}

local function warn(message)
  vim.notify(message, vim.log.levels.WARN, { title = "Notes" })
end

local function writable()
  if require("deskboard.config").writable() then return true end
  warn("Note writes are disabled; enable notes.allow_writes explicitly")
  return false
end

local function inside(path, root)
  local base = uv.fs_realpath(root) or root
  local actual = uv.fs_realpath(path) or path
  return actual:sub(1, #base + 1) == base .. "/"
end

function M.current(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if vim.fn.fnamemodify(path, ":t"):lower() == "index.md" then return nil end
  for scope, root in pairs(require("deskboard.notes").roots()) do
    if path:sub(1, #root + 1) == root .. "/" and inside(path, root) then
      return require("deskboard.notes").describe(path, root, scope,
        uv.fs_stat(path) or { size = 0, mtime = { sec = 0, nsec = 0 } })
    end
  end
end

local function stamp(path)
  local stat = uv.fs_stat(path)
  return stat and (stat.size .. ":" .. stat.mtime.sec .. ":" .. stat.mtime.nsec) or nil
end

local function write_atomic(path, lines, before)
  local temporary = path .. ".tmp-" .. tostring(uv.hrtime())
  local stat = uv.fs_stat(path)
  local fd = uv.fs_open(temporary, "wx", stat and stat.mode % 512 or 384)
  if not fd then return false end
  local text = table.concat(lines, "\n") .. "\n"
  local written = uv.fs_write(fd, text, 0)
  uv.fs_close(fd)
  if written ~= #text or stamp(path) ~= before then uv.fs_unlink(temporary); return false end
  local ok = uv.fs_rename(temporary, path)
  if not ok then uv.fs_unlink(temporary) end
  return not not ok
end

local function index_plans(note, remove)
  local parent = note.index_root or (require("deskboard.config").get().notes.legacy_globals and vim.g.sprint_note_index_root)
    or require("deskboard.config").get().notes.index_root
    or (vim.fn.fnamemodify(note.root, ":t") == note.scope and vim.fn.fnamemodify(note.root, ":h") or note.root)
  local plans, seen = {}, {}
  local title = note.title:gsub("\\", "\\\\"):gsub("%[", "\\["):gsub("%]", "\\]")
  for _, dir in ipairs({ vim.fn.fnamemodify(note.path, ":h"), note.root, parent }) do
    local path = dir .. "/index.md"
    if not seen[path] then
      seen[path] = true
      local buf, stat = vim.fn.bufnr(path), uv.fs_lstat(path)
      if (buf >= 0 and (vim.bo[buf].modified or vim.bo[buf].readonly))
        or (stat and (stat.type ~= "file" or not uv.fs_access(path, "w"))) then
        return nil, "An index is modified, read-only or unsafe; resolve it first"
      end
      if stat or not remove then
        local before = stamp(path)
        local ok, original = pcall(vim.fn.readfile, path)
        if not ok then
          if stat then return nil, "Cannot read an index" end
          original = { "# Notes", "" }
        end
        local lines = {}
        local relative = note.path:sub(#dir + 2):gsub("[^%w%-%._~/]", function(c) return ("%%%02X"):format(c:byte()) end)
        local suffix, found = "](" .. relative .. ")", false
        for _, line in ipairs(original) do
          local start, finish = line:find(suffix, 1, true)
          if start then
            found = true
            if remove then
              local prefix, tail = line:sub(1, start - 1), vim.trim(line:sub(finish + 1))
              if not prefix:match("^%s*%-%s*%[") or prefix:find("](", 1, true) or tail ~= "" then
                return nil, "Index uses a custom link layout; remove that link manually before deleting"
              end
            else
              lines[#lines + 1] = line:match("^%s*%-%s*%[") and ("- [" .. title .. suffix) or line
            end
          else lines[#lines + 1] = line end
        end
        if not found and not remove then
          if lines[#lines] ~= "" then lines[#lines + 1] = "" end
          lines[#lines + 1] = "- [" .. title .. suffix
        end
        if not stat or not vim.deep_equal(lines, original) then
          plans[#plans + 1] = { path = path, lines = lines, original = original, before = before }
        end
      end
    end
  end
  return plans
end

local function refresh_indexes(plans)
  for _, plan in ipairs(plans) do
    local buf = vim.fn.bufnr(plan.path)
    if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
      local autoread = vim.bo[buf].autoread
      vim.bo[buf].autoread = true
      vim.api.nvim_buf_call(buf, function() vim.cmd("checktime") end)
      vim.bo[buf].autoread = autoread
    end
  end
end

local function rollback_indexes(plans)
  for _, plan in ipairs(plans) do
    if plan.after and stamp(plan.path) == plan.after then
      if plan.before then write_atomic(plan.path, plan.original, plan.after) else uv.fs_unlink(plan.path) end
    end
  end
end

local function apply_indexes(plans)
  for _, plan in ipairs(plans) do
    if not write_atomic(plan.path, plan.lines, plan.before) then rollback_indexes(plans); return false end
    plan.after = stamp(plan.path)
  end
  return true
end

function M.index(note)
  if not writable() then return false end
  if not note or note.kind ~= "file" or not note.root or not inside(note.path, note.root) then return false end
  local plans, err = index_plans(note)
  if not plans or not apply_indexes(plans) then
    warn((err or "Index changed or could not be written") .. "; note content is safe. Run :DeskboardNotesIndex to retry.")
    return false
  end
  refresh_indexes(plans)
  return true
end

function M.watch(_note, buf)
  if not require("deskboard.config").writable() then return end
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.b[buf].deskboard_note_watched then return end
  vim.b[buf].deskboard_note_watched = true
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("deskboard_note_watches", { clear = false }),
    buffer = buf,
    callback = function(event)
      if not require("deskboard.config").writable() then return end
      local current = M.current(event.buf)
      if current then M.index(current) end
    end,
    desc = "Maintain note/category/unified indexes after explicit saves",
  })
end

local function dates(today)
  local t = os.date("*t", today or os.time())
  local reviewed = os.date("%Y-%m-%d", today or os.time())
  local interval = math.max(1, math.floor(tonumber(require("deskboard.config").get().notes.legacy_globals and vim.g.sprint_note_review_days)
    or require("deskboard.config").get().notes.review_days))
  return reviewed, os.date("%Y-%m-%d", os.time({ year = t.year, month = t.month, day = t.day + interval, hour = 12 }))
end

function M.edit(note, changes)
  if not writable() then return false end
  if not note or note.kind ~= "file" or not note.root or not inside(note.path, note.root) then
    warn("Reminder entries need a standalone Markdown note first (:DeskboardNotesNew).")
    return false
  end
  require("deskboard.notes").open(note)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local current = meta.parse(lines)
  if not current.valid then warn(current.error .. "; fix the frontmatter first."); return false end
  local values = vim.tbl_extend("force", {}, changes)
  if not current.uid and not values.id then
    local id, err = require("deskboard.note_ids").next()
    if not id then warn(err); return false end
    values.id = id
  end
  local updated, err = meta.update(lines, values)
  if not updated then warn(err); return false end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, updated)
  vim.notify("Local note updated in buffer; :w saves it. Nothing was published.", vim.log.levels.INFO, { title = "Notes" })
  return true
end

function M.status(note)
  if not writable() then return end
  local options = { "inbox", "draft", "review", "ready", "archived" }
  vim.ui.select(options, { prompt = "Local note status (no publication)" }, function(value)
    if not value then return end
    local changes = { status = value }
    if value == "ready" then
      vim.ui.select({ "Cancel", "I checked context, examples, links, duplicates, and secrets" }, { prompt = "Confirm local review" }, function(choice)
        if choice ~= "I checked context, examples, links, duplicates, and secrets" then return end
        changes.reviewed, changes.review_due = dates()
        M.edit(note, changes)
      end)
    else M.edit(note, changes) end
  end)
end

function M.reviewed(note)
  if not writable() then return end
  vim.ui.select({ "Cancel", "Mark reviewed locally" }, { prompt = "Review completed? No publication will occur." }, function(value)
    if value ~= "Mark reviewed locally" then return end
    local reviewed, due = dates()
    M.edit(note, { reviewed = reviewed, review_due = due })
  end)
end

function M.visibility(note)
  if not writable() then return end
  vim.ui.select({ "private", "team" }, { prompt = "Visibility (private is excluded from publication queue)" }, function(value)
    if not value then return end
    if value == "private" then M.edit(note, { visibility = value }); return end
    vim.ui.select({ "Cancel", "Allow this note in the team publication queue" }, { prompt = "Confirm no private data/secrets" }, function(choice)
      if choice == "Allow this note in the team publication queue" then M.edit(note, { visibility = "team" }) end
    end)
  end)
end

function M.create(opts)
  if not writable() then return nil, "Note writes are disabled" end
  opts = opts or {}
  local root = require("deskboard.notes").roots(opts)[opts.scope or "personal"]
  local category = opts.category or "inbox"
  if not root or category == "" or #category > 160 then return nil, "Invalid note scope/category" end
  for part in (category .. "/"):gmatch("(.-)/") do
    if not part:match("^[a-z0-9][a-z0-9%-]*$") then return nil, "Use lowercase category segments, not paths/traversal" end
  end
  local title = vim.trim(opts.title or "")
  if title == "" or title:find("[%z\1-\31\127]") then return nil, "A single-line title is required" end
  local slug = title:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if slug == "" or slug == "index" then return nil, "Choose a title with a usable, non-index filename" end
  local dir = root
  for part in category:gmatch("[^/]+") do
    dir = dir .. "/" .. part
    local stat = uv.fs_lstat(dir)
    if stat and stat.type ~= "directory" then return nil, "Category must not contain symlinks or files" end
  end
  local path = dir .. "/" .. slug .. ".md"
  if uv.fs_lstat(path) or vim.fn.bufnr(path) >= 0 then return nil, "A note with that filename already exists" end
  local made = pcall(vim.fn.mkdir, dir, "p")
  if not made or not uv.fs_stat(dir) or uv.fs_stat(dir).type ~= "directory" then return nil, "Cannot create note category" end
  local id, allocation_error = require("deskboard.note_ids").next(opts)
  if not id then return nil, allocation_error end
  vim.cmd.edit(vim.fn.fnameescape(path))
  local values = { "---", "id: " .. vim.json.encode(id),
    "title: " .. vim.json.encode(title), "type: note", "status: inbox", "visibility: private",
    "tags: " .. vim.json.encode(opts.tags or {}), "---", "", "# " .. title, "", "## Purpose", "",
    "## Procedure", "", "## Verification", "", "## References", "", "## Review checklist", "",
    "- [ ] Context is clear", "- [ ] Examples verified", "- [ ] Links checked",
    "- [ ] Duplicates checked", "- [ ] No secrets or private information", "" }
  vim.api.nvim_buf_set_lines(0, 0, -1, false, values)
  M.watch({ kind = "file", path = path, root = root, scope = opts.scope or "personal" })
  return path
end

function M.new_prompt()
  if not writable() then return end
  local roots = require("deskboard.notes").roots()
  local scopes = vim.tbl_keys(roots); table.sort(scopes)
  vim.ui.select(scopes, { prompt = "Choose private/publishable vault" }, function(scope)
    if not scope then return end
    vim.ui.input({ prompt = "Note title: " }, function(title)
      if not title or vim.trim(title) == "" then return end
      vim.ui.input({ prompt = "Category (folder path): ", default = "inbox" }, function(category)
        if not category then return end
        vim.ui.input({ prompt = "Tags (comma-separated, optional): ", default = "" }, function(raw)
          if raw == nil then return end
          local tags = {}; for tag in raw:gmatch("[^,]+") do tags[#tags + 1] = vim.trim(tag):lower() end
          local _, err = M.create({ scope = scope, title = title, category = category, tags = tags })
          if err then warn(err) end
        end)
      end)
    end)
  end)
end

local function managed(note)
  if not note or note.kind ~= "file" or type(note.path) ~= "string" or not note.root
    or vim.fn.fnamemodify(note.path, ":t"):lower() == "index.md" then return false end
  for _, root in pairs(require("deskboard.notes").roots()) do
    if (uv.fs_realpath(root) or root) == (uv.fs_realpath(note.root) or note.root)
      and inside(note.path, root) then return true end
  end
  return false
end

local function file_signature(path)
  local stat = uv.fs_lstat(path)
  if not stat or stat.type ~= "file" then return nil end
  return table.concat({ stat.dev, stat.ino, stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
end

local function note_buffers(path)
  local buffers, source = {}, uv.fs_stat(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local stat = name ~= "" and uv.fs_stat(name) or nil
    if name == path or (source and stat and source.ino == stat.ino and source.dev == stat.dev) then
      if vim.bo[buf].modified then return nil end
      buffers[#buffers + 1] = buf
    end
  end
  return buffers
end

function M.delete(note, done)
  if not writable() then if done then done(false) end; return end
  done = done or function() end
  if not managed(note) or not note.path:lower():match("%.md$") or not file_signature(note.path) then
    warn("Delete is only for saved, managed Markdown notes, not reminders, indexes or symlinks."); done(false); return
  end
  if not note_buffers(note.path) then warn("Save or discard unsaved note changes before deleting."); done(false); return end
  note = require("deskboard.notes").describe(note.path, note.root, note.scope) or note
  local before = file_signature(note.path)
  vim.ui.select({ "Cancel", "Move note to trash" }, {
    prompt = "Delete " .. (note.uid or "legacy note") .. " — " .. note.path .. "?",
  }, function(choice)
    if choice ~= "Move note to trash" then done(false); return end
    local buffers = note_buffers(note.path)
    if not buffers or not managed(note) or file_signature(note.path) ~= before then
      warn("Note changed while confirming; nothing was deleted. Retry after reviewing it."); done(false); return
    end
    local plans, err = index_plans(note, true)
    if not plans then warn(err .. "; nothing was deleted."); done(false); return end
    local trash = note.root .. "/.trash"
    local stat = uv.fs_lstat(trash)
    if stat and stat.type ~= "directory" then warn("Unsafe note trash directory"); done(false); return end
    if not stat and not uv.fs_mkdir(trash, 448) then warn("Cannot create local note trash"); done(false); return end
    if not inside(trash, note.root) then warn("Trash must stay inside the note vault"); done(false); return end
    local bundle = trash .. "/" .. (note.uid or "legacy"):gsub("[^%w%-]", "_") .. "-" .. tostring(uv.hrtime())
    if not uv.fs_mkdir(bundle, 448) then warn("Cannot create note recovery directory"); done(false); return end
    local target = bundle .. "/" .. vim.fn.fnamemodify(note.path, ":t")
    local manifest = bundle .. "/recovery.json"
    local fd = uv.fs_open(manifest, "wx", 384)
    local data = vim.json.encode({ version = 1, original_path = note.path, uid = note.uid,
      scope = note.scope, deleted_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), title = note.title }) .. "\n"
    local written = fd and uv.fs_write(fd, data, 0)
    if fd then uv.fs_close(fd) end
    if written ~= #data or file_signature(note.path) ~= before or not uv.fs_rename(note.path, target) then
      uv.fs_unlink(manifest); uv.fs_rmdir(bundle)
      warn("Note could not be moved; source content was not deleted."); done(false); return
    end
    if not apply_indexes(plans) then
      if not uv.fs_lstat(note.path) and uv.fs_rename(target, note.path) then
        uv.fs_unlink(manifest); uv.fs_rmdir(bundle)
        warn("Index update failed; the note was restored. Review indexes and retry.")
      else warn("Index update failed; recover the note from " .. target) end
      done(false); return
    end
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = false }) end
    end
    refresh_indexes(plans)
    vim.notify("Note moved to local trash: " .. target, vim.log.levels.INFO, { title = "Notes" })
    if _G.Snacks and Snacks.dashboard then pcall(Snacks.dashboard.update) end
    done(true, target)
  end)
end

function M.assign_id(note)
  if not writable() then return end
  if not managed(note) then warn("Open a managed Markdown note first"); return end
  local current = require("deskboard.notes").describe(note.path, note.root, note.scope) or note
  local before = current.uid
  vim.ui.select({ "Cancel", "Assign new NOTE ID" }, {
    prompt = "Replace " .. (before or "missing ID") .. "? Existing references may need updating; :w saves.",
  }, function(choice)
    if choice ~= "Assign new NOTE ID" then return end
    local fresh = require("deskboard.notes").describe(note.path, note.root, note.scope) or note
    if fresh.uid ~= before then warn("Note ID changed while confirming; retry"); return end
    local id, err = require("deskboard.note_ids").next()
    if not id then warn(err); return end
    M.edit(note, { id = id, previous_id = before })
  end)
end

function M.browser(note)
  if not managed(note) then warn("Open a standalone managed note first"); return false end
  local exposed = vim.g.mkdp_open_to_the_world
  if exposed ~= nil and exposed ~= false and exposed ~= 0 and exposed ~= "0" then
    warn("Refusing network-exposed note preview. Disable mkdp_open_to_the_world and restart its preview server first.")
    return false
  end
  require("deskboard.notes").open(note) -- keep unsaved text, never auto-save
  vim.bo.filetype = "markdown"
  if vim.fn.exists(":MarkdownPreview") ~= 2 then
    warn("Browser preview requires markdown-preview.nvim; install/build it with :Lazy."); return false
  end
  local ok = pcall(vim.cmd, "MarkdownPreview")
  if not ok then warn("Browser preview could not start; check :Lazy build markdown-preview.nvim.") end
  return ok
end

function M.details(note, owner)
  if not note then return end
  if note.kind == "file" then
    local current = require("deskboard.notes").describe(note.path, note.root, note.scope) or note
    -- ID uniqueness is checked by the vault index, not a single-file parse.
    if note.metadata_error == "Duplicate note ID" then
      current.metadata_error, current.visibility = note.metadata_error, "private"
    end
    note = current
  end
  local ready = require("deskboard.notes").ready(note)
  local lines = { "# " .. note.title, "", "- ID: " .. (note.uid or "legacy / none"),
    "- Previous ID: " .. (note.previous_id or "none"),
    "- Category: " .. (note.scope or "reminders") .. "/" .. (note.category or "general"),
    "- Type: " .. (note.note_type or "reminder"), "- Status: " .. (note.status or "inbox"),
    "- Visibility: " .. (note.visibility or "private"), "- Tags: " .. table.concat(note.tags or {}, ", "),
    "- Reviewed: " .. (note.reviewed or "not yet"), "- Review due: " .. (note.review_due or "not scheduled"),
    "- Ready to publish locally: " .. (ready and "yes" or "no"),
    "- Buffer: " .. (note.dirty and "unsaved changes (:w saves)" or "saved"), "", "> No Confluence publishing is configured.", "",
    "- File: " .. note.path }
  if note.metadata_error then vim.list_extend(lines, { "", "> Metadata needs attention: " .. note.metadata_error }) end
  for i, line in ipairs(lines) do lines[i] = line:gsub("[%z\1-\31\127]", " ") end
  local popup = require("deskboard.preview").popup(owner, lines, { title = " Note details · q close ", glow = false })
  if popup then
    local group = vim.api.nvim_create_augroup("note_details_" .. owner.buf, { clear = true })
    vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
      group = group, buffer = owner.buf, callback = function() vim.schedule(function() popup:close() end) end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = popup.buf, once = true,
      callback = function() pcall(vim.api.nvim_del_augroup_by_id, group) end })
  end
  return popup
end

function M.search(notes)
  notes = notes or require("deskboard.notes").list()
  local paths, seen = {}, {}
  for _, note in ipairs(notes) do
    if note.kind ~= "reminder" and not seen[note.path] then paths[#paths + 1] = note.path; seen[note.path] = true end
  end
  if #paths == 0 then warn("No standalone Markdown notes match the filters; capture reminder entries with :DeskboardNotesNew first"); return end
  local ok, telescope = pcall(require, "telescope.builtin")
  if not ok then warn("Telescope is required for full-text note search"); return end
  telescope.live_grep({ search_dirs = paths, prompt_title = "Local notes · literal full-text search",
    additional_args = { "--fixed-strings" } })
end

function M.dispose()
  pcall(vim.api.nvim_del_augroup_by_name, "deskboard_note_workflow")
  pcall(vim.api.nvim_del_augroup_by_name, "deskboard_note_watches")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do vim.b[buf].deskboard_note_watched = nil end
end

function M.setup()
  M.dispose()
  for _, name in ipairs(registered) do pcall(vim.api.nvim_del_user_command, name) end
  registered = {}
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = vim.api.nvim_create_augroup("deskboard_note_workflow", { clear = true }), pattern = "*.md",
    callback = function(event)
      local note = M.current(event.buf)
      if note then M.watch(note, event.buf) end
    end,
    desc = "Watch managed notes only; never project Markdown or indexes",
  })
  local function command(name, callback)
    vim.api.nvim_create_user_command("Deskboard" .. name, callback, { force = true })
    registered[#registered + 1] = "Deskboard" .. name
    if require("deskboard.config").get().compat_commands then
      vim.api.nvim_create_user_command(name, callback, { force = true }); registered[#registered + 1] = name
    end
  end
  command("NotesNew", M.new_prompt)
  for name, fn in pairs({ NotesStatus = M.status, NotesReviewed = M.reviewed, NotesVisibility = M.visibility,
    NotesIndex = M.index, NotesDelete = M.delete, NotesAssignID = M.assign_id, NotesBrowser = M.browser }) do
    command(name, function()
      local note = M.current()
      if not note then warn("Open a managed Markdown note first"); return end
      fn(note)
    end)
  end
  command("NotesSearch", function() M.search() end)
  if require("deskboard.config").writable() then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then local note = M.current(buf); if note then M.watch(note, buf) end end
    end
  end
end

return M

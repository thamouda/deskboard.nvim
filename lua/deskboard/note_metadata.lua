-- Safe, deliberately small YAML-frontmatter schema. No YAML execution/tags.
-- Supports scalar workflow fields and inline/block tag lists; preserves other
-- fields verbatim when editing. Unsupported workflow values fail closed.
local M = { statuses = { "inbox", "draft", "review", "ready", "published", "archived" } }
local known = { id = true, previous_id = true, title = true, type = true, status = true, visibility = true,
  tags = true, reviewed = true, review_due = true }
local statuses = {}; for _, value in ipairs(M.statuses) do statuses[value] = true end

function M.date(value)
  if type(value) ~= "string" then return false end
  local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return false end
  local ok, stamp = pcall(os.time, { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  if not ok or not stamp then return false end
  local actual = os.date("*t", stamp)
  return actual.year == tonumber(y) and actual.month == tonumber(m) and actual.day == tonumber(d)
end

local function scalar(value)
  value = vim.trim(value)
  if value:sub(1, 1) == '"' then
    local escaped = false
    for i = 2, #value do
      local c = value:sub(i, i)
      if c == '"' and not escaped then
        local tail = vim.trim(value:sub(i + 1))
        if tail ~= "" and tail:sub(1, 1) ~= "#" then return nil, "Invalid quoted metadata" end
        local ok, result = pcall(vim.json.decode, value:sub(1, i))
        if ok and type(result) == "string" then return result end
        return nil, "Invalid quoted metadata"
      end
      escaped = c == "\\" and not escaped
    end
    return nil, "Unclosed metadata quote"
  elseif value:sub(1, 1) == "'" then
    local result, i = "", 2
    while i <= #value do
      local c = value:sub(i, i)
      if c == "'" then
        if value:sub(i + 1, i + 1) == "'" then result = result .. "'"; i = i + 1
        else
          local tail = vim.trim(value:sub(i + 1))
          if tail == "" or tail:sub(1, 1) == "#" then return result end
          return nil, "Invalid quoted metadata"
        end
      else result = result .. c end
      i = i + 1
    end
    return nil, "Unclosed metadata quote"
  end
  value = vim.trim(value:gsub("%s+#.*$", ""))
  if value == "" or value == "null" or value == "~" or value:sub(1, 1) == "#" then return nil end
  if value:find("^[%[%]{|>&*!]") or value:find(":%s") then return nil, "Unsupported workflow metadata value" end
  return value
end

local function tags(value)
  local result, seen = {}, {}
  local function add(raw)
    local v, err = scalar(raw)
    if err then return err end
    if v then
      if v:find("[%z\1-\31\127]") then return "Tags must be single-line text" end
      v = vim.trim(v):lower()
      if v ~= "" and not seen[v] then seen[v] = true; result[#result + 1] = v end
    end
  end
  if type(value) == "table" then
    for _, raw in ipairs(value) do local err = add(raw); if err then return nil, err end end
  else
    local inside, tail = value:match("^%s*%[(.*)%](.*)$")
    if not inside or (vim.trim(tail) ~= "" and vim.trim(tail):sub(1, 1) ~= "#") then return nil, "Tags must be a YAML list" end
    local start, quote, escape = 1, nil, false
    for i = 1, #inside + 1 do
      local c = inside:sub(i, i)
      if quote then
        if c == quote and not escape then quote = nil end
        escape = c == "\\" and not escape
      elseif c == '"' or c == "'" then quote = c
      elseif c == "," or i > #inside then
        local err = add(inside:sub(start, i - 1)); if err then return nil, err end
        start = i + 1
      end
    end
    if quote then return nil, "Unclosed tag quote" end
  end
  table.sort(result)
  return result
end

function M.parse(lines)
  local meta = { status = "inbox", visibility = "private", type = "note", tags = {}, valid = true }
  if (lines[1] or ""):gsub("\r$", "") ~= "---" then return meta end
  local finish
  for i = 2, math.min(64, #lines) do
    local line = lines[i]:gsub("\r$", "")
    if line == "---" or line == "..." then finish = i; break end
  end
  if not finish then meta.valid, meta.error = false, "Frontmatter is unclosed or exceeds 64 lines"; return meta end
  meta.finish, meta.fields = finish, {}
  local active
  for i = 2, finish - 1 do
    local line = lines[i]:gsub("\r$", "")
    local key, raw = line:match("^([%w_]+):%s*(.*)$")
    if key then
      active = nil
      if known[key] then
        if meta.fields[key] then meta.valid, meta.error = false, "Duplicate workflow metadata field"; return meta end
        meta.fields[key] = i
        if key == "tags" and (raw == "" or raw:match("^#")) then
          meta.raw_tags, active = {}, "tags"
        else
          local value, err
          if key == "tags" then value, err = tags(raw) else value, err = scalar(raw) end
          if err then meta.valid, meta.error = false, err; return meta end
          if key == "id" then meta.uid = value else meta[key] = value end
        end
      end
    elseif active == "tags" and line:match("^%s*%-%s+") then
      meta.raw_tags[#meta.raw_tags + 1] = line:match("^%s*%-%s+(.*)$")
    elseif line:match("^%s*$") or line:match("^%s*#") then
      -- Comments do not terminate a block list.
    elseif active == "tags" then
      meta.valid, meta.error = false, "Unsupported tag list"; return meta
    end
  end
  if meta.raw_tags then
    local values, err = tags(meta.raw_tags)
    if err then meta.valid, meta.error = false, err; return meta end
    meta.tags = values
  end
  meta.tags = meta.tags or {}
  if meta.status == "to-review" or meta.status == "to review" then meta.status = "review" end
  if not statuses[meta.status] or (meta.visibility ~= "private" and meta.visibility ~= "team") then
    meta.valid, meta.error = false, "Invalid status or visibility"
  end
  if meta.fields.title and (not meta.title or vim.trim(meta.title) == "") then
    meta.valid, meta.error = false, "A metadata title must not be empty"
  end
  if meta.uid and not meta.uid:match("^[%w_:%-%.]+$") then meta.valid, meta.error = false, "Invalid note ID" end
  for _, field in ipairs({ "reviewed", "review_due" }) do
    if meta[field] and not M.date(meta[field]) then meta.valid, meta.error = false, "Invalid review date" end
  end
  return meta
end

function M.update(lines, changes)
  local meta = M.parse(lines)
  if not meta.valid then return nil, meta.error end
  local result = vim.deepcopy(lines)
  if not meta.finish then
    result = { "---", "---", "" }
    vim.list_extend(result, lines)
    meta.finish, meta.fields = 2, {}
  end
  -- Only scalar workflow fields are edited here; unknown/nested fields and
  -- the complete body remain untouched. Tags can be edited in the buffer.
  for _, key in ipairs({ "id", "previous_id", "title", "type", "status", "visibility", "reviewed", "review_due" }) do
    if changes[key] ~= nil then
      local value = key .. ": " .. vim.json.encode(changes[key])
      if meta.fields[key] then result[meta.fields[key]] = value
      else table.insert(result, meta.finish, value); meta.finish = meta.finish + 1 end
    end
  end
  local checked = M.parse(result)
  if not checked.valid then return nil, checked.error end
  return result
end

return M

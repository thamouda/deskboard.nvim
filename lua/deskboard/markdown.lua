-- Read-only conversion for the sprint popup: Jira wiki/ADF -> Markdown.
-- Code is never executed; preserve it verbatim inside language-aware fences.
local M = {}

local aliases = {
  pl = "perl",
  py = "python",
  js = "javascript",
  ts = "typescript",
  sh = "bash",
  shell = "bash",
  shellscript = "bash",
  yml = "yaml",
  ["c++"] = "cpp",
  ["c#"] = "csharp",
  ps1 = "powershell",
  console = "text",
  none = "text",
  plain = "text",
  plaintext = "text",
  noformat = "text",
}
local function language(value)
  local name = type(value) == "string" and vim.trim(value):lower() or "text"
  name = name:match("^[%w_+.#%-]+") or "text"
  return aliases[name] or name
end

local function longest_ticks(text)
  local n = 0
  for ticks in text:gmatch("`+") do
    n = math.max(n, #ticks)
  end
  return n
end

local function code_span(text)
  text = type(text) == "string" and text or ""
  local fence = string.rep("`", longest_ticks(text) + 1)
  local padding = text:match("^[` ]") or text:match("[` ]$")
  return fence .. (padding and " " or "") .. text .. (padding and " " or "") .. fence
end

local function fenced(code, lang)
  local fence = string.rep("`", math.max(3, longest_ticks(code) + 1))
  return fence .. language(lang) .. "\n" .. code .. (code:sub(-1) == "\n" and "" or "\n") .. fence
end

-- Only CommonMark-style fences (up to three leading spaces). Four-space
-- indented code must not accidentally become a new top-level fenced block.
local function fence_line(line)
  local indent, run, info = line:match("^( *)(`+)(.*)$")
  if not run then
    indent, run, info = line:match("^( *)(~+)(.*)$")
  end
  if run and #run >= 3 and #indent <= 3 then
    return indent, run, info
  end
end

local function closes(line, active)
  local _, run, info = fence_line(line)
  return run and run:sub(1, 1) == active.run:sub(1, 1) and #run >= #active.run and vim.trim(info) == ""
end

local function wiki_inline(text)
  -- Protect inline code before converting emphasis or links. Use a marker
  -- that cannot collide with the source, then restore every protected span.
  local marker = "SPRINT_CODE_PLACEHOLDER_"
  while text:find(marker, 1, true) do
    marker = marker .. "_"
  end
  local saved = {}
  local function keep(value)
    saved[#saved + 1] = value
    return marker .. #saved .. "_END"
  end
  local out, pos = {}, 1
  while pos <= #text do
    local first, last = text:find("`+", pos)
    local wf, wl, code = text:find("{{(.-)}}", pos)
    if wf and (not first or wf < first) then
      out[#out + 1] = text:sub(pos, wf - 1)
      out[#out + 1] = keep(code_span(code))
      pos = wl + 1
    elseif first then
      out[#out + 1] = text:sub(pos, first - 1)
      local ticks = text:sub(first, last)
      local finish, closing = text:find(ticks, last + 1, true)
      while finish and (text:sub(finish - 1, finish - 1) == "`" or text:sub(closing + 1, closing + 1) == "`") do
        finish, closing = text:find(ticks, closing + 1, true)
      end
      if finish then
        out[#out + 1] = keep(text:sub(first, closing))
        pos = closing + 1
      else
        out[#out + 1] = ticks
        pos = last + 1
      end
    else
      out[#out + 1] = text:sub(pos)
      break
    end
  end
  text = table.concat(out)
  text = text:gsub("(%*+)(.-)%1", function(stars, value)
    return (#stars == 1 and "**" or stars) .. value .. (#stars == 1 and "**" or stars)
  end)
  text = text:gsub("%[([^%]|]+)|([^%]]+)%]", function(label, url)
    return "[" .. label .. "](" .. url .. ")"
  end)
  text = text:gsub("%[([%a][%w+.-]*://[^%]]+)%]", "<%1>")
  return (text:gsub(vim.pesc(marker) .. "(%d+)_END", function(index)
    return saved[tonumber(index)]
  end))
end

local function wiki_line(line)
  local level, heading = line:match("^%s*h([1-6])%.%s+(.*)$")
  if level then
    return string.rep("#", math.min(6, tonumber(level) + 3)) .. " " .. wiki_inline(heading)
  end
  local indent, marks, value = line:match("^( *)([%*#]+)%s+(.*)$")
  if marks then
    return indent .. string.rep("  ", #marks - 1) .. (marks:sub(-1) == "#" and "1. " or "- ") .. wiki_inline(value)
  end
  local quote = line:match("^bq%.%s+(.*)$")
  if quote then
    return "> " .. wiki_inline(quote)
  end
  return wiki_inline(line)
end

local function wiki_language(attrs)
  local named = attrs:match("language=([^|]+)")
  return language(named or attrs:match("^:([^|]+)") or "text")
end

local function wiki_open(text)
  local ranges = {}
  for first, last in text:gmatch("(){{.-}}()") do
    ranges[#ranges + 1] = { first, last - 1 }
  end
  local pos = 1
  while pos <= #text do
    local first, last = text:find("`+", pos)
    if not first then
      break
    end
    local closing, finish = text:find(text:sub(first, last), last + 1, true)
    if not closing then
      break
    end
    ranges[#ranges + 1] = { first, finish }
    pos = finish + 1
  end
  local function protected(index)
    for _, range in ipairs(ranges) do
      if index >= range[1] and index <= range[2] then
        return true
      end
    end
    return false
  end
  pos = 1
  while true do
    local first, last, attrs = text:find("{code([^}]*)}", pos)
    local nf, nl = text:find("{noformat}", pos, true)
    local kind = "code"
    if nf and (not first or nf < first) then
      first, last, attrs, kind = nf, nl, "", "noformat"
    end
    if not first then
      return nil
    end
    if not protected(first) and (attrs == "" or attrs:sub(1, 1) == ":") then
      return first, last, attrs, kind
    end
    pos = last + 1
  end
end

local function wiki(text)
  local out, code, markdown = {}, nil, nil
  local function emit_code()
    out[#out + 1] = ""
    out[#out + 1] = fenced(table.concat(code.lines, "\n"), code.lang)
    out[#out + 1] = ""
    code = nil
  end
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if markdown then
      out[#out + 1] = line
      if closes(line, markdown) then
        markdown = nil
      end
    else
      local indent, run = fence_line(line)
      if not code and run then
        markdown = { indent = indent, run = run }
        out[#out + 1] = line
      else
        local rest = line
        while true do
          if code then
            local first, last = rest:find("{" .. code.kind .. "}", 1, true)
            if first then
              code.lines[#code.lines + 1] = rest:sub(1, first - 1)
              rest = rest:sub(last + 1)
              emit_code()
              if rest == "" then
                break
              end
            else
              code.lines[#code.lines + 1] = rest
              break
            end
          else
            local first, last, attrs, kind = wiki_open(rest)
            if not first then
              out[#out + 1] = wiki_line(rest)
              break
            end
            local before = rest:sub(1, first - 1)
            if before ~= "" then
              out[#out + 1] = wiki_line(before)
            end
            code = { kind = kind, lang = kind == "code" and wiki_language(attrs) or "text", lines = {} }
            rest = rest:sub(last + 1)
            if rest == "" then
              break
            end
          end
        end
      end
    end
  end
  if code then
    emit_code()
  end -- Prevent an unclosed Jira block eating MR details.
  return table.concat(out, "\n")
end

local function escape(text)
  text = type(text) == "string" and text or ""
  return (text:gsub("([\\`*_{}%[%]<>])", "\\%1"))
end

local adf
local function children(node, raw)
  if type(node) ~= "table" then
    return ""
  end
  local parts = {}
  for _, child in ipairs(type(node.content) == "table" and node.content or {}) do
    if raw then
      parts[#parts + 1] = type(child) == "table" and type(child.text) == "string" and child.text
        or children(child, true)
    else
      parts[#parts + 1] = adf(child)
    end
  end
  return table.concat(parts)
end

adf = function(node)
  if type(node) ~= "table" then
    return ""
  end
  local attrs = type(node.attrs) == "table" and node.attrs or {}
  local kind = node.type
  if kind == "text" or type(node.text) == "string" then
    local value = escape(node.text or "")
    for _, mark in ipairs(type(node.marks) == "table" and node.marks or {}) do
      if type(mark) == "table" and mark.type == "code" then
        return code_span(node.text or "")
      end
    end
    for _, mark in ipairs(type(node.marks) == "table" and node.marks or {}) do
      local mark_type = type(mark) == "table" and mark.type
      if mark_type == "strong" then
        value = "**" .. value .. "**"
      elseif mark_type == "em" then
        value = "*" .. value .. "*"
      elseif mark_type == "strike" then
        value = "~~" .. value .. "~~"
      elseif mark_type == "link" and type(mark.attrs) == "table" and type(mark.attrs.href) == "string" then
        value = "[" .. value .. "](" .. mark.attrs.href .. ")"
      end
    end
    return value
  elseif kind == "codeBlock" then
    return "\n" .. fenced(children(node, true), attrs.language) .. "\n\n"
  elseif kind == "hardBreak" then
    return "  \n"
  elseif kind == "paragraph" then
    return children(node) .. "\n\n"
  elseif kind == "heading" then
    return string.rep("#", math.min(6, math.max(1, tonumber(attrs.level) or 1) + 3)) .. " " .. children(node) .. "\n\n"
  elseif kind == "rule" then
    return "\n---\n\n"
  elseif kind == "blockquote" then
    local lines = vim.split(children(node):gsub("\n+$", ""), "\n", { plain = true })
    return "> " .. table.concat(lines, "\n> ") .. "\n\n"
  elseif kind == "bulletList" or kind == "orderedList" or kind == "taskList" then
    local lines = {}
    for index, item in ipairs(type(node.content) == "table" and node.content or {}) do
      local prefix = kind == "orderedList" and (tostring((tonumber(attrs.order) or 1) + index - 1) .. ". ") or "- "
      if kind == "taskList" then
        prefix = "- ["
          .. (type(item) == "table" and type(item.attrs) == "table" and item.attrs.state == "DONE" and "x" or " ")
          .. "] "
      end
      local text = adf(item):gsub("\n+$", "")
      lines[#lines + 1] = prefix .. text:gsub("\n", "\n" .. string.rep(" ", #prefix))
    end
    return table.concat(lines, "\n") .. "\n\n"
  elseif kind == "mention" then
    return escape(attrs.text or "@unknown")
  elseif kind == "emoji" then
    return type(attrs.text) == "string" and attrs.text or type(attrs.shortName) == "string" and attrs.shortName or ""
  elseif kind == "inlineCard" or kind == "blockCard" then
    return type(attrs.url) == "string" and ("<" .. attrs.url .. ">") or ""
  end
  return children(node)
end

-- Normalize code language aliases, add a small label, preserve every code line,
-- and close malformed source fences before another preview section is appended.
local function normalize_fences(text)
  local out, active = {}, nil
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if active then
      out[#out + 1] = line
      if closes(line, active) then
        active = nil
      end
    else
      local indent, run, info = fence_line(line)
      if run then
        local lang = language(vim.trim(info))
        active = { indent = indent, run = run }
        out[#out + 1] = ""
        out[#out + 1] = indent .. "**" .. lang:upper() .. "**"
        out[#out + 1] = ""
        out[#out + 1] = indent .. run .. lang
      else
        out[#out + 1] = line
      end
    end
  end
  if active then
    out[#out + 1] = active.indent .. active.run
  end
  return table.concat(out, "\n")
end

function M.to_markdown(value, source)
  local text = ""
  if type(value) == "table" then
    text = adf(value)
  elseif type(value) == "string" then
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = source == "jira" and wiki(value) or value
  end
  return normalize_fences(text:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

-- A bounded preview must not leave a fence open when it truncates a code block.
function M.excerpt(text, limit)
  local lines, out, active = vim.split(text, "\n", { plain = true }), {}, nil
  for i = 1, math.min(limit or 200, #lines) do
    local line = lines[i]
    out[#out + 1] = line
    if active then
      if closes(line, active) then
        active = nil
      end
    else
      local indent, run = fence_line(line)
      if run then
        active = { indent = indent, run = run }
      end
    end
  end
  if #out < #lines then
    if active then
      out[#out + 1] = active.indent .. active.run
    end
    out[#out + 1] = ""
    out[#out + 1] = "> … description truncated; open in browser for the full text."
    out[#out + 1] = ""
  end
  return out
end

return M

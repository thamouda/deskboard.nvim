dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/sprint-markdown.lua
-- Pure conversion fixtures; no plugins, CLI calls, network or real tickets.
vim.opt.rtp:prepend(vim.fn.getcwd())
local md = require("workbench.markdown")
local count = 0
local function test(name, fn)
  fn()
  count = count + 1
  print("PASS: " .. name)
end
local function contains(text, wanted)
  assert(text:find(wanted, 1, true), "Missing " .. wanted .. "\nActual:\n" .. text)
end

test("Jira wiki code keeps indentation, punctuation and explicit language", function()
  local code = '    my $value = { key => "*literal* _name_ {{raw}}" };\n    print $value;\n'
  local value = md.to_markdown(
    "h2. Example\nUse *strict* and {{my_identifier}}.\n{code:perl|title=example}\n" .. code .. "{code}\nAfter",
    "jira"
  )
  contains(value, "##### Example")
  contains(value, "**strict**")
  contains(value, "`my_identifier`")
  contains(value, "**PERL**")
  contains(value, "```perl\n" .. code .. "```")
  contains(value, "After")
end)

test("Jira inline blocks and noformat become isolated code fences", function()
  local value =
    md.to_markdown('Before {code:json}{"key": 1}{code} After\n{noformat}\n    {{raw}} *raw*\n{noformat}', "jira")
  contains(value, '```json\n{"key": 1}\n```')
  contains(value, "```text\n    {{raw}} *raw*\n```")
  contains(value, "Before ")
  contains(value, " After")
end)

test("code markers inside inline examples are never treated as blocks", function()
  local value = md.to_markdown("Use `{code:perl}` and {{ {code:python} }} as literal examples.", "jira")
  contains(value, "`{code:perl}`")
  contains(value, "{code:python}")
  assert(not value:find("```", 1, true))
end)

test("invalid lookalike tags do not mask a later valid code block", function()
  local value = md.to_markdown('{codeExample} then {code:py}print("ok"){code}', "jira")
  contains(value, "{codeExample}")
  contains(value, '```python\nprint("ok")\n```')
end)

test("existing Markdown code in Jira is not rewritten as wiki markup", function()
  local code = "h1. literal\n{code:json}\n{{literal}} *literal*\n"
  local value = md.to_markdown("```pl\n" .. code .. "```", "jira")
  contains(value, "```perl\n" .. code .. "```")
  assert(not value:find("#### literal", 1, true))
end)

test("fences grow when the code itself contains triple backticks", function()
  local value = md.to_markdown("{code:markdown}\n```perl\n    print 1;\n```\n{code}", "jira")
  contains(value, "````markdown\n```perl\n    print 1;\n```\n````")
end)

test("inline code is protected from wiki emphasis and link conversion", function()
  local value = md.to_markdown("*bold* {{a*b_c|d}} and `a*b_c|d` [guide|https://example.invalid]", "jira")
  contains(value, "**bold**")
  contains(value, "`a*b_c|d`")
  contains(value, "[guide](https://example.invalid)")
end)

test("mixed inline syntaxes never rewrite code or leak protection markers", function()
  local value = md.to_markdown("Use `{{literal}}` and {{a`b`c}}", "jira")
  contains(value, "`{{literal}}`")
  contains(value, "``a`b`c``")
  assert(not value:find("SPRINT_CODE_PLACEHOLDER_", 1, true))
  value = md.to_markdown("SPRINT_CODE_PLACEHOLDER_1_END and {{safe}}", "jira")
  contains(value, "SPRINT_CODE_PLACEHOLDER_1_END and `safe`")
end)

test("MR Markdown stays Markdown, with normalized code aliases", function()
  local value =
    md.to_markdown("*emphasis* and {{not Jira}}\n\n```py\n    print('ok')\n```\n\n~~~diff\n-old\n+new\n~~~", "markdown")
  contains(value, "*emphasis* and {{not Jira}}")
  contains(value, "**PYTHON**")
  contains(value, "```python\n    print('ok')\n```")
  contains(value, "~~~diff\n-old\n+new\n~~~")
end)

test("ADF code blocks retain their raw content and language", function()
  local code = '    my $entry = { name => "*literal*" };\n    print $entry;'
  local value = md.to_markdown({
    type = "doc",
    content = {
      { type = "paragraph", content = { { type = "text", text = "Important", marks = { { type = "strong" } } } } },
      { type = "codeBlock", attrs = { language = "perl" }, content = { { type = "text", text = code } } },
      { type = "paragraph", content = { { type = "text", text = "entry_name", marks = { { type = "code" } } } } },
    },
  }, "jira")
  contains(value, "**Important**")
  contains(value, "```perl\n" .. code .. "\n```")
  contains(value, "`entry_name`")
  assert(not value:find('"\\*literal', 1, true))
end)

test("ADF lists, quotes, headings, links and hard breaks survive conversion", function()
  local value = md.to_markdown({
    type = "doc",
    content = {
      { type = "heading", attrs = { level = 1 }, content = { { type = "text", text = "Steps" } } },
      {
        type = "bulletList",
        content = {
          {
            type = "listItem",
            content = {
              { type = "paragraph", content = { { type = "text", text = "First" } } },
            },
          },
        },
      },
      {
        type = "orderedList",
        attrs = { order = 3 },
        content = {
          {
            type = "listItem",
            content = {
              { type = "paragraph", content = { { type = "text", text = "Third" } } },
            },
          },
        },
      },
      { type = "blockquote", content = { { type = "paragraph", content = { { type = "text", text = "Note" } } } } },
      {
        type = "paragraph",
        content = {
          {
            type = "text",
            text = "guide",
            marks = { { type = "link", attrs = { href = "https://example.invalid" } } },
          },
          { type = "hardBreak" },
          { type = "text", text = "next line" },
        },
      },
    },
  }, "jira")
  for _, wanted in ipairs({
    "#### Steps",
    "- First",
    "3. Third",
    "> Note",
    "[guide](https://example.invalid)",
    "  \nnext line",
  }) do
    contains(value, wanted)
  end
end)

test("preview truncation closes an interrupted code fence before the notice", function()
  local value = md.to_markdown("```perl\n" .. string.rep("    print 1;\n", 300) .. "```", "markdown")
  local excerpt = table.concat(md.excerpt(value, 12), "\n")
  contains(excerpt, "```perl")
  contains(excerpt, "\n```\n\n> … description truncated")
  assert(#md.excerpt(value, 12) <= 16)
end)

test("truncation respects long and tilde fences", function()
  for _, run in ipairs({ "````", "~~~" }) do
    local value = md.to_markdown(run .. "text\n" .. string.rep("line\n", 40) .. run, "markdown")
    contains(table.concat(md.excerpt(value, 10), "\n"), "\n" .. run .. "\n\n> … description truncated")
  end
end)

test("malformed unclosed source blocks cannot swallow later MR sections", function()
  for _, input in ipairs({ "{code:perl}\nprint 1;", "```perl\nprint 1;" }) do
    local value = md.to_markdown(input, "jira")
    assert(value:match("```%s*$"), value)
  end
end)

test("Windows line endings and named language attributes are normalized", function()
  local value = md.to_markdown('{code:language=Python|linenumbers=true}\r\n    print("ok")\r\n{code}\r\n', "jira")
  contains(value, '```python\n    print("ok")\n```')
  assert(not value:find("\r", 1, true))
end)

test("empty or malformed descriptions are safe", function()
  for _, value in ipairs({ vim.NIL, false, {}, { type = "doc", content = { vim.NIL } } }) do
    assert(md.to_markdown(value, "jira") == "")
  end
  assert(md.to_markdown(nil, "jira") == "")
end)

print(("All %d sprint Markdown tests passed"):format(count))

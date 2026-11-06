dofile("tests/support/bootstrap.lua")
-- Run: nvim --headless -u NONE -l tests/sprint-preview-glow.lua
-- No network or credentials. Real Glow integration is skipped if not installed.
vim.opt.rtp:prepend(vim.fn.getcwd())
local preview = require("deskboard.preview")
local original_fetch, count = preview.fetch, 0
preview.fetch = function()
  return function() end
end
local board_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, board_buf)
local dashboard = { buf = board_buf, win = vim.api.nvim_get_current_win() }
local pane = preview.attach(dashboard, {})
local function test(name, fn)
  fn()
  count = count + 1
  print("PASS: " .. name)
end
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false), "\n")
end
local function wait_render(needle)
  assert(
    vim.wait(3000, function()
      return pane:is_open()
        and vim.bo[pane.buf].buftype == "terminal"
        and not pane.render_job
        and text():find(needle, 1, true) ~= nil
    end, 10),
    "Glow output was not rendered: " .. text()
  )
end
local ok, err = xpcall(function()
  test("JSON styles follow dark/light mode and allow user overrides", function()
    local background, custom = vim.o.background, vim.g.sprint_preview_glow_style
    for _, mode in ipairs({ "dark", "light" }) do
      vim.o.background = mode
      local path = preview.glow_style({})
      assert(path:find("sprint-preview-" .. mode .. ".json", 1, true))
      local style = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      assert(style.code_block.background_color and style.code_block.chroma.keyword.color)
      assert(style.h2.prefix == "▌ ")
    end
    vim.g.sprint_preview_glow_style = "~/custom-review.json"
    assert(preview.glow_style({}) == vim.fn.expand("~/custom-review.json"))
    assert(preview.glow_style({ glow_style = "dark" }) == "dark")
    vim.o.background, vim.g.sprint_preview_glow_style = background, custom
  end)

  if vim.fn.executable("glow") == 1 then
    test("real Glow formats Markdown in a focused popup without a shell or split", function()
      local width = vim.api.nvim_win_get_width(dashboard.win)
      pane:show({ ticket = "TEST-42" })
      pane:write({ "# Review heading", "", "**Bold text** and `code`", "", "- First item", "- Second item" })
      wait_render("Review heading")
      assert(not text():find("# Review heading", 1, true))
      assert(not text():find("**Bold text**", 1, true))
      assert(text():find("Bold text", 1, true))
      assert(not text():find("\27", 1, true), "ANSI escapes should be interpreted, not shown")
      assert(vim.bo[pane.buf].filetype == "glowpreview")
      assert(vim.api.nvim_win_get_config(pane.win).relative == "editor")
      assert(vim.api.nvim_get_current_win() == pane.win)
      assert(vim.api.nvim_win_get_width(dashboard.win) == width)
      assert(not vim.bo[pane.buf].modifiable)
      assert(vim.fn.maparg("q", "n", false, true).callback)
      assert(vim.fn.maparg("q", "t", false, true).callback)
    end)

    test("Glow keeps Ticket and MR details separate with visible status, assignee and description", function()
      local data = {
        fetched_at = os.time(),
        errors = {},
        jira = {
          fields = {
            summary = "Example ticket",
            status = { name = "To review" },
            assignee = { displayName = "Example reviewer" },
            description = "Ticket-only description",
          },
        },
        mr = {
          iid = 516,
          title = "Example MR",
          state = "opened",
          description = "MR-only description",
          head_pipeline = { status = "success" },
        },
      }
      pane:write(preview.lines(data, { ticket = "TEST-42", mr_iid = "516" }))
      wait_render("Ticket Details")
      assert(text():find("Merge Request Details", 1, true))
      assert(text():find("Status: To review", 1, true))
      assert(text():find("Assignee: Example reviewer", 1, true))
      assert(text():find("Ticket-only description", 1, true))
      assert(text():find("MR-only description", 1, true))
    end)

    test("Jira/ADF code becomes labelled highlighted blocks with indentation preserved", function()
      local data = {
        fetched_at = os.time(),
        errors = {},
        jira = {
          fields = {
            summary = "Code sample",
            status = { name = "To review" },
            description = '{code:perl}\n    my $entry = "demo";\n    print $entry;\n{code}',
          },
        },
        mr = {
          iid = 516,
          title = "Code review",
          state = "opened",
          description = '```py\n    print("python-demo")\n```',
          head_pipeline = { status = "success" },
        },
      }
      pane:write(preview.lines(data, { ticket = "TEST-42", mr_iid = "516" }))
      wait_render("python-demo")
      assert(text():find("PERL", 1, true) and text():find("PYTHON", 1, true))
      assert(text():find('    my $entry = "demo";', 1, true))
      assert(text():find('    print("python-demo")', 1, true))
      assert(not text():find("{code:perl}", 1, true) and not text():find("```", 1, true))
      data.jira.fields.description = {
        type = "doc",
        content = {
          {
            type = "codeBlock",
            attrs = { language = "javascript" },
            content = {
              { type = "text", text = '    console.log("adf-demo");' },
            },
          },
        },
      }
      pane:write(preview.lines(data, { ticket = "TEST-42", mr_iid = "516" }))
      wait_render("adf-demo")
      assert(text():find("JAVASCRIPT", 1, true))
      assert(text():find('    console.log("adf-demo");', 1, true))
    end)

    test("custom styles apply real syntax colours rather than plain text code", function()
      local function colours(style, lang)
        local result = vim
          .system({ "glow", "--style", style, "--width", "72", "-" }, {
            text = true,
            stdin = "```" .. lang .. '\n# comment\nmy $entry = "demo";\nprint $entry + 42;\n```',
          })
          :wait(5000)
        assert(result.code == 0)
        local seen, count = {}, 0
        for sequence in result.stdout:gmatch("\27%[([%d;]*)m") do
          if sequence:find("38;", 1, true) and not seen[sequence] then
            seen[sequence], count = true, count + 1
          end
        end
        return count
      end
      local background = vim.o.background
      for _, mode in ipairs({ "dark", "light" }) do
        vim.o.background = mode
        local style = preview.glow_style({})
        assert(colours(style, "perl") > colours(style, "text"), mode .. " syntax colour palette")
      end
      vim.o.background = background
    end)

    test("new Glow renders discard old terminal scrollback and retain q close", function()
      local long = { "# Old details" }
      for _ = 1, 80 do
        long[#long + 1] = "Previous ticket content"
      end
      pane:write(long)
      wait_render("Previous ticket content")
      local old_buf = pane.buf
      pane:write({ "# New details", "", "Replacement body" })
      wait_render("New details")
      assert(pane.buf ~= old_buf and not vim.api.nvim_buf_is_valid(old_buf))
      assert(not text():find("Previous ticket content", 1, true))
      assert(not text():find("Old details", 1, true))
      local buf = pane.buf
      vim.fn.maparg("q", "n", false, true).callback()
      assert(not pane:is_open() and not vim.api.nvim_buf_is_valid(buf))
      assert(vim.api.nvim_get_current_win() == dashboard.win)
    end)
  else
    print("SKIP: real Glow integration (binary not installed)")
  end

  test("missing Glow leaves readable Markdown with q close", function()
    pane.opts = { glow = "/nonexistent/sprint-test-glow" }
    pane:show({ ticket = "TEST-42" })
    pane:write({ "# Plain fallback", "", "Readable body" })
    assert(vim.bo[pane.buf].buftype == "nofile")
    assert(text():find("# Plain fallback", 1, true))
    vim.fn.maparg("q", "n", false, true).callback()
    assert(not pane:is_open())
  end)

  test("Glow uses stdin, theme, bounded argv and ignores stale render callbacks", function()
    local calls = {}
    pane.opts = {
      glow = "/bin/true",
      render_run = function(cmd, opts, done)
        local call = { cmd = cmd, opts = opts, done = done }
        calls[#calls + 1] = call
        return {
          kill = function()
            call.killed = true
          end,
        }
      end,
    }
    pane:show({ ticket = "TEST-42" })
    pane:write({ "# Old render" })
    local old = calls[#calls]
    pane:write({ "# Current render", "", "text\27[31m" })
    local current = calls[#calls]
    assert(old.killed and current.opts.timeout == 5000)
    assert(current.opts.stdin == "# Current render\n\ntext[31m")
    assert(current.cmd[2] == "--style" and current.cmd[3] == preview.glow_style(pane.opts))
    assert(current.cmd[#current.cmd] == "-")
    old.done({ code = 0, stdout = "\27[1mStale content\27[0m\n" })
    vim.wait(20, function()
      return false
    end)
    assert(not text():find("Stale content", 1, true))
    current.done({ code = 0, stdout = "\27[1mCurrent formatted\27[0m\n" })
    wait_render("Current formatted")
    pane:write({ "# Late after close" })
    local late = calls[#calls]
    pane:close()
    assert(late.killed)
    local previous_error = vim.v.errmsg
    late.done({ code = 0, stdout = "late content\n" })
    vim.wait(20, function()
      return false
    end)
    assert(not pane:is_open() and vim.v.errmsg == previous_error)
  end)

  test("failed, timed out or unspawnable Glow preserves Markdown fallback", function()
    for _, code in ipairs({ 1, 124 }) do
      local done
      pane.opts = {
        glow = "/bin/true",
        render_run = function(_, _, callback)
          done = callback
          return { kill = function() end }
        end,
      }
      pane:show({ ticket = "TEST-42" })
      pane:write({ "# Fallback " .. code })
      done({ code = code, stdout = "" })
      vim.wait(20, function()
        return false
      end)
      assert(text():find("# Fallback " .. code, 1, true))
      assert(vim.bo[pane.buf].buftype == "nofile")
      pane:close()
    end
    pane.opts = {
      glow = "/bin/true",
      render_run = function()
        error("spawn failed")
      end,
    }
    pane:show({ ticket = "TEST-42" })
    pane:write({ "# Spawn fallback" })
    assert(text():find("# Spawn fallback", 1, true))
    pane:close()
  end)
end, debug.traceback)
pane:close()
preview.fetch = original_fetch
assert(ok, err)
print(("All %d sprint Glow preview tests passed"):format(count))

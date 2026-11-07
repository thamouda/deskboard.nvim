-- Trusted repo config discovery, provider routing and repository lifecycle.
vim.opt.rtp:prepend(vim.fn.getcwd())
local core, config = require("deskboard"), require("deskboard.config")
local repo = require("deskboard.repo_config")
local sandbox, cwd = vim.fn.tempname() .. " repo configs", vim.fn.getcwd()
local a, b, nested = sandbox .. "/github", sandbox .. "/newt", sandbox .. "/github/nested"
for _, dir in ipairs({ a .. "/.git", a .. "/src/sub", b .. "/.git", nested .. "/.git" }) do vim.fn.mkdir(dir, "p") end
local github = { version = 1, issues = { provider = "github", project = "team/repo" }, reviews = { provider = "github", project = "team/repo" } }
local newt = { version = 1, issues = { provider = "jira", project = "NEWT" }, reviews = { provider = "gitlab", host = "gitlab.example.invalid", project = "products/newt/server" } }
local function save(root, data) vim.fn.writefile({ vim.json.encode(data) }, root .. "/.deskboard.json") end
local function read(path) return table.concat(vim.fn.readfile(path), "\n") end
save(a, github); save(b, newt)
local passed = 0
local function test(name, fn) fn(); passed = passed + 1; print("PASS: " .. name) end
local system, secure_read, notify, stdpath = vim.system, vim.secure.read, vim.notify, vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == "state" and sandbox .. "/state" or stdpath(kind) end
local jobs = {}
local ok, err = xpcall(function()
  local base = config.set({ repo_config = { enabled = true }, providers = {
    jira = { enabled = true, project = "OLD", snapshot = sandbox .. "/old.md" },
    gitlab = { enabled = true, host = "old.example.invalid", project = "old/repo" },
  } })
  test("subdirectories discover their config without crossing nested git roots", function()
    local path, root = repo.find(a .. "/src/sub")
    assert(path == a .. "/.deskboard.json" and root == a)
    path, root = repo.find(nested)
    assert(not path and root == nested)
    local alias = sandbox .. "/alias"
    assert(vim.uv.fs_symlink(a, alias))
    assert(repo.resolve(base, alias, read).repo_identity == repo.resolve(base, a, read).repo_identity)
  end)
  test("the two config modes enable only the correct providers and isolate all snapshots", function()
    local gh = repo.resolve(base, a, read)
    local gl = repo.resolve(base, b, read)
    assert(gh.providers.github.enabled and not gh.providers.jira.enabled and not gh.providers.gitlab.enabled)
    assert(gl.providers.jira.enabled and gl.providers.gitlab.enabled and not gl.providers.github.enabled)
    assert(gl.providers.jira.project == "NEWT" and gl.providers.gitlab.project == "products/newt/server")
    assert(gl.providers.jira.snapshot ~= base.providers.jira.snapshot)
    assert(gl.providers.gitlab.cache_file ~= gh.providers.github.cache_file)
    assert(gh.providers.github.cache_file ~= gh.providers.github.issues_cache_file)
    assert(base.providers.jira.project == "OLD", "Resolving must not mutate global setup options")
    local second = sandbox .. "/other-checkout"; vim.fn.mkdir(second .. "/.git", "p"); save(second, github)
    assert(repo.resolve(base, second, read).providers.github.cache_file ~= gh.providers.github.cache_file)
  end)
  test("loading is opt-in and trust denial or invalid configuration fails closed", function()
    local calls = 0
    local function denied() calls = calls + 1; return nil end
    local disabled = config.set()
    assert(not repo.resolve(disabled, a, denied).providers.github.enabled and calls == 0)
    local rejected = repo.resolve(base, a, denied)
    assert(calls == 1 and rejected.repo_error and not rejected.providers.jira.enabled and not rejected.providers.gitlab.enabled)
    for _, data in ipairs({
      { version = 2 }, { version = 1, issues = newt.issues, reviews = github.reviews },
      vim.tbl_extend("force", github, { command = { "SECRET" } }),
      { version = 1, issues = { provider = "github", project = "../repo" }, reviews = github.reviews },
      { version = 1, issues = newt.issues, reviews = { provider = "gitlab", project = "team/repo", host = "https://user:SECRET@host" } },
    }) do
      save(a, data)
      local result = repo.resolve(base, a, read)
      assert(result.repo_error and not result.providers.github.enabled and not result.providers.jira.enabled)
      assert(not result.repo_error:find("SECRET", 1, true))
    end
    save(a, github)
    local result = repo.resolve(base, nested, read)
    assert(result.repo_config_missing and not result.repo_error and not result.providers.jira.enabled)
  end)
  test("repo-local symlink and oversized configs are never trusted or evaluated", function()
    local target = sandbox .. "/target.json"; vim.fn.writefile({ vim.json.encode(github) }, target)
    vim.fn.delete(a .. "/.deskboard.json"); assert(vim.uv.fs_symlink(target, a .. "/.deskboard.json"))
    local reads = 0
    local function reader(path) reads = reads + 1; return read(path) end
    assert(repo.resolve(base, a, reader).repo_error and reads == 0)
    vim.fn.delete(a .. "/.deskboard.json")
    vim.fn.writefile({ string.rep(" ", 65537) }, a .. "/.deskboard.json")
    assert(repo.resolve(base, a, reader).repo_error and reads == 0)
    save(a, github)
  end)
  test("working-directory changes cancel old requests, reset panels and route refresh to the new provider", function()
    local notices = {}
    vim.secure.read, vim.notify = read, function(message) notices[#notices + 1] = message end
    vim.system = function(command, options, done)
      local job = { command = command, options = options, done = done }
      jobs[#jobs + 1] = job
      return { kill = function() job.killed = true end }
    end
    vim.cmd.cd(vim.fn.fnameescape(a))
    local reminder = sandbox .. "/reminders.md"
    vim.fn.writefile({ "- [ ] OLD-1|In Progress|Task", "- [ ] personal capture" }, reminder)
    core.setup({ repo_config = { enabled = true }, reminders = { path = reminder } })
    assert(config.get().providers.github.enabled and vim.fn.exists(":DeskboardReloadConfig") == 2)
    local owner = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(), opts = {} }
    function owner:update() self.items = core.sections(self) end
    function owner:find() for _, item in ipairs(self.items) do if item.issue_number or item.review or item.ticket then return item end end end
    owner:update()
    assert(vim.wait(200, function() return #jobs == 1 end))
    assert(jobs[1].command[2]:match("github%-sync%.py$") and jobs[1].command[4] == "issues")
    local state = require("deskboard.views").get({ buf = owner.buf })
    local report = { version = 1, ok = true, user = { username = "me" }, rows = {
      { iid = 1, title = "GitHub issue", author = "other", state = "open", labels = "bug", project = "team/repo", target_branch = "", web_url = "https://github.com/team/repo/issues/1" },
    } }
    jobs[1].done({ code = 0, stdout = vim.json.encode(report) })
    assert(vim.wait(200, function() return #state.issues.rows == 1 end))
    local item = owner:find()
    assert(item.issue_number == "1" and item.provider == "github" and not item.ticket and not item.mr_iid)
    state:switch("reviews")
    assert(#jobs == 2 and jobs[2].command[4] == "reviews")
    vim.cmd.cd(vim.fn.fnameescape(b))
    assert(jobs[2].killed and state.disposed and not state:refresh())
    local current = require("deskboard.views").get({ buf = owner.buf })
    assert(current ~= state and current.active == "mine" and not current.issues)
    assert(config.get().providers.jira.project == "NEWT" and config.get().providers.gitlab.enabled)
    assert(not owner:find(), "Global reminder tickets must not leak into a repo-scoped snapshot")
    jobs[2].done({ code = 0, stdout = vim.json.encode(report) })
    vim.wait(20, function() return false end)
    assert(#current.rows == 0)
    current:switch("reviews")
    assert(jobs[3].command[2]:match("sprint%-sync%.py$") and jobs[3].command[3] == "--reviews")
    current:switch("mine"); core.refresh()
    local command = table.concat(jobs[4].command, " ")
    assert(command:find("--jira-project NEWT", 1, true) and command:find("--project products/newt/server", 1, true))
    vim.cmd.cd(vim.fn.fnameescape(nested))
    assert(jobs[3].killed and jobs[4].killed)
    assert(not config.get().providers.jira.enabled and not config.get().providers.github.enabled)
    assert(config.get().repo_config_missing and not config.get().repo_error and #notices == 0)
    local local_state = require("deskboard.views").get({ buf = owner.buf })
    assert(local_state.active == "notes" and local_state.local_only)
    local tabs = {}
    for _, chunk in ipairs(owner.items[1].text) do tabs[#tabs + 1] = chunk[1] end
    local labels = table.concat(tabs)
    assert(labels:find("Notes", 1, true) and labels:find("Reminders", 1, true))
    assert(not labels:find("My tickets", 1, true) and not labels:find("Reviews", 1, true))
    for _, section in ipairs(owner.items) do assert(not section.ticket and not section.review and not section.issue_number) end
    local count = #jobs
    local_state:switch("mine"); local_state:switch("reviews"); assert(local_state.active == "notes")
    vim.fn.maparg("N", "n", false, true).callback(); assert(local_state.active == "reminders")
    vim.fn.maparg("<Tab>", "n", false, true).callback(); assert(local_state.active == "notes")
    vim.fn.maparg("<S-Tab>", "n", false, true).callback(); assert(local_state.active == "reminders")
    core.refresh(); assert(#jobs == count)
    vim.cmd.cd(vim.fn.fnameescape(b))
    local restored = require("deskboard.views").get({ buf = owner.buf })
    assert(not restored.local_only and restored.active == "mine" and restored:is_available("reviews"))
    vim.cmd.cd(vim.fn.fnameescape(nested))
    core.setup({ repo_config = { enabled = true }, reminders = { path = reminder } })
    owner:update()
    assert(require("deskboard.views").get({ buf = owner.buf }).active == "notes", "Startup without a config must also use local-only panels")
    assert(#notices == 0)
    core.dispose()
    vim.wait(50, function() return false end)
    assert(#jobs == count, "Disposed scheduled work must not restart a provider")
  end)
end, debug.traceback)
core.dispose()
vim.system, vim.secure.read, vim.notify, vim.fn.stdpath = system, secure_read, notify, stdpath
vim.cmd.cd(vim.fn.fnameescape(cwd))
vim.fn.delete(sandbox, "rf")
assert(ok, err)
print(string.format("%d repository config/routing tests passed", passed))

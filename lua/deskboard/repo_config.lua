-- Declarative, trusted repository configuration. Never execute repo-local Lua,
-- commands, credential helpers, or filesystem paths from this file.
local M = {}

local function keys(value, allowed)
  assert(type(value) == "table", "Expected an object")
  for key in pairs(value) do assert(allowed[key], "Unsupported configuration field") end
end
local function project(value, github)
  assert(type(value) == "string" and #value <= 250 and not value:find("[^%w_./%-]"), "Invalid project")
  local parts = vim.split(value, "/", { plain = true })
  assert(#parts >= 2 and (not github or #parts == 2), "Expected owner/project")
  for _, part in ipairs(parts) do assert(part ~= "" and part ~= "." and part ~= "..", "Invalid project segment") end
end
function M.validate(data)
  keys(data, { version = true, issues = true, reviews = true })
  assert(data.version == 1, "Unsupported config version")
  keys(data.issues, { provider = true, project = true })
  keys(data.reviews, { provider = true, host = true, project = true })
  if data.issues.provider == "github" and data.reviews.provider == "github" then
    project(data.issues.project, true); project(data.reviews.project, true)
    assert(data.issues.project == data.reviews.project, "GitHub panels must use the same repository")
    assert(data.reviews.host == nil or data.reviews.host == "github.com", "Only github.com is supported")
  else
    assert(data.issues.provider == "jira" and data.reviews.provider == "gitlab", "Use GitHub-only or Jira + GitLab")
    assert(type(data.issues.project) == "string" and data.issues.project:match("^[A-Z][A-Z0-9_]*$"), "Invalid Jira project key")
    project(data.reviews.project, false)
    assert(type(data.reviews.host) == "string" and data.reviews.host:match("^[%w][%w.%-]*$")
      and #data.reviews.host <= 253, "Invalid GitLab hostname")
  end
  return data
end

function M.find(cwd)
  local dir = vim.uv.fs_realpath(cwd) or vim.fs.normalize(cwd)
  while dir do
    local path = dir .. "/.deskboard.json"
    local stat = vim.uv.fs_lstat(path)
    -- Workspaces can contain nested git repos. A config at the nearest root
    -- wins; never inherit a parent config across an unconfigured git boundary.
    if stat then return path, dir end
    if vim.uv.fs_stat(dir .. "/.git") then return nil, dir end
    local parent = vim.fs.dirname(dir)
    if parent == dir then break end
    dir = parent
  end
end

function M.resolve(base, cwd, reader)
  local opts = vim.deepcopy(base)
  if not opts.repo_config.enabled or opts.demo then return opts end
  for _, name in ipairs({ "jira", "gitlab", "github" }) do opts.providers[name].enabled = false end
  local path, root = M.find(cwd)
  opts.repo_root = root
  opts.repo_error, opts.repo_config_path, opts.repo_config_missing = nil, nil, false
  opts.repo_identity = "unconfigured:" .. (root or cwd)
  opts.providers.jira.snapshot, opts.providers.jira.state_file = nil, nil
  -- Repo mode must use the bundled, project-scoped Jira backend rather than a
  -- globally pinned snapshot command that could query another project.
  opts.providers.jira.command = nil
  if not path then
    -- An unconfigured project is a normal local-only workspace, not an error.
    opts.repo_config_missing = true
    return opts
  end
  local stat = vim.uv.fs_lstat(path)
  if stat.type ~= "file" or stat.size > 65536 then
    opts.repo_error = "Repository config must be a regular JSON file smaller than 64 KiB"
    return opts
  end
  local ok, text = pcall(reader or vim.secure.read, path)
  if not ok or type(text) ~= "string" then
    opts.repo_error = "Repository config is not trusted; providers remain disabled"
    return opts
  end
  local valid, data = pcall(function() return M.validate(vim.json.decode(text)) end)
  if not valid then
    opts.repo_error = "Invalid .deskboard.json; use GitHub-only or Jira + GitLab configuration"
    return opts
  end
  local identity = vim.json.encode({ root, data.issues.provider, data.issues.project, data.reviews.provider,
    data.reviews.host or "github.com", data.reviews.project })
  local state = vim.fn.stdpath("state") .. "/deskboard/repositories/" .. vim.fn.sha256(identity)
  opts.repo_identity, opts.repo_config_path, opts.repo_error = identity, path, nil
  opts.actions.repo = root -- keep write/checkout opt-ins unchanged
  if data.issues.provider == "github" then
    opts.providers.github.enabled = true
    opts.providers.github.host, opts.providers.github.project = "github.com", data.issues.project
    opts.providers.github.cache_file, opts.providers.github.issues_cache_file = state .. "/reviews.json", state .. "/issues.json"
  else
    opts.providers.jira.enabled, opts.providers.gitlab.enabled = true, true
    opts.providers.jira.project = data.issues.project
    opts.providers.jira.snapshot, opts.providers.jira.state_file = state .. "/snapshot.md", state .. "/sync.json"
    opts.providers.gitlab.host, opts.providers.gitlab.project = data.reviews.host, data.reviews.project
    opts.providers.gitlab.cache_file = state .. "/reviews.json"
  end
  return opts
end
return M

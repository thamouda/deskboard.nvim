-- Checkout from the sprint dashboard. Only local / already-fetched remote
-- branches are considered; no branch is guessed, force-switched or auto-popped.
local M = {}
local busy = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Sprint checkout" })
end

local function candidates(refs, ticket)
  local local_branches, remote_branches, names = {}, {}, {}
  local pattern = "%f[%w]" .. vim.pesc(ticket) .. "%f[^%w]"
  for ref in refs:gmatch("[^\r\n]+") do
    local branch = ref:match("^refs/heads/(.+)$")
    if branch and branch:find(pattern) then
      names[branch] = true
      local_branches[#local_branches + 1] = { name = branch }
    else
      local remote, name = ref:match("^refs/remotes/([^/]+)/(.+)$")
      if name and name ~= "HEAD" and name:find(pattern) then
        remote_branches[#remote_branches + 1] = { name = name, remote = remote .. "/" .. name }
      end
    end
  end
  for _, branch in ipairs(remote_branches) do
    if not names[branch.name] then
      local_branches[#local_branches + 1] = branch
    end
  end
  table.sort(local_branches, function(a, b)
    return (a.remote or a.name) < (b.remote or b.name)
  end)
  return local_branches
end

local function modified_buffer(repo)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buftype == "" and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      local path = vim.uv.fs_realpath(name) or vim.fs.normalize(name)
      if path:sub(1, #repo + 1) == repo .. "/" then
        return name
      end
    end
  end
end

---opts.repo defaults to the explicitly configured worktree.
---on_done(ok) is also called for cancellation/failure; on_success refreshes UI.
function M.checkout(ticket, opts)
  opts = opts or {}
  if not require("deskboard.config").get().actions.checkout then notify("Checkout is disabled", vim.log.levels.WARN); return end
  local configured = opts.repo or require("deskboard.config").get().actions.repo
  if not configured then notify("Configure actions.repo first", vim.log.levels.WARN); return end
  local repo = vim.fn.expand(configured)
  repo = vim.uv.fs_realpath(repo) or vim.fs.normalize(repo)
  local lock = repo
  if busy[lock] then
    notify("A branch checkout is already in progress", vim.log.levels.WARN)
    return
  end
  if not ticket or not ticket:match("^%u[%u%d]*%-%d+$") then
    notify("Select a sprint ticket first", vim.log.levels.WARN)
    return
  end
  busy[lock] = true

  local thread, resume, stash_oid
  -- Resume on the main loop, including when a UI implementation calls back
  -- synchronously. Git processes never block the editor while stashing.
  local function await(start)
    start(function(value)
      vim.schedule(function()
        resume(value)
      end)
    end)
    return coroutine.yield()
  end

  local function git(args, allow_failure)
    local cmd = { "git", "-C", repo }
    vim.list_extend(cmd, args)
    local result = await(function(done)
      vim.system(cmd, { text = true, timeout = 120000 }, done)
    end)
    if result.code ~= 0 and not allow_failure then
      error("git " .. args[1] .. " failed; inspect Git locally before retrying", 0)
    end
    return result
  end

  thread = coroutine.create(function()
    repo = vim.trim(git({ "rev-parse", "--show-toplevel" }).stdout)
    local refs = git({ "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes" }).stdout
    local branches = candidates(refs, ticket)
    if #branches == 0 then
      error("No local or fetched remote branch found for " .. ticket .. ". Fetch branches first if needed.", 0)
    end
    local target = branches[1]
    if #branches > 1 then
      target = await(function(done)
        vim.ui.select(branches, {
          prompt = "Checkout branch for " .. ticket,
          format_item = function(branch)
            return branch.remote and (branch.name .. " (track " .. branch.remote .. ")") or branch.name
          end,
        }, done)
      end)
      if not target then
        return false
      end
    end

    local current = git({ "symbolic-ref", "--quiet", "--short", "HEAD" }, true)
    local previous = current.code == 0 and vim.trim(current.stdout)
      or ("detached-" .. vim.trim(git({ "rev-parse", "--short", "HEAD" }).stdout))
    if previous == target.name then
      notify("Already on " .. target.name)
      return true
    end
    local unsaved = modified_buffer(repo)
    if unsaved then
      error("Save or discard the unsaved buffer before switching:\n" .. unsaved, 0)
    end

    local status = git({ "status", "--porcelain", "--untracked-files=all" }).stdout
    if status ~= "" then
      local stat = git({ "diff", "--stat", "HEAD", "--" }).stdout
      notify("Saving changes from " .. previous .. " before checkout:\n" .. status .. stat)
      local message = ("[wip] %s — sprint board checkout to %s (%s)"):format(
        previous, target.name, os.date("%Y-%m-%d %H:%M:%S")
      )
      git({ "stash", "push", "--include-untracked", "--message", message })
      stash_oid = vim.trim(git({ "rev-parse", "refs/stash" }).stdout)
      -- Submodule changes, for example, cannot be saved by the parent stash.
      if git({ "status", "--porcelain", "--untracked-files=all" }).stdout ~= "" then
        error("Working tree is still dirty after stashing; checkout cancelled", 0)
      end
    end

    -- Catch edits made while Git was running, too. Never discard buffer text.
    unsaved = modified_buffer(repo)
    if unsaved then
      error("Buffer changed during checkout; save it first:\n" .. unsaved, 0)
    end
    if target.remote then
      git({ "switch", "--track", "-c", target.name, "--", target.remote })
    else
      git({ "switch", "--", target.name })
    end
    pcall(vim.cmd, "checktime")
    local message = "Checked out " .. target.name
    if stash_oid then
      message = message .. "\nSaved " .. previous .. " in stash " .. stash_oid:sub(1, 12)
        .. " (not applied; inspect with git stash list in " .. repo .. ")"
    end
    notify(message)
    if opts.on_success then
      local refreshed, err = pcall(opts.on_success)
      if not refreshed then
        notify("Branch switched, but dashboard refresh failed: " .. tostring(err), vim.log.levels.WARN)
      end
    end
    return true
  end)

  resume = function(...)
    local ok, result = coroutine.resume(thread, ...)
    if not ok or coroutine.status(thread) == "dead" then
      busy[lock] = nil
      if not ok then
        local message = tostring(result)
        if stash_oid then
          message = message .. "\nYour changes remain safe in stash " .. stash_oid
            .. ". Restore manually with git -C " .. vim.fn.shellescape(repo) .. " stash apply " .. stash_oid
        end
        notify(message, vim.log.levels.ERROR)
      end
      if opts.on_done then
        opts.on_done(ok and result == true)
      end
    end
  end
  resume()
end

return M

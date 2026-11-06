-- Synthetic, offline data only. No credentials, worktree paths, or private data.
local M = {}
function M.snapshot()
  return {
    { ticket = "DEMO-1", text = "DEMO-1|In Progress|Task|1d|!1 [OK]|1/2|1|yes|—", done = false },
    { ticket = "DEMO-2", text = "DEMO-2|Done|Task|1h|!2 [OK]|2/2|2|merged|main", done = true },
  }, nil, { { id = "demo-capture", title = "Demo reminder · no source file", done = false } }
end
function M.reviews()
  return { { iid = 1, title = "DEMO-1 Example change", author = "example-user", project = "example/project",
    web_url = "https://example.invalid", commits = 3, target_branch = "main", threads = { resolved = 1, total = 2 },
    my_threads = { resolved = 0, total = 1 }, my_approved = false, other_approvals = 1, ci = "success" } }
end
function M.notes()
  return { { id = "demo-note", uid = "DEMO-NOTE", title = "Demo knowledge note", kind = "demo", path = "Demo only",
    scope = "demo", category = "examples", status = "draft", visibility = "private", tags = { "demo" } } }
end
return M

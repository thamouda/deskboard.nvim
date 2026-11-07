# deskboard.nvim

A Snacks-backed Neovim dashboard for tickets, review assignments, local knowledge
notes, and quick reminders. Shared fixed frames, title-bar clocks, pagination,
author/metadata filters, and concise status badges.

**Local v0.1 development extraction. Not published on GitHub yet.** Runtime:
Neovim 0.11+ and Snacks. Core setup does not depend on LazyVim or lazy.nvim and
does not configure Snacks a second time.

## Install with lazy.nvim / LazyVim

During development use the local directory. After publication replace `dir` and
`name` with your actual GitHub repository URL; do not install a placeholder URL.

```lua
return {
  {
    dir = vim.fn.expand("~/dev/deskboard.nvim"),
    name = "deskboard.nvim",
    main = "deskboard",
    opts = { demo = true }, -- synthetic offline data, no writable actions
  },
  {
    "folke/snacks.nvim",
    dependencies = { "deskboard.nvim" },
    opts = function(_, opts)
      opts.dashboard = opts.dashboard or {}
      opts.dashboard.enabled = true
      opts.dashboard.sections = function(owner)
        return require("deskboard").sections(owner)
      end
    end,
  },
}
```

The dependency goes **Snacks -> Deskboard**. Deskboard setup must not require or
setup Snacks; the adapter accesses it only when opening/rendering. Existing
explorer/notifier/terminal settings are preserved.

Open `:Deskboard`; inspect `:checkhealth deskboard`. Empty/offline panels work
without credentials. No default global mappings are installed.

## Configuration

All remote integrations and writes are disabled by default:

```lua
opts = {
  width = 124,
  page_size = 6,
  notes = {
    enabled = true,
    roots = {
      personal = vim.fn.expand("~/notes/personal"),
      work = vim.fn.expand("~/notes/work"),
    },
    allow_writes = false,
    review_days = 90,
  },
  reminders = { path = vim.fn.expand("~/notes/reminder.md") },
  providers = {
    jira = { enabled = false, auto_refresh = false },
    gitlab = {
      enabled = false,
      host = "gitlab.com",
      project = "example/project", -- set the real project privately
      -- proxy = "http://your-proxy:port",
      -- token_command = { "your-secret-helper", "entry" },
    },
  },
  actions = { checkout = false, pipeline = false, jira_edit = false },
  preview = { glow = false },
  compat_commands = false,
}
```

GitLab reviews use configured `glab` authentication/environment; no password
manager is invoked unless you explicitly configure `token_command`. The bundled
Python backend has no pip dependencies. Jira snapshots use configured `jira`
authentication. Enable `auto_refresh` deliberately. A custom Jira `command` argv
is supported for private environment/credential wrappers.

Git operations require an explicit `actions.repo` and `actions.checkout` opt-in.
Note creation/status/visibility/index/trash/ID operations require
`notes.enabled` **and** `notes.allow_writes`. Remote Jira edits and pipelines have
separate flags. Demo mode refuses any enabled live provider or writable action.

## Dependencies

| Feature | Dependency |
|---|---|
| Dashboard | Neovim 0.11+, `folke/snacks.nvim` |
| Notes/reminders/rendering | No external tool |
| GitLab reviews | Python 3 (standard library), `glab` |
| Jira snapshots/editing | `jira`; Python for bundled snapshot backend |
| Checkout/stash | Git, explicit opt-in |
| Full-text notes search | Telescope + ripgrep |
| Styled popup | Optional Glow; plain Markdown fallback |
| Browser preview | Optional markdown-preview.nvim, local server/default browser |

No Docker, LSP, neotest, database, or personal configuration modules are required.

## Panels and keys

Buffer-local: Tab / Shift-Tab cycles panels; `[p` / `]p` or PageUp/PageDown pages;
`!` opens full safe status diagnostics; `R` refreshes the active panel.

- Tickets: project, MR/CI, discussions and approval metadata; checkout/edit/
  pipeline actions disabled unless configured.
- Reviews: only open MRs explicitly assigned to the authenticated reviewer,
  excluding authored MRs. `a` selects author; `A` clears it. MR is first; targets
  show `main` or ticket keys; threads are resolved/total. Approved is your status
  plus distinct other approvers. My threads counts discussions you started,
  not replies. Unknown/incomplete data stays `?`.
- Notes: ID/title/status/category/tags, private-by-default metadata, review/ready
  queues. C/S/t/Q filter category/status/tag/queue; A clears; F searches; K/P
  details. `+`, M, v, V and D are writable actions and require explicit opt-in.
- Reminders: separate quick captures; Enter/o edits source, not article metadata.
  `x` toggles the selected Markdown checkbox and saves it locally, then refreshes
  the dashboard. Requires `notes.enabled` and `notes.allow_writes`; unsaved or
  read-only source buffers block the write. Free-text rows are not toggled.

Commands are namespaced: `:Deskboard`, `:DeskboardRefresh`,
`:DeskboardNotesNew`, `:DeskboardNotesStatus`, `:DeskboardNotesReviewed`,
`:DeskboardNotesVisibility`, `:DeskboardNotesSearch`, `:DeskboardNotesIndex`,
`:DeskboardNotesDelete`, `:DeskboardNotesAssignID`, `:DeskboardNotesBrowser`.
`compat_commands=true` adds legacy `Notes*` / `SprintBoardRefresh` aliases only
for migration of an existing private setup.

## Data and safety

No private roots are selected or scanned by default. Explicit note roots retain
Markdown as source of truth. Simple YAML workflow fields, inline/block tags,
unique NOTE IDs, and date checks are supported; executable YAML tags/anchors are
not evaluated. Unsupported workflow data is flagged, not rewritten.

Status/review/visibility/ID changes edit buffers only: `:w` saves. New drafts do
not overwrite existing files. Indexes are updated after explicit saves, with
modified/read-only/concurrent-edit protection. Confirmed delete moves only the
note to local `.trash`; dirty buffers refuse deletion and failed index updates
roll back. Browser preview is local-only and does not auto-save or publish.
Confluence publishing is not implemented.

Default state lives under `stdpath('state')/deskboard`. To migrate existing NOTE
reservations, set `notes.id_state_dir` to the original allocator directory or
explicitly migrate its high-water JSON; do not simply delete/reset it. Existing
IDs are not silently changed. `notes.legacy_globals=true` is an optional legacy
bridge; normal installs use `setup(opts)` only.

Cached records/credentials are not shipped in the repository. Remote errors are
sanitized and callbacks cancelled on teardown. Each dashboard buffer owns its
view/filter/page state. `setup()` is idempotent; `dispose()` cancels previews,
review requests, sync requests and the redraw timer.

## Development

```sh
for test in tests/*.lua; do
  nvim --headless -u NONE -i NONE -l "$test" || exit 1
done
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
```

Unit fixtures use disposable note/state roots and mock remote mutations,
credentials and browser launch. `tests/core.lua` exercises default read-only
setup without legacy fixture permissions. Smoke tests require Snacks/lazy paths
provided explicitly. No real notes or API services should be accessed in CI.

## Release status

No public remote or release exists yet. Before publishing: review
licensing/provenance, pin tested dependencies/actions, audit source/history
and synthetic screenshots, run clean lazy install smoke tests on supported
platforms, then tag `v0.1.0`. Initially exercised on Linux/Neovim 0.11.6;
Windows support is not claimed. License: Apache-2.0; see LICENSE.

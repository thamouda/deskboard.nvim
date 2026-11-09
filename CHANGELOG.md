# Changelog

## Unreleased

### Added

- **Dashboard customization module** (`deskboard.dashboard`): Customize section titles, display formatting, and interactive features
  - Custom review title: show "My Reviews (count)" instead of "Reviews for me"
  - Custom reminders title: display open/done breakdown with emojis and counts
  - Reminder toggle keymaps: press Space or x in dashboard to mark reminders done/undone
  - Titles support both string format templates and callback functions for full control
- **Reminder toggle functionality**: Interactive keymaps (configurable) to toggle reminder checkboxes in the reminders file
- **Example configuration**: `examples/customization.lua` demonstrates dashboard customization setup

### Changed

- `board.lua` now hooks into dashboard customization for title formatting
- `init.lua` exposes `M.dashboard` module for public customization API

## v0.1.0 — 2026-11-07

First public release, published at https://github.com/thamouda/deskboard.nvim.

- Four Snacks panels, fixed frames and shared inline clock headers.
- Optional Jira/GitLab providers and synthetic offline demo data.
- Local knowledge notes, IDs, filters, queues, confirmed trash, and previews.
- Neutral configuration, namespaced modules/commands, read-only/offline defaults.
- Explicit opt-ins for note writes, checkout, pipelines and Jira edits.
- Isolated regression tests, lifecycle/default-safety tests, and real Snacks/lazy smoke tests.

Linux/Neovim 0.11.6 is exercised in CI; Windows support is not claimed.

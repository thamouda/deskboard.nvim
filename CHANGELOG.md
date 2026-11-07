# Changelog

## Unreleased

- Fix dashboard reminder status toggling with `x`, guarded by local write opt-ins
  and protection for unsaved source edits.

## v0.1.0 — 2026-11-07

First public release, published at https://github.com/thamouda/deskboard.nvim.

- Four Snacks panels, fixed frames and shared inline clock headers.
- Optional Jira/GitLab providers and synthetic offline demo data.
- Local knowledge notes, IDs, filters, queues, confirmed trash, and previews.
- Neutral configuration, namespaced modules/commands, read-only/offline defaults.
- Explicit opt-ins for note writes, checkout, pipelines and Jira edits.
- Isolated regression tests, lifecycle/default-safety tests, and real Snacks/lazy smoke tests.

Linux/Neovim 0.11.6 is exercised in CI; Windows support is not claimed.

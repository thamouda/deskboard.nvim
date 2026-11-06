# Contributing

This is an unreleased local extraction. Discuss new providers or destructive
operations before expanding the public API.

- Keep `deskboard.*` free of personal config imports, private hosts, real account
  data, default credential helpers, or automatic remote mutations.
- Setup/rendering must remain usable offline, idempotent, and read-only by default.
- Provider commands are argv arrays with bounded timeouts and safe error text.
- Tests use temporary vault AND state directories. Never use real credentials,
  note bodies, ticket writes, browser launches or real-worktree checkout in CI.
- Preserve the note format, ID high-water reservations, unsaved buffer data,
  and rollback/recovery behavior when changing storage code.
- Add regression coverage for cancellation, stale callbacks, empty/partial data,
  narrow windows and cleanup. Optional dependencies must have graceful fallbacks.
- Run all `tests/*.lua` with headless Neovim and Python unittest discovery.
  Set `DESKBOARD_SNACKS` / `DESKBOARD_LAZY` for real offline UI/install smoke tests.
- Do not claim a new platform/version until it is tested. Pin/review dependency
  updates and keep README/help/changelog in sync.

Retain Apache-2.0 attribution and verify code/data can be released publicly.

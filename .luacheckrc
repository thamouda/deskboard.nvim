std = "lua51"
-- Neovim's `vim` global exposes magic-write namespaces (vim.bo/vim.wo/vim.b/...)
-- and tests legitimately stub `io.open`; declare both writable to avoid noisy
-- false "setting read-only field" warnings.
globals = { "vim", "io", "os" }
read_globals = { "Snacks" }
-- This codebase intentionally keeps long, dense single-purpose lines
-- (tests especially); don't fight that style with a hard line-length rule.
max_line_length = false
ignore = {
  "311", -- grouped `local a, b = {}, {}` declarations are routinely replaced
         -- before use once a branch below picks the real value; harmless idiom.
  "431", -- shadowing a local/upvalue
  "432", -- shadowing a parameter
         -- Short-lived closures (tests especially) commonly reuse names like
         -- `value`/`count`/`owner` in nested scopes; low risk, not worth the
         -- renaming churn.
  "542", -- intentionally empty branch, used only to document a documented
         -- no-op case (see the inline comment at the call site).
}

-- Local development. Replace the dir spec with your real GitHub URL after
-- publication. Safe synthetic data only; no provider credentials or note writes.
return {
  {
    dir = vim.fn.expand("~/dev/deskboard.nvim"),
    name = "deskboard.nvim",
    main = "deskboard",
    opts = { demo = true },
  },
  {
    "folke/snacks.nvim",
    dependencies = { "deskboard.nvim" },
    opts = function(_, opts)
      opts.dashboard = opts.dashboard or {}
      opts.dashboard.enabled = true
      opts.dashboard.sections = function(owner) return require("deskboard").sections(owner) end
    end,
  },
}

-- Format on save with each project's own tools. Each formatter only runs where the
-- project has it (require_cwd), so nothing gets restyled by a tool the project
-- doesn't use.
local options = {
  formatters_by_ft = {
    lua = { "stylua" },
    php = { "pint" },
    javascript = { "eslint_fix", "prettier", stop_after_first = true },
    typescript = { "eslint_fix", "prettier", stop_after_first = true },
    vue = { "eslint_fix", "prettier", stop_after_first = true },
    css = { "prettier" },
    scss = { "prettier" },
    json = { "prettier" },
    yaml = { "prettier" },
  },

  formatters = {
    -- The project's vendor/bin/pint, from the folder holding composer.json.
    pint = {
      require_cwd = true,
      cwd = require("conform.util").root_file { "composer.json" },
      condition = function(_, ctx)
        local root = vim.fs.root(ctx.filename, "composer.json")
        return root ~= nil and vim.uv.fs_stat(root .. "/vendor/bin/pint") ~= nil
      end,
    },
    prettier = { require_cwd = true },
    -- The project's own eslint --fix. Lint fixes only; it restyles nothing the
    -- project's eslint config doesn't ask for.
    eslint_fix = {
      command = require("conform.util").from_node_modules "eslint",
      args = { "--fix", "$FILENAME" },
      stdin = false,
      cwd = require("conform.util").root_file { "eslint.config.js", "eslint.config.mjs", "eslint.config.ts" },
      require_cwd = true,
    },
  },

  -- After the write rather than before it, so a slow formatter (pint starts PHP)
  -- doesn't hold up saving. The buffer reloads with the formatted file.
  format_after_save = { lsp_format = "never" },
  notify_no_formatters = false,
}

return options

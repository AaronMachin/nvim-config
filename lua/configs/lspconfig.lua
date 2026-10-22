-- load defaults i.e lua_lsp
require("nvchad.configs.lspconfig").defaults()

local lspconfig = require "lspconfig"
local nvlsp = require "nvchad.configs.lspconfig"

-- Servers are installed with Mason. vue-language-server is pinned to 2.2.8: 3.x needs
-- a newer lspconfig than the one lazy-lock.json holds.
local function setup(server, opts)
  lspconfig[server].setup(vim.tbl_deep_extend("force", {
    on_attach = nvlsp.on_attach,
    on_init = nvlsp.on_init,
    capabilities = nvlsp.capabilities,
  }, opts or {}))
end

setup "html"
setup "cssls"
setup "jsonls"
setup("intelephense", {
  settings = { intelephense = { environment = { phpVersion = "8.4.0" } } },
})

-- The Vue server handles templates; TypeScript in .vue files goes through ts_ls with
-- Vue's TypeScript plugin, which comes with the Vue server's Mason package.
local vue_package = vim.fn.stdpath "data" .. "/mason/packages/vue-language-server"

-- Updating in the Mason window (or :MasonInstallAll) installs 3.x, which this
-- lspconfig can't drive, and Vue navigation then stops with no error. Say so instead.
local receipt = io.open(vue_package .. "/mason-receipt.json", "r")
if receipt then
  local version = receipt:read("*a"):match "language%-server@(%d+)%."
  receipt:close()
  if version and version ~= "2" then
    vim.schedule(function()
      vim.notify(
        "vue-language-server " .. version .. ".x is installed, which this config can't use. "
          .. "Run :MasonInstall vue-language-server@2.2.8",
        vim.log.levels.WARN
      )
    end)
  end
end

setup "volar"
setup("ts_ls", {
  init_options = {
    plugins = {
      {
        name = "@vue/typescript-plugin",
        location = vue_package,
        languages = { "vue" },
      },
    },
  },
  filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact", "vue" },
})

if vim.g.loaded_helm_schemas then return end
vim.g.loaded_helm_schemas = true

require("helm-schemas").setup()

local hs = require("helm-schemas")

vim.keymap.set("n", "<leader>hs", function() hs.pick() end,           { desc = "Helm: insert schema template" })
vim.keymap.set("n", "<leader>hS", function() hs.generate() end,       { desc = "Helm: sync SchemaStore templates" })
vim.keymap.set("n", "<leader>hk", function() hs.sync_k8s() end,       { desc = "Helm: sync core k8s schemas (yannh, cached)" })
vim.keymap.set("n", "<leader>hd", function() hs.sync_datreeio() end,  { desc = "Helm: sync CRD schemas (datreeio catalog, cached)" })
vim.keymap.set("n", "<leader>hc", function() hs.sync_cluster() end,   { desc = "Helm: sync CRDs from kubectl context" })
vim.keymap.set("n", "<leader>hC", function() hs.prompt_crd() end,     { desc = "Helm: add CRD from file or URL" })
vim.keymap.set("n", "<leader>hx", function() hs.clear() end,          { desc = "Helm: clear schemas" })

-- Attach yamlls to helm files so the workspace/configuration handler in
-- autoschema.lua can inject the correct per-file schema.
vim.lsp.config("yamlls", {
  filetypes = { "yaml", "yaml.docker-compose", "yaml.gitlab", "yaml.helm-values", "helm" },
  settings = {
    yaml = {
      keyOrdering = false,
      validate     = true,
      schemaStore  = { enable = false, url = "" },
      schemas = {
        ["https://json.schemastore.org/chart.json"] = "Chart.yaml",
      },
    },
  },
})

-- Disable helm_ls's internal yamlls subprocess: yamlls is already attached
-- directly to helm files (see filetypes override above) and provides schema
-- completions via the workspace/configuration handler in autoschema.lua.
-- Having both would produce duplicate completion suggestions.
vim.lsp.config("helm_ls", {
  settings = {
    ["helm-ls"] = {
      yamlls = { enabled = false },
    },
  },
})

-- Enable servers if not already enabled by another plugin (e.g. LazyVim).
vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  once = true,
  callback = function()
    if not vim.lsp.is_enabled("yamlls") then
      vim.lsp.enable("yamlls")
    end
    if not vim.lsp.is_enabled("helm_ls") then
      vim.lsp.enable("helm_ls")
    end
  end,
})

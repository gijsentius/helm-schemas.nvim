if vim.g.loaded_helm_schemas then return end
vim.g.loaded_helm_schemas = true

require("helm-schemas").setup()

local hs = require("helm-schemas")

vim.keymap.set("n", "<leader>hs", function() hs.pick() end,         { desc = "Helm: insert schema template" })
vim.keymap.set("n", "<leader>hS", function() hs.generate() end,     { desc = "Helm: sync SchemaStore templates" })
vim.keymap.set("n", "<leader>hk", function() hs.sync_k8s() end,     { desc = "Helm: sync core k8s templates" })
vim.keymap.set("n", "<leader>hc", function() hs.prompt_crd() end,   { desc = "Helm: add CRD from file or URL" })
vim.keymap.set("n", "<leader>hC", function() hs.sync_cluster() end, { desc = "Helm: sync CRDs from kubectl context" })
vim.keymap.set("n", "<leader>hx", function() hs.clear() end,        { desc = "Helm: clear schemas" })

-- Configure yamlls: inject helm-schemas JSON files and apply base settings.
-- vim.lsp.config() merges with any existing config (including user or LazyVim settings).
vim.lsp.config("yamlls", {
  before_init = function(_, config)
    local ok, store = pcall(require, "schemastore")
    if ok then
      config.settings = config.settings or {}
      config.settings.yaml = config.settings.yaml or {}
      config.settings.yaml.schemas = vim.tbl_deep_extend(
        "force",
        config.settings.yaml.schemas or {},
        store.yaml.schemas()
      )
    end
    local gen = require("helm-schemas.generate")
    local schemas_dir = gen.schemas_dir()
    config.settings = config.settings or {}
    config.settings.yaml = config.settings.yaml or {}
    local schemas = config.settings.yaml.schemas or {}
    for _, fpath in ipairs(vim.fn.glob(schemas_dir .. "/*.json", false, true)) do
      local uri = "file://" .. fpath
      if not schemas[uri] then schemas[uri] = "" end
    end
    config.settings.yaml.schemas = schemas
  end,
  settings = {
    yaml = {
      keyOrdering = false,
      validate     = true,
      schemaStore  = { enable = false, url = "" },
      schemas = {
        ["https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/master-standalone-strict/all.json"] = {
          "*.yaml", "*.yml",
        },
        ["https://json.schemastore.org/chart.json"] = "Chart.yaml",
      },
    },
  },
})

vim.lsp.config("helm_ls", {
  settings = {
    ["helm-ls"] = {
      yamlls = { path = "yaml-language-server" },
    },
  },
})

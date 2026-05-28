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

-- Base yamlls settings (merged by vim.lsp.config; user/LazyVim settings applied on top).
vim.lsp.config("yamlls", {
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

-- Attach a LspAttach handler to inject our cluster schemas into yamlls
-- after it starts. This runs after all before_init callbacks so it doesn't
-- conflict with LazyVim's lang.yaml schemastore setup.
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if not client or client.name ~= "yamlls" then return end

    local gen = require("helm-schemas.generate")
    local schemas_dir = gen.schemas_dir()
    local schemas = vim.deepcopy(
      vim.tbl_get(client.config, "settings", "yaml", "schemas") or {}
    )
    local changed = false
    for _, fpath in ipairs(vim.fn.glob(schemas_dir .. "/*.json", false, true)) do
      local uri = "file://" .. fpath
      if not schemas[uri] then
        schemas[uri] = ""
        changed = true
      end
    end
    if changed then
      local settings = vim.deepcopy(client.config.settings or {})
      settings.yaml = settings.yaml or {}
      settings.yaml.schemas = schemas
      client.notify("workspace/didChangeConfiguration", { settings = settings })
    end
  end,
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

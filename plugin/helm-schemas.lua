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

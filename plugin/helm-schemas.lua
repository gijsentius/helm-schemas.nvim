-- Auto-loaded by Neovim when the plugin directory is on the runtimepath.
-- Calls setup() so _plugin_dir is always resolved, even without an explicit
-- require("helm-schemas").setup() call in the user's config.
if vim.g.loaded_helm_schemas then return end
vim.g.loaded_helm_schemas = true

require("helm-schemas").setup()

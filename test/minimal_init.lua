-- Minimal init for headless test runs.
-- Adds the plugin source and plenary to runtimepath, nothing else.
local plugin_dir  = vim.fn.fnamemodify(debug.getinfo(1).source:match("@?(.+)"), ":h:h")
local plenary_dir = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"

vim.opt.rtp:prepend(plugin_dir)
vim.opt.rtp:prepend(plenary_dir)

-- Load plenary busted
vim.cmd("runtime plugin/plenary.vim")

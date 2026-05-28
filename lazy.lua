-- lazy.nvim reads this file automatically and merges it as the plugin's own
-- spec, wiring up all optional integrations without any user configuration.

local function hs() return require("helm-schemas") end
local function gen() return require("helm-schemas.generate") end

return {

  -- LSP: yamlls and helm-ls configuration
  {
    "neovim/nvim-lspconfig",
    optional = true,
    opts = {
      servers = {
        yamlls = {
          before_init = function(_, config)
            local ok, store = pcall(require, "schemastore")
            if ok then
              config.settings.yaml.schemas = vim.tbl_deep_extend(
                "force",
                config.settings.yaml.schemas or {},
                store.yaml.schemas()
              )
            end
            local schemas_dir = gen().schemas_dir()
            local schemas     = config.settings.yaml.schemas or {}
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
        },

        helm_ls = {
          settings = {
            ["helm-ls"] = {
              yamlls = { path = "yaml-language-server" },
            },
          },
        },
      },
    },
  },

  -- Treesitter: yaml parser is required by LazyVim; gotmpl for Helm templates
  {
    "nvim-treesitter/nvim-treesitter",
    optional = true,
    opts = { ensure_installed = { "yaml", "gotmpl" } },
  },

  -- Mason: auto-install language servers
  {
    "mason-org/mason.nvim",
    optional = true,
    opts = { ensure_installed = { "helm-ls", "yamllint" } },
  },

  -- which-key: group label for <leader>h
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>h", group = "helm", icon = "" },
      },
    },
  },

  -- blink.cmp: allow space as trigger so "key: " shows completions
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      opts.completion = opts.completion or {}
      opts.completion.trigger = opts.completion.trigger or {}
      local blocked = opts.completion.trigger.show_on_blocked_trigger_characters
      if type(blocked) == "table" then
        local new = {}
        for _, ch in ipairs(blocked) do
          if ch ~= " " then new[#new + 1] = ch end
        end
        opts.completion.trigger.show_on_blocked_trigger_characters = new
      elseif blocked == nil then
        opts.completion.trigger.show_on_blocked_trigger_characters = {}
      end

      local group = vim.api.nvim_create_augroup("helm_schemas_completion", { clear = true })

      vim.api.nvim_create_autocmd({ "InsertEnter", "CursorMovedI" }, {
        group   = group,
        pattern = { "*.yaml", "*.yml", "*.tpl" },
        callback = function()
          local line = vim.api.nvim_get_current_line()
          if line:match("^%s*%-?%s*$") then
            vim.schedule(function()
              local ok, blink = pcall(require, "blink.cmp")
              if ok then blink.show() end
            end)
          end
        end,
      })

      vim.api.nvim_create_autocmd("TextChangedI", {
        group   = group,
        pattern = { "*.yaml", "*.yml", "*.tpl" },
        callback = function()
          local line = vim.api.nvim_get_current_line()
          local col  = vim.api.nvim_win_get_cursor(0)[2]
          local before = line:sub(1, col)
          if before:match(":%s$") or before:match("^%s+%w$") or before:match("^%w$") then
            vim.schedule(function()
              local ok, blink = pcall(require, "blink.cmp")
              if ok then blink.show() end
            end)
          end
        end,
      })

      return opts
    end,
  },
}

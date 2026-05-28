-- lazy.nvim plugin spec that wires up all integrations.
-- Users who want the full out-of-the-box experience can load this via:
--
--   { import = "helm-schemas.spec" }    -- in their lazy.nvim plugins table
--
-- Or configure manually using the individual require("helm-schemas") API.

local function hs() return require("helm-schemas") end
local function gen() return require("helm-schemas.generate") end

return {

  -- -------------------------------------------------------------------------
  -- The plugin itself
  -- -------------------------------------------------------------------------
  {
    "gijsentius/helm-schemas.nvim",
    lazy = false,
    opts = {},
  },

  -- -------------------------------------------------------------------------
  -- Mason: keep the required language servers installed
  -- -------------------------------------------------------------------------
  {
    "mason-org/mason.nvim",
    optional = true,
    opts = {
      ensure_installed = { "helm-ls", "yamllint" },
    },
  },

  -- -------------------------------------------------------------------------
  -- Treesitter: gotmpl grammar for Helm template syntax
  -- -------------------------------------------------------------------------
  {
    "nvim-treesitter/nvim-treesitter",
    optional = true,
    opts = {
      ensure_installed = { "gotmpl" },
    },
  },

  -- -------------------------------------------------------------------------
  -- Helm syntax highlighting (sets ft=helm for files in templates/)
  -- -------------------------------------------------------------------------
  {
    "towolf/vim-helm",
    ft = "helm",
    optional = true,
  },

  -- -------------------------------------------------------------------------
  -- LSP: wire yamlls and helm-ls with CRD schemas
  -- -------------------------------------------------------------------------
  {
    "neovim/nvim-lspconfig",
    optional = true,
    opts = {
      servers = {
        -- yamlls ────────────────────────────────────────────────────────────
        -- before_init consolidates SchemaStore + local CRD file:// schemas.
        -- lazy.nvim's merge() overwrites functions rather than chaining them,
        -- so we must call SchemaStore ourselves here.
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
            -- CRD/cluster schemas are applied via the $schema modeline the
            -- template inserts. Registering them here with a glob would cause
            -- yamlls to merge all 175+ schemas for every YAML file, breaking
            -- completions. The file:// URIs must still be listed so yamlls
            -- can resolve them when referenced from a modeline.
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
                -- All core k8s resources via yannh master-standalone-strict.
                ["https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/master-standalone-strict/all.json"] = {
                  "*.yaml", "*.yml",
                },
                ["https://json.schemastore.org/chart.json"] = "Chart.yaml",
              },
            },
          },
        },

        -- helm-ls ────────────────────────────────────────────────────────────
        -- Passes CRD schemas into helm-ls's internal yamlls instance.
        -- The $schema modeline does not work in helm templates because helm-ls
        -- strips '$' from Go-template variables in comments.
        helm_ls = {
          before_init = function(_, config)
            local schemas     = {}
            local schemas_dir = gen().schemas_dir()
            for _, fpath in ipairs(vim.fn.glob(schemas_dir .. "/*.json", false, true)) do
              schemas["file://" .. fpath] = { "*.yaml", "*.yml" }
            end
            if vim.tbl_isempty(schemas) then return end
            local cfg      = config.settings["helm-ls"] or {}
            local yls      = type(cfg.yamlls)        == "table" and cfg.yamlls        or {}
            local inner    = type(yls.config)        == "table" and yls.config        or {}
            local yaml_cfg = type(inner.yaml)        == "table" and inner.yaml        or {}
            yaml_cfg.schemas = vim.tbl_extend("keep", schemas,
              type(yaml_cfg.schemas) == "table" and yaml_cfg.schemas or {})
            inner.yaml = yaml_cfg; yls.config = inner; cfg.yamlls = yls
            config.settings["helm-ls"] = cfg
          end,
          settings = {
            ["helm-ls"] = {
              yamlls = { path = "yaml-language-server" },
            },
          },
        },
      },
    },
  },

  -- -------------------------------------------------------------------------
  -- Formatting: prettier for yaml
  -- -------------------------------------------------------------------------
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = {
      formatters_by_ft = { yaml = { "prettier" } },
    },
  },

  -- -------------------------------------------------------------------------
  -- Linting: yamllint on save
  -- -------------------------------------------------------------------------
  {
    "mfussenegger/nvim-lint",
    optional = true,
    opts = {
      linters_by_ft = {
        yaml = { "yamllint" },
        helm = { "yamllint" },
      },
    },
  },

  -- -------------------------------------------------------------------------
  -- which-key group label
  -- -------------------------------------------------------------------------
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>h", group = "helm", icon = "" },
      },
    },
  },

  -- -------------------------------------------------------------------------
  -- Keymaps via snacks.nvim picker
  -- -------------------------------------------------------------------------
  {
    "snacks.nvim",
    optional = true,
    keys = {
      {
        "<leader>hs",
        function() hs().pick() end,
        desc = "Helm: insert schema template",
        ft   = { "yaml", "helm" },
      },
      {
        "<leader>hS",
        function() hs().generate() end,
        desc = "Helm: sync SchemaStore templates",
      },
      {
        "<leader>hk",
        function() hs().sync_k8s() end,
        desc = "Helm: sync core k8s templates (yannh)",
      },
      {
        "<leader>hc",
        function() hs().prompt_crd() end,
        desc = "Helm: add CRD from file or URL",
      },
      {
        "<leader>hC",
        function() hs().sync_cluster() end,
        desc = "Helm: sync CRDs from current kubectl context",
      },
      {
        "<leader>hx",
        function() hs().clear() end,
        desc = "Helm: clear schemas",
      },
    },
  },

  -- -------------------------------------------------------------------------
  -- blink.cmp: trigger completions in yaml/helm files
  -- yamlls advertises no trigger characters so blink never auto-fires.
  -- Space is in blink's default show_on_blocked_trigger_characters list,
  -- which prevents completions after "key: ". We allow it for yaml/helm.
  -- -------------------------------------------------------------------------
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      -- Allow space as a trigger character in yaml/helm files so "key: "
      -- shows completions. blink blocks ' ' by default.
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

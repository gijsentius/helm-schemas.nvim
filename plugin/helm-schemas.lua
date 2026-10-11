if vim.g.loaded_helm_schemas then return end
vim.g.loaded_helm_schemas = true

require("helm-schemas").setup()

local hs = require("helm-schemas")

vim.keymap.set("n", "<leader>hs", function() hs.pick() end,           { desc = "Helm: insert schema template" })
vim.keymap.set("n", "<leader>hS", function() hs.generate() end,       { desc = "Helm: sync SchemaStore templates" })
vim.keymap.set("n", "<leader>hk", function() hs.sync_k8s() end,       { desc = "Helm: sync core k8s schemas (yannh, cached)" })
vim.keymap.set("n", "<leader>hc", function() hs.sync_cluster() end,   { desc = "Helm: sync CRDs from kubectl context" })
vim.keymap.set("n", "<leader>hC", function() hs.prompt_crd() end,     { desc = "Helm: add CRD from file or URL" })
vim.keymap.set("n", "<leader>hx", function() hs.clear() end,          { desc = "Helm: clear schemas" })

-- Attach yamlls to helm files so the workspace/configuration handler in
-- autoschema.lua can inject the correct per-file schema.
vim.lsp.config("yamlls", {
  filetypes = { "yaml", "yaml.docker-compose", "yaml.gitlab", "yaml.helm-values", "helm" },
  -- Disable auto-format (LazyVim's vim.b.autoformat) for k8s manifests: they may
  -- contain Go template syntax ({{ }}) which formatters corrupt. Detected by
  -- top-level kind/apiVersion keys in the first 20 lines of the buffer.
  on_attach = function(_, bufnr)
    local has_kind, has_api = false, false
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 20, false)) do
      if line:match("^kind:%s*%S") then has_kind = true end
      if line:match("^apiVersion:%s*%S") then has_api = true end
      if has_kind and has_api then
        vim.b[bufnr].autoformat = false
        return
      end
    end
  end,
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

-- ---------------------------------------------------------------------------
-- BufWritePre: strip trailing whitespace, collapse 3+ blank lines to 2,
-- and remove trailing blank lines at EOF so yamllint never flags them.
-- ---------------------------------------------------------------------------
vim.api.nvim_create_autocmd("BufWritePre", {
  group = vim.api.nvim_create_augroup("helm_schemas_yaml_clean", { clear = true }),
  pattern = { "*.yaml", "*.yml", "*.tpl" },
  callback = function()
    local view = vim.fn.winsaveview()
    local buf  = vim.api.nvim_get_current_buf()
    vim.cmd([[silent! %s/\s\+$//e]])
    local i, blanks = 1, 0
    while i <= vim.api.nvim_buf_line_count(buf) do
      local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
      if line == "" then
        blanks = blanks + 1
        if blanks > 2 then
          vim.api.nvim_buf_set_lines(buf, i - 1, i, false, {})
        else
          i = i + 1
        end
      else
        blanks = 0
        i = i + 1
      end
    end
    local last = vim.api.nvim_buf_line_count(buf)
    while last > 1 and vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] == "" do
      vim.api.nvim_buf_set_lines(buf, last - 1, last, false, {})
      last = last - 1
    end
    vim.fn.winrestview(view)
  end,
})

-- ---------------------------------------------------------------------------
-- BufWritePost: run yamllint + kubeconform.
-- For ft=helm files, render via `helm template -s` first so linters receive
-- plain YAML instead of Go template syntax.
-- ---------------------------------------------------------------------------

local function helm_render(bufnr)
  if vim.fn.exepath("helm") == "" then return nil end
  local fpath = vim.api.nvim_buf_get_name(bufnr)
  if fpath == "" then return nil end
  local chart_root, d = nil, vim.fn.fnamemodify(fpath, ":h")
  while d ~= "/" do
    if vim.fn.filereadable(d .. "/Chart.yaml") == 1 then chart_root = d; break end
    d = vim.fn.fnamemodify(d, ":h")
  end
  if not chart_root then return nil end
  local tmpl_rel = fpath:sub(#chart_root + 2)
  local cmd = "helm template "
    .. vim.fn.shellescape(vim.fn.fnamemodify(chart_root, ":t"))
    .. " " .. vim.fn.shellescape(chart_root)
    .. " -s " .. vim.fn.shellescape(tmpl_rel)
    .. " 2>&1"
  local out = vim.fn.system(cmd)
  local ns  = vim.api.nvim_create_namespace("helm_render_error")
  if vim.v.shell_error ~= 0 then
    vim.diagnostic.set(ns, bufnr, {{
      lnum=0, end_lnum=0, col=0, end_col=0,
      severity=vim.diagnostic.severity.ERROR,
      source="helm", message=out:gsub("^Error: ", ""):gsub("\n.*", ""),
    }})
    return nil
  end
  vim.diagnostic.set(ns, bufnr, {})
  return out
end

vim.api.nvim_create_autocmd("BufWritePost", {
  group = vim.api.nvim_create_augroup("helm_schemas_lint", { clear = true }),
  pattern = { "*.yaml", "*.yml", "*.tpl" },
  callback = function()
    local lint_ok, lint = pcall(require, "lint")
    if not lint_ok then return end

    if not lint.linters.kubeconform then
      local ok, linter_mod = pcall(require, "helm-schemas.linter")
      if ok then lint.linters.kubeconform = linter_mod.linter() end
    end

    local buf = vim.api.nvim_get_current_buf()
    local ft  = vim.bo[buf].filetype

    if ft == "helm" then
      local rendered = helm_render(buf)
      if not rendered then return end
      if vim.fn.exepath("kubeconform") ~= "" then
        local ok, linter_mod = pcall(require, "helm-schemas.linter")
        if not ok then return end
        local kc_def = linter_mod.linter()
        local schema_args = ""
        for i = 1, #kc_def.args - 1 do
          schema_args = schema_args .. " " .. vim.fn.shellescape(kc_def.args[i])
        end
        local tmp = vim.fn.tempname() .. ".yaml"
        vim.fn.writefile(vim.fn.split(rendered, "\n"), tmp)
        local kc_out = vim.fn.system("kubeconform" .. schema_args .. " " .. vim.fn.shellescape(tmp))
        vim.fn.delete(tmp)
        local diags = linter_mod.parse_output(kc_out, buf)
        vim.diagnostic.set(vim.api.nvim_create_namespace("kubeconform"), buf, diags or {})
      end
    else
      lint.try_lint()
      if vim.fn.exepath("kubeconform") ~= "" then
        lint.try_lint("kubeconform")
      end
    end
  end,
})

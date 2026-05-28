-- Automatically select the right schema for a yaml/helm buffer based on its
-- kind/apiVersion fields, without requiring a $schema modeline.
--
-- Targets both yamlls (plain yaml files) and helm_ls (files under templates/).
-- For helm_ls the schema is injected via helm-ls.yamlls.config.yaml.schemas.

local M = {}

-- Build a lookup: "Kind|apiVersion" -> { uri, priority }
local function build_lookup(generate)
  local index = generate.load_index()
  local lookup = {}
  for _, entry in ipairs(index) do
    if entry.kind and entry.apiVersion and entry.file then
      local key      = entry.kind .. "|" .. entry.apiVersion
      local priority = ({ cluster = 1, kubernetes = 2, crd = 3, schemastore = 4 })[entry.source] or 9
      local existing = lookup[key]
      if not existing or priority < existing.priority then
        local schema_file = entry.file:gsub("%.yaml$", ".json")
        local schema_path = generate.schemas_dir() .. "/" .. schema_file
        lookup[key] = { uri = "file://" .. schema_path, priority = priority }
      end
    end
  end
  return lookup
end

-- Extract kind and apiVersion from the first 50 lines of a buffer.
local function extract_gvk(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 50, false)
  local kind, api_version
  for _, line in ipairs(lines) do
    if not kind        then kind        = line:match("^kind:%s*(.-)%s*$") end
    if not api_version then api_version = line:match("^apiVersion:%s*(.-)%s*$") end
    if kind and api_version then break end
  end
  return kind, api_version
end

local function apply_to_yamlls(client, fpath, schema_uri)
  local settings = vim.deepcopy(client.config.settings or {})
  settings.yaml = settings.yaml or {}
  settings.yaml.schemas = settings.yaml.schemas or {}
  settings.yaml.schemas[schema_uri] = fpath
  client.notify("workspace/didChangeConfiguration", { settings = settings })
end

local function apply_to_helm_ls(client, fpath, schema_uri)
  local settings = vim.deepcopy(client.config.settings or {})
  local cfg      = type(settings["helm-ls"])    == "table" and settings["helm-ls"]    or {}
  local yls      = type(cfg.yamlls)             == "table" and cfg.yamlls             or {}
  local inner    = type(yls.config)             == "table" and yls.config             or {}
  local yaml_cfg = type(inner.yaml)             == "table" and inner.yaml             or {}
  yaml_cfg.schemas = yaml_cfg.schemas or {}
  yaml_cfg.schemas[schema_uri] = fpath
  inner.yaml = yaml_cfg; yls.config = inner; cfg.yamlls = yls
  settings["helm-ls"] = cfg
  client.notify("workspace/didChangeConfiguration", { settings = settings })
end

local function apply_schema(bufnr, schema_uri)
  local fpath = vim.api.nvim_buf_get_name(bufnr)
  if fpath == "" then return end

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.name == "yamlls" then
      apply_to_yamlls(client, fpath, schema_uri)
    elseif client.name == "helm_ls" then
      apply_to_helm_ls(client, fpath, schema_uri)
    end
  end
end

local lookup_cache = nil
local lookup_dirty = true

local function get_lookup()
  if lookup_cache and not lookup_dirty then return lookup_cache end
  local ok, generate = pcall(require, "helm-schemas.generate")
  if not ok then return {} end
  lookup_cache = build_lookup(generate)
  lookup_dirty = false
  return lookup_cache
end

function M.invalidate()
  lookup_dirty = true
end

local function handle_buf(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft ~= "yaml" and ft ~= "helm" then return end

  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  if first:match("yaml%-language%-server.*%$schema") then return end

  local kind, api_version = extract_gvk(bufnr)
  if not kind or not api_version then return end

  local entry = get_lookup()[kind .. "|" .. api_version]
  if not entry then return end

  apply_schema(bufnr, entry.uri)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("helm_schemas_autoschema", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWritePost" }, {
    group   = group,
    pattern = { "*.yaml", "*.yml", "*.tpl" },
    callback = function(ev)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then handle_buf(ev.buf) end
      end, 500)
    end,
  })

  -- Fire on both yamlls and helm_ls attach.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if client and (client.name == "yamlls" or client.name == "helm_ls") then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then handle_buf(ev.buf) end
        end, 300)
      end
    end,
  })
end

return M

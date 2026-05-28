-- Automatically select the right schema for a yaml buffer based on its
-- kind/apiVersion fields, without requiring a $schema modeline.
--
-- Strategy: when a yaml buffer is opened or its content changes, read
-- kind+apiVersion, find a matching schema in the index, then reconfigure
-- yamlls for that buffer by sending workspace/didChangeConfiguration with
-- the schema mapped to the buffer's absolute path.

local M = {}

-- Build a lookup table: "Kind|apiVersion" -> schema file URI
local function build_lookup(generate)
  local index = generate.load_index()
  local lookup = {}
  for _, entry in ipairs(index) do
    if entry.kind and entry.apiVersion and entry.file then
      local key = entry.kind .. "|" .. entry.apiVersion
      -- Prefer cluster > kubernetes > crd > schemastore
      local priority = ({ cluster = 1, kubernetes = 2, crd = 3, schemastore = 4 })[entry.source] or 9
      local existing = lookup[key]
      if not existing or priority < existing.priority then
        local schema_file = entry.file:gsub("%.yaml$", ".json")
        local schema_path = generate.schemas_dir() .. "/" .. schema_file
        lookup[key] = {
          uri      = "file://" .. schema_path,
          priority = priority,
        }
      end
    end
  end
  return lookup
end

-- Extract kind and apiVersion from buffer lines (cheap grep, no LSP needed).
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

-- Send an updated yaml.schemas config to every attached yamlls client so that
-- the schema maps to this buffer's file path specifically.
local function apply_schema(bufnr, schema_uri)
  local fpath = vim.api.nvim_buf_get_name(bufnr)
  if fpath == "" then return end

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "yamlls" })) do
    local settings = vim.deepcopy(client.config.settings or {})
    settings.yaml = settings.yaml or {}
    settings.yaml.schemas = settings.yaml.schemas or {}
    -- Map this exact file path to the chosen schema.
    settings.yaml.schemas[schema_uri] = fpath
    client.notify("workspace/didChangeConfiguration", { settings = settings })
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

-- Call this after any sync operation to force a rebuild of the lookup.
function M.invalidate()
  lookup_dirty = true
end

local function handle_buf(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft ~= "yaml" and ft ~= "helm" then return end

  -- Don't override files that already have a $schema modeline.
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  if first:match("yaml%-language%-server.*%$schema") then return end

  local kind, api_version = extract_gvk(bufnr)
  if not kind or not api_version then return end

  local lookup = get_lookup()
  local entry  = lookup[kind .. "|" .. api_version]
  if not entry then return end

  apply_schema(bufnr, entry.uri)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("helm_schemas_autoschema", { clear = true })

  -- Fire when a yaml buffer is opened or text changes significantly.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWritePost" }, {
    group   = group,
    pattern = { "*.yaml", "*.yml", "*.tpl" },
    callback = function(ev)
      -- Defer so LSP client has time to attach.
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          handle_buf(ev.buf)
        end
      end, 500)
    end,
  })

  -- Also fire when a yamlls client attaches (handles already-open buffers).
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if client and client.name == "yamlls" then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            handle_buf(ev.buf)
          end
        end, 200)
      end
    end,
  })
end

return M

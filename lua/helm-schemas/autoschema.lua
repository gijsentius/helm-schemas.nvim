-- Automatically select the right schema for a yaml/helm buffer based on its
-- kind/apiVersion fields.
--
-- Schema injection strategy (mirrors yaml-schema-router):
--   Override client.handlers["workspace/configuration"] on the yamlls client so
--   that whenever yamlls pulls its configuration we inject the correct per-file
--   schema into the yaml.schemas map.  This is the only delivery mechanism that
--   reliably works for file:// URIs in yamlls — didChangeConfiguration and the
--   $schema modeline both fail for multi-doc files (yamlls engine limitation).
--
-- Multi-doc files: a composite {"anyOf":[{$ref:A},{$ref:B},...]} schema is
-- written to disk and assigned to the file.  Completions inside a multi-doc
-- file still only return results for whichever sub-schema matches the cursor
-- document — this is a yamlls limitation, not something the delivery mechanism
-- can fix.

local M = {}

-- ---------------------------------------------------------------------------
-- GVK extraction helpers
-- ---------------------------------------------------------------------------

local function doc_start_line(lines, cursor_line)
  local start = 0
  for i = 0, cursor_line do
    if lines[i + 1] and lines[i + 1]:match("^%-%-%-%s*$") then
      start = i
    end
  end
  return start
end

local function extract_gvk(bufnr, cursor_line)
  local total   = vim.api.nvim_buf_line_count(bufnr)
  local read_end = cursor_line and math.min(total, cursor_line + 50) or math.min(total, 50)
  local lines   = vim.api.nvim_buf_get_lines(bufnr, 0, read_end, false)

  local start = cursor_line and doc_start_line(lines, cursor_line) or 0
  local kind, api_version
  for i = start + 1, #lines do
    local line = lines[i]
    if line:match("^%-%-%-%s*$") and i > start + 1 then break end
    if not kind        then kind        = line:match("^kind:%s*(.-)%s*$") end
    if not api_version then api_version = line:match("^apiVersion:%s*(.-)%s*$") end
    if kind and api_version then break end
  end
  return kind, api_version
end

-- Extract GVK for every document in the buffer.
local function extract_all_gvks(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local results = {}
  local i = 1
  while i <= #lines do
    -- find start of next document
    local doc_start = i
    -- skip leading --- separator line
    if lines[i] and lines[i]:match("^%-%-%-%s*$") then
      i = i + 1
      doc_start = i
    end
    local kind, api_version
    local j = i
    while j <= #lines do
      local line = lines[j]
      if line:match("^%-%-%-%s*$") and j > doc_start then break end
      if not kind        then kind        = line:match("^kind:%s*(.-)%s*$") end
      if not api_version then api_version = line:match("^apiVersion:%s*(.-)%s*$") end
      if kind and api_version then break end
      j = j + 1
    end
    if kind and api_version then
      results[#results + 1] = { kind = kind, api_version = api_version }
    end
    -- j either stopped at a --- boundary or ran off the end.
    -- If it stopped at ---, that line is the start of the next doc;
    -- the outer loop will handle the separator skip on the next iteration.
    i = j
    if i > #lines then break end
    -- If j didn't land on ---, advance until we find one or run out.
    if not lines[i]:match("^%-%-%-%s*$") then
      i = i + 1
      while i <= #lines and not lines[i]:match("^%-%-%-%s*$") do
        i = i + 1
      end
    end
  end
  return results
end

-- ---------------------------------------------------------------------------
-- Schema lookup
-- ---------------------------------------------------------------------------

local lookup_cache = nil
local lookup_dirty = true

local function build_lookup(generate)
  local index = generate.load_index()
  local lookup = {}
  for _, entry in ipairs(index) do
    if entry.kind and entry.apiVersion and entry.file then
      local key      = entry.kind .. "|" .. entry.apiVersion
      local priority = ({
        cluster     = 1,   -- live cluster schema (most specific)
        kubernetes  = 2,   -- yannh k8s builtins
        crd         = 3,   -- user-added CRD via prompt_crd
        schemastore = 4,   -- SchemaStore fallback
      })[entry.source] or 9
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

-- ---------------------------------------------------------------------------
-- Composite schema generation
-- For multi-doc files: write a {"anyOf":[{$ref:A},{$ref:B}]} schema to disk.
-- ---------------------------------------------------------------------------

local function composite_dir()
  local ok, generate = pcall(require, "helm-schemas.generate")
  if not ok then return nil end
  return generate.data_dir() .. "/composite"
end

local function make_composite(uris)
  local dir = composite_dir()
  if not dir then return nil end
  vim.fn.mkdir(dir, "p")

  -- Deduplicate and sort for a stable hash.
  local seen = {}
  local sorted = {}
  for _, u in ipairs(uris) do
    if not seen[u] then seen[u] = true; sorted[#sorted + 1] = u end
  end
  table.sort(sorted)

  local key = vim.fn.sha256(table.concat(sorted, "|")):sub(1, 16)
  local path = dir .. "/composite_" .. key .. ".json"

  if vim.fn.filereadable(path) == 0 then
    local any_of = {}
    for _, u in ipairs(sorted) do
      any_of[#any_of + 1] = { ["$ref"] = u }
    end
    local ok2, encoded = pcall(vim.json.encode, { anyOf = any_of })
    if not ok2 then return nil end
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(encoded); f:close()
  end

  return "file://" .. path
end

-- ---------------------------------------------------------------------------
-- Per-buffer schema state  (bufnr -> schema_uri)
-- Mirrors the router's schemaState map.
-- ---------------------------------------------------------------------------

local schema_state = {}  -- bufnr -> schema_uri assigned to this buffer

local function resolve_schema_for_buf(bufnr, cursor_line)
  local lookup = get_lookup()

  -- Collect schema URIs for all documents in the buffer.
  local all_gvks = extract_all_gvks(bufnr)
  local uris = {}
  local seen = {}
  for _, gvk in ipairs(all_gvks) do
    local entry = lookup[gvk.kind .. "|" .. gvk.api_version]
    if entry and not seen[entry.uri] then
      seen[entry.uri] = true
      uris[#uris + 1] = entry.uri
    end
  end

  if #uris == 0 then return nil end
  if #uris == 1 then return uris[1] end
  return make_composite(uris)
end

-- ---------------------------------------------------------------------------
-- workspace/configuration handler injection
-- ---------------------------------------------------------------------------

-- Build the yaml.schemas map to inject: { schema_uri -> [file_path] }
-- Mirrors interceptWorkspaceConfiguration in the router.
local function build_schemas_map(client)
  local schemas = {}
  -- Preserve any non-file:// entries from the client's static config
  -- (e.g. SchemaStore bindings like Chart.yaml -> chart.json).
  local orig = vim.tbl_get(client.config, "settings", "yaml", "schemas") or {}
  for uri, match in pairs(orig) do
    if not uri:match("^file://") then
      schemas[uri] = match
    end
  end
  -- Inject per-buffer schemas from our state.
  for bufnr, schema_uri in pairs(schema_state) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local fpath = vim.api.nvim_buf_get_name(bufnr)
      if fpath ~= "" then
        if not schemas[schema_uri] then schemas[schema_uri] = {} end
        -- Value must be an array of file paths (not URIs).
        local paths = type(schemas[schema_uri]) == "table"
          and schemas[schema_uri] or { schemas[schema_uri] }
        paths[#paths + 1] = fpath
        schemas[schema_uri] = paths
      end
    end
  end
  return schemas
end

-- Install a per-client workspace/configuration handler that intercepts the
-- config pull from yamlls and injects our schemas — exactly as the router does.
local function install_handler(client)
  -- Keep a reference to the original handler so we can chain through it for
  -- non-yaml sections.
  local orig = client.handlers["workspace/configuration"]
    or vim.lsp.handlers["workspace/configuration"]

  client.handlers["workspace/configuration"] = function(err, params, ctx)
    -- Let the original handler build the base response first.
    local response = orig(err, params, ctx)
    if type(response) ~= "table" then return response end

    -- Find which item(s) in the response correspond to the "yaml" section
    -- and inject our schemas map into each.
    local items = (params or {}).items or {}
    for i, item in ipairs(items) do
      if item.section == "yaml" then
        local cfg = type(response[i]) == "table" and response[i] or {}
        cfg.schemas = build_schemas_map(client)
        -- Ensure completion and validation are on (mirrors router defaults).
        if cfg.completion == nil then cfg.completion = true end
        if cfg.validation == nil then cfg.validation = true end
        response[i] = cfg
      end
    end

    return response
  end
end

-- ---------------------------------------------------------------------------
-- Main handler — resolves schema and updates state
-- ---------------------------------------------------------------------------

local function cursor_line_for(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then return pos[1] - 1 end
  end
  return nil
end

local function handle_buf(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft ~= "yaml" and ft ~= "helm" then return end

  local cursor_line = cursor_line_for(bufnr)
  local schema_uri  = resolve_schema_for_buf(bufnr, cursor_line)

  if not schema_uri then
    if schema_state[bufnr] then
      schema_state[bufnr] = nil
      -- Nudge yamlls to re-pull config so the stale schema is cleared.
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client.name == "yamlls" then
          client.notify("workspace/didChangeConfiguration", {})
        end
      end
    end
    return
  end

  if schema_state[bufnr] == schema_uri then return end
  schema_state[bufnr] = schema_uri

  -- Nudge yamlls to re-pull workspace/configuration — our handler will
  -- intercept the pull and inject the updated schema map.
  -- Then send a didChange with the current content so yamlls re-validates
  -- immediately, clearing any stale diagnostics from a previous schema.
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.name == "yamlls" then
      client.notify("workspace/didChangeConfiguration", {})
      -- Re-send buffer content so yamlls re-validates with the new schema.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          local text  = table.concat(lines, "\n")
          local fpath = vim.api.nvim_buf_get_name(bufnr)
          if fpath ~= "" then
            client.notify("textDocument/didChange", {
              textDocument   = { uri = "file://" .. fpath, version = 2 },
              contentChanges = { { text = text } },
            })
          end
        end
      end)
    end
  end
end

-- Public entry point so autocmds.lua can trigger re-apply after save.
function M.apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  schema_state[bufnr] = nil
  handle_buf(bufnr)
end

-- ---------------------------------------------------------------------------
-- Autocmds
-- ---------------------------------------------------------------------------

local timers = {}

local function schedule_handle(bufnr, delay_ms)
  if timers[bufnr] then timers[bufnr]:stop() end
  local timer = vim.uv.new_timer()
  timers[bufnr] = timer
  timer:start(delay_ms, 0, vim.schedule_wrap(function()
    timers[bufnr] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then handle_buf(bufnr) end
  end))
end

function M.setup()
  local group = vim.api.nvim_create_augroup("helm_schemas_autoschema", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group   = group,
    pattern = { "*.yaml", "*.yml", "*.tpl" },
    callback = function(ev) schedule_handle(ev.buf, 600) end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group   = group,
    pattern = { "*.yaml", "*.yml", "*.tpl" },
    callback = function(ev) schedule_handle(ev.buf, 800) end,
  })

  -- Re-evaluate when cursor crosses a --- document boundary so the nudge
  -- triggers yamlls to re-pull config with the cursor document's schema.
  local last_doc_start = {}
  vim.api.nvim_create_autocmd("CursorMoved", {
    group   = group,
    pattern = { "*.yaml", "*.yml", "*.tpl" },
    callback = function(ev)
      local bufnr = ev.buf
      local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, cursor_line + 1, false)
      local start = doc_start_line(lines, cursor_line)
      if last_doc_start[bufnr] ~= start then
        last_doc_start[bufnr] = start
        schema_state[bufnr] = nil
        schedule_handle(bufnr, 150)
      end
    end,
  })

  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client or client.name ~= "yamlls" then return end
      install_handler(client)
      schema_state[ev.buf] = nil
      schedule_handle(ev.buf, 300)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      schema_state[ev.buf] = nil
      if timers[ev.buf] then timers[ev.buf]:stop(); timers[ev.buf] = nil end
    end,
  })
end

return M

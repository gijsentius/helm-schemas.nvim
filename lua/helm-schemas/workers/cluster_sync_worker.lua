-- Cluster CRD sync worker: fetches all CRDs from the current kubectl context
-- and generates templates for each version that has an openAPIV3Schema.
-- Args: <templates_dir> <index_path>
-- Runs inside `nvim --headless -l` so vim.* APIs are available.

local templates_dir = arg[1]
local index_path    = arg[2]

if not templates_dir or not index_path then
  io.stderr:write("usage: cluster_sync_worker.lua <templates_dir> <index_path>\n")
  os.exit(1)
end

local tmpl        = require("helm-schemas.template")
local schemas_dir = vim.fn.fnamemodify(templates_dir, ":h") .. "/schemas"
os.execute("mkdir -p " .. vim.fn.shellescape(schemas_dir))

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function sh(cmd)
  local h = io.popen(cmd .. " 2>/dev/null")
  if not h then return nil end
  local out = h:read("*a"); h:close()
  return (out and out ~= "") and out or nil
end

local kubectl = vim.fn.exepath("kubectl")
if kubectl == "" then
  io.write("err: kubectl not found in PATH\n"); io.flush(); os.exit(1)
end

-- ---------------------------------------------------------------------------
-- Get current context for display and source tagging
-- ---------------------------------------------------------------------------

local context = vim.trim(sh(kubectl .. " config current-context") or "unknown")
io.write("cluster: " .. context .. "\n"); io.flush()

-- ---------------------------------------------------------------------------
-- Fetch all CRDs in one call
-- ---------------------------------------------------------------------------

io.write("Fetching CRDs from cluster…\n"); io.flush()

local json_out = sh(kubectl .. " get crd -o json")
if not json_out then
  io.write("err: kubectl get crd failed\n"); io.flush(); os.exit(1)
end

local ok, crd_list = pcall(vim.json.decode, json_out)
if not ok or type(crd_list) ~= "table" or type(crd_list.items) ~= "table" then
  io.write("err: failed to parse kubectl output\n"); io.flush(); os.exit(1)
end

local total = #crd_list.items
io.write("Found " .. total .. " CRDs\n"); io.flush()

-- ---------------------------------------------------------------------------
-- Load existing index (append, don't clobber)
-- ---------------------------------------------------------------------------

local index = {}
do
  local f = io.open(index_path, "r")
  if f then
    local raw = f:read("*a"); f:close()
    local ok2, existing = pcall(vim.json.decode, raw)
    if ok2 and type(existing) == "table" then index = existing end
  end
end

local existing_pos = {}
for i, e in ipairs(index) do
  existing_pos[e.name .. "|" .. (e.cluster or "")] = i
end

-- ---------------------------------------------------------------------------
-- Process each CRD
-- ---------------------------------------------------------------------------

os.execute("mkdir -p " .. vim.fn.shellescape(templates_dir))

local added = 0

for _, crd in ipairs(crd_list.items) do
  local spec   = type(crd.spec) == "table" and crd.spec or {}
  local names  = type(spec.names) == "table" and spec.names or {}
  local kind   = names.kind
  local group  = spec.group

  if not kind or not group then goto next_crd end

  for _, ver in ipairs(type(spec.versions) == "table" and spec.versions or {}) do
    local version    = ver.name
    local api_version = group .. "/" .. version
    local display_name = kind .. " (" .. api_version .. ")"
    local source_key   = display_name .. "|" .. context

    local schema = type(ver.schema) == "table"
      and type(ver.schema.openAPIV3Schema) == "table"
      and ver.schema.openAPIV3Schema
      or nil

    if not schema then
      io.write("warn: no openAPIV3Schema for " .. display_name .. "\n"); io.flush()
      goto next_version
    end

    -- Inject apiVersion/kind enum so template emits them as literals
    local props = schema.properties
    if type(props) == "table" then
      if type(props.apiVersion) == "table" then props.apiVersion.enum = { api_version } end
      if type(props.kind) == "table"       then props.kind.enum = { kind } end
    end

    -- Save schema as local JSON for yamlls
    local schema_fname = "cluster_" .. context:gsub("[^a-z0-9]+", "_") .. "_" .. tmpl.to_filename(display_name):gsub("%.yaml$", ".json")
    local schema_fpath = schemas_dir .. "/" .. schema_fname
    local schema_uri   = "file://" .. schema_fpath
    do
      local sf = io.open(schema_fpath, "w")
      if sf then
        local ok_enc, enc = pcall(vim.json.encode, schema)
        if ok_enc then sf:write(enc) end
        sf:close()
      end
    end

    local fname = "cluster_" .. context:gsub("[^a-z0-9]+", "_") .. "_" .. tmpl.to_filename(display_name)
    local fpath = templates_dir .. "/" .. fname
    local f = io.open(fpath, "w")
    if f then f:write(tmpl.to_template(schema, display_name, context, schema_uri)); f:close() end

    local entry = {
      name        = display_name,
      url         = context,
      file        = fname,
      source      = "cluster",
      kind        = kind,
      apiVersion  = api_version,
      group       = group,
      cluster     = context,
    }
    local pos = existing_pos[source_key]
    if pos then
      index[pos] = entry
      io.write("updated [cluster]: " .. display_name .. "\n"); io.flush()
    else
      index[#index + 1] = entry
      existing_pos[source_key] = #index
      io.write("ok [cluster]: " .. display_name .. "\n"); io.flush()
    end
    added = added + 1

    ::next_version::
  end

  ::next_crd::
end

-- ---------------------------------------------------------------------------
-- Write updated index
-- ---------------------------------------------------------------------------

local ok2, encoded = pcall(vim.json.encode, index)
if ok2 then
  local f = io.open(index_path, "w")
  if f then f:write(encoded); f:close() end
end

io.write(
  "done: " .. added .. " template(s) written\n"
)
io.flush()

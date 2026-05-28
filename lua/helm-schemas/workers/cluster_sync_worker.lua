-- Cluster sync worker: fetches CRDs AND built-in API resources from the
-- current kubectl context and generates templates for each.
-- Built-in resource schemas come from the cluster's OpenAPI v3 endpoint,
-- replacing any yannh (kubernetes) or schemastore entries for the same kind.
-- Args: <lua_dir> <templates_dir> <index_path>

package.path = arg[1] .. "/?.lua;" .. arg[1] .. "/?/init.lua;" .. package.path

local templates_dir = arg[2]
local index_path    = arg[3]

if not templates_dir or not index_path then
  io.stderr:write("usage: cluster_sync_worker.lua <lua_dir> <templates_dir> <index_path>\n")
  os.exit(1)
end

local tmpl        = require("helm-schemas.template")
local schemas_dir = vim.fn.fnamemodify(templates_dir, ":h") .. "/schemas"
os.execute("mkdir -p " .. vim.fn.shellescape(schemas_dir))
os.execute("mkdir -p " .. vim.fn.shellescape(templates_dir))

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

local context = vim.trim(sh(kubectl .. " config current-context") or "unknown")
io.write("cluster: " .. context .. "\n"); io.flush()

local ctx_slug = context:gsub("[^a-z0-9]+", "_")

-- ---------------------------------------------------------------------------
-- Load existing index
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

-- Build lookup by (kind, apiVersion) -> index position for cluster entries,
-- and collect positions of kubernetes/schemastore entries to prune later.
local cluster_pos  = {}   -- "kind|apiVersion" -> index position
local ks_positions = {}   -- positions of kubernetes/schemastore entries

for i, e in ipairs(index) do
  if e.source == "cluster" then
    cluster_pos[(e.kind or "") .. "|" .. (e.apiVersion or "")] = i
  elseif e.source == "kubernetes" or e.source == "schemastore" then
    if e.kind and e.apiVersion then
      ks_positions[i] = true
    end
  end
end

-- ---------------------------------------------------------------------------
-- Inline $ref resolution: converts OpenAPI v3 component refs into a
-- self-contained JSON Schema by moving shared defs into $defs.
-- ---------------------------------------------------------------------------

local function inline_refs(schema, all_components)
  -- Collect all component names referenced (directly or transitively).
  local needed = {}
  local function collect(node)
    if type(node) ~= "table" then return end
    local ref = node["$ref"]
    if type(ref) == "string" then
      local name = ref:match("^#/components/schemas/(.+)$")
      if name and not needed[name] then
        needed[name] = true
        collect(all_components[name])
      end
    end
    for _, v in pairs(node) do collect(v) end
  end
  collect(schema)

  -- Rewrite $ref values from "#/components/schemas/X" to "#/definitions/X".
  -- Use "definitions" (draft-04/07) rather than "$defs" (draft 2019-09)
  -- because yamlls validates and resolves schemas against draft-04/07.
  local function rewrite(node)
    if type(node) ~= "table" then return node end
    local out = {}
    for k, v in pairs(node) do
      if k == "$ref" and type(v) == "string" then
        local name = v:match("^#/components/schemas/(.+)$")
        out[k] = name and ("#/definitions/" .. name) or v
      else
        out[k] = rewrite(v)
      end
    end
    return out
  end

  local root = rewrite(schema)

  -- Populate definitions with rewritten component schemas.
  if next(needed) then
    local defs = {}
    for name in pairs(needed) do
      local comp = all_components[name]
      if comp then defs[name] = rewrite(comp) end
    end
    root["definitions"] = defs
  end

  return root
end

-- ---------------------------------------------------------------------------
-- Write one schema+template entry and update index
-- ---------------------------------------------------------------------------

local covered_keys = {}   -- "kind|apiVersion" keys written this run

local function write_entry(kind, api_version, display_name, schema, source_tag)
  local key = kind .. "|" .. api_version
  covered_keys[key] = true

  local fname_base = "cluster_" .. ctx_slug .. "_" .. tmpl.to_filename(display_name)
  local schema_fname = fname_base:gsub("%.yaml$", ".json")
  local schema_fpath = schemas_dir .. "/" .. schema_fname
  local schema_uri   = "file://" .. schema_fpath

  -- Inject apiVersion/kind enum so snippet emits them as literals.
  local props = schema.properties
  if type(props) == "table" then
    if type(props.apiVersion) == "table" then props.apiVersion.enum = { api_version } end
    if type(props.kind)       == "table" then props.kind.enum       = { kind }        end
  end

  -- Add top-level required array so yamlls warns on missing apiVersion/kind/metadata/spec.
  local top_required = {}
  for _, f in ipairs({ "apiVersion", "kind", "metadata", "spec" }) do
    if type(props) == "table" and props[f] then
      top_required[#top_required + 1] = f
    end
  end
  if #top_required > 0 then schema.required = top_required end

  local sf = io.open(schema_fpath, "w")
  if sf then
    local ok_enc, enc = pcall(vim.json.encode, schema)
    if ok_enc then sf:write(enc) end
    sf:close()
  end

  local fpath = templates_dir .. "/" .. fname_base
  local tf = io.open(fpath, "w")
  if tf then tf:write(tmpl.to_template(schema, display_name, context, schema_uri)); tf:close() end

  local entry = {
    name       = display_name,
    url        = context,
    file       = fname_base,
    source     = "cluster",
    kind       = kind,
    apiVersion = api_version,
    group      = api_version:match("^(.+)/") or "core",
    cluster    = context,
  }

  local pos = cluster_pos[key]
  if pos then
    index[pos] = entry
  else
    index[#index + 1] = entry
    cluster_pos[key]  = #index
  end
end

-- ---------------------------------------------------------------------------
-- Phase 1: CRDs via kubectl get crd
-- ---------------------------------------------------------------------------

io.write("Fetching CRDs from cluster…\n"); io.flush()

local crd_json = sh(kubectl .. " get crd -o json")
if crd_json then
  local ok, crd_list = pcall(vim.json.decode, crd_json)
  if ok and type(crd_list) == "table" and type(crd_list.items) == "table" then
    io.write("Found " .. #crd_list.items .. " CRDs\n"); io.flush()
    for _, crd in ipairs(crd_list.items) do
      local spec  = type(crd.spec)  == "table" and crd.spec  or {}
      local names = type(spec.names)== "table" and spec.names or {}
      local kind  = names.kind
      local group = spec.group
      if not kind or not group then goto next_crd end

      for _, ver in ipairs(type(spec.versions) == "table" and spec.versions or {}) do
        local version     = ver.name
        local api_version = group .. "/" .. version
        local display_name = kind .. " (" .. api_version .. ")"
        local schema = type(ver.schema) == "table"
          and type(ver.schema.openAPIV3Schema) == "table"
          and ver.schema.openAPIV3Schema or nil
        if not schema then
          io.write("warn: no openAPIV3Schema for " .. display_name .. "\n"); io.flush()
        else
          write_entry(kind, api_version, display_name, schema, "cluster")
        end
      end
      ::next_crd::
    end
  else
    io.write("warn: failed to parse kubectl get crd output\n"); io.flush()
  end
else
  io.write("warn: kubectl get crd failed\n"); io.flush()
end

-- ---------------------------------------------------------------------------
-- Phase 2: Built-in API resources via OpenAPI v3
-- ---------------------------------------------------------------------------

io.write("Fetching OpenAPI v3 paths from cluster…\n"); io.flush()

local openapi_paths
do
  local raw = sh(kubectl .. " get --raw /openapi/v3")
  if raw then
    local ok_idx, parsed = pcall(vim.json.decode, raw)
    if ok_idx and type(parsed) == "table" and type(parsed.paths) == "table" then
      openapi_paths = parsed.paths
    else
      io.write("warn: failed to parse /openapi/v3 index\n"); io.flush()
    end
  else
    io.write("warn: /openapi/v3 not available, skipping built-in resources\n"); io.flush()
  end
end

if openapi_paths then
for path_key, path_meta in pairs(openapi_paths) do
  -- Only process per-group-version paths (api/v1, apis/<group>/<version>)
  if not path_key:match("^api") then goto next_path end
  if path_key == "api" or path_key == "apis" then goto next_path end
  -- Skip paths that have further sub-paths (not a leaf version endpoint)
  local slash_count = select(2, path_key:gsub("/", ""))
  -- api/v1 has 1 slash, apis/<group>/<version> has 2 slashes
  if slash_count ~= 1 and slash_count ~= 2 then goto next_path end

  local server_url = type(path_meta) == "table" and path_meta.serverRelativeURL or nil
  if not server_url then goto next_path end

  io.write("Fetching schemas for " .. path_key .. "…\n"); io.flush()

  local doc_raw = sh(kubectl .. " get --raw " .. vim.fn.shellescape(server_url))
  if not doc_raw then goto next_path end

  local ok_doc, doc = pcall(vim.json.decode, doc_raw)
  if not ok_doc or type(doc) ~= "table" then goto next_path end

  local components = type(doc.components) == "table"
    and type(doc.components.schemas) == "table"
    and doc.components.schemas or {}

  if not next(components) then goto next_path end

  for _, comp_schema in pairs(components) do
    local gvk_list = comp_schema["x-kubernetes-group-version-kind"]
    if type(gvk_list) ~= "table" then goto next_comp end

    for _, gvk in ipairs(gvk_list) do
      local kind        = gvk.kind
      local group       = gvk.group or ""
      local version     = gvk.version
      if not kind or not version then goto next_gvk end

      -- Skip list types and internal/status sub-resources
      if kind:match("List$") or kind:match("Options$") or kind:match("Status$") then
        goto next_gvk
      end

      local api_version  = (group ~= "" and (group .. "/" .. version)) or version
      local display_name = kind .. " (" .. api_version .. ")"

      -- Only include top-level resources (those that have spec or data or rules)
      local props = type(comp_schema.properties) == "table" and comp_schema.properties or {}
      if not (props.spec or props.data or props.rules or props.subjects) then
        goto next_gvk
      end

      local schema = inline_refs(comp_schema, components)
      write_entry(kind, api_version, display_name, schema, "cluster")

      ::next_gvk::
    end
    ::next_comp::
  end

  ::next_path::
end
end -- if openapi_paths

-- ---------------------------------------------------------------------------
-- Prune superseded kubernetes/schemastore entries
-- ---------------------------------------------------------------------------

-- Any kubernetes or schemastore entry whose kind+apiVersion is now covered
-- by a cluster entry gets removed from the index.
local pruned = 0
local new_index = {}
for i, e in ipairs(index) do
  if ks_positions[i] and covered_keys[(e.kind or "") .. "|" .. (e.apiVersion or "")] then
    pruned = pruned + 1
  else
    new_index[#new_index + 1] = e
  end
end
index = new_index

-- ---------------------------------------------------------------------------
-- Write updated index
-- ---------------------------------------------------------------------------

local ok2, encoded = pcall(vim.json.encode, index)
if ok2 then
  local f = io.open(index_path, "w")
  if f then f:write(encoded); f:close() end
end

local written = 0
for _ in pairs(covered_keys) do written = written + 1 end
io.write("done: " .. written .. " template(s) written, " .. pruned .. " superseded entries pruned\n")
io.flush()

-- CRD worker: parses a CRD YAML (path or URL) and appends entries to the index.
-- Args: <lua_dir> <source> <templates_dir> <index_path>
-- Runs inside `nvim --headless -l` so vim.* APIs are available.

package.path = arg[1] .. "/?.lua;" .. arg[1] .. "/?/init.lua;" .. package.path

local source        = arg[2]
local templates_dir = arg[3]
local index_path    = arg[4]

if not source or not templates_dir or not index_path then
  io.stderr:write("usage: crd_worker.lua <lua_dir> <source> <templates_dir> <index_path>\n")
  os.exit(1)
end

local tmpl        = require("helm-schemas.template")
local schemas_dir = vim.fn.fnamemodify(templates_dir, ":h") .. "/schemas"
os.execute("mkdir -p " .. vim.fn.shellescape(schemas_dir))

local yq = vim.fn.exepath("yq")
if yq == "" then
  io.write("err: yq not found in PATH\n"); io.flush(); os.exit(1)
end

local function shellescape(s) return vim.fn.shellescape(s) end

local function sh(cmd)
  local h = io.popen(cmd .. " 2>/dev/null")
  if not h then return nil end
  local out = h:read("*a"); h:close()
  return (out and out ~= "") and out or nil
end

-- ---------------------------------------------------------------------------
-- Fetch source into a temp file
-- ---------------------------------------------------------------------------

local tmp_yaml = os.tmpname() .. ".yaml"

if source:match("^https?://") then
  local ret = os.execute("curl -fsSL --max-time 30 " .. shellescape(source) .. " -o " .. shellescape(tmp_yaml))
  if ret ~= 0 then
    io.write("err: failed to fetch " .. source .. "\n"); io.flush(); os.exit(1)
  end
else
  os.execute("cp " .. shellescape(vim.fn.expand(source)) .. " " .. shellescape(tmp_yaml))
end

local doc_count = tonumber(sh(yq .. " eval-all '[.] | length' " .. shellescape(tmp_yaml))) or 1
io.write("source: " .. source .. " (" .. doc_count .. " document(s))\n"); io.flush()

-- ---------------------------------------------------------------------------
-- Load existing index (append, don't clobber)
-- ---------------------------------------------------------------------------

local index = {}
do
  local f = io.open(index_path, "r")
  if f then
    local raw = f:read("*a"); f:close()
    local ok, existing = pcall(vim.json.decode, raw)
    if ok and type(existing) == "table" then index = existing end
  end
end

-- Build a lookup from key -> index position so we can update in place
local existing_pos = {}
for i, e in ipairs(index) do
  existing_pos[e.name .. "|" .. (e.url or "")] = i
end

-- ---------------------------------------------------------------------------
-- Parse each document
-- ---------------------------------------------------------------------------

os.execute("mkdir -p " .. shellescape(templates_dir))

local added = 0

for i = 0, doc_count - 1 do
  local sel = "select(document_index == " .. i .. ") | select(.kind == \"CustomResourceDefinition\")"

  local kind_raw  = sh(yq .. " eval-all " .. shellescape(sel .. " | .spec.names.kind")  .. " " .. shellescape(tmp_yaml))
  local group_raw = sh(yq .. " eval-all " .. shellescape(sel .. " | .spec.group") .. " " .. shellescape(tmp_yaml))

  if not kind_raw  or kind_raw:match("^null")  or kind_raw:match("^%s*$") then goto next_doc end
  if not group_raw or group_raw:match("^null") or group_raw:match("^%s*$") then goto next_doc end

  local kind  = vim.trim(kind_raw)
  local group = vim.trim(group_raw)

  local versions_raw = sh(yq .. " eval-all " .. shellescape(sel .. " | .spec.versions[].name") .. " " .. shellescape(tmp_yaml))
  if not versions_raw then goto next_doc end

  local versions = {}
  for v in versions_raw:gmatch("[^\n]+") do
    v = vim.trim(v)
    if v ~= "" and not v:match("^null") then versions[#versions + 1] = v end
  end

  for vi, version in ipairs(versions) do
    local api_version  = group .. "/" .. version
    local display_name = kind .. " (" .. api_version .. ")"

    local schema_expr = sel .. " | .spec.versions[" .. (vi - 1) .. "].schema.openAPIV3Schema"
    local schema_json = sh(yq .. " eval-all -o=json " .. shellescape(schema_expr) .. " " .. shellescape(tmp_yaml))

    if not schema_json or schema_json:match("^null") then
      io.write("warn: no openAPIV3Schema for " .. display_name .. "\n"); io.flush()
      goto next_version
    end

    local ok, schema = pcall(vim.json.decode, schema_json)
    if not ok or type(schema) ~= "table" then
      io.write("warn: schema parse error for " .. display_name .. "\n"); io.flush()
      goto next_version
    end

    -- CRD schemas define apiVersion/kind as plain strings with no enum,
    -- so inject the known values as single-item enums before template generation.
    -- to_template's single_enum() will then emit them as literal values.
    local props = schema.properties
    if type(props) == "table" then
      if type(props.apiVersion) == "table" then
        props.apiVersion.enum = { api_version }
      end
      if type(props.kind) == "table" then
        props.kind.enum = { kind }
      end
    end

    -- Save the dereferenced schema as a local JSON file so yamlls can use it
    local schema_fname = "crd_" .. tmpl.to_filename(display_name):gsub("%.yaml$", ".json")
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

    local fname = "crd_" .. tmpl.to_filename(display_name)
    local f = io.open(templates_dir .. "/" .. fname, "w")
    if f then f:write(tmpl.to_template(schema, display_name, source, schema_uri)); f:close() end

    local entry = {
      name       = display_name,
      url        = source,
      file       = fname,
      source     = "crd",
      kind       = kind,
      apiVersion = api_version,
      group      = group,
    }
    local key = display_name .. "|" .. source
    local pos = existing_pos[key]
    if pos then
      index[pos] = entry
      io.write("updated [crd]: " .. display_name .. "\n"); io.flush()
    else
      index[#index + 1] = entry
      existing_pos[key] = #index
      io.write("ok [crd]: " .. display_name .. "\n"); io.flush()
    end
    added = added + 1

    ::next_version::
  end

  ::next_doc::
end

os.remove(tmp_yaml)

-- ---------------------------------------------------------------------------
-- Write updated index
-- ---------------------------------------------------------------------------

local ok2, encoded = pcall(vim.json.encode, index)
if ok2 then
  local f = io.open(index_path, "w")
  if f then f:write(encoded); f:close() end
end

if added == 0 then
  io.write("warn: no new CRD entries found in " .. source .. "\n")
else
  io.write("done: added " .. added .. " CRD template(s)\n")
end
io.flush()

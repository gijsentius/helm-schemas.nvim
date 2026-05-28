-- SchemaStore worker: fetches k8s-related schemas from schemastore.org.
-- Args: <lua_dir> <templates_dir> <index_path>
-- Runs inside `nvim --headless -l` so vim.* APIs are available.

package.path = arg[1] .. "/?.lua;" .. arg[1] .. "/?/init.lua;" .. package.path

local templates_dir = arg[2]
local index_path    = arg[3]

if not templates_dir or not index_path then
  io.stderr:write("usage: generate_worker.lua <lua_dir> <templates_dir> <index_path>\n")
  os.exit(1)
end

local tmpl = require("helm-schemas.template")

local CATALOG_URL = "https://www.schemastore.org/api/json/catalog.json"

local function json_decode(s)
  local ok, v = pcall(vim.json.decode, s); return ok and v or nil
end

local function json_encode(v)
  local ok, s = pcall(vim.json.encode, v); return ok and s or nil
end

local function fetch(url)
  local h = io.popen("curl -fsSL --max-time 20 " .. vim.fn.shellescape(url) .. " 2>/dev/null")
  if not h then return nil end
  local b = h:read("*a"); h:close()
  return (b and b ~= "") and json_decode(b) or nil
end

local function parallel_fetch(url_map, label)
  local tmp_dir = os.tmpname() .. "_schemas"
  os.execute("mkdir -p " .. tmp_dir)
  local cfg_path = tmp_dir .. "/urls.cfg"
  local cfg = io.open(cfg_path, "w")
  if not cfg then return {} end
  for fname, url in pairs(url_map) do
    cfg:write('url = "' .. url .. '"\n')
    cfg:write('output = "' .. tmp_dir .. "/" .. fname .. '"\n')
    cfg:write("silent\nmax-time = 20\nnext\n")
  end
  cfg:close()
  io.write(label .. ": downloading " .. vim.tbl_count(url_map) .. " schemas in parallel…\n")
  io.flush()
  os.execute("curl --parallel --parallel-max 32 -K " .. cfg_path .. " 2>/dev/null")
  local results = {}
  for fname in pairs(url_map) do
    local f = io.open(tmp_dir .. "/" .. fname, "r")
    if f then results[fname] = f:read("*a"); f:close() end
    os.remove(tmp_dir .. "/" .. fname)
  end
  os.remove(cfg_path)
  os.execute("rmdir " .. tmp_dir .. " 2>/dev/null")
  return results
end

-- ---------------------------------------------------------------------------
-- Load existing index; preserve non-schemastore entries (crd, cluster, kubernetes)
-- ---------------------------------------------------------------------------

os.execute("mkdir -p " .. templates_dir)

local index = {}
do
  local f = io.open(index_path, "r")
  if f then
    local raw = f:read("*a"); f:close()
    local ok, existing = pcall(vim.json.decode, raw)
    if ok and type(existing) == "table" then index = existing end
  end
end

-- Build update-in-place map for schemastore entries
local existing_pos = {}
for i, e in ipairs(index) do
  if e.source == "schemastore" then
    existing_pos[e.name] = i
  end
end

-- ---------------------------------------------------------------------------
-- Fetch catalog and download all k8s-related schemas in parallel
-- ---------------------------------------------------------------------------

io.write("Fetching SchemaStore catalog…\n"); io.flush()

local catalog = fetch(CATALOG_URL)
if not catalog or not catalog.schemas then
  io.write("err: failed to fetch or parse SchemaStore catalog\n"); io.flush(); os.exit(1)
end
io.write("SchemaStore: " .. #catalog.schemas .. " schemas found\n"); io.flush()

local ss_url_map, ss_meta = {}, {}
for _, meta in ipairs(catalog.schemas) do
  if meta.url and meta.name then
    local fname = "ss_" .. tmpl.to_filename(meta.name)
    ss_url_map[fname] = meta.url
    ss_meta[fname] = meta
  end
end

local ss_bodies = parallel_fetch(ss_url_map, "SchemaStore")
local matched = 0
local added   = 0
local updated = 0

for fname, body in pairs(ss_bodies) do
  local schema = json_decode(body)
  if schema then
    local ok, s = pcall(json_encode, schema)
    if ok and type(s) == "string"
      and s:find('"apiVersion"', 1, true)
      and s:find('"kind"', 1, true)
    then
      local meta = ss_meta[fname]
      matched = matched + 1
      local out = tmpl.to_filename(meta.name)
      local f = io.open(templates_dir .. "/" .. out, "w")
      if f then f:write(tmpl.to_template(schema, meta.name, meta.url)); f:close() end

      local entry = { name = meta.name, url = meta.url, file = out, source = "schemastore" }
      local pos = existing_pos[meta.name]
      if pos then
        index[pos] = entry
        updated = updated + 1
      else
        index[#index + 1] = entry
        existing_pos[meta.name] = #index
        added = added + 1
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Write index
-- ---------------------------------------------------------------------------

local f = io.open(index_path, "w")
if f then f:write(json_encode(index) or "[]"); f:close() end

io.write("done: " .. matched .. " SchemaStore templates (" .. added .. " new, " .. updated .. " updated)\n"); io.flush()

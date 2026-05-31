-- datreeio CRD catalog worker: fetches CRD schemas from datreeio/CRDs-catalog.
-- Uses a local disk cache so repeated runs skip already-downloaded schemas.
-- Args: <lua_dir> <templates_dir> <index_path>
-- Runs inside `nvim --headless -l` so vim.* APIs are available.

package.path = arg[1] .. "/?.lua;" .. arg[1] .. "/?/init.lua;" .. package.path

local templates_dir = arg[2]
local index_path    = arg[3]

if not templates_dir or not index_path then
  io.stderr:write("usage: datreeio_worker.lua <lua_dir> <templates_dir> <index_path>\n")
  os.exit(1)
end

local tmpl            = require("helm-schemas.template")
local data_dir        = vim.fn.fnamemodify(templates_dir, ":h")
local schemas_dir     = data_dir .. "/schemas"
local kubeconform_dir = data_dir .. "/kubeconform"
local cache_dir       = data_dir .. "/cache/datreeio"
os.execute("mkdir -p " .. vim.fn.shellescape(schemas_dir))
os.execute("mkdir -p " .. vim.fn.shellescape(kubeconform_dir))
os.execute("mkdir -p " .. vim.fn.shellescape(cache_dir))
os.execute("mkdir -p " .. vim.fn.shellescape(templates_dir))

local DATREEIO_BASE = "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/"
local DATREEIO_TREE = "https://api.github.com/repos/datreeio/CRDs-catalog/git/trees/main?recursive=1"

local function json_decode(s)
  local ok, v = pcall(vim.json.decode, s); return ok and v or nil
end

local function json_encode(v)
  local ok, s = pcall(vim.json.encode, v); return ok and s or nil
end

local function sh_fetch(url)
  local h = io.popen("curl -fsSL --max-time 20 " .. vim.fn.shellescape(url) .. " 2>/dev/null")
  if not h then return nil end
  local b = h:read("*a"); h:close()
  return (b and b ~= "") and b or nil
end

local function write_kc_link(kind, api_version, schema_fpath)
  local group = api_version:match("^(.+)/") or ""
  local ver   = api_version:match("[^/]+$")
  local name  = group ~= ""
    and (kind:lower() .. "-" .. group:lower() .. "-" .. ver:lower() .. ".json")
    or  (kind:lower() .. "-" .. ver:lower() .. ".json")
  local link = kubeconform_dir .. "/" .. name
  os.remove(link)
  os.execute("ln -s " .. vim.fn.shellescape(schema_fpath) .. " " .. vim.fn.shellescape(link))
end

-- Cache-key: flatten the catalog path into a single filename.
-- "acme.cert-manager.io/challenge_v1.json" -> "acme.cert-manager.io__challenge_v1.json"
local function cache_path_for(catalog_path)
  return cache_dir .. "/" .. catalog_path:gsub("/", "__")
end

-- Parse kind, group, version from a datreeio catalog path.
-- "acme.cert-manager.io/challenge_v1.json" -> kind="Challenge", group="acme.cert-manager.io", version="v1"
local function parse_path(catalog_path)
  local group, rest = catalog_path:match("^([^/]+)/(.+)$")
  if not group or not rest then return nil end
  local kind_lower, version = rest:match("^(.-)_([^_]+)%.json$")
  if not kind_lower or not version then return nil end
  -- Capitalise first letter of kind.
  local kind = kind_lower:sub(1,1):upper() .. kind_lower:sub(2)
  return kind, group, version
end

-- ---------------------------------------------------------------------------
-- Fetch the full file tree in one API call
-- ---------------------------------------------------------------------------

io.write("Fetching datreeio/CRDs-catalog file tree…\n"); io.flush()

local tree_raw = sh_fetch(DATREEIO_TREE)
if not tree_raw then
  io.write("err: failed to fetch datreeio tree listing\n"); io.flush(); os.exit(1)
end

local tree_data = json_decode(tree_raw)
if not tree_data or type(tree_data.tree) ~= "table" then
  io.write("err: failed to parse datreeio tree listing\n"); io.flush(); os.exit(1)
end

-- Filter to {group}/{kind}_{version}.json paths only.
local catalog_paths = {}
for _, entry in ipairs(tree_data.tree) do
  local p = entry.path or ""
  if p:match("^[^/]+/[^/]+_v[^/]+%.json$") and not p:match("^Utilities/") then
    catalog_paths[#catalog_paths + 1] = p
  end
end

io.write("datreeio: " .. #catalog_paths .. " CRD schemas in catalog\n"); io.flush()

-- ---------------------------------------------------------------------------
-- Separate into cached vs needs-fetch
-- ---------------------------------------------------------------------------

local need_fetch = {}
local cache_hits = 0

for _, p in ipairs(catalog_paths) do
  local cp = cache_path_for(p)
  local cf = io.open(cp, "r")
  if cf then
    cf:close()
    cache_hits = cache_hits + 1
  else
    need_fetch[#need_fetch + 1] = p
  end
end

io.write("datreeio: " .. cache_hits .. " cached, " .. #need_fetch .. " to fetch\n"); io.flush()

-- Parallel download of uncached schemas using curl.
if #need_fetch > 0 then
  local tmp_dir = os.tmpname() .. "_datreeio"
  os.execute("mkdir -p " .. tmp_dir)
  local cfg_path = tmp_dir .. "/urls.cfg"
  local cfg = io.open(cfg_path, "w")
  if cfg then
    for _, p in ipairs(need_fetch) do
      -- Use a flat filename in the tmp dir (same as cache key filename).
      local flat = p:gsub("/", "__")
      cfg:write('url = "' .. DATREEIO_BASE .. p .. '"\n')
      cfg:write('output = "' .. tmp_dir .. "/" .. flat .. '"\n')
      cfg:write("silent\nmax-time = 20\nnext\n")
    end
    cfg:close()
    io.write("datreeio: downloading " .. #need_fetch .. " schemas in parallel…\n"); io.flush()
    os.execute("curl --parallel --parallel-max 32 -K " .. cfg_path .. " 2>/dev/null")

    -- Move downloaded files into the cache.
    for _, p in ipairs(need_fetch) do
      local flat = p:gsub("/", "__")
      local tmp_path = tmp_dir .. "/" .. flat
      local f = io.open(tmp_path, "r")
      if f then
        local body = f:read("*a"); f:close()
        if body and body ~= "" then
          local cf = io.open(cache_path_for(p), "w")
          if cf then cf:write(body); cf:close() end
        end
        os.remove(tmp_path)
      end
    end
    os.remove(cfg_path)
    os.execute("rmdir " .. tmp_dir .. " 2>/dev/null")
  end
end

-- ---------------------------------------------------------------------------
-- Schema rewriting: strip default keys (vim.json round-trip corruption) and
-- flatten allOf:[{$ref:X}] wrappers (yamlls completion killer).
-- Same logic as cluster_sync_worker.lua rewrite().
-- ---------------------------------------------------------------------------

local function rewrite(node)
  if type(node) ~= "table" then return node end
  local out = {}
  for k, v in pairs(node) do
    if k == "default" then
      -- Drop: vim.json encodes {} as [] breaking yamlls type inference.
    else
      out[k] = rewrite(v)
    end
  end
  -- Flatten allOf:[{$ref:X}] -> {$ref:X}
  if out["allOf"] and not out["properties"] and not out["$ref"] then
    local allof = out["allOf"]
    if type(allof) == "table" and #allof == 1
        and type(allof[1]) == "table" and allof[1]["$ref"] then
      local flat = { ["$ref"] = allof[1]["$ref"] }
      for k, v in pairs(out) do
        if k ~= "allOf" then flat[k] = v end
      end
      return flat
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Load existing index
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

local existing_pos = {}
for i, e in ipairs(index) do
  if e.source == "datreeio" then
    existing_pos[e.name] = i
  end
end

-- ---------------------------------------------------------------------------
-- Process all cached schemas: write schema JSON, template, kubeconform link
-- ---------------------------------------------------------------------------

local added   = 0
local updated = 0
local skipped = 0

for _, catalog_path in ipairs(catalog_paths) do
  local kind, group, version = parse_path(catalog_path)
  if not kind then skipped = skipped + 1; goto continue end

  local cp = cache_path_for(catalog_path)
  local cf = io.open(cp, "r")
  if not cf then skipped = skipped + 1; goto continue end
  local body = cf:read("*a"); cf:close()
  if not body or body == "" then skipped = skipped + 1; goto continue end

  local ok, schema = pcall(vim.json.decode, body)
  if not ok or type(schema) ~= "table" then skipped = skipped + 1; goto continue end

  -- Strip default keys and flatten allOf wrappers before any further processing
  -- to avoid vim.json round-trip corruption.
  schema = rewrite(schema)

  local api_version  = group .. "/" .. version
  local display_name = kind .. " (" .. api_version .. ")"

  -- Inject enum values for kind/apiVersion so the template emits them as literals.
  local props = schema.properties
  if type(props) == "table" then
    if type(props.apiVersion) == "table" then props.apiVersion.enum = { api_version } end
    if type(props.kind)       == "table" then props.kind.enum       = { kind }        end
  end

  -- Add top-level required array for resources that look like k8s objects.
  if type(props) == "table" then
    local top_required = {}
    for _, f in ipairs({ "apiVersion", "kind", "metadata", "spec" }) do
      if props[f] then top_required[#top_required + 1] = f end
    end
    if #top_required > 0 then schema.required = top_required end
  end

  schema["$schema"] = "http://json-schema.org/draft-07/schema#"

  local schema_fname = "datreeio_" .. tmpl.to_filename(display_name):gsub("%.yaml$", ".json")
  local schema_fpath = schemas_dir .. "/" .. schema_fname
  local schema_uri   = "file://" .. schema_fpath

  local sf = io.open(schema_fpath, "w")
  if sf then
    local ok_enc, enc = pcall(vim.json.encode, schema)
    if ok_enc then sf:write(enc) end
    sf:close()
  end
  write_kc_link(kind, api_version, schema_fpath)

  local fname = "datreeio_" .. tmpl.to_filename(display_name)
  local tf = io.open(templates_dir .. "/" .. fname, "w")
  if tf then tf:write(tmpl.to_template(schema, display_name, DATREEIO_BASE .. catalog_path, schema_uri)); tf:close() end

  local entry = {
    name       = display_name,
    url        = DATREEIO_BASE .. catalog_path,
    file       = fname,
    source     = "datreeio",
    kind       = kind,
    apiVersion = api_version,
    group      = group,
  }

  local pos = existing_pos[display_name]
  if pos then
    index[pos] = entry
    updated = updated + 1
  else
    index[#index + 1] = entry
    existing_pos[display_name] = #index
    added = added + 1
  end

  ::continue::
end

-- ---------------------------------------------------------------------------
-- Write updated index
-- ---------------------------------------------------------------------------

local ok2, encoded = pcall(vim.json.encode, index)
if ok2 then
  local f = io.open(index_path, "w")
  if f then f:write(encoded); f:close() end
end

io.write("done: " .. (added + updated) .. " datreeio schemas ("
  .. added .. " new, " .. updated .. " updated, " .. skipped .. " skipped)\n")
io.flush()

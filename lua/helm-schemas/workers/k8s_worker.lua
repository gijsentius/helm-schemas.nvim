-- Kubernetes schema worker: fetches core k8s schemas from yannh/kubernetes-json-schema.
-- Args: <templates_dir> <index_path>
-- Runs inside `nvim --headless -l` so vim.* APIs are available.

local templates_dir = arg[1]
local index_path    = arg[2]

if not templates_dir or not index_path then
  io.stderr:write("usage: k8s_worker.lua <templates_dir> <index_path>\n")
  os.exit(1)
end

local tmpl = require("helm-schemas.template")

local YANNH_BASE = "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/master-standalone-strict/"
local YANNH_API  = "https://api.github.com/repos/yannh/kubernetes-json-schema/contents/master-standalone-strict"

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
-- Load existing index; build update-in-place position map
-- ---------------------------------------------------------------------------

os.execute("mkdir -p " .. vim.fn.shellescape(templates_dir))

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
  if e.source == "kubernetes" then
    existing_pos[e.name] = i
  end
end

-- ---------------------------------------------------------------------------
-- Fetch listing and download all versioned schemas in parallel
-- ---------------------------------------------------------------------------

io.write("Fetching yannh/kubernetes-json-schema listing…\n"); io.flush()

local listing = fetch(YANNH_API)
if not listing then
  io.write("err: failed to fetch yannh repo listing\n"); io.flush(); os.exit(1)
end

local version_pat = "%-v%d[a-z0-9]*%.json$"
local skip = { ["all.json"] = true, ["_definitions.json"] = true }

local url_map = {}
for _, entry in ipairs(listing) do
  local name = entry.name
  if not skip[name] and name:match(version_pat) then
    url_map[name] = YANNH_BASE .. name
  end
end

io.write("yannh: " .. vim.tbl_count(url_map) .. " versioned schemas to fetch\n"); io.flush()

local bodies = parallel_fetch(url_map, "yannh")
local matched = 0

for fname, body in pairs(bodies) do
  local schema = json_decode(body)
  if schema then
    local gvk_list = schema["x-kubernetes-group-version-kind"]
    if type(gvk_list) == "table" and #gvk_list > 0 then
      local gvk        = gvk_list[1]
      local api_version = gvk.group ~= "" and (gvk.group .. "/" .. gvk.version) or gvk.version
      local display_name = gvk.kind .. " (" .. api_version .. ")"
      local url        = YANNH_BASE .. fname
      local out        = "k8s_" .. tmpl.to_filename(display_name)

      local f = io.open(templates_dir .. "/" .. out, "w")
      if f then f:write(tmpl.to_template(schema, display_name, url)); f:close() end

      local entry = {
        name       = display_name,
        url        = url,
        file       = out,
        source     = "kubernetes",
        kind       = gvk.kind,
        apiVersion = api_version,
        group      = gvk.group ~= "" and gvk.group or "core",
      }

      local pos = existing_pos[display_name]
      if pos then
        index[pos] = entry
        io.write("updated [k8s]: " .. display_name .. "\n"); io.flush()
      else
        index[#index + 1] = entry
        existing_pos[display_name] = #index
        io.write("ok [k8s]: " .. display_name .. "\n"); io.flush()
      end
      matched = matched + 1
    end
  end
end

-- ---------------------------------------------------------------------------
-- Write index
-- ---------------------------------------------------------------------------

local f = io.open(index_path, "w")
if f then f:write(json_encode(index) or "[]"); f:close() end

io.write("done: " .. matched .. " k8s templates written\n"); io.flush()

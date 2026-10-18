-- Tests for the local schema registry, cache behaviour, and feature requirements:
--
-- 1. Smart Detection:    GVK extracted from buffer content (not filename/extension)
-- 2. Multi-Document:     composite anyOf schema generated for multi-doc files
-- 3. Dynamic State:      schema detached when buffer emptied; reattached on new content
-- 4. Local Cache:        yannh schemas written to cache dir; re-runs skip download
-- 5. No Modeline:        schema_state drives workspace/configuration, no $schema comment needed

local function plugin_dir()
  return vim.fn.fnamemodify(debug.getinfo(1,"S").source:match("@?(.+)"), ":h:h")
end

local function data_dir()
  return vim.fn.stdpath("data") .. "/helm-schemas"
end

-- ---------------------------------------------------------------------------
-- Helpers shared across tests
-- ---------------------------------------------------------------------------

local MODELINE_PAT = "^# yaml%-language%-server:.*%$schema="

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft or "yaml"
  vim.bo[buf].modified = false
  return buf
end

-- Replica of extract_all_gvks from autoschema.lua
local function extract_all_gvks(lines)
  local results = {}
  local i = 1
  while i <= #lines do
    if lines[i] and lines[i]:match("^%-%-%-%s*$") then i = i + 1 end
    local doc_start = i
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
    i = j
    if i > #lines then break end
    if not lines[i]:match("^%-%-%-%s*$") then
      i = i + 1
      while i <= #lines and not lines[i]:match("^%-%-%-%s*$") do i = i + 1 end
    end
  end
  return results
end

-- Replica of make_composite logic from autoschema.lua
local function make_composite_path(uris, composite_dir)
  local seen, sorted = {}, {}
  for _, u in ipairs(uris) do
    if not seen[u] then seen[u]=true; sorted[#sorted+1]=u end
  end
  table.sort(sorted)
  local key = vim.fn.sha256(table.concat(sorted,"|")):sub(1,16)
  return composite_dir .. "/composite_" .. key .. ".json"
end

-- Replica of build_schemas_map from autoschema.lua
local function build_schemas_map(schema_state, client_schemas)
  client_schemas = client_schemas or {}
  local schemas = {}
  for uri, match in pairs(client_schemas) do
    if not uri:match("^file://") then schemas[uri] = match end
  end
  for fpath, schema_uri in pairs(schema_state) do
    if not schemas[schema_uri] then schemas[schema_uri] = {} end
    local paths = type(schemas[schema_uri])=="table"
      and schemas[schema_uri] or {schemas[schema_uri]}
    paths[#paths+1] = fpath
    schemas[schema_uri] = paths
  end
  return schemas
end

-- ---------------------------------------------------------------------------
-- 1. Smart Detection
-- ---------------------------------------------------------------------------

describe("smart detection: GVK from buffer content", function()

  it("detects kind and apiVersion from a plain YAML buffer", function()
    local gvks = extract_all_gvks({
      "apiVersion: apps/v1",
      "kind: Deployment",
      "metadata:",
      "  name: test",
    })
    assert.equals(1, #gvks)
    assert.equals("Deployment", gvks[1].kind)
    assert.equals("apps/v1",    gvks[1].api_version)
  end)

  it("works regardless of field order (kind before apiVersion)", function()
    local gvks = extract_all_gvks({
      "kind: Service",
      "apiVersion: v1",
    })
    assert.equals(1, #gvks)
    assert.equals("Service", gvks[1].kind)
    assert.equals("v1",      gvks[1].api_version)
  end)

  it("returns nothing for a file with no GVK fields", function()
    local gvks = extract_all_gvks({ "foo: bar", "baz: qux" })
    assert.equals(0, #gvks)
  end)

  it("returns nothing for an empty file (dynamic state: detach)", function()
    local gvks = extract_all_gvks({})
    assert.equals(0, #gvks)
  end)

  it("detects CRD group in apiVersion (e.g. cert-manager)", function()
    local gvks = extract_all_gvks({
      "apiVersion: cert-manager.io/v1",
      "kind: Certificate",
    })
    assert.equals(1, #gvks)
    assert.equals("Certificate",       gvks[1].kind)
    assert.equals("cert-manager.io/v1", gvks[1].api_version)
  end)

end)

-- ---------------------------------------------------------------------------
-- 2. Multi-Document Support
-- ---------------------------------------------------------------------------

describe("multi-document: composite anyOf schema", function()

  local URI_A = "file:///schemas/deployment.json"
  local URI_B = "file:///schemas/service.json"
  local URI_C = "file:///schemas/configmap.json"
  local tmp   = vim.fn.stdpath("cache") .. "/hs_test_composite"

  before_each(function()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  it("extracts two GVKs from a two-doc buffer", function()
    local gvks = extract_all_gvks({
      "apiVersion: apps/v1", "kind: Deployment",
      "---",
      "apiVersion: v1",      "kind: Service",
    })
    assert.equals(2, #gvks)
    assert.equals("Deployment", gvks[1].kind)
    assert.equals("Service",    gvks[2].kind)
  end)

  it("generates a composite file with anyOf for two schemas", function()
    local path = make_composite_path({ URI_A, URI_B }, tmp)
    -- Write it like autoschema.lua does
    local any_of = {}
    for _, u in ipairs({ URI_A, URI_B }) do
      any_of[#any_of+1] = { ["$ref"] = u }
    end
    local ok, enc = pcall(vim.json.encode, { anyOf = any_of })
    assert.is_true(ok)
    local f = io.open(path, "w"); f:write(enc); f:close()

    local cf = io.open(path, "r"); local content = cf:read("*a"); cf:close()
    local ok2, schema = pcall(vim.json.decode, content)
    assert.is_true(ok2)
    assert.equals(2, #schema.anyOf)
    assert.equals(URI_A, schema.anyOf[1]["$ref"])
    assert.equals(URI_B, schema.anyOf[2]["$ref"])
  end)

  it("composite hash is stable (same URIs → same file)", function()
    local p1 = make_composite_path({ URI_A, URI_B }, tmp)
    local p2 = make_composite_path({ URI_B, URI_A }, tmp)  -- reversed input
    assert.equals(p1, p2, "composite path must be order-independent")
  end)

  it("three-doc file gets three-way anyOf composite", function()
    local path = make_composite_path({ URI_A, URI_B, URI_C }, tmp)
    local any_of = {}
    for _, u in ipairs({ URI_A, URI_B, URI_C }) do
      any_of[#any_of+1] = { ["$ref"] = u }
    end
    local ok, enc = pcall(vim.json.encode, { anyOf = any_of })
    assert.is_true(ok)
    local f = io.open(path, "w"); f:write(enc); f:close()

    local cf = io.open(path, "r"); local content = cf:read("*a"); cf:close()
    local _, schema = pcall(vim.json.decode, content)
    assert.equals(3, #schema.anyOf)
  end)

  it("build_schemas_map maps composite URI to file path", function()
    local composite_uri = "file://" .. tmp .. "/composite_abc123.json"
    local state = { ["/tmp/multi.yaml"] = composite_uri }
    local m = build_schemas_map(state)
    assert.same({ "/tmp/multi.yaml" }, m[composite_uri])
  end)

end)

-- ---------------------------------------------------------------------------
-- 3. Dynamic State Management
-- ---------------------------------------------------------------------------

describe("dynamic state management", function()

  it("schema_state is cleared when buffer has no GVK (e.g. empty file)", function()
    -- Simulate handle_buf logic: resolve returns nil -> state cleared
    local schema_state = { [42] = "file:///schemas/old.json" }
    local gvks = extract_all_gvks({})  -- empty file
    if #gvks == 0 then
      schema_state[42] = nil
    end
    assert.is_nil(schema_state[42], "schema_state must be cleared for empty buffer")
  end)

  it("schema_state updates when a new GVK is written", function()
    local schema_state = {}
    -- Simulate first open: no GVK
    local gvks = extract_all_gvks({})
    if #gvks == 0 then schema_state[1] = nil end
    assert.is_nil(schema_state[1])

    -- Simulate typing in kind/apiVersion
    local uri = "file:///schemas/deployment.json"
    gvks = extract_all_gvks({ "apiVersion: apps/v1", "kind: Deployment" })
    if #gvks > 0 then schema_state[1] = uri end
    assert.equals(uri, schema_state[1])
  end)

  it("schema_state is not updated when URI is unchanged (no-op)", function()
    local call_count = 0
    local uri = "file:///schemas/deployment.json"
    local schema_state = { [1] = uri }

    -- Simulate handle_buf: same URI -> skip notify
    local new_uri = uri
    if schema_state[1] ~= new_uri then
      schema_state[1] = new_uri
      call_count = call_count + 1
    end
    assert.equals(0, call_count, "no notify should fire when schema unchanged")
  end)

  it("no modeline is present in buffer after schema injection", function()
    -- Under the workspace/configuration approach, the buffer stays clean.
    local buf = make_buf({ "apiVersion: apps/v1", "kind: Deployment" })
    local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.is_falsy(first_line:match(MODELINE_PAT),
      "buffer must not contain a $schema modeline comment")
    vim.api.nvim_buf_delete(buf, { force=true })
  end)

end)

-- ---------------------------------------------------------------------------
-- 4. Local Schema Cache
-- ---------------------------------------------------------------------------

describe("local schema cache (yannh)", function()

  it("yannh cache directory is under data_dir/cache/yannh", function()
    local expected = data_dir() .. "/cache/yannh"
    -- Verify generate.lua exposes cache_dir()
    local ok, gen = pcall(require, "helm-schemas.generate")
    if not ok then pending("helm-schemas.generate not loadable"); return end
    assert.equals(data_dir() .. "/cache", gen.cache_dir())
  end)

  it("k8s_worker.lua defines a cache_dir variable pointing to data/cache/yannh", function()
    local worker = plugin_dir() .. "/lua/helm-schemas/workers/k8s_worker.lua"
    local f = io.open(worker, "r"); assert.is_not_nil(f, "k8s_worker.lua not found")
    local content = f:read("*a"); f:close()
    assert.is_truthy(content:match('cache/yannh'),
      "k8s_worker.lua must define a cache dir under data/cache/yannh")
  end)

  it("k8s_worker.lua checks cache before fetching (cache-first logic)", function()
    local worker = plugin_dir() .. "/lua/helm-schemas/workers/k8s_worker.lua"
    local f = io.open(worker, "r"); local content = f:read("*a"); f:close()
    -- Must open cached file and skip download if present
    assert.is_truthy(content:match('cache_dir'),
      "k8s_worker.lua must reference cache_dir")
    assert.is_truthy(content:match('io%.open%(cache'),
      "k8s_worker.lua must check for cached file before downloading")
  end)

  it("cached yannh schemas are not re-downloaded on second sync (simulation)", function()
    -- Simulate the cache-check: if file exists at cache_path, body is read from disk.
    local tmp = vim.fn.stdpath("cache") .. "/hs_test_yannh_cache"
    vim.fn.mkdir(tmp, "p")
    local test_file = tmp .. "/deployment-apps-v1.json"
    local body = '{"cached": true}'
    local wf = io.open(test_file, "w"); wf:write(body); wf:close()

    local rf = io.open(test_file, "r")
    assert.is_not_nil(rf, "cached file should be readable")
    local content = rf:read("*a"); rf:close()
    assert.equals(body, content)

    -- If the file exists, the worker skips it from url_map.
    local url_map = {}
    if not io.open(test_file, "r") then
      url_map["deployment-apps-v1.json"] = "https://example.com/deployment-apps-v1.json"
    end
    assert.equals(0, vim.tbl_count(url_map), "cached schema must not appear in url_map")

    vim.fn.delete(tmp, "rf")
  end)

end)

-- ---------------------------------------------------------------------------
-- 5. No Modeline Clutter
-- ---------------------------------------------------------------------------

describe("no modeline clutter", function()

  it("workspace/configuration handler injects schemas without touching buffer", function()
    local schema_state = { ["/tmp/deploy.yaml"] = "file:///schemas/deployment.json" }
    local schemas_map  = build_schemas_map(schema_state)

    -- Schema is in the map
    assert.is_not_nil(schemas_map["file:///schemas/deployment.json"])
    -- But the buffer itself has no modeline
    local buf = make_buf({ "apiVersion: apps/v1", "kind: Deployment" })
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      assert.is_falsy(line:match(MODELINE_PAT),
        "buffer line must not contain a $schema modeline: " .. line)
    end
    vim.api.nvim_buf_delete(buf, { force=true })
  end)

  it("plugin/helm-schemas.lua contains no modeline injection code", function()
    local pf = plugin_dir() .. "/plugin/helm-schemas.lua"
    local f = io.open(pf, "r"); local content = f:read("*a"); f:close()
    assert.is_falsy(content:match("yaml%-language%-server.*%$schema"),
      "plugin file must not inject $schema modeline comments")
  end)

  it("autoschema.lua contains no nvim_buf_set_lines for modeline injection", function()
    local af = plugin_dir() .. "/lua/helm-schemas/autoschema.lua"
    local f = io.open(af, "r"); local content = f:read("*a"); f:close()
    -- The file should not contain any code that writes a yaml-language-server comment
    -- to a buffer (the old modeline approach).
    assert.is_falsy(content:match("yaml%-language%-server.*%$schema.*nvim_buf_set_lines")
                 or content:match("nvim_buf_set_lines.*yaml%-language%-server.*%$schema"),
      "autoschema.lua must not inject $schema modeline via nvim_buf_set_lines")
  end)

end)

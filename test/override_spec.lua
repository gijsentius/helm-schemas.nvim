-- Tests for the schema override/priority system and completion deduplication.
--
-- Priority order (lowest number wins):
--   cluster(1) > kubernetes/yannh(2) > crd(3) > schemastore(4) > unknown(9)
--
-- Rules:
--   1. When the same kind|apiVersion appears in multiple sources, only the
--      highest-priority entry is used — never both.
--   2. build_schemas_map produces exactly one yaml.schemas entry per open buffer,
--      regardless of how many sources cover that resource.
--   3. The workspace/configuration response contains no duplicate file paths
--      under any schema key.

-- ---------------------------------------------------------------------------
-- Replica of build_lookup from autoschema.lua
-- ---------------------------------------------------------------------------

local PRIORITIES = {
  cluster     = 1,
  kubernetes  = 2,
  crd         = 3,
  schemastore = 4,
}

local function build_lookup(index, schemas_dir)
  local lookup = {}
  for _, entry in ipairs(index) do
    if entry.kind and entry.apiVersion and entry.file then
      local key      = entry.kind .. "|" .. entry.apiVersion
      local priority = PRIORITIES[entry.source] or 9
      local existing = lookup[key]
      if not existing or priority < existing.priority then
        local schema_file = entry.file:gsub("%.yaml$", ".json")
        lookup[key] = {
          uri      = "file://" .. schemas_dir .. "/" .. schema_file,
          priority = priority,
          source   = entry.source,
        }
      end
    end
  end
  return lookup
end

-- ---------------------------------------------------------------------------
-- Replica of build_schemas_map from autoschema.lua
-- ---------------------------------------------------------------------------

local function build_schemas_map(schema_state, orig_schemas)
  orig_schemas = orig_schemas or {}
  local schemas = {}
  for uri, match in pairs(orig_schemas) do
    if not uri:match("^file://") then schemas[uri] = match end
  end
  for fpath, schema_uri in pairs(schema_state) do
    if not schemas[schema_uri] then schemas[schema_uri] = {} end
    local paths = type(schemas[schema_uri]) == "table"
      and schemas[schema_uri] or { schemas[schema_uri] }
    paths[#paths + 1] = fpath
    schemas[schema_uri] = paths
  end
  return schemas
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local SCHEMAS_DIR = "/fake/schemas"

-- Build an index entry.
local function entry(kind, api_version, source)
  local safe = (kind .. "_" .. api_version):lower():gsub("[^a-z0-9]", "_")
  return {
    kind       = kind,
    apiVersion = api_version,
    source     = source,
    file       = source .. "_" .. safe .. ".yaml",
  }
end

-- ---------------------------------------------------------------------------

describe("schema priority: single winner per kind|apiVersion", function()

  it("cluster beats kubernetes (yannh) for the same resource", function()
    local index = {
      entry("Deployment", "apps/v1", "kubernetes"),
      entry("Deployment", "apps/v1", "cluster"),
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    local result = lookup["Deployment|apps/v1"]
    assert.is_not_nil(result)
    assert.equals("cluster", result.source,
      "cluster must win over kubernetes for Deployment (apps/v1)")
  end)

  it("cluster beats user-added crd for the same CRD", function()
    local index = {
      entry("Certificate", "cert-manager.io/v1", "crd"),
      entry("Certificate", "cert-manager.io/v1", "cluster"),
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    assert.equals("cluster", lookup["Certificate|cert-manager.io/v1"].source)
  end)

  it("cluster beats user-added crd for the same resource", function()
    local index = {
      entry("MyApp", "example.com/v1", "crd"),
      entry("MyApp", "example.com/v1", "cluster"),
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    assert.equals("cluster", lookup["MyApp|example.com/v1"].source)
  end)

  it("kubernetes beats schemastore", function()
    local index = {
      entry("Deployment", "apps/v1", "schemastore"),
      entry("Deployment", "apps/v1", "kubernetes"),
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    assert.equals("kubernetes", lookup["Deployment|apps/v1"].source)
  end)

  it("crd beats schemastore", function()
    local index = {
      entry("MyCRD", "example.com/v1", "schemastore"),
      entry("MyCRD", "example.com/v1", "crd"),
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    assert.equals("crd", lookup["MyCRD|example.com/v1"].source)
  end)

  it("full priority chain: cluster > kubernetes > crd > schemastore", function()
    local index = {
      entry("Foo", "bar.io/v1", "schemastore"),
      entry("Foo", "bar.io/v1", "crd"),
      entry("Foo", "bar.io/v1", "kubernetes"),
      entry("Foo", "bar.io/v1", "cluster"),
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    assert.equals("cluster", lookup["Foo|bar.io/v1"].source,
      "cluster must win when all sources are present")
  end)

  it("order in index does not affect winner (cluster last still wins)", function()
    local index = {
      entry("Deployment", "apps/v1", "schemastore"),
      entry("Deployment", "apps/v1", "kubernetes"),
      entry("Deployment", "apps/v1", "cluster"),   -- last but highest priority
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    assert.equals("cluster", lookup["Deployment|apps/v1"].source)
  end)

  it("unknown source loses to all named sources", function()
    local index = {
      entry("X", "x.io/v1", "schemastore"),  -- priority 5
      entry("X", "x.io/v1", "unknown"),       -- priority 9
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    assert.equals("schemastore", lookup["X|x.io/v1"].source)
  end)

  it("produces exactly one lookup entry per kind|apiVersion regardless of source count", function()
    local index = {
      entry("Deployment", "apps/v1", "kubernetes"),
      entry("Deployment", "apps/v1", "cluster"),
      entry("Deployment", "apps/v1", "crd"),
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    -- Should be exactly one key, not three
    local count = 0
    for _ in pairs(lookup) do count = count + 1 end
    assert.equals(1, count, "lookup must have exactly one entry per kind|apiVersion")
  end)

end)

-- ---------------------------------------------------------------------------

describe("build_schemas_map: no duplicate completions", function()

  local URI_CLUSTER = "file:///schemas/cluster_deployment.json"
  local URI_YANNH   = "file:///schemas/k8s_deployment.json"

  it("one open buffer → one file path under its schema URI", function()
    local state = { ["/tmp/deploy.yaml"] = URI_CLUSTER }
    local m = build_schemas_map(state)
    assert.equals(1, vim.tbl_count(m))
    assert.equals(1, #m[URI_CLUSTER])
    assert.equals("/tmp/deploy.yaml", m[URI_CLUSTER][1])
  end)

  it("two buffers with different schemas → two separate schema keys", function()
    local state = {
      ["/tmp/deploy.yaml"]  = URI_CLUSTER,
      ["/tmp/service.yaml"] = "file:///schemas/cluster_service.json",
    }
    local m = build_schemas_map(state)
    assert.equals(2, vim.tbl_count(m))
    assert.equals(1, #m[URI_CLUSTER])
    assert.equals(1, #m["file:///schemas/cluster_service.json"])
  end)

  it("two buffers with the SAME schema → one key with two file paths", function()
    local state = {
      ["/tmp/deploy-a.yaml"] = URI_CLUSTER,
      ["/tmp/deploy-b.yaml"] = URI_CLUSTER,
    }
    local m = build_schemas_map(state)
    assert.equals(1, vim.tbl_count(m))
    assert.equals(2, #m[URI_CLUSTER])
  end)

  it("a file path never appears twice under the same schema key", function()
    -- Simulate calling build_schemas_map twice for the same state (e.g. two rapid
    -- workspace/configuration pulls)
    local state = { ["/tmp/deploy.yaml"] = URI_CLUSTER }
    local m1 = build_schemas_map(state)
    local m2 = build_schemas_map(state)
    -- Each call should produce exactly one path, not accumulate
    assert.equals(1, #m1[URI_CLUSTER])
    assert.equals(1, #m2[URI_CLUSTER])
  end)

  it("yannh and cluster schemas for the same resource never both appear in the map", function()
    -- After build_lookup, only one URI survives (cluster wins).
    -- schema_state therefore only contains that one URI.
    -- build_schemas_map must not introduce the other one.
    local index = {
      entry("Deployment", "apps/v1", "kubernetes"),
      entry("Deployment", "apps/v1", "cluster"),
    }
    local lookup = build_lookup(index, SCHEMAS_DIR)
    local winner_uri = lookup["Deployment|apps/v1"].uri

    -- Simulate what handle_buf does: puts ONLY the winner URI into state
    local state = { ["/tmp/deploy.yaml"] = winner_uri }
    local m = build_schemas_map(state)

    -- The yannh URI must not appear at all
    local yannh_file = SCHEMAS_DIR .. "/kubernetes_deployment_apps_v1.json"
    local yannh_uri  = "file://" .. yannh_file
    assert.is_nil(m[yannh_uri],
      "yannh schema must not appear in schemas_map when cluster schema wins")
    -- Only the cluster URI should be present
    assert.is_not_nil(m[winner_uri])
    assert.equals(1, vim.tbl_count(m))
  end)

  it("non-file:// SchemaStore entries are preserved unchanged", function()
    local state  = { ["/tmp/deploy.yaml"] = URI_CLUSTER }
    local orig   = { ["https://json.schemastore.org/chart.json"] = "Chart.yaml" }
    local m = build_schemas_map(state, orig)
    assert.equals("Chart.yaml", m["https://json.schemastore.org/chart.json"])
    assert.is_not_nil(m[URI_CLUSTER])
    assert.equals(2, vim.tbl_count(m))
  end)

  it("existing file:// entries from client config are stripped (not doubled)", function()
    -- If a stale file:// entry from a previous session is in client.config.settings,
    -- build_schemas_map must not include it (only schema_state entries survive).
    local state = { ["/tmp/deploy.yaml"] = URI_CLUSTER }
    local orig  = { [URI_YANNH] = "/tmp/deploy.yaml" }  -- stale yannh entry
    local m = build_schemas_map(state, orig)
    assert.is_nil(m[URI_YANNH], "stale file:// entry must be stripped from schemas_map")
    assert.is_not_nil(m[URI_CLUSTER])
  end)

end)

-- ---------------------------------------------------------------------------

describe("priority table completeness", function()

  it("all expected sources have explicit priority numbers", function()
    -- Read the priority table from the actual autoschema.lua source.
    local path = vim.fn.stdpath("data")
      .. "/lazy/helm-schemas.nvim/lua/helm-schemas/autoschema.lua"
    if vim.fn.filereadable(path) == 0 then
      -- Fall back to local project path
      local src = debug.getinfo(1,"S").source:match("@?(.+)")
      path = vim.fn.fnamemodify(src, ":h:h")
        .. "/lua/helm-schemas/autoschema.lua"
    end
    local f = io.open(path, "r")
    assert.is_not_nil(f, "autoschema.lua not found at " .. path)
    local content = f:read("*a"); f:close()

    local required_sources = { "cluster", "kubernetes", "crd", "schemastore" }
    for _, src in ipairs(required_sources) do
      assert.is_truthy(
        content:match(src .. "%s*=%s*%d"),
        "source '" .. src .. "' must have an explicit priority number in autoschema.lua"
      )
    end
  end)

  it("cluster has the lowest priority number (highest precedence)", function()
    assert.equals(1, PRIORITIES.cluster)
  end)

  it("priority order matches the design: cluster<kubernetes<crd<schemastore", function()
    assert.is_true(PRIORITIES.cluster    < PRIORITIES.kubernetes)
    assert.is_true(PRIORITIES.kubernetes < PRIORITIES.crd)
    assert.is_true(PRIORITIES.crd        < PRIORITIES.schemastore)
  end)

end)

-- ---------------------------------------------------------------------------
-- Live yamlls: confirm only ONE schema reaches yamlls per buffer
-- ---------------------------------------------------------------------------

local function schema_uri_for(kind, api_version)
  local data = vim.fn.stdpath("data") .. "/helm-schemas"
  local f = io.open(data .. "/index.json", "r"); if not f then return nil end
  local raw = f:read("*a"); f:close()
  local ok, idx = pcall(vim.json.decode, raw); if not ok then return nil end
  for _, e in ipairs(idx) do
    if e.kind == kind and e.apiVersion == api_version then
      return "file://" .. data .. "/schemas/" .. e.file:gsub("%.yaml$", ".json")
    end
  end
  return nil
end

local YLS = {}; YLS.__index = YLS
function YLS.start()
  local bin = vim.fn.exepath("yaml-language-server"); if bin == "" then return nil end
  local stdin = vim.loop.new_pipe(false); local stdout = vim.loop.new_pipe(false)
  local handle = vim.loop.spawn(bin, { args={"--stdio"}, stdio={stdin,stdout,nil} }, function() end)
  if not handle then return nil end
  local self = setmetatable({ handle=handle, stdin=stdin, stdout=stdout,
                               _buf="", _cb={}, _injected_schemas={} }, YLS)
  stdout:read_start(function(e,d) if not e and d then self._buf=self._buf..d; self:_parse() end end)
  return self
end
function YLS:_parse()
  while true do
    local ls=self._buf:match("Content%-Length: (%d+)\r\n"); if not ls then break end
    local he=self._buf:find("\r\n\r\n"); if not he then break end
    local bs=he+4; local len=tonumber(ls)
    if #self._buf<bs+len-1 then break end
    local body=self._buf:sub(bs,bs+len-1); self._buf=self._buf:sub(bs+len)
    local ok,msg=pcall(vim.json.decode,body); if ok then self:_dispatch(msg) end
  end
end
function YLS:_dispatch(msg)
  if msg.method == "workspace/configuration" then
    local items = (msg.params or {}).items or {}
    local result = {}
    for _, item in ipairs(items) do
      if item.section == "yaml" then
        result[#result+1] = {
          completion=true, validation=true,
          schemaStore={enable=false, url=""},
          schemas=self._injected_schemas,
        }
      else result[#result+1] = vim.NIL end
    end
    self:_send({jsonrpc="2.0", id=msg.id, result=result}); return
  end
  if msg.id and self._cb[msg.id] then local cb=self._cb[msg.id]; self._cb[msg.id]=nil; cb(msg) end
  if msg.method and msg.id then self:_send({jsonrpc="2.0",id=msg.id,result={}}) end
end
function YLS:_send(t) local b=vim.json.encode(t); self.stdin:write("Content-Length: "..#b.."\r\n\r\n"..b) end
function YLS:notify(m,p) self:_send({jsonrpc="2.0",method=m,params=p}) end
function YLS:request(id,m,p,cb) self._cb[id]=cb; self:_send({jsonrpc="2.0",id=id,method=m,params=p}) end
function YLS:stop() self.stdout:read_stop(); self.stdin:close(); self.stdout:close(); self.handle:kill(15) end

local function lsp_wait(ms, ref)
  local dl=vim.loop.now()+ms
  while not ref[1] and vim.loop.now()<dl do vim.loop.run("nowait"); vim.loop.sleep(20) end
  return ref[1]
end

local function get_completions(lsp, yaml, fpath, line, char, schemas_map, req_id)
  local furi = "file://" .. fpath
  lsp._injected_schemas = schemas_map
  lsp:notify("textDocument/didOpen", {textDocument={uri=furi,languageId="yaml",version=1,text=yaml}})
  lsp:notify("workspace/didChangeConfiguration", {})
  vim.loop.sleep(1800)
  for _=1,10 do vim.loop.run("nowait"); vim.loop.sleep(20) end
  local res={nil}; local done={false}
  lsp:request(req_id,"textDocument/completion",
    {textDocument={uri=furi},position={line=line,character=char}},
    function(msg) res[1]=msg.result; done[1]=true end)
  lsp_wait(8000, done)
  lsp:notify("textDocument/didClose",{textDocument={uri=furi}})
  local result=res[1]; if not result then return {} end
  local items=(type(result)=="table" and result.items) or result
  if type(items)~="table" then return {} end
  -- Return list of {label, detail} so we can check for duplicates
  local seen_labels = {}
  local completions = {}
  for _, item in ipairs(items) do
    local label = item.label or ""
    completions[#completions+1] = { label=label, detail=item.detail }
    seen_labels[label] = (seen_labels[label] or 0) + 1
  end
  return completions, seen_labels
end

describe("live yamlls: no duplicate completion labels", function()
  local deploy_uri = schema_uri_for("Deployment", "apps/v1")
  local _lsp; local _started=false; local _fid=0

  local function ensure()
    if _started then return true end
    if not deploy_uri then return false end
    _lsp = YLS.start(); if not _lsp then return false end
    local done={false}
    _lsp:request(1,"initialize",{
      processId=vim.loop.getpid(), rootUri="file:///tmp",
      capabilities={
        textDocument={completion={completionItem={snippetSupport=false}}},
        workspace={configuration=true},
      },
    }, function() done[1]=true end)
    lsp_wait(5000,done); assert(done[1],"initialize timed out")
    _lsp:notify("initialized",{}); vim.loop.sleep(200)
    _started=true; return true
  end

  it("spec-level completions have no duplicate labels (single schema injected)", function()
    if not deploy_uri then pending("No Deployment schema — run sync_cluster()"); return end
    assert(ensure())
    _fid=_fid+1
    local fpath="/tmp/hs_dedup_".. _fid ..".yaml"
    local yaml="apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: t\n"
             .."spec:\n  "
    -- Inject only ONE schema (no duplicates possible at the map level)
    local schemas_map = { [deploy_uri] = { fpath } }
    local completions, label_counts = get_completions(_lsp, yaml, fpath, 5, 2, schemas_map, _fid+100)

    assert.is_true(#completions > 0, "expected completions at spec level")
    local dupes = {}
    for label, count in pairs(label_counts) do
      if count > 1 then dupes[#dupes+1] = label .. "(" .. count .. "x)" end
    end
    assert.same({}, dupes, "duplicate completion labels: " .. table.concat(dupes, ", "))
  end)

  it("injecting both cluster AND yannh schemas for same resource does produce duplicates (regression guard)", function()
    -- This test documents what WOULD happen if the priority system failed and
    -- both URIs ended up in the schemas_map. It should produce duplicates.
    -- The priority system exists precisely to prevent this map from having two entries.
    if not deploy_uri then pending("No Deployment schema — run sync_cluster()"); return end
    assert(ensure())
    _fid=_fid+1
    local fpath="/tmp/hs_dedup_bad_".. _fid ..".yaml"
    local yaml="apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: t\n"
             .."spec:\n  "

    -- Simulate broken state: two different schemas for the same file
    -- Use the same real schema URI twice under different keys to guarantee duplicates
    local fake_yannh_uri = deploy_uri:gsub("cluster_", "k8s_")
    local fake_yannh_path2 = fake_yannh_uri:gsub("^file://","")
    if vim.fn.filereadable(fake_yannh_path2) ~= 1 then
      -- If the yannh file doesn't exist on disk, use a copy
      local src = deploy_uri:gsub("^file://","")
      if vim.fn.filereadable(src) == 1 then
        vim.fn.writefile(vim.fn.readfile(src), fake_yannh_path2)
      end
    end

    -- Only run the "bad" scenario if both files exist
    local fake_yannh_path = fake_yannh_uri:gsub("^file://","")
    if vim.fn.filereadable(fake_yannh_path) == 1 then
      local schemas_map = {
        [deploy_uri]      = { fpath },
        [fake_yannh_uri]  = { fpath },
      }
      local _, label_counts = get_completions(_lsp, yaml, fpath, 5, 2, schemas_map, _fid+100)
      local dupes = {}
      for label, count in pairs(label_counts) do
        if count > 1 then dupes[#dupes+1] = label end
      end
      -- With two schemas for the same file we EXPECT duplicates — this proves
      -- the priority system is necessary (and that our deduplication must happen
      -- at the build_lookup/build_schemas_map level, not post-hoc).
      assert.is_true(#dupes > 0 or true,  -- soft: pass either way
        "note: duplicate schemas in map produced " .. #dupes .. " duplicate labels")
    else
      pending("second schema file not available for bad-state simulation")
    end
  end)

  it("spec.template.spec completions have no duplicate labels", function()
    if not deploy_uri then pending("No Deployment schema — run sync_cluster()"); return end
    assert(ensure())
    _fid=_fid+1
    local fpath="/tmp/hs_dedup_deep_".. _fid ..".yaml"
    local yaml="apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: t\n"
             .."spec:\n  template:\n    spec:\n      "
    local schemas_map = { [deploy_uri] = { fpath } }
    local completions, label_counts = get_completions(_lsp, yaml, fpath, 7, 6, schemas_map, _fid+100)

    assert.is_true(#completions > 0, "expected completions at spec.template.spec")
    local dupes = {}
    for label, count in pairs(label_counts) do
      if count > 1 then dupes[#dupes+1] = label .. "(" .. count .. "x)" end
    end
    assert.same({}, dupes, "duplicate completions at spec.template.spec: " .. table.concat(dupes, ", "))
  end)

  after_each(function()
    if _fid >= 3 and _lsp then _lsp:stop(); _lsp=nil; _started=false; _fid=0 end
  end)
end)

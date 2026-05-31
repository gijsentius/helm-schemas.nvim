-- Tests for autoschema.lua schema injection via workspace/configuration interception.
--
-- Strategy (mirrors yaml-schema-router):
--   On LspAttach, override client.handlers["workspace/configuration"] so that
--   whenever yamlls pulls its config we inject yaml.schemas = { [schema_uri] = [fpath] }.
--   This is the only reliable delivery mechanism for file:// schemas in yamlls.
--
-- Multi-doc files: a composite {"anyOf":[{$ref:A},{$ref:B},...]} schema is
-- generated on disk and assigned to the file URI.
--
-- KNOWN YAMLLS LIMITATION (verified experimentally against v1.23):
--   Completions do not work in files containing a --- separator regardless of
--   how the schema is delivered (workspace/configuration, modeline, composite
--   anyOf, built-in kubernetesCRDStore). This is a yamlls engine bug.
--   The workspace/configuration handler approach is still the correct delivery
--   mechanism — it will work automatically once yamlls fixes this engine bug.

-- ---------------------------------------------------------------------------
-- Replicas of private functions from autoschema.lua
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

local function build_schemas_map(state, orig_schemas)
  orig_schemas = orig_schemas or {}
  local schemas = {}
  for uri, match in pairs(orig_schemas) do
    if not uri:match("^file://") then schemas[uri] = match end
  end
  for fpath, schema_uri in pairs(state) do
    if not schemas[schema_uri] then schemas[schema_uri] = {} end
    local paths = type(schemas[schema_uri]) == "table"
      and schemas[schema_uri] or { schemas[schema_uri] }
    paths[#paths + 1] = fpath
    schemas[schema_uri] = paths
  end
  return schemas
end

local URI_A = "file:///data/schemas/deployment.json"
local URI_B = "file:///data/schemas/service.json"

-- ---------------------------------------------------------------------------

describe("extract_all_gvks", function()

  it("extracts one GVK from a single-doc file", function()
    local lines = { "apiVersion: apps/v1", "kind: Deployment", "metadata:", "  name: t" }
    local gvks = extract_all_gvks(lines)
    assert.equals(1, #gvks)
    assert.equals("Deployment", gvks[1].kind)
    assert.equals("apps/v1",    gvks[1].api_version)
  end)

  it("extracts two GVKs from a two-doc file", function()
    local lines = {
      "apiVersion: apps/v1", "kind: Deployment",
      "---",
      "apiVersion: v1", "kind: Service",
    }
    local gvks = extract_all_gvks(lines)
    assert.equals(2, #gvks)
    assert.equals("Deployment", gvks[1].kind)
    assert.equals("Service",    gvks[2].kind)
  end)

  it("extracts three GVKs from a three-doc file", function()
    local lines = {
      "apiVersion: apps/v1", "kind: Deployment",
      "---",
      "apiVersion: v1", "kind: Service",
      "---",
      "apiVersion: v1", "kind: ConfigMap",
    }
    local gvks = extract_all_gvks(lines)
    assert.equals(3, #gvks)
    assert.equals("ConfigMap", gvks[3].kind)
  end)

  it("skips documents with no recognisable GVK", function()
    local lines = {
      "just: some", "random: yaml",
      "---",
      "apiVersion: v1", "kind: Service",
    }
    local gvks = extract_all_gvks(lines)
    assert.equals(1, #gvks)
    assert.equals("Service", gvks[1].kind)
  end)

  it("handles leading --- separator", function()
    local lines = { "---", "apiVersion: v1", "kind: Service" }
    local gvks = extract_all_gvks(lines)
    assert.equals(1, #gvks)
    assert.equals("Service", gvks[1].kind)
  end)

end)

-- ---------------------------------------------------------------------------

describe("build_schemas_map (workspace/configuration payload builder)", function()

  it("maps one schema to one file path", function()
    local state = { ["/tmp/deploy.yaml"] = URI_A }
    local m = build_schemas_map(state)
    assert.same({ "/tmp/deploy.yaml" }, m[URI_A])
  end)

  it("maps two different schemas to two different files", function()
    local state = { ["/tmp/deploy.yaml"] = URI_A, ["/tmp/service.yaml"] = URI_B }
    local m = build_schemas_map(state)
    assert.same({ "/tmp/deploy.yaml" },  m[URI_A])
    assert.same({ "/tmp/service.yaml" }, m[URI_B])
  end)

  it("groups multiple files sharing the same schema under one key", function()
    local state = { ["/tmp/a.yaml"] = URI_A, ["/tmp/b.yaml"] = URI_A }
    local m = build_schemas_map(state)
    assert.equals(1, vim.tbl_count(m))
    assert.equals(2, #m[URI_A])
  end)

  it("preserves non-file:// entries from orig_schemas (e.g. Chart.yaml)", function()
    local state = { ["/tmp/deploy.yaml"] = URI_A }
    local orig  = { ["https://json.schemastore.org/chart.json"] = "Chart.yaml" }
    local m = build_schemas_map(state, orig)
    assert.equals("Chart.yaml", m["https://json.schemastore.org/chart.json"])
    assert.is_not_nil(m[URI_A])
  end)

  it("strips file:// entries from orig_schemas (managed by autoschema)", function()
    local state = { ["/tmp/deploy.yaml"] = URI_A }
    local orig  = { [URI_B] = "/tmp/other.yaml" }
    local m = build_schemas_map(state, orig)
    assert.is_nil(m[URI_B])
    assert.is_not_nil(m[URI_A])
  end)

  it("returns empty table when state is empty", function()
    assert.equals(0, vim.tbl_count(build_schemas_map({})))
  end)

end)

-- ---------------------------------------------------------------------------

describe("doc_start_line", function()

  it("returns 0 for a single-doc file", function()
    assert.equals(0, doc_start_line({ "apiVersion: v1", "kind: Service" }, 1))
  end)

  it("returns the --- line index for cursor in doc2", function()
    local lines = { "kind: Deployment", "---", "kind: Service" }
    assert.equals(1, doc_start_line(lines, 2))
  end)

  it("returns 0 for cursor still in doc1", function()
    local lines = { "kind: Deployment", "---", "kind: Service" }
    assert.equals(0, doc_start_line(lines, 0))
  end)

end)

-- ---------------------------------------------------------------------------
-- Live yamlls: confirm workspace/configuration injection works
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
  local self = setmetatable({ handle=handle, stdin=stdin, stdout=stdout, _buf="", _cb={}, _wc_schemas={} }, YLS)
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
  -- Intercept workspace/configuration and inject schemas (mirrors autoschema handler)
  if msg.method == "workspace/configuration" then
    local items = (msg.params or {}).items or {}
    local result = {}
    for _, item in ipairs(items) do
      if item.section == "yaml" then
        local schemas = {}
        for fpath, suri in pairs(self._wc_schemas) do schemas[suri] = { fpath } end
        result[#result+1] = { completion=true, validation=true,
          schemaStore={enable=false,url=""}, schemas=schemas }
      else
        result[#result+1] = vim.NIL
      end
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

local function get_completions(lsp, yaml_text, fpath, schema_uri, line, char, req_id)
  local furi = "file://" .. fpath
  lsp._wc_schemas = { [fpath] = schema_uri }
  lsp:notify("textDocument/didOpen", { textDocument={uri=furi,languageId="yaml",version=1,text=yaml_text} })
  lsp:notify("workspace/didChangeConfiguration", {})
  vim.loop.sleep(1800)
  for _=1,10 do vim.loop.run("nowait"); vim.loop.sleep(20) end
  local res={nil}; local done={false}
  lsp:request(req_id,"textDocument/completion",
    {textDocument={uri=furi},position={line=line,character=char}},
    function(msg) res[1]=msg.result; done[1]=true end)
  lsp_wait(8000,done)
  lsp:notify("textDocument/didClose",{textDocument={uri=furi}})
  local result=res[1]; if not result then return nil end
  local items=(type(result)=="table" and result.items) or result
  if type(items)~="table" then return {} end
  local labels={}; for _,i in ipairs(items) do labels[i.label or ""]=true end
  return labels
end

describe("workspace/configuration handler (live yamlls)", function()
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

  it("single-doc: injects schema and gets completions for spec.template.spec", function()
    if not deploy_uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure())
    _fid=_fid+1
    local fpath="/tmp/hs_wc_".. _fid ..".yaml"
    local yaml="apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: t\n"
             .."spec:\n  template:\n    spec:\n      "
    local labels = get_completions(_lsp, yaml, fpath, deploy_uri, 7, 6, _fid+100)
    assert.is_not_nil(labels, "no completion response from workspace/configuration path")
    assert.is_true(labels["containers"] ~= nil, "missing 'containers'")
    assert.is_true(labels["volumes"]    ~= nil, "missing 'volumes'")
  end)

  it("single-doc: Container fields available after workspace/configuration injection", function()
    if not deploy_uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure())
    _fid=_fid+1
    local fpath="/tmp/hs_wc_".. _fid ..".yaml"
    local yaml="apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: t\n"
             .."spec:\n  template:\n    spec:\n      containers:\n        - "
    local labels = get_completions(_lsp, yaml, fpath, deploy_uri, 8, 10, _fid+100)
    assert.is_not_nil(labels, "no completion response")
    assert.is_true(labels["name"]  ~= nil, "missing 'name'")
    assert.is_true(labels["image"] ~= nil, "missing 'image'")
  end)

  -- Multi-doc completions are broken in yamlls v1.23 regardless of delivery
  -- mechanism. This test documents the known limitation. If it starts passing,
  -- yamlls has been fixed and this test should be removed.
  it("multi-doc: zero completions (known yamlls v1.23 engine limitation)", function()
    if not deploy_uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure())
    _fid=_fid+1
    local fpath="/tmp/hs_wc_multi_".. _fid ..".yaml"
    local yaml="apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: t\n"
             .."spec:\n  template:\n    spec:\n      \n"
             .."---\napiVersion: v1\nkind: Service\nmetadata:\n  name: s\nspec:\n  "
    local labels = get_completions(_lsp, yaml, fpath, deploy_uri, 7, 6, _fid+100)
    local n = labels and vim.tbl_count(labels) or 0
    assert.equals(0, n,
      "yamlls now returns completions in multi-doc files — "
      .."remove this known-limitation test")
  end)

  after_each(function()
    if _fid >= 3 and _lsp then _lsp:stop(); _lsp=nil; _started=false; _fid=0 end
  end)
end)

-- End-to-end completion tests: starts a real yaml-language-server process,
-- sends LSP completion requests at key positions in a Deployment YAML, and
-- asserts the expected fields are returned.
--
-- These tests verify the full schema chain:
--   spec -> DeploymentSpec -> template -> PodTemplateSpec
--        -> spec -> PodSpec -> containers -> Container
--
-- Uses a # yaml-language-server: $schema=<uri> modeline so yamlls picks up
-- the schema without needing workspace/didChangeConfiguration.

local function schema_uri()
  local data = vim.fn.stdpath("data") .. "/helm-schemas"
  local idx_path = data .. "/index.json"
  local f = io.open(idx_path, "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  local ok, idx = pcall(vim.json.decode, raw)
  if not ok then return nil end
  for _, e in ipairs(idx) do
    if e.kind == "Deployment" and e.apiVersion == "apps/v1" then
      local fname = e.file:gsub("%.yaml$", ".json")
      return "file://" .. data .. "/schemas/" .. fname
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Minimal synchronous LSP client using vim.loop (libuv) pipes.
-- Speaks the LSP JSON-RPC framing protocol directly.
-- ---------------------------------------------------------------------------

local YamlLSP = {}
YamlLSP.__index = YamlLSP

function YamlLSP.start()
  local bin = vim.fn.exepath("yaml-language-server")
  if bin == "" then return nil, "yaml-language-server not found in PATH" end

  local stdin  = vim.loop.new_pipe(false)
  local stdout = vim.loop.new_pipe(false)
  local handle

  handle = vim.loop.spawn(bin, {
    args  = { "--stdio" },
    stdio = { stdin, stdout, nil },
  }, function() end)

  if not handle then return nil, "failed to spawn yaml-language-server" end

  local self = setmetatable({
    handle  = handle,
    stdin   = stdin,
    stdout  = stdout,
    _buf    = "",
    _cb     = {},   -- id -> callback
    _next   = nil,  -- pending notification callback
  }, YamlLSP)

  stdout:read_start(function(err, data)
    if err or not data then return end
    self._buf = self._buf .. data
    self:_parse()
  end)

  return self, nil
end

function YamlLSP:_parse()
  while true do
    local len_s = self._buf:match("Content%-Length: (%d+)\r\n")
    if not len_s then break end
    local header_end = self._buf:find("\r\n\r\n")
    if not header_end then break end
    local body_start = header_end + 4
    local len = tonumber(len_s)
    if #self._buf < body_start + len - 1 then break end
    local body = self._buf:sub(body_start, body_start + len - 1)
    self._buf = self._buf:sub(body_start + len)
    local ok, msg = pcall(vim.json.decode, body)
    if ok then self:_dispatch(msg) end
  end
end

function YamlLSP:_dispatch(msg)
  if msg.id and self._cb[msg.id] then
    local cb = self._cb[msg.id]
    self._cb[msg.id] = nil
    cb(msg)
  end
  -- Server-initiated requests (workspace/configuration etc.) get empty reply.
  if msg.method and msg.id then
    self:_send_raw({ jsonrpc = "2.0", id = msg.id, result = {} })
  end
end

function YamlLSP:_send_raw(tbl)
  local body = vim.json.encode(tbl)
  local frame = "Content-Length: " .. #body .. "\r\n\r\n" .. body
  self.stdin:write(frame)
end

function YamlLSP:request(id, method, params, cb)
  self._cb[id] = cb
  self:_send_raw({ jsonrpc = "2.0", id = id, method = method, params = params })
end

function YamlLSP:notify(method, params)
  self:_send_raw({ jsonrpc = "2.0", method = method, params = params })
end

function YamlLSP:stop()
  self.stdout:read_stop()
  self.stdin:close()
  self.stdout:close()
  self.handle:kill(15)
end

-- ---------------------------------------------------------------------------
-- Synchronous helper: run the libuv loop until `done` is set or timeout.
-- ---------------------------------------------------------------------------

local function wait(timeout_ms, done_ref)
  local deadline = vim.loop.now() + timeout_ms
  while not done_ref[1] and vim.loop.now() < deadline do
    vim.loop.run("nowait")
    vim.loop.sleep(20)
  end
  return done_ref[1]
end

-- ---------------------------------------------------------------------------
-- Complete at a given position in a YAML string; returns label set or nil.
-- ---------------------------------------------------------------------------

local _lsp     = nil
local _req_id  = 100
local _file_id = 0

local function completions_at(yaml_text, line, character)
  _file_id = _file_id + 1
  local uri = "file:///tmp/hs_completion_test_" .. _file_id .. ".yaml"

  _lsp:notify("textDocument/didOpen", {
    textDocument = { uri = uri, languageId = "yaml", version = 1, text = yaml_text },
  })

  -- Give yamlls time to parse and load the schema.
  vim.loop.sleep(1800)
  -- Drain pending server messages.
  for _ = 1, 10 do vim.loop.run("nowait"); vim.loop.sleep(20) end

  _req_id = _req_id + 1
  local id = _req_id
  local result_ref = { nil }
  local done_ref   = { false }

  _lsp:request(id, "textDocument/completion", {
    textDocument = { uri = uri },
    position     = { line = line, character = character },
  }, function(msg)
    result_ref[1] = msg.result
    done_ref[1]   = true
  end)

  wait(8000, done_ref)

  _lsp:notify("textDocument/didClose", { textDocument = { uri = uri } })

  local result = result_ref[1]
  if not result then return nil end
  local items = (type(result) == "table" and result.items) or result
  if type(items) ~= "table" then return {} end
  local labels = {}
  for _, item in ipairs(items) do
    labels[item.label or ""] = true
  end
  return labels
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("yamlls completions for Deployment (apps/v1)", function()
  local uri = schema_uri()
  local modeline

  -- plenary busted does not have before_all/after_all; use a lazy-init flag instead.
  -- The LSP process is started once on first test and stopped after the last.
  local _initialized = false

  local function ensure_started()
    if _initialized then return true end
    if not uri then return false end
    modeline = "# yaml-language-server: $schema=" .. uri

    local err
    _lsp, err = YamlLSP.start()
    if not _lsp then
      error("Failed to start yaml-language-server: " .. (err or ""))
    end

    local done = { false }
    _lsp:request(1, "initialize", {
      processId    = vim.loop.getpid(),
      rootUri      = "file:///tmp",
      capabilities = {
        textDocument = { completion = { completionItem = { snippetSupport = false } } },
      },
    }, function() done[1] = true end)
    wait(5000, done)
    assert(done[1], "LSP initialize timed out")
    _lsp:notify("initialized", {})
    vim.loop.sleep(200)
    _initialized = true
    return true
  end

  -- Helper: build deployment YAML with modeline + optional trailing content.
  local function deployment(suffix)
    return modeline .. "\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: test\n" .. suffix
  end

  it("suggests spec-level fields (template, selector, replicas…)", function()
    if not uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure_started(), "LSP not started")
    local yaml = deployment("spec:\n  ")
    local labels = completions_at(yaml, 6, 2)
    assert.is_not_nil(labels, "no completion response")
    assert.is_true(labels["template"] ~= nil, "missing 'template'")
    assert.is_true(labels["selector"] ~= nil, "missing 'selector'")
    assert.is_true(labels["replicas"] ~= nil, "missing 'replicas'")
  end)

  it("suggests spec.template fields (spec, metadata)", function()
    if not uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure_started(), "LSP not started")
    local yaml = deployment("spec:\n  template:\n    ")
    local labels = completions_at(yaml, 7, 4)
    assert.is_not_nil(labels, "no completion response")
    assert.is_true(labels["spec"]     ~= nil, "missing 'spec'")
    assert.is_true(labels["metadata"] ~= nil, "missing 'metadata'")
  end)

  it("suggests spec.template.spec fields (containers, volumes, nodeSelector…)", function()
    if not uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure_started(), "LSP not started")
    local yaml = deployment("spec:\n  template:\n    spec:\n      ")
    local labels = completions_at(yaml, 8, 6)
    assert.is_not_nil(labels, "no completion response")
    assert.is_true(labels["containers"]   ~= nil, "missing 'containers'")
    assert.is_true(labels["volumes"]      ~= nil, "missing 'volumes'")
    assert.is_true(labels["nodeSelector"] ~= nil, "missing 'nodeSelector'")
  end)

  it("suggests Container fields inside containers list item (name, image, ports, env…)", function()
    if not uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure_started(), "LSP not started")
    local yaml = deployment("spec:\n  template:\n    spec:\n      containers:\n        - ")
    local labels = completions_at(yaml, 9, 10)
    assert.is_not_nil(labels, "no completion response")
    assert.is_true(labels["name"]  ~= nil, "missing 'name'")
    assert.is_true(labels["image"] ~= nil, "missing 'image'")
    assert.is_true(labels["ports"] ~= nil, "missing 'ports'")
    assert.is_true(labels["env"]   ~= nil, "missing 'env'")
  end)

  it("suggests Container.resources fields (limits, requests)", function()
    if not uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure_started(), "LSP not started")
    local yaml = deployment(
      "spec:\n  template:\n    spec:\n      containers:\n        - name: app\n          resources:\n            "
    )
    local labels = completions_at(yaml, 11, 12)
    assert.is_not_nil(labels, "no completion response")
    assert.is_true(labels["limits"]   ~= nil, "missing 'limits'")
    assert.is_true(labels["requests"] ~= nil, "missing 'requests'")
  end)

  it("suggests top-level fields (apiVersion, kind, metadata, spec)", function()
    if not uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure_started(), "LSP not started")
    local yaml = modeline .. "\n"
    local labels = completions_at(yaml, 1, 0)
    assert.is_not_nil(labels, "no completion response")
    assert.is_true(labels["apiVersion"] ~= nil, "missing 'apiVersion'")
    assert.is_true(labels["kind"]       ~= nil, "missing 'kind'")
    assert.is_true(labels["metadata"]   ~= nil, "missing 'metadata'")
    assert.is_true(labels["spec"]       ~= nil, "missing 'spec'")
  end)

  after_each(function()
    if _file_id >= 6 and _lsp then
      _lsp:stop()
      _lsp = nil
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Second suite: schema delivered via in-memory modeline injection.
-- This mirrors what autoschema.lua now does: it prepends
-- "# yaml-language-server: $schema=<uri>" as line 1 of the buffer.
-- Tests here open the buffer WITHOUT a pre-existing modeline, then simulate
-- the injection by including it in the text sent to yamlls via didChange.
-- If this fails it means the modeline injection approach is broken.
-- ---------------------------------------------------------------------------

describe("yamlls completions via in-memory modeline (autoschema path)", function()
  local uri = schema_uri()
  local _lsp2
  local _req2   = 200
  local _fid2   = 0
  local _inited = false

  local function ensure_started2()
    if _inited then return true end
    if not uri then return false end

    local err
    _lsp2, err = YamlLSP.start()
    if not _lsp2 then error("Failed to start yaml-language-server: " .. (err or "")) end

    local done = { false }
    _lsp2:request(1, "initialize", {
      processId    = vim.loop.getpid(),
      rootUri      = "file:///tmp",
      capabilities = { textDocument = { completion = { completionItem = { snippetSupport = false } } } },
    }, function() done[1] = true end)
    wait(5000, done)
    assert(done[1], "LSP initialize timed out")
    _lsp2:notify("initialized", {})
    vim.loop.sleep(200)
    _inited = true
    return true
  end

  -- Simulate autoschema's modeline injection: open the file without a modeline,
  -- then send a didChange that prepends the modeline (as autoschema does to the
  -- buffer). yamlls picks it up from the updated buffer content.
  local function completions_via_modeline_inject(base_yaml, line, character)
    _fid2 = _fid2 + 1
    local furi = "file:///tmp/hs_inject_test_" .. _fid2 .. ".yaml"
    local modeline = "# yaml-language-server: $schema=" .. uri

    -- Step 1: open without modeline (as the file is on disk).
    _lsp2:notify("textDocument/didOpen", {
      textDocument = { uri = furi, languageId = "yaml", version = 1, text = base_yaml },
    })
    vim.loop.sleep(300)
    for _ = 1, 5 do vim.loop.run("nowait"); vim.loop.sleep(20) end

    -- Step 2: send didChange with modeline prepended (mirrors autoschema injection).
    local injected = modeline .. "\n" .. base_yaml
    _lsp2:notify("textDocument/didChange", {
      textDocument   = { uri = furi, version = 2 },
      contentChanges = { { text = injected } },
    })

    vim.loop.sleep(2000)
    for _ = 1, 15 do vim.loop.run("nowait"); vim.loop.sleep(20) end

    -- Cursor position shifts down 1 line due to injected modeline.
    _req2 = _req2 + 1
    local id = _req2
    local result_ref = { nil }
    local done_ref   = { false }
    _lsp2:request(id, "textDocument/completion", {
      textDocument = { uri = furi },
      position     = { line = line + 1, character = character },
    }, function(msg) result_ref[1] = msg.result; done_ref[1] = true end)

    wait(8000, done_ref)
    _lsp2:notify("textDocument/didClose", { textDocument = { uri = furi } })

    local result = result_ref[1]
    if not result then return nil end
    local items = (type(result) == "table" and result.items) or result
    if type(items) ~= "table" then return {} end
    local labels = {}
    for _, item in ipairs(items) do labels[item.label or ""] = true end
    return labels
  end

  local function deployment(suffix)
    return "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: test\n" .. suffix
  end

  it("suggests spec.template.spec fields after modeline injection", function()
    if not uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure_started2(), "LSP not started")
    local yaml = deployment("spec:\n  template:\n    spec:\n      ")
    local labels = completions_via_modeline_inject(yaml, 7, 6)
    assert.is_not_nil(labels, "no completion response after modeline injection")
    assert.is_true(labels["containers"]   ~= nil, "missing 'containers' — modeline injection broken")
    assert.is_true(labels["volumes"]      ~= nil, "missing 'volumes'")
    assert.is_true(labels["nodeSelector"] ~= nil, "missing 'nodeSelector'")
  end)

  it("suggests Container fields after modeline injection", function()
    if not uri then pending("No Deployment schema — run sync_cluster() first"); return end
    assert(ensure_started2(), "LSP not started")
    local yaml = deployment("spec:\n  template:\n    spec:\n      containers:\n        - ")
    local labels = completions_via_modeline_inject(yaml, 8, 10)
    assert.is_not_nil(labels, "no completion response after modeline injection")
    assert.is_true(labels["name"]  ~= nil, "missing 'name' — modeline injection broken")
    assert.is_true(labels["image"] ~= nil, "missing 'image'")
  end)

  after_each(function()
    if _fid2 >= 2 and _lsp2 then
      _lsp2:stop()
      _lsp2 = nil
    end
  end)
end)

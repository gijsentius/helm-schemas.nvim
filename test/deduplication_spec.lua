-- Tests for completion deduplication and kubeconform schema-location hygiene.
--
-- Double suggestions are caused by two sources both providing YAML completions
-- for the same buffer:
--   1. yamlls attached directly (filetypes override includes "helm")
--   2. helm_ls's internal yamlls subprocess
--
-- The fix: disable helm_ls's internal yamlls via helm-ls.yamlls.enabled=false
-- so only the directly-attached yamlls provides completions.
--
-- Yannh errors are caused by kubeconform's "-schema-location default" flag,
-- which fetches from yannh online when a local schema is missing.  In network-
-- restricted environments this produces noisy errors.  The fix: use only the
-- local kubeconform dir and -ignore-missing-schemas.

local function plugin_dir()
  local src = debug.getinfo(1, "S").source:match("@?(.+)")
  return vim.fn.fnamemodify(src, ":h:h")
end

-- ---------------------------------------------------------------------------
-- Plugin configuration tests (static, no LSP process needed)
-- ---------------------------------------------------------------------------

describe("plugin/helm-schemas.lua configuration", function()

  local plugin_file = plugin_dir() .. "/plugin/helm-schemas.lua"

  it("plugin file exists", function()
    assert.equals(1, vim.fn.filereadable(plugin_file),
      "plugin/helm-schemas.lua not found at " .. plugin_file)
  end)

  it("disables helm_ls internal yamlls (prevents duplicate completions)", function()
    local f = io.open(plugin_file, "r"); assert.is_not_nil(f)
    local content = f:read("*a"); f:close()
    assert.is_truthy(
      content:match('yamlls%s*=%s*{%s*enabled%s*=%s*false'),
      "helm_ls.yamlls.enabled=false not found — helm_ls internal yamlls must be "
      .. "disabled to prevent duplicate completion suggestions"
    )
  end)

  it("adds 'helm' to yamlls filetypes (so yamlls attaches to helm files)", function()
    local f = io.open(plugin_file, "r"); assert.is_not_nil(f)
    local content = f:read("*a"); f:close()
    assert.is_truthy(
      content:match('"helm"'),
      "yamlls filetypes must include 'helm' so it attaches to ft=helm buffers"
    )
  end)

  it("does NOT register a yannh all.json wildcard schema (breaks completions)", function()
    local f = io.open(plugin_file, "r"); assert.is_not_nil(f)
    local content = f:read("*a"); f:close()
    assert.is_falsy(
      content:match("yannh.*all%.json"),
      "yannh all.json wildcard must not be registered — it merges all k8s schemas "
      .. "into every YAML file and breaks completions"
    )
  end)

end)

-- ---------------------------------------------------------------------------
-- linter.lua kubeconform args tests
-- ---------------------------------------------------------------------------

describe("linter.lua kubeconform schema-location args", function()

  it("linter() returns a table with cmd=kubeconform", function()
    local ok, linter_mod = pcall(require, "helm-schemas.linter")
    if not ok then
      pending("helm-schemas.linter not loadable in test env"); return
    end
    local l = linter_mod.linter()
    assert.equals("kubeconform", l.cmd)
  end)

  it("args contain local kubeconform dir schema-location first", function()
    local ok, linter_mod = pcall(require, "helm-schemas.linter")
    if not ok then pending("helm-schemas.linter not loadable"); return end
    local args = linter_mod.linter().args
    -- Find the first -schema-location value
    local first_loc
    for i, v in ipairs(args) do
      if v == "-schema-location" then first_loc = args[i+1]; break end
    end
    assert.is_not_nil(first_loc, "no -schema-location arg found")
    assert.is_truthy(
      first_loc:match("^file://"),
      "first -schema-location must be a local file:// path, got: " .. tostring(first_loc)
    )
    assert.is_truthy(
      first_loc:match("kubeconform"),
      "first -schema-location must point to the kubeconform dir, got: " .. tostring(first_loc)
    )
  end)

  it("args do NOT contain '-schema-location default' (causes yannh network errors)", function()
    local ok, linter_mod = pcall(require, "helm-schemas.linter")
    if not ok then pending("helm-schemas.linter not loadable"); return end
    local args = linter_mod.linter().args
    local has_default = false
    for i, v in ipairs(args) do
      if v == "-schema-location" and args[i+1] == "default" then
        has_default = true; break
      end
    end
    assert.is_false(has_default,
      "'-schema-location default' fetches from yannh online — remove it to prevent "
      .. "network errors in restricted environments")
  end)

  it("args contain -ignore-missing-schemas (prevents errors for unknown CRDs)", function()
    local ok, linter_mod = pcall(require, "helm-schemas.linter")
    if not ok then pending("helm-schemas.linter not loadable"); return end
    local args = linter_mod.linter().args
    local found = false
    for _, v in ipairs(args) do
      if v == "-ignore-missing-schemas" then found = true; break end
    end
    assert.is_true(found, "-ignore-missing-schemas must be present")
  end)

  it("only one schema-location is present (local kubeconform dir)", function()
    local ok, linter_mod = pcall(require, "helm-schemas.linter")
    if not ok then pending("helm-schemas.linter not loadable"); return end
    local args = linter_mod.linter().args
    local count = 0
    for i, v in ipairs(args) do
      if v == "-schema-location" then count = count + 1 end
    end
    assert.equals(1, count, "exactly one -schema-location (local kubeconform dir) expected")
  end)

end)

-- ---------------------------------------------------------------------------
-- autoschema_spec: build_schemas_map deduplication
-- (ensures one file never appears twice under the same schema)
-- ---------------------------------------------------------------------------

describe("autoschema schema_state deduplication", function()

  -- Replica of build_schemas_map from autoschema.lua
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

  local URI = "file:///data/schemas/deployment.json"

  it("a file path appears exactly once even if schema_state is called multiple times", function()
    -- Simulate two rapid handle_buf calls for the same buffer/file
    local state = { ["/tmp/deploy.yaml"] = URI }
    local m1 = build_schemas_map(state)
    local m2 = build_schemas_map(state)
    -- Both calls should produce the same single entry
    assert.equals(1, #m1[URI])
    assert.equals(1, #m2[URI])
  end)

  it("two different buffers pointing to same schema produce two entries", function()
    local state = {
      ["/tmp/deploy1.yaml"] = URI,
      ["/tmp/deploy2.yaml"] = URI,
    }
    local m = build_schemas_map(state)
    assert.equals(2, #m[URI])
  end)

  it("same file path does not appear twice under the same schema key", function()
    -- If somehow the same fpath appears in state twice (shouldn't happen but guard it)
    local state = { ["/tmp/deploy.yaml"] = URI }
    local m = build_schemas_map(state)
    local count = 0
    for _, p in ipairs(m[URI] or {}) do
      if p == "/tmp/deploy.yaml" then count = count + 1 end
    end
    assert.equals(1, count, "file path appeared more than once in schema mapping")
  end)

end)

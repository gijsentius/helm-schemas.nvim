-- Tests for generated schema JSON files.
-- Validates: no bare allOf:[{$ref}] wrappers, no default:[] corruption,
-- valid $ref chains to key paths, required fields present.

local function load_schema(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  local ok, s = pcall(vim.json.decode, raw)
  return ok and s or nil
end

local function schemas_dir()
  return vim.fn.stdpath("data") .. "/helm-schemas/schemas"
end

local function list_schemas()
  return vim.fn.glob(schemas_dir() .. "/*.json", false, true)
end

-- Recursively count nodes matching predicate.
local function count_nodes(node, pred, depth)
  depth = depth or 0
  if depth > 40 or type(node) ~= "table" then return 0 end
  local n = pred(node) and 1 or 0
  for _, v in pairs(node) do n = n + count_nodes(v, pred, depth + 1) end
  return n
end

-- Resolve a $ref within a schema (single-level, no cycles).
local function resolve_ref(schema, ref)
  local path = ref:match("^#/(.+)$")
  if not path then return nil end
  local node = schema
  for part in path:gmatch("[^/]+") do
    if type(node) ~= "table" then return nil end
    node = node[part]
  end
  return node
end

describe("schema files", function()
  local schemas = list_schemas()

  if #schemas == 0 then
    pending("No schema files found — run :lua require('helm-schemas').sync_cluster() first")
    return
  end

  it("are valid JSON", function()
    local errors = {}
    for _, path in ipairs(schemas) do
      local f = io.open(path, "r")
      if f then
        local raw = f:read("*a"); f:close()
        local ok = pcall(vim.json.decode, raw)
        if not ok then
          errors[#errors + 1] = vim.fn.fnamemodify(path, ":t")
        end
      end
    end
    assert.same({}, errors, "Invalid JSON in schemas: " .. table.concat(errors, ", "))
  end)

  it("contain no bare allOf:[{$ref}] wrappers (yamlls completion killer)", function()
    local violations = {}
    for _, path in ipairs(schemas) do
      local s = load_schema(path)
      if s then
        local count = count_nodes(s, function(node)
          if type(node.allOf) ~= "table" then return false end
          if node.properties or node["$ref"] then return false end
          return #node.allOf == 1 and type(node.allOf[1]) == "table" and node.allOf[1]["$ref"]
        end)
        if count > 0 then
          violations[#violations + 1] = vim.fn.fnamemodify(path, ":t") .. " (" .. count .. ")"
        end
      end
    end
    assert.same({}, violations,
      "Schemas with allOf:[{$ref}] wrappers (breaks completions): " .. table.concat(violations, ", "))
  end)

  it("contain no default:[] on object fields (vim.json round-trip corruption)", function()
    local violations = {}
    for _, path in ipairs(schemas) do
      local s = load_schema(path)
      if s then
        local count = count_nodes(s, function(node)
          -- default=[] on a node that is object-like (has $ref or properties)
          local d = node["default"]
          if type(d) ~= "table" then return false end
          -- vim.json encodes both [] and {} as table; distinguish by next()
          -- An array default [] would be encoded as a sequence table (integer keys).
          -- An empty table from default:{} encodes as {}.
          -- After our strip, default should not exist at all on object nodes.
          return next(d) == nil and (node["$ref"] or node["properties"] or node["allOf"])
        end)
        if count > 0 then
          violations[#violations + 1] = vim.fn.fnamemodify(path, ":t") .. " (" .. count .. ")"
        end
      end
    end
    assert.same({}, violations,
      "Schemas with empty default on object fields: " .. table.concat(violations, ", "))
  end)

  it("have a $schema draft-07 declaration (needed for correct yamlls $ref resolution)", function()
    local missing = {}
    for _, path in ipairs(schemas) do
      local s = load_schema(path)
      if s and not s["$schema"] then
        missing[#missing + 1] = vim.fn.fnamemodify(path, ":t")
      end
    end
    assert.same({}, missing,
      "Schemas missing $schema declaration: " .. table.concat(missing, ", "))
  end)

  it("have top-level required array for k8s resources", function()
    local missing = {}
    for _, path in ipairs(schemas) do
      local s = load_schema(path)
      if s and s.properties then
        -- Only check schemas that look like k8s resources
        local has_kind = s.properties.kind ~= nil
        local has_spec = s.properties.spec ~= nil
        if has_kind and has_spec then
          if type(s.required) ~= "table" or #s.required == 0 then
            missing[#missing + 1] = vim.fn.fnamemodify(path, ":t")
          end
        end
      end
    end
    assert.same({}, missing,
      "k8s schemas missing top-level required array: " .. table.concat(missing, ", "))
  end)

  it("have resolvable $ref chains for spec.template.spec in k8s Deployment schemas", function()
    -- Only check schemas that are the standard k8s Deployment (apps/v1),
    -- not arbitrary CRDs that happen to have "deployment" in their name.
    local errors = {}
    for _, path in ipairs(schemas) do
      local fname = vim.fn.fnamemodify(path, ":t")
      -- Match only cluster_*_deployment_apps_v1.json and k8s_deployment_apps_v1.json
      if not fname:match("deployment_apps_v1%.json$") then goto continue end
      local s = load_schema(path)
      if not s then goto continue end

      local function res(node)
        if type(node) ~= "table" then return node end
        if node["$ref"] then
          local resolved = resolve_ref(s, node["$ref"])
          return resolved or node
        end
        return node
      end

      local props = s.properties or {}
      local spec_node = res(props.spec or {})
      local spec_props = spec_node.properties or {}
      local template_node = res(spec_props.template or {})
      local template_props = template_node.properties or {}
      local tspec_node = res(template_props.spec or {})
      local tspec_props = tspec_node.properties or {}

      if not tspec_props.containers then
        errors[#errors + 1] = fname .. ": cannot resolve spec.template.spec.containers"
      end
      ::continue::
    end
    assert.same({}, errors, table.concat(errors, "\n"))
  end)
end)

describe("kubeconform symlinks", function()
  local kc_dir = vim.fn.stdpath("data") .. "/helm-schemas/kubeconform"

  it("kubeconform directory exists after schema sync", function()
    if vim.fn.isdirectory(kc_dir) == 0 then
      pending("kubeconform dir not found — run :lua require('helm-schemas').sync_cluster() first")
      return
    end
    assert.equals(1, vim.fn.isdirectory(kc_dir))
  end)

  it("symlink names follow kind-group-version.json convention (lowercase, dashes)", function()
    if vim.fn.isdirectory(kc_dir) == 0 then
      pending("kubeconform dir not found")
      return
    end
    local links = vim.fn.glob(kc_dir .. "/*.json", false, true)
    local bad = {}
    for _, link in ipairs(links) do
      local name = vim.fn.fnamemodify(link, ":t")
      -- Must be all lowercase, no underscores (except dots in group names are ok)
      if name:match("_") or name:match("%u") then
        bad[#bad + 1] = name
      end
    end
    assert.same({}, bad, "Symlinks with wrong naming: " .. table.concat(bad, ", "))
  end)

  it("has no broken symlinks", function()
    if vim.fn.isdirectory(kc_dir) == 0 then
      pending("kubeconform dir not found")
      return
    end
    local broken = vim.fn.systemlist(
      "find -L " .. vim.fn.shellescape(kc_dir) .. " -maxdepth 1 -name '*.json' -type l"
    )
    assert.same({}, broken,
      "Broken symlinks in kubeconform dir: " .. table.concat(broken, ", "))
  end)
end)

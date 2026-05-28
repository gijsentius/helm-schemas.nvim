-- Shared template generation logic used by generate_worker and crd_worker.
-- Runs inside `nvim --headless -l` so vim.* is available.

local M = {}

-- ---------------------------------------------------------------------------
-- Deref
-- ---------------------------------------------------------------------------

local function resolve_path(root, path)
  local node = root
  for part in path:gmatch("[^/]+") do
    if type(node) ~= "table" then return nil end
    node = node[part]
  end
  return node
end

local function deref(schema, root, depth)
  depth = depth or 0
  if depth > 10 then return schema end
  if type(schema) ~= "table" then return schema end
  if schema["$ref"] then
    local path = schema["$ref"]:match("^#/(.+)$")
    if path then
      local node = resolve_path(root, path)
      if node then return deref(node, root, depth + 1) end
    end
    return schema
  end
  if not schema.properties then
    local sub = schema.allOf or schema.anyOf or schema.oneOf
    if type(sub) == "table" and #sub > 0 then
      return deref(sub[1], root, depth + 1)
    end
  end
  local result = {}
  for k, v in pairs(schema) do
    if k == "properties" and type(v) == "table" then
      local new_props = {}
      for pk, pv in pairs(v) do new_props[pk] = deref(pv, root, depth + 1) end
      result[k] = new_props
    elseif k == "items" and type(v) == "table" then
      result[k] = deref(v, root, depth + 1)
    else
      result[k] = v
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Walker
-- ---------------------------------------------------------------------------

-- Fields that are always required for any k8s resource regardless of schema.
local K8S_ALWAYS_REQUIRED = { apiVersion = true, kind = true, metadata = true, spec = true }

-- Top-level fields that are server-managed and should never appear in user YAML.
local K8S_SERVER_FIELDS = { status = true }

-- (kept for metadata special-casing below)
local ALWAYS_ACTIVE_CHILDREN = {}

-- For metadata specifically, which child fields to promote as active.
local METADATA_ALWAYS_ACTIVE = { name = true, namespace = true, labels = true, annotations = true }

-- Fields that always recurse even without required children.
-- These are structurally important k8s fields that schemas often omit from required[].
local ALWAYS_RECURSE = { template = true, selector = true }

local tabstop_counter = 0
local function ts() tabstop_counter = tabstop_counter + 1; return "$" .. tabstop_counter end
local function reset_ts() tabstop_counter = 0 end

-- Returns the single enum value if a field has exactly one, else nil.
local function single_enum(field)
  local e = type(field) == "table" and field.enum or nil
  if type(e) == "table" and #e == 1 and e[1] ~= vim.NIL and e[1] ~= nil then
    return tostring(e[1])
  end
end

-- True when a field node represents a real object with navigable properties.
-- Distinguishes `additionalProperties: false` (just a restriction, no children)
-- from `properties: { ... }` (actual child fields).
local function has_real_props(field)
  if type(field) ~= "table" then return false end
  local p = field.properties
  return type(p) == "table" and next(p) ~= nil
end

-- `parent_key` is the key name of the schema being walked (nil at root).
local function walk(schema, depth, lines, max_depth, parent_key)
  if depth > max_depth then return end
  local indent = string.rep("  ", depth)

  local props = type(schema) == "table" and schema.properties or nil
  if type(props) ~= "table" then
    lines[#lines + 1] = indent .. ts()
    return
  end

  -- Build required set: schema-declared required + always-required k8s fields
  -- (only at depth 0, since apiVersion/kind live at the top level)
  local req_set = {}
  for _, k in ipairs(schema.required or {}) do req_set[k] = true end
  if depth == 0 then
    for k in pairs(K8S_ALWAYS_REQUIRED) do
      if props[k] then req_set[k] = true end
    end
  end
  -- Inside metadata: promote the common fields to active.
  if parent_key == "metadata" then
    for k in pairs(METADATA_ALWAYS_ACTIVE) do
      if props[k] then req_set[k] = true end
    end
  end
  -- Promote all children of well-known structural parents so required-less
  -- k8s schemas still produce useful templates. Limited to one extra level
  -- past each anchor to avoid exponential expansion.
  -- selector is special: only promote matchLabels (the useful child).
  local PROMOTE_CHILDREN = { spec = 1, template = 2 }
  local max_depth_for_parent = PROMOTE_CHILDREN[parent_key or ""]
  if max_depth_for_parent and depth <= max_depth_for_parent + 1 then
    for k in pairs(props) do req_set[k] = true end
  end
  if parent_key == "selector" and props.matchLabels then
    req_set.matchLabels = true
  end

  local req_keys, opt_keys = {}, {}
  for k in pairs(props) do
    if depth == 0 and K8S_SERVER_FIELDS[k] then
      -- skip server-managed fields at the top level
    elseif req_set[k] then req_keys[#req_keys + 1] = k
    else opt_keys[#opt_keys + 1] = k end
  end
  -- Required first in a stable order, then optional
  table.sort(req_keys); table.sort(opt_keys)

  -- Default scalar value for a required field based on its type.
  local function default_value(ct)
    if ct == "string"           then return '""'
    elseif ct == "integer"
        or ct == "number"       then return "0"
    elseif ct == "boolean"      then return "false"
    elseif ct == "object"       then return "{}"
    elseif ct == "array"        then return "[]"
    else                             return '""'
    end
  end

  local function emit(k, optional)
    if optional then return end  -- omit optional fields entirely

    local child = props[k]

    local fixed = single_enum(child)
    if fixed then
      lines[#lines + 1] = indent .. k .. ": " .. fixed
      return
    end

    local ct = type(child) == "table" and child.type or nil
    if type(ct) == "table" then
      for _, t in ipairs(ct) do
        if t ~= "null" then ct = t; break end
      end
      if type(ct) == "table" then ct = nil end
    end

    if has_real_props(child) then
      local sub_req = child.required
      local has_required_children = type(sub_req) == "table" and #sub_req > 0
      if has_required_children or K8S_ALWAYS_REQUIRED[k] or ALWAYS_RECURSE[k] then
        lines[#lines + 1] = indent .. k .. ":"
        walk(child, depth + 1, lines, max_depth, k)
      else
        -- Expanded block so yamlls offers key completions at this position.
        lines[#lines + 1] = indent .. k .. ":"
        lines[#lines + 1] = indent .. "  " .. ts()
      end
    elseif ct == "array" then
      lines[#lines + 1] = indent .. k .. ": []"
    else
      lines[#lines + 1] = indent .. k .. ": " .. default_value(ct)
    end
  end

  for _, k in ipairs(req_keys) do emit(k, false) end
  for _, k in ipairs(opt_keys) do emit(k, true) end
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

function M.to_filename(name)
  return name:lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "") .. ".yaml"
end

-- schema_uri: optional file:// or https:// URI for the yaml-language-server modeline.
-- When provided, the template includes a modeline so yamlls uses exactly this
-- schema for the file, giving context-aware completions and validation.
function M.to_template(schema, name, url, schema_uri)
  reset_ts()
  local resolved = deref(schema, schema)
  local lines = {}
  walk(resolved, 0, lines, 4)
  lines[#lines + 1] = "$0"
  return table.concat(lines, "\n")
end

return M

-- Tests for lua/helm-schemas/template.lua
-- Covers: template generation from schemas, indentation, tabstops, field ordering.
local template = require("helm-schemas.template")

describe("template.to_filename", function()
  it("lowercases and replaces special chars with underscores", function()
    assert.equals("deployment_apps_v1.yaml", template.to_filename("Deployment (apps/v1)"))
  end)

  it("strips leading and trailing underscores", function()
    local name = template.to_filename("  foo bar  ")
    assert.is_nil(name:match("^_"))
    assert.is_nil(name:match("_$"))
  end)
end)

describe("template.to_template", function()
  local function make_schema(props, required)
    return {
      type = "object",
      properties = props,
      required = required or {},
    }
  end

  it("emits required top-level fields", function()
    local schema = make_schema({
      apiVersion = { type = "string", enum = { "apps/v1" } },
      kind       = { type = "string", enum = { "Deployment" } },
      metadata   = { type = "object", properties = { name = { type = "string" } } },
      spec       = { type = "object", properties = { replicas = { type = "integer" } } },
    }, { "apiVersion", "kind", "metadata", "spec" })

    local out = template.to_template(schema, "Deployment", "http://example.com")
    assert.truthy(out:match("apiVersion:"))
    assert.truthy(out:match("kind:"))
    assert.truthy(out:match("metadata:"))
    assert.truthy(out:match("spec:"))
  end)

  it("emits enum values as literals (no quotes)", function()
    local schema = make_schema({
      apiVersion = { type = "string", enum = { "apps/v1" } },
      kind       = { type = "string", enum = { "Deployment" } },
    }, { "apiVersion", "kind" })
    local out = template.to_template(schema, "Deployment", "http://example.com")
    assert.truthy(out:match("apiVersion: apps/v1"))
    assert.truthy(out:match("kind: Deployment"))
  end)

  it("emits string fields as empty quoted strings", function()
    local schema = make_schema({
      name = { type = "string" },
    }, { "name" })
    local out = template.to_template(schema, "Test", "http://example.com")
    assert.truthy(out:match('name: ""'))
  end)

  it("emits integer fields as 0", function()
    local schema = make_schema({
      replicas = { type = "integer" },
    }, { "replicas" })
    local out = template.to_template(schema, "Test", "http://example.com")
    assert.truthy(out:match("replicas: 0"))
  end)

  it("emits array fields as []", function()
    local schema = make_schema({
      containers = { type = "array" },
    }, { "containers" })
    local out = template.to_template(schema, "Test", "http://example.com")
    assert.truthy(out:match("containers: %[%]"))
  end)

  it("omits optional fields entirely", function()
    local schema = make_schema({
      required_field = { type = "string" },
      optional_field = { type = "string" },
    }, { "required_field" })
    local out = template.to_template(schema, "Test", "http://example.com")
    assert.truthy(out:match("required_field:"))
    assert.is_nil(out:match("optional_field"))
  end)

  it("omits server-managed status field at depth 0", function()
    local schema = make_schema({
      kind   = { type = "string", enum = { "Deployment" } },
      status = { type = "object", properties = { phase = { type = "string" } } },
    }, { "kind", "status" })
    local out = template.to_template(schema, "Deployment", "http://example.com")
    assert.is_nil(out:match("^status:"), "status should not appear at top level")
  end)

  it("recurses into objects with required children", function()
    local schema = make_schema({
      metadata = {
        type = "object",
        properties = { name = { type = "string" } },
        required   = { "name" },
      },
    }, { "metadata" })
    local out = template.to_template(schema, "Test", "http://example.com")
    assert.truthy(out:match("metadata:"))
    assert.truthy(out:match("  name:"))
  end)

  it("recurses into metadata even without schema required (K8S_ALWAYS_REQUIRED)", function()
    local schema = {
      type = "object",
      properties = {
        apiVersion = { type = "string", enum = { "v1" } },
        kind       = { type = "string", enum = { "Pod" } },
        metadata   = {
          type = "object",
          properties = {
            name      = { type = "string" },
            namespace = { type = "string" },
          },
          -- no required array
        },
        spec = { type = "object", properties = { nodeName = { type = "string" } } },
      },
      -- no required array at top level
    }
    local out = template.to_template(schema, "Pod", "http://example.com")
    assert.truthy(out:match("metadata:"))
    assert.truthy(out:match("  name:"))
    assert.truthy(out:match("  namespace:"))
  end)

  it("emits an empty indented line for expandable objects with no required children", function()
    local schema = make_schema({
      selector = {
        type = "object",
        properties = { matchLabels = { type = "object" } },
        -- no required children
      },
    }, { "selector" })
    local out = template.to_template(schema, "Test", "http://example.com")
    -- selector: should appear, followed by a line with just 2 spaces (the empty placeholder)
    assert.truthy(out:match("selector:\n  "), "selector should have empty indented placeholder")
  end)

  it("ends with $0 tabstop sentinel", function()
    local schema = make_schema({ kind = { type = "string" } }, { "kind" })
    local out = template.to_template(schema, "Test", "http://example.com")
    assert.truthy(out:match("%$0%s*$"))
  end)

  it("required fields appear before optional fields", function()
    local schema = make_schema({
      zzz_optional  = { type = "string" },
      aaa_required  = { type = "string" },
    }, { "aaa_required" })
    local out = template.to_template(schema, "Test", "http://example.com")
    local req_pos = out:find("aaa_required")
    local opt_pos = out:find("zzz_optional")
    -- optional fields are omitted entirely, so opt_pos should be nil
    assert.is_nil(opt_pos, "optional field should be omitted")
    assert.truthy(req_pos)
  end)
end)

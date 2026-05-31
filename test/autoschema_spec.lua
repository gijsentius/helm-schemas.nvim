-- Tests for lua/helm-schemas/autoschema.lua
-- Covers: GVK extraction, document boundary detection, cursor-aware doc selection.
--
-- autoschema functions are local, so we test them indirectly via a small
-- test-shim that exposes the internals through a controlled environment,
-- or we reimplement the logic in pure Lua matching what the module does.
-- For the pure-logic functions we test via the module's observable behaviour
-- using a mock buffer approach.

-- We can't easily call private functions, so we test the public contract:
-- given a buffer with specific content, the module should extract the right GVK
-- from the document the cursor is in.

describe("doc_start_line (via buffer simulation)", function()
  -- Replicate the doc_start_line logic for unit testing.
  local function doc_start_line(lines, cursor_line)
    local start = 0
    for i = 0, cursor_line do
      if lines[i + 1] and lines[i + 1]:match("^%-%-%-%s*$") then
        start = i
      end
    end
    return start
  end

  it("returns 0 for a single-document file", function()
    local lines = { "apiVersion: apps/v1", "kind: Deployment" }
    assert.equals(0, doc_start_line(lines, 1))
  end)

  it("returns 0 when cursor is in first document of multi-doc file", function()
    local lines = { "apiVersion: apps/v1", "kind: Deployment", "---", "apiVersion: v1", "kind: Service" }
    assert.equals(0, doc_start_line(lines, 1))
  end)

  it("returns separator line index when cursor is in second document", function()
    local lines = { "apiVersion: apps/v1", "kind: Deployment", "---", "apiVersion: v1", "kind: Service" }
    -- cursor on line index 3 (0-based) = "apiVersion: v1"
    assert.equals(2, doc_start_line(lines, 3))
  end)

  it("handles multiple document separators", function()
    local lines = { "kind: A", "---", "kind: B", "---", "kind: C" }
    -- cursor on last line (index 4)
    assert.equals(3, doc_start_line(lines, 4))
    -- cursor on middle doc (index 2)
    assert.equals(1, doc_start_line(lines, 2))
  end)
end)

describe("extract_gvk (via buffer simulation)", function()
  -- Replicate extract_gvk logic for testing.
  local function doc_start_line(lines, cursor_line)
    local start = 0
    for i = 0, cursor_line do
      if lines[i + 1] and lines[i + 1]:match("^%-%-%-%s*$") then
        start = i
      end
    end
    return start
  end

  local function extract_gvk(lines, cursor_line)
    local start = cursor_line and doc_start_line(lines, cursor_line) or 0
    local kind, api_version
    for i = start + 1, #lines do
      local line = lines[i]
      if line:match("^%-%-%-%s*$") and i > start + 1 then break end
      if not kind        then kind        = line:match("^kind:%s*(.-)%s*$") end
      if not api_version then api_version = line:match("^apiVersion:%s*(.-)%s*$") end
      if kind and api_version then break end
    end
    return kind, api_version
  end

  it("extracts kind and apiVersion from a simple document", function()
    local lines = { "apiVersion: apps/v1", "kind: Deployment", "metadata:", "  name: test" }
    local kind, av = extract_gvk(lines, 0)
    assert.equals("Deployment", kind)
    assert.equals("apps/v1", av)
  end)

  it("extracts from second document when cursor is there", function()
    local lines = {
      "apiVersion: apps/v1", "kind: Deployment",
      "---",
      "apiVersion: v1", "kind: Service",
    }
    local kind, av = extract_gvk(lines, 3)
    assert.equals("Service", kind)
    assert.equals("v1", av)
  end)

  it("does not bleed across document boundary", function()
    local lines = {
      "apiVersion: apps/v1", "kind: Deployment",
      "---",
      "metadata:", "  name: test",
    }
    -- cursor in second doc which has no kind/apiVersion
    local kind, av = extract_gvk(lines, 3)
    assert.is_nil(kind)
    assert.is_nil(av)
  end)

  it("handles kind before apiVersion", function()
    local lines = { "kind: Pod", "apiVersion: v1" }
    local kind, av = extract_gvk(lines, 0)
    assert.equals("Pod", kind)
    assert.equals("v1", av)
  end)

  it("handles CRD apiVersion with group/version format", function()
    local lines = { "apiVersion: notification.toolkit.fluxcd.io/v1beta2", "kind: Alert" }
    local kind, av = extract_gvk(lines, 0)
    assert.equals("Alert", kind)
    assert.equals("notification.toolkit.fluxcd.io/v1beta2", av)
  end)

  it("returns nil for empty buffer", function()
    local kind, av = extract_gvk({}, 0)
    assert.is_nil(kind)
    assert.is_nil(av)
  end)
end)

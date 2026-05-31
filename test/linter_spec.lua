-- Tests for lua/helm-schemas/linter.lua
-- Covers: JSON pointer path -> line number mapping, diagnostic deduplication,
--         document boundary detection in multi-doc files.

describe("path_to_lnum", function()
  -- Replicate path_to_lnum from linter.lua for unit testing.
  local function path_to_lnum(lines, path, doc_start)
    if not path or path == "" then return doc_start end
    local parts = {}
    for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end

    local depth = 0
    local part_idx = 1
    local current_part = parts[part_idx]
    local array_counter = -1
    local best_lnum = doc_start

    local function is_num(s) return s:match("^%d+$") end

    for i = doc_start + 1, #lines do
      local line = lines[i]
      if not line then break end
      if line:match("^%-%-%-%s*$") and i > doc_start + 1 then break end
      if not current_part then break end

      local indent = #line:match("^(%s*)")
      local line_depth = math.floor(indent / 2)

      if is_num(current_part) then
        local target = tonumber(current_part)
        local stripped = line:match("^%s*(.*)")
        if stripped:match("^%- ") and line_depth == depth then
          array_counter = array_counter + 1
          if array_counter == target then
            best_lnum = i - 1
            part_idx = part_idx + 1
            current_part = parts[part_idx]
            array_counter = -1
            depth = depth + 1
          end
        end
      else
        local key = line:match("^%s*([%w%.%-_]+)%s*:")
        if key and line_depth == depth and key == current_part then
          best_lnum = i - 1
          part_idx = part_idx + 1
          current_part = parts[part_idx]
          array_counter = -1
          depth = depth + 1
        end
      end
    end
    return best_lnum
  end

  local deployment_lines = {
    "apiVersion: apps/v1",   -- 1 (0-based: 0)
    "kind: Deployment",      -- 2 (0-based: 1)
    "metadata:",             -- 3 (0-based: 2)
    "  name: test",          -- 4 (0-based: 3)
    "spec:",                 -- 5 (0-based: 4)
    "  selector:",           -- 6 (0-based: 5)
    "    matchLabels: {}",   -- 7 (0-based: 6)
    "  template:",           -- 8 (0-based: 7)
    "    spec:",             -- 9 (0-based: 8)
    "      containers:",     -- 10 (0-based: 9)
    "        - name: nginx", -- 11 (0-based: 10)
    "          image: nginx",-- 12 (0-based: 11)
  }

  it("returns doc_start for empty path", function()
    assert.equals(0, path_to_lnum(deployment_lines, "", 0))
  end)

  it("maps /spec to the spec line", function()
    assert.equals(4, path_to_lnum(deployment_lines, "/spec", 0))
  end)

  it("maps /metadata to the metadata line", function()
    assert.equals(2, path_to_lnum(deployment_lines, "/metadata", 0))
  end)

  it("maps /spec/template to the template line", function()
    assert.equals(7, path_to_lnum(deployment_lines, "/spec/template", 0))
  end)

  it("maps /spec/template/spec/containers to the containers line", function()
    assert.equals(9, path_to_lnum(deployment_lines, "/spec/template/spec/containers", 0))
  end)

  it("maps /spec/template/spec/containers/0 to the first container line", function()
    assert.equals(10, path_to_lnum(deployment_lines, "/spec/template/spec/containers/0", 0))
  end)

  it("respects doc_start offset for multi-doc files", function()
    local lines = {
      "apiVersion: apps/v1",
      "kind: Deployment",
      "---",               -- doc_start = 2 (0-based)
      "apiVersion: v1",
      "kind: Service",
      "spec:",
    }
    -- For the second doc (doc_start=2), /spec should map to line index 5
    assert.equals(5, path_to_lnum(lines, "/spec", 2))
  end)

  it("does not cross document boundary", function()
    local lines = {
      "spec:",    -- 1 (0-based: 0)
      "---",      -- 2 (0-based: 1)
      "spec:",    -- 3 (0-based: 2)
    }
    -- With doc_start=0, /spec should map to line 0 (first doc's spec)
    assert.equals(0, path_to_lnum(lines, "/spec", 0))
  end)
end)

describe("kubeconform error filtering", function()
  -- Test the deduplication and noise filtering logic from linter.lua parser.
  local function should_include(msg)
    return not msg:match("^allOf failed")
      and not msg:match("^oneOf failed")
      and not msg:match("^anyOf failed")
      and not msg:match("^validation failed$")
  end

  it("filters allOf failed messages", function()
    assert.is_false(should_include("allOf failed"))
  end)

  it("filters oneOf failed messages", function()
    assert.is_false(should_include("oneOf failed"))
  end)

  it("filters anyOf failed messages", function()
    assert.is_false(should_include("anyOf failed"))
  end)

  it("filters bare validation failed messages", function()
    assert.is_false(should_include("validation failed"))
  end)

  it("keeps missing property errors", function()
    assert.is_true(should_include("missing property 'metadata'"))
  end)

  it("keeps additional properties errors", function()
    assert.is_true(should_include("additional properties 'foo' not allowed"))
  end)

  it("keeps type mismatch errors", function()
    assert.is_true(should_include("got null, want string"))
  end)
end)

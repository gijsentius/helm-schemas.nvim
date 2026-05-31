-- Tests for lua/helm-schemas/picker.lua
-- Covers: separator logic for multi-document insertion, buffer state detection.

describe("multi-document separator logic", function()
  -- Replicate the separator decision from picker.lua do_insert("append").
  local function make_separator(last_line)
    if last_line == "" then
      return { "---", "" }
    else
      return { "", "---", "" }
    end
  end

  it("uses {---, ''} when previous last line is already blank", function()
    local sep = make_separator("")
    assert.same({ "---", "" }, sep)
  end)

  it("uses {'', ---, ''} when previous last line has content", function()
    local sep = make_separator("  image: nginx")
    assert.same({ "", "---", "" }, sep)
  end)

  it("always ends with a blank line so snippet starts clean", function()
    for _, last in ipairs({ "", "content", "  key: val" }) do
      local sep = make_separator(last)
      assert.equals("", sep[#sep], "separator should end with empty line, last_line=" .. last)
    end
  end)

  it("always contains --- as a separator line", function()
    for _, last in ipairs({ "", "content" }) do
      local sep = make_separator(last)
      local has_sep = false
      for _, l in ipairs(sep) do if l == "---" then has_sep = true end end
      assert.is_true(has_sep, "separator must contain ---")
    end
  end)
end)

describe("buffer emptiness detection", function()
  -- Replicate the is_empty check from picker.lua confirm callback.
  local function is_empty(lines_in_buf)
    local line_count = #lines_in_buf
    return line_count == 0
      or (line_count == 1 and lines_in_buf[1] == "")
  end

  it("empty table is empty", function()
    assert.is_true(is_empty({}))
  end)

  it("single blank line is empty", function()
    assert.is_true(is_empty({ "" }))
  end)

  it("single non-blank line is not empty", function()
    assert.is_false(is_empty({ "apiVersion: v1" }))
  end)

  it("multiple lines is not empty", function()
    assert.is_false(is_empty({ "apiVersion: v1", "kind: Pod" }))
  end)
end)

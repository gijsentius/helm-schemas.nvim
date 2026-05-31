-- nvim-lint custom linter for kubeconform.
-- Validates the current yaml/helm buffer against local cluster/CRD schemas
-- (falling back to the upstream yannh schemas) and reports diagnostics with
-- line numbers derived from the JSON pointer paths in kubeconform's output.

local M = {}

-- ---------------------------------------------------------------------------
-- JSON pointer -> line number
-- ---------------------------------------------------------------------------

-- Walk buffer lines to find the line that best matches a JSON pointer path
-- like /spec/template/spec/containers/0/image.
-- Returns a 0-based line number (falls back to 0 on failure).
local function path_to_lnum(lines, path, doc_start)
  if not path or path == "" then return doc_start end

  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end

  local depth = 0
  local part_idx = 1
  local current_part = parts[part_idx]
  local array_idx = nil  -- expected 0-based array index when non-nil

  -- Convert numeric parts to array indices.
  local function is_num(s) return s:match("^%d+$") end

  local best_lnum = doc_start
  local array_counter = -1  -- counts "- " items at current depth

  for i = doc_start + 1, #lines do
    local line = lines[i]
    if not line then break end
    -- Stop at next document boundary.
    if line:match("^%-%-%-%s*$") and i > doc_start + 1 then break end
    if not current_part then break end

    -- Calculate indent depth (2 spaces per level).
    local indent = #line:match("^(%s*)")
    local line_depth = math.floor(indent / 2)

    if is_num(current_part) then
      -- Looking for the Nth array item ("- ") at the right depth.
      local target = tonumber(current_part)
      if line:match("^%s*%-%s") and line_depth == depth then
        array_counter = array_counter + 1
        if array_counter == target then
          best_lnum = i - 1  -- 0-based
          part_idx = part_idx + 1
          current_part = parts[part_idx]
          array_counter = -1
          depth = depth + 1
        end
      end
    else
      -- Looking for a mapping key at the right depth.
      local key = line:match("^%s*([%w%.%-_]+)%s*:")
      if key and line_depth == depth and key == current_part then
        best_lnum = i - 1  -- 0-based
        part_idx = part_idx + 1
        current_part = parts[part_idx]
        array_counter = -1
        depth = depth + 1
      end
    end
  end

  return best_lnum
end

-- ---------------------------------------------------------------------------
-- Document boundary helpers (duplicated from autoschema.lua to keep linter
-- self-contained when used as a standalone nvim-lint linter table).
-- ---------------------------------------------------------------------------

local function doc_boundaries(lines)
  -- Returns list of {start, stop} pairs (1-based, inclusive) for each document.
  local docs = {}
  local start = 1
  for i, line in ipairs(lines) do
    if line:match("^%-%-%-%s*$") and i > 1 then
      docs[#docs + 1] = { start = start, stop = i - 1 }
      start = i
    end
  end
  docs[#docs + 1] = { start = start, stop = #lines }
  return docs
end

-- ---------------------------------------------------------------------------
-- Build the linter table for nvim-lint
-- ---------------------------------------------------------------------------

-- Parse kubeconform JSON output against a given buffer, returning diagnostics.
-- Exported so autocmds.lua can call it after rendering helm templates.
function M.parse_output(output, bufnr)
  if not output or output == "" then return {} end
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok or type(decoded) ~= "table" or type(decoded.resources) ~= "table" then
    return {}
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local docs   = doc_boundaries(lines)
  local diags  = {}

  local function find_doc_start(kind, name, api_version)
    for _, doc in ipairs(docs) do
      local found_kind, found_av, found_name
      for i = doc.start, math.min(doc.stop, doc.start + 50) do
        local l = lines[i] or ""
        if not found_kind then found_kind = l:match("^kind:%s*(.-)%s*$") end
        if not found_av   then found_av   = l:match("^apiVersion:%s*(.-)%s*$") end
        if not found_name then found_name = l:match("^  name:%s*(.-)%s*$") end
      end
      local kind_match = (not kind or kind == "" or found_kind == kind)
      local av_match   = (not api_version or api_version == "" or found_av == api_version)
      local name_match = (not name or name == "" or found_name == name)
      if kind_match and av_match and name_match then return doc.start - 1 end
    end
    return 0
  end

  for _, resource in ipairs(decoded.resources) do
    if resource.status == "statusInvalid" or resource.status == "statusError" then
      local doc_start = find_doc_start(resource.kind, resource.name, resource.version)
      local errors = resource.validationErrors
      if type(errors) == "table" and #errors > 0 then
        local seen = {}
        for _, ve in ipairs(errors) do
          local msg = ve.msg or ""
          if not msg:match("^allOf failed") and not msg:match("^oneOf failed")
            and not msg:match("^anyOf failed") and not msg:match("^validation failed$") then
            local key = (ve.path or "") .. "|" .. msg
            if not seen[key] then
              seen[key] = true
              local lnum = path_to_lnum(lines, ve.path, doc_start)
              diags[#diags + 1] = {
                lnum=lnum, end_lnum=lnum, col=0, end_col=0,
                severity=vim.diagnostic.severity.ERROR,
                source="kubeconform", message=msg,
              }
            end
          end
        end
      elseif resource.status == "statusError" then
        diags[#diags + 1] = {
          lnum=doc_start, end_lnum=doc_start, col=0, end_col=0,
          severity=vim.diagnostic.severity.WARN,
          source="kubeconform", message=resource.msg or "parse error",
        }
      end
    end
  end
  return diags
end

function M.linter()
  local generate = require("helm-schemas.generate")
  local kc_dir   = generate.kubeconform_dir()

  return {
    name = "kubeconform",
    cmd  = "kubeconform",
    stdin = true,
    stream = "stdout",
    ignore_exitcode = true,
    args = {
      "-output", "json",
      "-ignore-missing-schemas",
      -- Local cluster/CRD schemas synced by this plugin (highest priority).
      "-schema-location", "file://" .. kc_dir .. "/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json",
      -- datreeio CRDs catalog as online fallback (no yannh/default to avoid
      -- noisy network errors in restricted environments).
      "-schema-location", "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json",
      "-",
    },
    parser = function(output, bufnr)
      if not output or output == "" then return {} end
      local ok, decoded = pcall(vim.json.decode, output)
      if not ok or type(decoded) ~= "table" or type(decoded.resources) ~= "table" then
        return {}
      end

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local docs   = doc_boundaries(lines)
      local diags  = {}

      -- Build a map from (kind, name, apiVersion) -> doc start line so we can
      -- anchor each kubeconform result to the right document in the buffer.
      local function find_doc_start(kind, name, api_version)
        for _, doc in ipairs(docs) do
          local found_kind, found_av, found_name
          for i = doc.start, math.min(doc.stop, doc.start + 50) do
            local l = lines[i] or ""
            if not found_kind    then found_kind = l:match("^kind:%s*(.-)%s*$") end
            if not found_av      then found_av   = l:match("^apiVersion:%s*(.-)%s*$") end
            if not found_name    then found_name = l:match("^  name:%s*(.-)%s*$") end
          end
          local kind_match = (not kind or kind == "" or found_kind == kind)
          local av_match   = (not api_version or api_version == "" or found_av == api_version)
          local name_match = (not name or name == "" or found_name == name)
          if kind_match and av_match and name_match then
            return doc.start - 1  -- 0-based
          end
        end
        return 0
      end

      for _, resource in ipairs(decoded.resources) do
        if resource.status == "statusInvalid" or resource.status == "statusError" then
          local doc_start = find_doc_start(resource.kind, resource.name, resource.version)

          local errors = resource.validationErrors
          if type(errors) == "table" and #errors > 0 then
            -- Deduplicate: skip pure "allOf failed" / "oneOf failed" messages that
            -- are just wrapper noise — the child errors carry the real message.
            local seen = {}
            for _, ve in ipairs(errors) do
              local msg = ve.msg or ""
              if not msg:match("^allOf failed") and not msg:match("^oneOf failed")
                and not msg:match("^anyOf failed") and not msg:match("^validation failed$") then
                local key = ve.path .. "|" .. msg
                if not seen[key] then
                  seen[key] = true
                  local lnum = path_to_lnum(lines, ve.path, doc_start)
                  diags[#diags + 1] = {
                    lnum     = lnum,
                    end_lnum = lnum,
                    col      = 0,
                    end_col  = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    source   = "kubeconform",
                    message  = msg,
                  }
                end
              end
            end
          elseif resource.status == "statusError" then
            -- Parse errors (helm template syntax etc.) — report at line 1.
            diags[#diags + 1] = {
              lnum     = doc_start,
              end_lnum = doc_start,
              col      = 0,
              end_col  = 0,
              severity = vim.diagnostic.severity.WARN,
              source   = "kubeconform",
              message  = resource.msg or "parse error",
            }
          end
        end
      end

      return diags
    end,
  }
end

return M

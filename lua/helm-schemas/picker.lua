local M = {}

function M.pick()
  local generate      = require("helm-schemas.generate")
  local templates_dir = generate.templates_dir()
  local index         = generate.load_index()
  local indexed_files = {}
  local items         = {}

  local function source_tag(source)
    if     source == "kubernetes" then return "[k8s]    ", "DiagnosticHint"
    elseif source == "crd"        then return "[crd]    ", "DiagnosticWarn"
    elseif source == "cluster"    then return "[cluster]", "DiagnosticOk"
    else                               return "[store]  ", "DiagnosticInfo"
    end
  end

  for _, entry in ipairs(index) do
    local fpath = templates_dir .. "/" .. entry.file
    indexed_files[entry.file] = true
    local tag, hl = source_tag(entry.source)
    items[#items + 1] = {
      text   = tag .. " " .. entry.name,
      name   = entry.name,
      file   = fpath,
      source = entry.source or "schemastore",
      hl     = hl,
    }
  end

  for _, fpath in ipairs(vim.fn.glob(templates_dir .. "/*.yaml", false, true)) do
    local fname = vim.fn.fnamemodify(fpath, ":t")
    if not indexed_files[fname] then
      local name = fname:gsub("%.yaml$", ""):gsub("_", " ")
      local f = io.open(fpath, "r")
      if f then
        local first = f:read("*l") or ""
        f:close()
        local extracted = first:match("^# (.+)$")
        if extracted then name = extracted end
      end
      local source = fname:match("^k8s_")     and "kubernetes"
                  or fname:match("^crd_")     and "crd"
                  or fname:match("^cluster_") and "cluster"
                  or "schemastore"
      local tag, hl = source_tag(source)
      items[#items + 1] = { text = tag .. " " .. name, name = name,
                             file = fpath, source = source, hl = hl }
    end
  end

  if #items == 0 then
    vim.notify(
      "No helm-schemas templates found. Run <leader>hS, <leader>hk, or <leader>hc first.",
      vim.log.levels.WARN, { title = "helm-schemas" }
    )
    return
  end

  local order = { cluster = 1, kubernetes = 2, crd = 3, schemastore = 4 }
  table.sort(items, function(a, b)
    local oa, ob = order[a.source] or 9, order[b.source] or 9
    if oa ~= ob then return oa < ob end
    return a.name < b.name
  end)

  local target_buf = vim.api.nvim_get_current_buf()
  local target_win = vim.api.nvim_get_current_win()

  require("snacks").picker({
    title  = "Helm / Kubernetes Schema Templates",
    items  = items,
    layout = { preview = false },
    format = function(item)
      return {
        { item.text:sub(1, 11), item.hl },
        { item.name,            "SnacksPickerLabel" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      local f = io.open(item.file, "r")
      if not f then
        vim.notify("Template file not found: " .. item.file, vim.log.levels.ERROR)
        return
      end
      local content = f:read("*a"); f:close()
      vim.api.nvim_set_current_win(target_win)
      vim.api.nvim_set_current_buf(target_buf)
      vim.cmd("startinsert")
      vim.snippet.expand(content)
    end,
  })
end

return M

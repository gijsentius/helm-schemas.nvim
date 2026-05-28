local M = {}

-- Resolved once on first require; workers use this to find sibling scripts.
M._plugin_dir = nil

-- Called by plugin/helm-schemas.lua (or the user's setup() call).
-- opts: { data_dir? }
function M.setup(opts)
  opts = opts or {}

  -- Locate this file's directory so workers can be found at runtime regardless
  -- of where the plugin is installed (local path, lazy.nvim store, etc.).
  local info = debug.getinfo(1, "S")
  local src  = info and info.source:match("^@(.+)$")
  if src then
    -- .../lua/helm-schemas/init.lua  →  .../
    M._plugin_dir = vim.fn.fnamemodify(src, ":h:h:h")
  end

  -- Allow overriding the data directory (default: stdpath("data")/helm-schemas)
  if opts.data_dir then
    require("helm-schemas.generate")._set_data_dir(opts.data_dir)
  end
end

-- Convenience re-exports so callers can do require("helm-schemas").pick() etc.
function M.pick()          require("helm-schemas.picker").pick() end
function M.generate()      require("helm-schemas.generate").generate() end
function M.sync_k8s()      require("helm-schemas.generate").sync_k8s() end
function M.sync_cluster()  require("helm-schemas.generate").sync_cluster() end
function M.add_crd(source) require("helm-schemas.crd").add_crd(source) end
function M.prompt_crd()    require("helm-schemas.crd").prompt() end

return M

local M = {}

-- Data directory can be overridden via setup(). Default: stdpath("data")/helm-schemas
local _data_dir = nil

local function data_dir()
  return _data_dir or (vim.fn.stdpath("data") .. "/helm-schemas")
end

function M._set_data_dir(path)
  _data_dir = path
end

function M.data_dir()      return data_dir() end
function M.templates_dir() return data_dir() .. "/templates" end
function M.schemas_dir()   return data_dir() .. "/schemas" end
function M.index_path()    return data_dir() .. "/index.json" end

function M.load_index()
  local f = io.open(M.index_path(), "r")
  if not f then return {} end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

-- Resolve the workers/ directory relative to this file at runtime.
local function worker_dir()
  local hs = require("helm-schemas")
  if hs._plugin_dir then
    return hs._plugin_dir .. "/lua/helm-schemas/workers"
  end
  -- Fallback: derive from this file's location.
  local info = debug.getinfo(1, "S")
  local src  = info and info.source:match("^@(.+)$")
  return src and (vim.fn.fnamemodify(src, ":h") .. "/workers")
    or (vim.fn.stdpath("config") .. "/lua/helm-schemas/workers")
end

local function plugin_lua_dir()
  local hs = require("helm-schemas")
  if hs._plugin_dir then return hs._plugin_dir .. "/lua" end
  local info = debug.getinfo(1, "S")
  local src  = info and info.source:match("^@(.+)$")
  return src and vim.fn.fnamemodify(src, ":h:h") or (vim.fn.stdpath("config") .. "/lua")
end

local function spawn_worker(worker_name, extra_args, notify_title)
  local wpath   = worker_dir() .. "/" .. worker_name
  local lua_dir = plugin_lua_dir()
  -- Pass lua_dir as first arg so workers can set package.path before any require().
  local args  = { vim.v.progpath, "--headless", "-l", wpath, lua_dir }
  for _, a in ipairs(extra_args or {}) do args[#args + 1] = a end

  vim.system(args, {
    text = true,
    stdout = function(_, line)
      if not line or line == "" then return end
      vim.schedule(function()
        local level = line:match("^err:")  and vim.log.levels.ERROR
                   or line:match("^warn:") and vim.log.levels.WARN
                   or vim.log.levels.INFO
        vim.notify(line, level, { title = notify_title })
      end)
    end,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify(
          worker_name .. " failed (exit " .. result.code .. ")\n" .. (result.stderr or ""),
          vim.log.levels.ERROR, { title = notify_title }
        )
      end
    end)
  end)
end

function M.generate()
  vim.fn.mkdir(M.templates_dir(), "p")
  vim.notify("Fetching SchemaStore catalog…", vim.log.levels.INFO, { title = "helm-schemas" })
  spawn_worker("generate_worker.lua", { M.templates_dir(), M.index_path() }, "helm-schemas")
end

function M.sync_k8s()
  vim.fn.mkdir(M.templates_dir(), "p")
  vim.notify("Fetching yannh/kubernetes-json-schema…", vim.log.levels.INFO, { title = "helm-schemas" })
  spawn_worker("k8s_worker.lua", { M.templates_dir(), M.index_path() }, "helm-schemas")
end

function M.sync_cluster()
  if vim.fn.exepath("kubectl") == "" then
    vim.notify("kubectl not found in PATH", vim.log.levels.ERROR, { title = "helm-schemas" })
    return
  end
  local ctx = vim.trim(vim.fn.system("kubectl config current-context 2>/dev/null"))
  if ctx == "" or ctx:match("error") then
    vim.notify("No active kubectl context", vim.log.levels.ERROR, { title = "helm-schemas" })
    return
  end
  vim.fn.mkdir(M.templates_dir(), "p")
  vim.notify("Syncing CRDs from cluster: " .. ctx, vim.log.levels.INFO, { title = "helm-schemas" })
  spawn_worker("cluster_sync_worker.lua", { M.templates_dir(), M.index_path() }, "helm-schemas")
end

return M

local M = {}

function M.add_crd(source)
  if not source or source == "" then
    vim.notify("Usage: provide a file path or URL to a CRD YAML",
      vim.log.levels.WARN, { title = "helm-schemas" })
    return
  end

  local generate = require("helm-schemas.generate")
  local hs       = require("helm-schemas")
  local worker   = (hs._plugin_dir or vim.fn.stdpath("config"))
                   .. "/lua/helm-schemas/workers/crd_worker.lua"

  vim.notify("Parsing CRD: " .. source, vim.log.levels.INFO, { title = "helm-schemas" })

  vim.system(
    { vim.v.progpath, "--headless", "-l", worker,
      source, generate.templates_dir(), generate.index_path() },
    {
      text = true,
      stdout = function(_, line)
        if not line or line == "" then return end
        vim.schedule(function()
          local level = line:match("^err:") and vim.log.levels.ERROR or vim.log.levels.INFO
          vim.notify(line, level, { title = "helm-schemas" })
        end)
      end,
    },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          vim.notify("CRD import failed\n" .. (result.stderr or ""),
            vim.log.levels.ERROR, { title = "helm-schemas" })
        end
      end)
    end
  )
end

function M.prompt()
  local buf_path = vim.api.nvim_buf_get_name(0)
  local default  = (buf_path ~= "" and buf_path:match("%.ya?ml$")) and buf_path or ""
  vim.ui.input(
    { prompt = "CRD YAML path or URL: ", default = default, completion = "file" },
    function(input)
      if input and input ~= "" then M.add_crd(input) end
    end
  )
end

return M

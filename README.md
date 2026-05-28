# helm-schemas.nvim

Schema completions and validation for Helm charts and Kubernetes YAML files.

- Sync schemas from your live cluster (`kubectl`), SchemaStore, or yannh
- Auto-detects `kind`/`apiVersion` in any file — no modeline needed
- Pick and insert resource templates with `<leader>hs`
- Supports multiple schemas in one file via `---` document separators

---

## Requirements

- Neovim 0.10+
- [lazy.nvim](https://github.com/folke/lazy.nvim)
- [snacks.nvim](https://github.com/folke/snacks.nvim) — for the template picker

For completions and validation you also need a YAML language server. The recommended setup is:

- [yaml-language-server](https://github.com/redhat-developer/yaml-language-server) (`yamlls`) via mason: `MasonInstall yaml-language-server`
- [helm-ls](https://github.com/mrjosh/helm-ls) for files inside Helm charts: `MasonInstall helm-ls`

---

## Installation

### LazyVim

Create `~/.config/nvim/lua/plugins/helm.lua`:

```lua
return {
  { "gijsentius/helm-schemas.nvim", opts = {} },
}
```

### Plain lazy.nvim

```lua
{
  "gijsentius/helm-schemas.nvim",
  lazy = false,
  opts = {},
}
```

---

## LSP configuration

Add this to your `nvim-lspconfig` setup to enable completions and validation:

```lua
-- yamlls — for plain YAML files
require("lspconfig").yamlls.setup({
  settings = {
    yaml = {
      validate = true,
      schemaStore = { enable = false, url = "" },
    },
  },
})

-- helm_ls — for files inside a Helm chart (templates/)
require("lspconfig").helm_ls.setup({
  settings = {
    ["helm-ls"] = {
      yamlls = { path = "yaml-language-server" },
    },
  },
})
```

With LazyVim, add this to your `plugins/helm.lua` instead:

```lua
return {
  { "gijsentius/helm-schemas.nvim", opts = {} },

  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        yamlls = {
          settings = {
            yaml = {
              validate = true,
              schemaStore = { enable = false, url = "" },
            },
          },
        },
        helm_ls = {
          settings = {
            ["helm-ls"] = {
              yamlls = { path = "yaml-language-server" },
            },
          },
        },
      },
    },
  },
}
```

---

## First use

After installing, sync schemas for your cluster:

| Keymap | Description |
|--------|-------------|
| `<leader>hC` | Sync CRDs and API resources from the active `kubectl` context |
| `<leader>hS` | Sync SchemaStore templates |
| `<leader>hk` | Sync core Kubernetes types (yannh) |

---

## Keymaps

| Keymap | Description |
|--------|-------------|
| `<leader>hs` | Open template picker |
| `<leader>hS` | Sync SchemaStore templates |
| `<leader>hk` | Sync core Kubernetes types |
| `<leader>hc` | Add a CRD from a file path or URL |
| `<leader>hC` | Sync CRDs from active kubectl context |
| `<leader>hx` | Clear schemas |

---

## API

```lua
local hs = require("helm-schemas")

hs.pick()           -- open template picker
hs.generate()       -- sync SchemaStore templates
hs.sync_k8s()       -- sync core Kubernetes templates
hs.sync_cluster()   -- sync from active kubectl context
hs.add_crd(source)  -- import a CRD from file path or URL
hs.prompt_crd()     -- prompt for a CRD path/URL
hs.clear()          -- clear schemas
```

### `setup(opts)`

| Option | Default | Description |
|--------|---------|-------------|
| `data_dir` | `stdpath("data")/helm-schemas` | Where templates, schemas, and the index are stored |

---

## Data directory

```
stdpath("data")/helm-schemas/
  templates/   YAML snippet templates
  schemas/     JSON schema files
  index.json   Metadata index
```

Schemas are stored per-machine — run `<leader>hC` on each machine after installing.

---

## License

MIT

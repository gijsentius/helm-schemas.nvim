# helm-schemas.nvim

Neovim plugin that brings rich schema completions and validation to Helm charts and raw Kubernetes YAML files.

- **SchemaStore** templates — 500+ community schemas via [SchemaStore](https://www.schemastore.org/)
- **Core Kubernetes** types — all built-in resources via [yannh/kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema)
- **CRD support** — import any CRD from a local file or URL; sync all CRDs from the active `kubectl` context
- **yamlls + helm-ls** integration — schemas wired into both language servers automatically
- **blink.cmp** completion trigger — completions fire on blank/list lines (yamlls advertises no trigger characters)

---

## Requirements

- Neovim 0.10+
- [lazy.nvim](https://github.com/folke/lazy.nvim)

Optional (auto-configured when present):

- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) — LSP wiring
- [mason.nvim](https://github.com/mason-org/mason.nvim) — installs `helm-ls` and `yamllint`
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) — `gotmpl` grammar
- [towolf/vim-helm](https://github.com/towolf/vim-helm) — Helm filetype detection
- [b0o/SchemaStore.nvim](https://github.com/b0o/SchemaStore.nvim) — extended schema catalog
- [snacks.nvim](https://github.com/folke/snacks.nvim) — picker UI and keymaps
- [conform.nvim](https://github.com/stevearc/conform.nvim) — YAML formatting via prettier
- [nvim-lint](https://github.com/mfussenegger/nvim-lint) — YAML linting via yamllint
- [which-key.nvim](https://github.com/folke/which-key.nvim) — keymap group label
- [blink.cmp](https://github.com/Saghen/blink.cmp) — completion engine

---

## Installation

### Option A — one-liner (recommended)

Add this to your lazy.nvim plugins table to get the plugin **and** all integrations wired up automatically:

```lua
{ import = "helm-schemas.spec" }
```

This imports the bundled spec, which configures all optional dependencies if they are present.

### Option B — manual

```lua
{
  "gijsentius/helm-schemas.nvim",
  lazy = false,
  opts = {},
}
```

Then configure `nvim-lspconfig`, keymaps, etc. yourself using the API below.

---

## Keymaps (spec.lua defaults)

| Key | Description |
|-----|-------------|
| `<leader>hs` | Insert a schema template at cursor (picker) |
| `<leader>hS` | Sync SchemaStore templates |
| `<leader>hk` | Sync core Kubernetes types (yannh) |
| `<leader>hc` | Add a CRD from a file path or URL |
| `<leader>hC` | Sync all CRDs from the active kubectl context |

---

## API

```lua
local hs = require("helm-schemas")

hs.setup({ data_dir = "/custom/path" })  -- optional, called automatically by plugin/

hs.pick()           -- open schema template picker (snacks.nvim)
hs.generate()       -- sync SchemaStore templates
hs.sync_k8s()       -- sync core Kubernetes templates (yannh)
hs.sync_cluster()   -- sync CRDs from active kubectl context
hs.add_crd(source)  -- import a CRD from file path or URL
hs.prompt_crd()     -- prompt for a CRD path/URL via vim.ui.input
```

### `setup(opts)`

| Option | Default | Description |
|--------|---------|-------------|
| `data_dir` | `stdpath("data")/helm-schemas` | Where templates, schemas, and the index are stored |

---

## Data directory layout

```
stdpath("data")/helm-schemas/
  templates/   YAML snippet templates (one per schema)
  schemas/     JSON schemas for CRDs (used by yamlls file:// URIs)
  index.json   Metadata index for the picker
```

---

## How CRD schemas work

When you run `<leader>hc` or `<leader>hC`, the plugin:

1. Fetches the CRD YAML and extracts the embedded OpenAPI v3 schema.
2. Writes a JSON schema file to `schemas/<name>.json`.
3. Writes a YAML snippet template to `templates/crd_<name>.yaml`.

On LSP start, `before_init` hooks in `spec.lua` register the `file://` URIs with both `yamlls` and helm-ls's internal yamlls instance.

> **Note**: The `# yaml-language-server: $schema=` modeline does **not** work inside Helm templates because helm-ls strips `$` from Go-template variable references in YAML comments during pre-processing. The `before_init` approach is required for Helm files.

---

## License

MIT

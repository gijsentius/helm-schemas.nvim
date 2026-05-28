# helm-schemas.nvim

Neovim plugin that brings schema completions and validation to Helm charts and Kubernetes YAML files — without modelines or manual configuration.

- **Auto-detection** — reads `kind`/`apiVersion` from the buffer and applies the right schema automatically
- **SchemaStore** — 500+ community schemas via [SchemaStore](https://www.schemastore.org/)
- **Core Kubernetes** types — all built-in resources via [yannh/kubernetes-json-schema](https://github.com/yannh/kubernetes-json-schema)
- **Cluster sync** — fetch CRDs and built-in API resources directly from the active `kubectl` context
- **CRD import** — add any CRD from a local file or URL
- **Multi-document files** — pick multiple schemas into one file separated by `---`
- **yamlls + helm-ls** — schemas wired into both language servers automatically

---

## Requirements

- Neovim 0.10+
- [lazy.nvim](https://github.com/folke/lazy.nvim)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with the `yaml` parser installed

  ```lua
  -- ensure yaml parser is installed
  { "nvim-treesitter/nvim-treesitter", opts = { ensure_installed = { "yaml" } } }
  ```

Optional (auto-configured when present):

| Plugin | Purpose |
|--------|---------|
| [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) | LSP wiring for yamlls and helm-ls |
| [mason.nvim](https://github.com/mason-org/mason.nvim) | Auto-installs `helm-ls` and `yamllint` |
| [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) | `gotmpl` grammar for Helm templates |
| [towolf/vim-helm](https://github.com/towolf/vim-helm) | Helm filetype detection |
| [b0o/SchemaStore.nvim](https://github.com/b0o/SchemaStore.nvim) | Extended schema catalog |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | Picker UI and keymaps |
| [conform.nvim](https://github.com/stevearc/conform.nvim) | YAML formatting via prettier |
| [nvim-lint](https://github.com/mfussenegger/nvim-lint) | YAML linting via yamllint |
| [which-key.nvim](https://github.com/folke/which-key.nvim) | Keymap group label |
| [blink.cmp](https://github.com/Saghen/blink.cmp) | Completion engine |

---

## Installation

### LazyVim

Create a file `~/.config/nvim/lua/plugins/helm.lua` with:

```lua
return {
  { "gijsentius/helm-schemas.nvim", opts = {} },
  { "nvim-treesitter/nvim-treesitter", opts = { ensure_installed = { "yaml" } } },
}
```

That's it. lazy.nvim reads the bundled `lazy.lua` from the plugin and automatically wires up all integrations that are present in your config (LSP, keymaps, blink.cmp, Mason, etc.).

### Plain lazy.nvim (non-LazyVim)

Add to your plugins table:

```lua
{ "gijsentius/helm-schemas.nvim", opts = {} }
```

### Manual setup (without the bundled integrations)

If you want to configure everything yourself:

```lua
{
  "gijsentius/helm-schemas.nvim",
  lazy = false,
  opts = {},
  -- then configure nvim-lspconfig, keymaps, etc. yourself
}
```

---

## First use

After installing, sync schemas for your environment:

| Keymap | Description |
|--------|-------------|
| `<leader>hC` | Sync CRDs and built-in resources from the active `kubectl` context (recommended) |
| `<leader>hS` | Sync SchemaStore templates |
| `<leader>hk` | Sync core Kubernetes types (yannh) |

---

## Keymaps

| Keymap | Description |
|--------|-------------|
| `<leader>hs` | Open template picker — insert a schema at cursor or append with `---` |
| `<leader>hS` | Sync SchemaStore templates |
| `<leader>hk` | Sync core Kubernetes types (yannh) |
| `<leader>hc` | Add a CRD from a file path or URL |
| `<leader>hC` | Sync all CRDs and API resources from the active kubectl context |
| `<leader>hx` | Clear all schemas (or cluster schemas only) |

---

## How it works

### Schema auto-detection

When you open a YAML file, the plugin reads `kind` and `apiVersion` from the buffer content and sends the matching schema to yamlls and helm-ls via `workspace/didChangeConfiguration`. This happens automatically on every buffer open and text change (debounced), so any filename works — not just `deployment.yaml`.

Cluster schemas take priority over kubernetes schemas, which take priority over SchemaStore.

### Multi-document files

Press `<leader>hs` in a buffer that already has content and choose **"Append document (---)"** to add a second resource. Each document gets its own schema applied by the auto-detection.

### Template picker

Templates contain only the required fields with typed defaults — no commented-out optional fields. Pick a template and start filling in values; LSP completions provide the optional fields as you type.

---

## API

```lua
local hs = require("helm-schemas")

hs.setup({ data_dir = "/custom/path" })  -- optional, called automatically

hs.pick()           -- open template picker
hs.generate()       -- sync SchemaStore templates
hs.sync_k8s()       -- sync core Kubernetes templates (yannh)
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
  templates/   YAML snippet templates (one per schema)
  schemas/     JSON schema files (used by yamlls via file:// URIs)
  index.json   Metadata index for the picker
```

Schemas are stored per-machine and are not part of the plugin — run `<leader>hC` on each machine to populate them.

---

## License

MIT

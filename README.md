# CSA.nvim

**Cursor Side Agent for Neovim** — bring Cursor’s agent into the editor, without leaving your buffer.

CSA.nvim is a native side panel that drives the [Cursor CLI](https://cursor.com/docs/cli). You stay in Neovim; the agent reads, plans, and edits in context. Changes land as reviewable diffs you accept or reject — the same agent loop Cursor users expect, adapted to a keyboard-first workflow.

![CSA.nvim preview](assets/preview.png)

**中文文档：** [README.zh-CN.md](README.zh-CN.md) · **Help:** `:help csa`

## Requirements

- Neovim 0.10+
- [Cursor CLI](https://cursor.com/docs/cli) on `PATH`
- [`fd`](https://github.com/sharkdp/fd) for the file picker
- Optional: [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)

## Install

Repo: [https://github.com/Brandon-kk/CSA.nvim](https://github.com/Brandon-kk/CSA.nvim)

### Automic / Pack

```lua
Pack.register({
  "https://github.com/Brandon-kk/CSA.nvim",
  module = "csa",
}):load({
  cmd = { "CSAToggle", "CSAsk", "CSAgents" },
  config = function(plugin)
    plugin.setup({
      ui = { width = 0.40 },
      provider = {
        command = "cursor-agent",
        force = true, -- recommended for agent file writes
        auth = { env = "CURSOR_API_KEY" },
      },
    })
  end,
})
```

### lazy.nvim

```lua
{
  "Brandon-kk/CSA.nvim",
  cmd = { "CSAToggle", "CSAsk", "CSAgents" },
  opts = {
    ui = { width = 0.40 },
    provider = {
      command = "cursor-agent",
      force = true,
      auth = { env = "CURSOR_API_KEY" },
    },
  },
}
```

Auth: `export CURSOR_API_KEY=...` or `cursor-agent login`.

Help: `:help csa`.

## Commands

| Command | Description |
|---------|-------------|
| `:CSAToggle` | Toggle the side panel (default **agent** mode) |
| `:CSAsk` | Open in locked **ask** mode; visual/range prefills Input |
| `:CSAgents` | Open in locked **agent** mode; visual/range prefills Input |

Reopening restores the last non-empty session. Force a new chat:

```lua
require("csa").open({ fresh = true })
```

## Keymaps (summary)

- **Tab / S-Tab** — cycle Output / Files / Input (Output lands on a **user** message)
- **Input:** `<CR>` send · `f` files · `h` history · `A` model · `[`/`]` mode · `R` regenerate last
- **Output:** `[`/`]` prev/next **user** message · `y` copy · `r` regenerate · `e` edit & resend
- **Edited buffers:** `ca` accept · `cr` reject
- **Streaming:** `<C-c>` cancel

Regenerate / edit truncate from the current user turn downward, revert file edits from dropped turns, then re-run the model.

## Data

Under `stdpath("data")/site/csa/`: `history/`, `cache/`, `agents/*.md`.

## License

[MIT](LICENSE)

<div align="center">
  <h1>CSA.nvim</h1>
  <p>Cursor Side Agent for Neovim</p>
  <p>
    <a href="https://neovim.io"><img src="https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white" alt="Neovim 0.10+"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License"></a>
  </p>
  <p><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
</div>

---

## Scope

| Layer | Responsibility |
| ----- | -------------- |
| Cursor CLI (`cursor-agent` / `agent`) | Models, tools, streaming, workspace edits |
| CSA.nvim | Side panel UI, session history, file allow-list, edit review, keymaps |

Authoritative reference: `:help csa` (`doc/csa.txt`).

Lifecycle:

```text
open → prompt → stream → review → restore
```

<p align="center">
  <img src="assets/preview.png" alt="CSA.nvim preview" width="900">
</p>

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Commands](#commands)
- [Panels](#panels)
- [Keymaps](#keymaps)
- [Modes & models](#modes--models)
- [Files & review](#files--review)
- [History & restore](#history--restore)
- [Regenerate / edit](#regenerate--edit)
- [Configuration](#configuration)
- [Data directory](#data-directory)
- [Lua API](#lua-api)
- [License](#license)

---

## Requirements

- Neovim 0.10+
- [Cursor CLI](https://cursor.com/docs/cli) on `$PATH` (`cursor-agent` preferred; falls back to `agent`)
- [`fd`](https://github.com/sharkdp/fd) for the in-panel file picker
- Optional: [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) for Output rendering

Authenticate with `CURSOR_API_KEY` or `cursor-agent login`.

---

## Installation

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
        force = true,
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

---

## Commands

| Command | Behavior |
| ------- | -------- |
| `:CSAToggle` | Toggle the side panel. Default mode is `agent` (`[` / `]` to cycle). |
| `:CSAsk` | Open locked `ask` mode. Visual / `:[range]` prefills Input. `:CSAsk {text}` opens and **submits** immediately. |
| `:CSAgents` | Open locked `agent` mode. Visual / `:[range]` prefills Input. |

---

## Panels

Right-hand pad split plus floats:

| Panel | Role |
| ----- | ---- |
| Output | Transcript (Markdown; optional render-markdown). Focusable for navigation / regen / edit. |
| Files | Attached paths; after agent edits shows fg-only stats (`󰐕n 󰍴n`). |
| Input | Prompt entry; title shows mode and context usage (e.g. `12k/200k · 6%`). |

Foreign overlays (e.g. full-screen floats) temporarily hide CSA.

---

## Keymaps

### Global (inside CSA)

| Key | Behavior |
| --- | -------- |
| `Tab` / `S-Tab` | Cycle Output → Files → Input. Focusing Output lands on a **user** message. |
| `<C-w>{chord}` | Leave CSA to the main editor (common chords rebound). |
| `<C-c>` | Cancel in-flight AI stream (while streaming). |

While streaming, most panel shortcuts are locked; `<C-c>` remains available.

### Input

| Key | Behavior |
| --- | -------- |
| `<CR>` | Submit prompt |
| `<S-CR>` (insert) | Newline |
| `/` | Complete installed skill names (blink.cmp); `/name` injects that skill only |
| `f` | File picker (`fd`) |
| `h` | History picker |
| `A` | Model picker |
| `[` / `]` | Cycle mode: plan ↔ agent ↔ ask (no-op when locked) |
| `R` | Regenerate last turn |
| `<C-u>` / `<C-d>` | Scroll Output without leaving Input |

### Output

| Key | Behavior |
| --- | -------- |
| `[` / `]` | Previous / next **user** message (wraps) |
| `y` | Copy message body (`"` and `+`) |
| `r` | Regenerate current user turn |
| `e` | Edit current user message and resend |
| `Esc` | Focus Input |

### Files

| Key | Behavior |
| --- | -------- |
| `d` | Remove file under cursor |
| `e` | Open file in the main editor |
| `Esc` | Focus Input |

### Buffers with pending agent edits

| Key | Behavior |
| --- | -------- |
| `ca` | Accept edit for this buffer (or all if none on buffer) |
| `cr` | Reject and restore previous content (or all) |

### File / history / model pickers

| Key | Behavior |
| --- | -------- |
| `Esc` / `q` | Cancel |
| `<CR>` | Files: toggle select · History: open · Model: choose |
| `<C-CR>` | Files: confirm selection |
| `R` | Models: refresh list from CLI |
| `d` | History: delete session |

---

## Modes & models

| Mode | CLI behavior |
| ---- | ------------ |
| `plan` | `--mode plan` (read-only planning) |
| `agent` | Default write-capable path (omit `--mode`; uses `--force` when configured) |
| `ask` | `--mode ask` |

Selected model is cached and passed as `--model` (omitted when `auto`).

---

## Files & review

Attach paths with `f`. When the allow-list is non-empty, out-of-scope agent writes are rejected and reverted.

| Step | Behavior |
| ---- | -------- |
| Snapshot | Content captured before tool write |
| Decorate | Gutter signs + deleted virt lines (no Diff background wash) |
| Files panel | Fg-only add/delete stats |
| Accept / reject | `ca` / `cr` on the edited buffer |

Edits are stored on the assistant history message for rewind on regenerate / edit-resend.

---

## History & restore

Sessions persist under [Data directory](#data-directory). Opening History (`h`) previews sessions in Output; Enter continues that session. Cancel restores the previous Output and session id.

Reopening `:CSAToggle` restores the last non-empty session (`cache/last_session.json`). Force a blank chat:

```lua
require("csa").open({ fresh = true })
```

---

## Regenerate / edit

Target turn = user message under the Output cursor (or the active `[` / `]` selection; Input `R` uses the last turn).

| Action | Behavior |
| ------ | -------- |
| `r` Regenerate | Keep that user message; delete later messages; rewind file edits; clear Cursor `--resume` id and re-ask (seeds local history). |
| `e` Edit & resend | Load user text into Input; delete that user message and everything after; rewind edits; next `<CR>` sends with history seed. |

---

## Configuration

```lua
require("csa").setup({
  language = "en",
  ui = {
    width = 0.30,
    border = "rounded",
    input = { height = 3, icon = "󰏫" },
    files = { enabled = false, max_visible = 5, icon = "󰈙" },
    output = { icon = "󰚩" },
  },
  identity = {
    name = nil,
    icon = "",
  },
  provider = {
    enabled = true,
    command = "cursor-agent",
    workspace = nil,
    auth = { env = "CURSOR_API_KEY", key = nil },
    force = false,
    stream = true,
    trust = true,
  },
})
```

| Field | Type | Notes |
| ----- | ---- | ----- |
| `language` | `string` | Reply language injected into the provider prompt. Default `en`. Unknown values fall back to `en`. |
| `ui.width` | `number` | Fraction of columns when in `(0,1]`; absolute columns when `>1`. |
| `ui.border` | `string` / `table` | Float border style. |
| `ui.input.height` | `integer` | Input float height in lines. |
| `ui.input.icon` | `string` | Input title icon. |
| `ui.files.enabled` | `boolean` | Show Files panel even when empty. |
| `ui.files.max_visible` | `integer` | Max visible file rows. |
| `ui.files.icon` | `string` | Files title icon. |
| `ui.output.icon` | `string` | Output / assistant icon. |
| `identity.name` | `string` / `nil` | Display name in Output headers; default `git user.name` / `$USER`. |
| `identity.icon` | `string` | User header icon. |
| `provider.enabled` | `boolean` | Disable to use UI without CLI. |
| `provider.command` | `string` | CLI executable; falls back to `cursor-agent` / `agent`. |
| `provider.workspace` | `string` / `nil` | Working directory; `nil` → `getcwd()`. |
| `provider.auth.env` | `string` | **Environment variable name** holding the key (not the secret). |
| `provider.auth.key` | `string` / `nil` | Optional inline key (prefer env). |
| `provider.force` | `boolean` | Pass `--force` in agent mode (often required for writes). |
| `provider.stream` | `boolean` | `stream-json` + partial deltas. |
| `provider.trust` | `boolean` | Pass `--trust` for headless runs. |

`language` codes (18): `en` · `zh-CN` · `zh-TW` · `ja` · `ko` · `fr` · `de` · `es` · `pt` · `ru` · `it` · `nl` · `pl` · `tr` · `ar` · `hi` · `vi` · `th`.

---

## Data directory

Root: `stdpath("data")/site/csa/`

| Path | Contents |
| ---- | -------- |
| `history/<id>.json` | Session messages, `cursor_chat_id`, per-turn edits |
| `cache/models.json` | Model list cache |
| `cache/selected_model.json` | Selected model |
| `cache/last_session.json` | Last session id for reopen |
| `agents/*.md` | Persona / context docs (injected when non-empty) |
| `skills/` | Installed skills (`name/SKILL.md` or `name.md`); mention with `/name` in Input to inject **only those** skills into the turn (type `/` for blink.cmp completion) |

---

## Lua API

| Call | Behavior |
| ---- | -------- |
| `csa.setup({opts})` | Apply configuration and init highlights. |
| `csa.config()` | Return resolved options table. |
| `csa.toggle()` | Toggle panel (agent mode, unlocked). |
| `csa.open({opts})` | Open panel. `opts.mode`: `"ask"` \| `"agent"` \| `"plan"`; `opts.mode_locked`; `opts.fresh` skips last-session restore. |
| `csa.close()` | Close panel (saves last session if non-empty). |
| `csa.ask([{prefill}], [{opts}])` | Open locked ask mode; optional Input prefill. `opts.submit` sends immediately. |
| `csa.agents([{prefill}])` | Open locked agent mode; optional Input prefill. |
| `csa.set_files_visible([{visible}])` | Show / hide Files (`nil` toggles). |
| `csa.get_files()` | Return attached absolute paths. |

Lower-level modules (advanced): `csa.ui.picker`, `csa.storage`, `csa.review`, `csa.ai.cursor`.

---

## License

[MIT License](LICENSE)

# CSA.nvim

**Cursor Side Agent for Neovim** — 把 Cursor Agent 留在编辑器里。

CSA.nvim 是面向 Neovim 的原生侧栏，直接驱动 [Cursor CLI](https://cursor.com/docs/cli)。你不用切走窗口：提问、规划、改代码都在当前工程上下文中完成；Agent 写出的改动以可审阅的 diff 呈现，由你决定接受或回退。同一套 Cursor Agent 能力，适配键盘优先的编辑节奏。

![CSA.nvim 预览](assets/preview.png)

## 依赖

- Neovim 0.10+
- [Cursor CLI](https://cursor.com/docs/cli)（`cursor-agent` 或 `agent` 在 `PATH` 中）
- 文件选择器需要 [`fd`](https://github.com/sharkdp/fd)
- 可选：[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)（美化 Output）

## 安装

仓库：[https://github.com/Brandon-kk/CSA.nvim](https://github.com/Brandon-kk/CSA.nvim)

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
        force = true, -- Agent 写文件时建议开启
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

认证：`export CURSOR_API_KEY=...` 或执行 `cursor-agent login`。

帮助：`:help csa`。

## 命令

| 命令 | 说明 |
|------|------|
| `:CSAToggle` | 打开/关闭侧栏（默认 agent 模式，可用 `[`/`]` 切换） |
| `:CSAsk` | 打开 ask 模式并锁定；支持 visual / 行范围预填 Input |
| `:CSAgents` | 打开 agent 模式并锁定；支持 visual / 行范围预填 Input |

重开面板会**自动恢复上一次有内容的对话**。强制新会话：

```lua
require("csa").open({ fresh = true })
```

## 面板

右侧 pad + 浮层：

1. **Output** — 对话（Markdown / 可选 render-markdown）
2. **Files** — 附加文件；Agent 改动后显示 `󰐕n 󰍴n` 统计
3. **Input** — 输入；标题含模式与上下文用量（如 `12k/200k · 6%`）

## 快捷键

### 全局（面板内）

| 按键 | 作用 |
|------|------|
| `Tab` / `S-Tab` | 在 Output / Files / Input 间切换；进入 Output 时落在**用户消息**上 |
| `<C-w>*` | 离开 CSA，回到主编辑区 |
| `<C-c>` | 流式输出时取消请求 |

### Input

| 按键 | 作用 |
|------|------|
| `<CR>` | 发送 |
| `<S-CR>`（插入） | 换行 |
| `f` | 打开文件选择器（`fd`） |
| `h` | 历史会话 |
| `A` | 选择模型 |
| `[` / `]` | 切换模式 plan ↔ agent ↔ ask（`:CSAsk` / `:CSAgents` 时锁定） |
| `R` | 重新生成最后一轮 |
| `<C-u>` / `<C-d>` | 滚动 Output |

### Output

| 按键 | 作用 |
|------|------|
| `[` / `]` | 上一条 / 下一条**用户**消息 |
| `y` | 复制当前消息正文 |
| `r` | 重新生成（删掉该轮及之后、回退文件改动、再请求） |
| `e` | 编辑后重发（同上截断与回退，内容填入 Input） |
| `Esc` | 回到 Input |

### Files

| 按键 | 作用 |
|------|------|
| `d` | 移除附加文件 |
| `e` | 在主编辑区打开文件 |
| `Esc` | 回到 Input |

### 被改文件的 buffer（Agent 审阅）

| 按键 | 作用 |
|------|------|
| `ca` | 接受当前文件改动（无匹配时接受全部） |
| `cr` | 拒绝并回滚（无匹配时拒绝全部） |

### 文件选择器 / 历史 / 模型

| 按键 | 作用 |
|------|------|
| `<CR>` | 文件：切换多选；历史：打开；模型：选中 |
| `<C-CR>` | 文件：确认附加 |
| `Esc` / `q` | 取消 |
| `R`（模型） | 强制刷新模型列表 |
| `d`（历史） | 删除会话 |

## 重新生成 / 编辑后重发

- 以 Output 中光标（或 `[`/`]`）所在**用户回合**为准。
- 删除该回合及之后的全部消息。
- 回退这些回合产生的文件修改（含已 `ca` 接受的；新建文件会删除）。
- `r`：保留用户消息并重新生成回复；`e`：把用户消息放进 Input 修改后再发。

## 数据目录

`stdpath("data")/site/csa/`：

| 路径 | 内容 |
|------|------|
| `history/<id>.json` | 会话（messages、cursor_chat_id、edits） |
| `cache/models.json` | 模型列表缓存 |
| `cache/selected_model.json` | 当前模型 |
| `cache/last_session.json` | 上次会话（用于重开恢复） |
| `agents/*.md` | 人格 / 上下文文档（非空时注入 prompt） |

## 配置参考

```lua
require("csa").setup({
  language = "en",          -- 回复语言；见下方支持列表
  ui = {
    width = 0.30,           -- 0–1 为比例，>1 为列数
    border = "rounded",
    input = { height = 3, icon = "󰏫" },
    files = { enabled = false, max_visible = 5, icon = "󰈙" },
    output = { icon = "󰚩" },
  },
  identity = {
    name = nil,             -- 默认 git user.name / $USER
    icon = "",
  },
  provider = {
    enabled = true,
    command = "cursor-agent",
    workspace = nil,        -- 默认 cwd
    auth = { env = "CURSOR_API_KEY", key = nil },
    force = false,          -- agent 写盘时常需 true
    stream = true,
    trust = true,
  },
})
```

`language` 支持：`en` · `zh-CN` · `zh-TW` · `ja` · `ko` · `fr` · `de` · `es` · `pt` · `ru` · `it` · `nl` · `pl` · `tr` · `ar` · `hi` · `vi` · `th`。

## 许可

[MIT](LICENSE)

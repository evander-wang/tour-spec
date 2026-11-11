# pi-tour — 链路导览

把一段跨函数/跨文件的执行路径做成「分站导览」：一份 tour spec（JSON），同时渲染成

- **Neovim 里的可步进导览**：编号 virtual text + quickfix 站点清单 + 底部 why 浮条
- **自包含 HTML 代码地图**：纵向 = 调用顺序，横向 = 调用深度

两个消费端吃同一份 spec，改一处两边一起变。

## 目录

| 路径 | 作用 |
|---|---|
| `nvim/lua/pi_tour/init.lua` | Neovim 插件本体 |
| `nvim/pi-tour.lua` | lazy.nvim 插件声明（拷／symlink 到 `~/.config/nvim/lua/plugins/`） |
| `render.mjs` | spec → 单文件 HTML 代码地图，无依赖 |
| `skills/code-tour/SKILL.md` | agent 侧的 spec 生产契约（**前置依赖**，见下节） |
| `out/` | 想长期留档的 HTML（`/tmp` 会被系统清理）——已 gitignore |
| `/tmp/pi-tours/<slug>.json` | 运行时 spec 的默认目录，`:PiTour list` 扫这里 |

> 开发副本放 `~/src/pi-tours`（原始仓库），`~/.pi/agent/tours` 是指向它的 symlink——插件声明里的 `dir` 与本文所有路径都靠它稳定。

## 前置依赖：code-tour skill

本工具只负责 **消费** spec（渲染导览、画代码地图）。**生成** spec 靠 `code-tour` 这个 skill：agent 装不装它，决定你能不能对 agent 说一句「把这条链路做成导览」就得到一份 spec。没装也能用，但要自己手写 JSON。

skill 正文就在本仓库的 `skills/code-tour/SKILL.md`，把它挂到 Pi 的 skill 目录即可（Pi 会跟随目录 symlink）：

```bash
ln -s ~/src/pi-tours/skills/code-tour ~/.pi/agent/pi-hermes-memory/skills/code-tour
```

验证：新开一个 Pi 会话，看 skill 列表里有 `code-tour`（或直接问「有哪些 code tour 相关的 skill」）。确定性验法见 `CONTRIBUTING.md`。

> 这个仓库**不自己做包分发**：skill 在哪台机器上挂，都得自己建这条 symlink；也没有依赖检查脚本。

### 没装 skill 时：手写 spec 的最小示例

存成 `/tmp/pi-tours/hello.json`，直接 `:PiTour load /tmp/pi-tours/hello.json` 就能跑（下面这份以本仓库的 `render.mjs` 为标的，实测可载入、`:PiTour check` 无告警）：

```json
{
  "repo": "/Users/wangjichao/pi-tours",
  "name": "手写示例：render.mjs 怎么读 spec",
  "steps": [
    {
      "file": "render.mjs",
      "start": 25,
      "end": 29,
      "layer": "entry",
      "title": "先取参数：spec 路径、--out、--open",
      "why": "手写 spec 最容易漏的是两个相对关系：file 相对 repo，start 是 1-based。",
      "anchor": "const argv = process.argv.slice(2);"
    },
    {
      "file": "render.mjs",
      "start": 40,
      "end": 47,
      "layer": "data",
      "title": "读 spec 并 JSON.parse，坏 JSON 直接报错退出",
      "why": "解析失败就退出，不会带着半份 spec 继续渲染。",
      "anchor": "const raw = fs.readFileSync(specPath, \"utf8\");"
    }
  ]
}
```

只需记住三条：`repo` 是仓库根，`file` 相对 `repo`，`anchor` 必填（该范围首行的原文）。写完先跑 `:PiTour check /tmp/pi-tours/hello.json` 确认 anchor 能命中。

## 快捷键

`<leader>` 是空格，所以 `<leader>To` = `空格 T o`。

| 键 | 动作 | 说明 |
|---|---|---|
| `<F9>` / `]T` | 下一站 | `]T` 是双键前缀，`timeoutlen` 较小时容易按丢，故保留单键 `F9` |
| `<F10>` / `[T` | 上一站 | 同上 |
| `<leader>Tt` | 站点列表 | 弹选择器，跳到**当前** tour 的任意一站（不是切换 tour） |
| `<leader>To` | 切换导览 | 列出所有 spec，选中即载入另一份 tour；<C-d> 删除选中那份 |
| `<leader>Tr` | 重载 spec | 代码改动后按 anchor 重新定位（只对最后载入的那份生效） |
| `<leader>Ts` | 结束导览 | 清掉标记、浮条和 quickfix |

## 命令

```vim
:PiTour load /tmp/pi-tours/<slug>.json   " 载入（或 :PiTour load 后 Tab 补全）
:PiTour list                             " 选择器：切换已渲染过的 tour
:PiTour check [path]                     " 体检 spec：anchor 还能不能命中（结果进 loclist）
:PiTour rm <path>                        " 删除一份 spec + 同名 html（弹确认）
:PiTour! rm <path>                       " 同上但跳过确认（无 UI 时只能用这个）
:PiTour next | prev | goto <n>            " 步进
:PiTour pick                             " 当前 tour 的站点列表
:PiTour reload                            " 重载最后载入的 spec
:PiTour stop                              " 结束
:PiTour status                            " 当前站 / 总站数
```

## 清理 spec

- 列表里：`<leader>To` 选中目标后按 **`<C-d>`** → 弹确认 → 删掉 `<slug>.json` 和同目录同名的 `<slug>.html`，然后自动重新拉列表，可以连着清好几份
- 命令行：`:PiTour rm <path>`（同样带确认）、`:PiTour! rm <path>`（跳过确认；headless / 无 UI 时唯一可用）
- 删的正是当前活跃那份时，导览会自动 `stop()`，不会留下指向已删文件的残留标记
- 只删**同目录同名**的 `.html`。如果你用 `--out` 把 HTML 输出到了别处（如 `out/` 或仓内 `docs/tours/`），那份要自己删——插件无法推断你的输出路径

## 体检：`:PiTour check`

不传参数就查 `spec_dirs` 里全部 spec，传路径只查一份。结果写进当前窗口的 **location list**（`:lopen`，Enter 跳转），**不碰**导览自己的 quickfix，所以可以在导览进行中随时跑。

| 级别 | 含义 | 怎么处理 |
|---|---|---|
| `E` 锚点失效 | 首行原文在文件里找不到了，`resolve_lnum` 会静默退回 spec 里写的行号 | 导览看起来正常但高亮指错，改 anchor 或重做这份 spec |
| `E` 没有 anchor | 代码一改行号就失准 | 补 anchor |
| `E` 文件不存在 | 文件被改名/移动/删除 | 改 `file` 路径 |
| `W` 行号漂移 | 锚点命中，但落在与 spec 不同的行（已被自动修正） | 不用管，看情况回写 spec |
| `W` range 超界 | `end` 超过文件实际行数 | 把 `end` 改小 |

## 在新机器上安装

```bash
# 1) 开发副本放 ~/src（也就是原始仓库）
git clone git@github.com:evander-wang/pi-tours.git ~/src/pi-tours

# 2) 给 nvim 一个稳定路径（插件声明里的 dir 与本文示例都指向它）
ln -s ~/src/pi-tours ~/.pi/agent/tours

# 3) 让 Neovim 启动时加载插件（symlink 或 cp 都行）
mkdir -p ~/.config/nvim/lua/plugins
ln -s ~/.pi/agent/tours/nvim/pi-tour.lua ~/.config/nvim/lua/plugins/pi-tour.lua

# 4) spec 目录（agent 会往这里写；也可 --out 到别处长期留档）
mkdir -p /tmp/pi-tours
```

前置的 code-tour skill 按上一节自己挂。验一下：重启 nvim 后 `:PiTour status` 不报错、`<leader>To` 能弹选择器；`node ~/.pi/agent/tours/render.mjs <spec.json> --open` 能出 HTML。

## 开发循环

三样东西都是 symlink 指向开发副本，改完即时生效（nvim 重开一下、`node` 重新跑一遍即可），不需要任何“发布”步骤：

| 改什么 | 生效方式 |
|---|---|
| `nvim/lua/pi_tour/init.lua` | 重开 nvim |
| `render.mjs` | 下次 `node` |
| `skills/code-tour/SKILL.md` | 下次 Pi 会话（skill 在会话启动时加载） |

## 用法

```bash
# 1) 写 spec（由 agent 或你手写），默认放 /tmp/pi-tours/
# 2) 渲染到 Neovim
vim -c 'lua require("pi_tour").load("/tmp/pi-tours/xxx.json")'
#    或已在 nvim 里：:PiTour load /tmp/pi-tours/xxx.json
# 3) 渲染成 HTML 代码地图
node ~/.pi/agent/tours/render.mjs /tmp/pi-tours/xxx.json --open
node ~/.pi/agent/tours/render.mjs /tmp/pi-tours/xxx.json --out ~/.pi/agent/tours/out/xxx.html
```

## spec 格式

```json
{
  "repo": "/abs/path/to/repo",
  "name": "显示名（:PiTour list / quickfix 标题用它；也接受 title）",
  "steps": [
    {
      "file": "src/tasking/runtime.ts",
      "start": 96,
      "end": 118,
      "layer": "service",
      "title": "start() 只做三件事",
      "why": "为什么从上一站走到这里，或这段代码的关键约束",
      "anchor": "  public async start(opts: StartOpts) {"
    }
  ],
  "edges": [{ "from": "s1", "to": "s2", "label": "可选" }]
}
```

- `start` / `end` 是 1-based（也接受 `line` / `from` 与 `end` / `to` 这些早期写法；写错字段名不会报错，只会静默退到第 1 行，所以用 `:PiTour check` 验）
- `layer` 只从固定词表里挑，它决定 HTML 地图的横向深度：`entry / ui / api / service / domain / data / infra / client / config / test / code`
- `anchor` 必填：该范围首行的原文。代码改动后 nvim 和 HTML 都靠它重新定位，不写的话 spec 用一次就废
- 单站 5～40 行为宜

## 配置

```lua
require("pi_tour").setup({
  spec_dirs = { "/tmp/pi-tours", vim.fn.expand("~/tours") }, -- :PiTour list 扫描的目录
  keys = { list = "<leader>To", next = "]T" },              -- 全部键位可覆盖
})
```

## 多份 tour 的关系

spec 文件和 HTML 可以并存无数份，但 Neovim 里**同一时刻只有一份活跃导览**：`load` 第二份会替换第一份（标记、浮条、quickfix 全部重建），这是刻意的——两套编号叠在同一批行上只会更难读。切回去用 `:PiTour list` / `<leader>To`，不用记路径。

`/tmp/pi-tours` 会被系统清理；要留档就 `--out` 到仓内（如 `docs/tours/x.html`）或 `out/` 并提交。

## 已知行为

- 目标文件存在残留 `.swp`（上次崩溃或另一个 nvim 实例）时，载入期间临时给 `shortmess` 加 `A` 抑制 `E325: ATTENTION`，不打断导览；真读不出来的文件会记入 missing 并跳过该站
- spec 里没有 `name`/`title` 时，`:PiTour list` 用「第一站标题 + repo 名」区分不同 tour
- anchor 命中但行号不同时，整段 range 会跟着平移同样行数（站的长度不会因漂移缩水）
- `/tmp` 下的 spec 会被系统清理（macOS `com.apple.tmp_cleaner`：atime/mtime/ctime 全部超 3 天的普通文件每天 00:00 删一次）。`:PiTour list` 会读每份 spec，等于顺手刷新 atime；要长期留档就 `--out` 到仓内或 `out/`

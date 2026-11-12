# Changelog

本仓库有两类变更：**代码**（插件 / CLI / skill）和 **spec**（`/tmp/pi-tours/*.json` 里的 tour 定义）。
spec 不在本仓库里，但它决定导览指到哪几行，指错比代码 bug 更难发现，所以 spec 的行号改写也在这里记账。

格式参考 [Keep a Changelog](https://keepachangelog.com/)；spec 相关条目放 `### Specs`，标明文件、站号、改动前后值。

## [Unreleased]

### Specs

**`tool-params-source.json` — `:PiTour sync` 抹平 6 站行号漂移（12 个数字）**

标的仓库 `shared-agent-tools` 在 spec 生成后继续改动（`createAgentTools` 新增 `toolModels` 参数、
调用点换行重排），导致 6 站的行号过时。锚点全部命中，因此由 `:PiTour sync` 自动写回；
导览行为本来正确，改动只让 spec 里记录的行号与现实一致。

| 站 | 文件 | 层级 | start | end |
|---|---|---|---|---|
| 1 | `src/taskWorker.ts` | entry | 240 → **244** | 248 → **252** |
| 2 | `src/tasking/sharedWorkerBindings.ts` | service | 18 → **21** | 24 → **27** |
| 5 | `src/templateVideo/handler.ts` | api | 384 → **385** | 407 → **408** |
| 7 | `src/sharedAgentTools/agent.ts` | api | 30 → **32** | 50 → **52** |
| 8 | `src/sharedAgentTools/index.ts` | service | 704 → **708** | 716 → **720** |
| 9 | `src/sharedAgentTools/index.ts` | domain | 597 → **600** | 611 → **614** |

每站的 `end` 随 `start` 平移同样行数（站点长度不变），未越过文件末尾。
先 `:PiTour sync --dry-run` 预演（sha 校验零写入），再执行写入；仅该文件被改写。

验证：`:PiTour check` 全量 5 份 spec / 72 站 → `E=0 W=0`。
落点抽验：站 1 → `taskWorker.ts:244`、站 2 → `sharedWorkerBindings.ts:21`、站 8 → `sharedAgentTools/index.ts:708`。

### Added

- `:PiTour list` / `<leader>To` —— fzf-lua 选择器切换多份 spec，按 mtime 倒序、当前项带 `▶`、按 `spec.name` 显示
- `:PiTour check [path]` / `<leader>Tc` —— 锚点体检，`E`（锚点失效 / 无 anchor / 文件缺失）与 `W`（行号漂移 / range 超界）进 loclist，不占导览 quickfix
- `:PiTour sync [--dry-run|-n] [path]` / `<leader>Ty` —— 把锚点解出的真实行号写回 spec；失效锚点不猜；只替换数字 token，不重排 JSON
- `:PiTour rm <path>` / `:PiTour! rm <path>` / 列表内 `<C-d>` —— 确认后删 spec + 同名 html
- `render.mjs` —— spec → 自包含 HTML 代码地图；与 nvim 侧共用锚点解析与 range 平移规则
- `README.md` / `CONTRIBUTING.md` —— 快捷键表、spec 格式、清理与体检、依赖边界

### Fixed

- spec 行号字段支持 `start`/`end`（权威写法）与 `line`/`from`/`to`（兼容别名）；此前只认后者，导致行号静默退到第 1 行
- 标题支持 `spec.name`（此前只认 `title`）
- 残留 `.swp` 会让 `bufload` 抛 `E325` 并中断加载：读取期间临时 `shortmess+=A`
- 锚点命中但行号漂移时，range 随首行同步平移（nvim 与 HTML 一致；多处命中取离原行号最近的一处）
- `:PiTour` 补全误把 ArgLead 当子命令名，导致 `load`/`reload`/`check`/`sync`/`rm` 无法补全路径
- `check` 批量模式把目录里的普通 JSON 报成「解析失败」：现在只统计真正的 spec

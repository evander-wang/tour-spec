# CONTRIBUTING

改这个仓库前先读一节：**这个仓库是什么、不是什么**。我在这里走过一次回头路，记下来免得重犯。

## 仓库边界

仓库里是三种独立的东西，各自有各自的投递方式：

| 东西 | 怎么被使用 | 谁负责加载 |
|---|---|---|
| `nvim/lua/pi_tour/init.lua` + `nvim/tour-spec.lua` | Neovim 插件 | nvim（lazy.nvim 读 `~/.config/nvim/lua/plugins/tour-spec.lua`） |
| `render.mjs` | CLI，`node render.mjs spec.json` | 手动调用，无安装 |
| `skills/code-tour/SKILL.md` | agent 的生产约束 | **Pi 的 skill 注册机制**（见下） |

## 依赖边界：文档说明 ≠ skill 注册

`code-tour` 是**文档层面的前置依赖**，不是包依赖，也不是依赖检查项：

- README 里写清楚「生成 spec 靠这个 skill」是**说明关系**；
- 但一句话说明**不会让 Pi 找到它**——skill 要被加载，必须落在 Pi 会扫描的目录里。

所以这两件事要分开做，别用做依赖管理的方式去做说明：

1. **说明**：README「前置依赖」一节（为什么依赖、一条命令挂上、怎么验证）。
2. **注册**：在那台机器上把仓库的 skill 目录挂进 Pi 的 skill 目录（一行 `ln -s`）。

### Pi 到底从哪里加载 skill

Pi 的 skill 来源只有三类（`dist/core/skills.js` 的 `loadSkills()`）：

1. `<agentDir>/skills` —— 本机是 `~/.pi/agent/skills`（用户级）
2. `<cwd>/.pi/skills` —— 项目级
3. **扩展通过 `resources_discover` 事件贡献的 `skillPaths`**

第 3 条就是本机 hermes 记忆扩展的做法：它每次会话启动时返回

```
~/.pi/agent/pi-hermes-memory/skills
~/.pi/agent/projects-memory/<project>/skills
```

（见 `pi-hermes-memory/src/index.ts` 的 `skillPaths` 构造）

所以本仓库的 skill 挂在 `~/.pi/agent/pi-hermes-memory/skills/code-tour`——那条 symlink 指回 `~/src/tour-spec/skills/code-tour`。**这是必须在机器上做的一步，仓库里做不了。**

### 确定性验证（别用 `pi --print` 问模型）

`pi --print "列出你的 skills"` 不可靠：实测默认模型直接回答了 `NONE`，而 skill 其实在。用 SDK 把启动流程跑一遍再读系统提示：

```javascript
import { createAgentSession } from "/Users/wangjichao/.pi/agent/install/releases/1.5.2/node_modules/@earendil-works/pi-coding-agent/dist/index.js";

const { session } = await createAgentSession({ cwd: "/tmp" });
// 这是 Pi 启动时自己会调的那一步（dist/core/agent-session.js: extendResourcesFromExtensions）
await session.extendResourcesFromExtensions("startup");

const names = [...session.systemPrompt.matchAll(/<name>([^<]+)<\/name>/g)].map((m) => m[1]);
console.log("skill 总数:", names.length);          // 本机 ~84
console.log("有 code-tour:", names.includes("code-tour"));
```

不调用 `extendResourcesFromExtensions` 只会看到 78 个（缺扩展贡献的 6 个）——**这个差值是踩过的坑**，别据此判断“skill 没挂上”。

## 为什么不做 `package.json` / `pi install`

曾经加过 `package.json`（`pi.skills`）+ `pi install git:…`，事后撤回。理由是要付三个代价，换来的只是“少写一行 symlink”：

1. **破坏即时生效**：包 checkout 每次 `pi update` 会被 reset 到远端 ref，改 skill 必须 commit + push + update 才生效；symlink 则是改完下次会话就生效。
2. **多一份托管副本**：`~/.pi/agent/git/<host>/<owner>/<repo>` + `settings.json` 多一条记录，排查“到底加载的是哪份”要多跳一层。
3. **同名 collision 风险**：hermes 目录和包各提供一份 `code-tour` 时，Pi 只记 `name "code-tour" collision` 诊断，**谁先被扫到谁胜出**。这种“看起来在、实际用了另一份”的问题最难查。

结论：单人自用 + 需要快速改 skill 的场景，symlink 优于包分发。真要给外部用户装，再单独讨论（那时包机制才值这个代价）。

## 改动约定

- **spec 字段名不许再改**：`start` / `end` 是权威写法（`line` / `from` / `to` 作为兼容别名保留）。改错字段名不会报错，只会静默退到第 1 行——历史上就是这么坑过一次。
- **改行为要同步 README 的表格**：快捷键表、命令表、`:PiTour check` 的级别说明，三处都在 README。
- **anchor 是本仓库最关键的契约**：`resolve_lnum` 找不到 anchor 时会静默退回原行号，所以任何影响定位的改动都要跑 `:PiTour check` 看有没有新增 `E`。
- **`sync` 只改数字、不猜锚点**：`check` 报 `E` 时必须人看着新代码改 anchor；`sync` 遇到失效锚点会跳过并在输出里点名。
- **nvim 与 HTML 必须一致**：`render.mjs` 的 anchor 解析、range 平移要与 `init.lua` 保持一致（同为“多处命中取最近”“首行挪多少尾行挪多少”）。

## 提交前自检

```bash
# 1) 插件能载入、锚点能命中、体检无新增 E
nvim --headless -c 'lua local T=require("pi_tour"); T.setup(); T.load("/tmp/pi-tours/<slug>.json"); T.goto(1); print(T.status().total)' -c 'qa!'

# 2) 全量体检：应只有已知的 W（漂移/超界），E 必须为 0
nvim --headless -c 'lua require("pi_tour").check()' -c 'qa!'

# 2b) 有 W 就写回 spec（锚点失效的站不会被动，得人工改）
nvim --headless -c 'lua require("pi_tour").sync()' -c 'qa!'

# 3) HTML 与 nvim 的站号/行号一致
node render.mjs /tmp/pi-tours/<slug>.json --out /tmp/x.html
```

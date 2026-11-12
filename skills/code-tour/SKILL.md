---
name: "code-tour"
description: "把一段代码的调用链做成「分站导览」而不是一堆零散标记：一份 tour spec（JSON）同时渲染成 Neovim 里可步进的导览（编号 virtual text + quickfix 清单 + 底部 why 浮条）和一张自包含 HTML 代码地图（纵向=调用顺序，横向=调用深度）。当用户说「帮我看懂/梳理这段链路」「把这条调用链标出来」「mark 一下我要看的代码」「我按你的标记去看」「代码地图/调用图」「这段逻辑太绕」「这个功能是怎么走下来的」，或要求解释跨文件的数据流、事件流、请求链路时使用。"
version: 5
created: "2026-11-06"
updated: "2026-11-11"
---
## When to Use
用户要看懂一段跨函数/跨文件的执行路径，需要「按顺序读代码」而不是「跳几个位置」。也适用于给 PR、给同事讲一条主链。不适用于：改某一行代码、单文件小函数解释（直接回答更快）、纯静态架构图（那是 mermaid/architecture 的事）。

## Procedure
1. 先读代码把行号读准：用 read / grep -n 拿到真实的行号区间和每站首行原文，不要凭记忆编行号。
2. 切站：一站 = 一个能独立讲清的动作（一次分派、一次记账、一次刷新），6～14 站。太少讲不清，超过 15 站用户是在读第二份代码。
3. 给每站选 layer，只从固定词表里挑：entry / ui / api / service / domain / data / infra / client / config / test / code。地图的横向深度就是靠它，乱填就没有「立体」效果。
4. 写 why：只回答「为什么从上一站走到这里」或用一句话点出这段代码的关键约束（例如「并行工具全部结束才恢复计时，否则瞬时速率会被静默期污染」）。不要复述代码。
5. 每站必填 anchor：该范围首行的原文（不含行号前缀，保留缩进）。代码改动后 nvim 和 HTML 都靠它重新定位，这是 spec 不会「用一次就废」的关键。
6. 写 spec 到 /tmp/pi-tours/<slug>.json，spec.repo 填仓库绝对路径，file 用仓库相对路径；行号字段写 start / end（1-based），spec.name 写显示名（:PiTour list 里好认，不写就退到第一站标题）。
7. 落盘后先跑 :PiTour check（或 nvim --headless 调 require('pi_tour').check()）验一遍 anchor 能不能命中，再交付——锚点失效不会报错，只会让高亮静默指错行。
8. 渲染到 Neovim：用 nvim_vim_exec_lua 调 require('pi_tour').load('/tmp/pi-tours/<slug>.json')；插件目录为 ~/.pi/agent/tour-spec/nvim。若 nvim 启动时已加载插件，等价命令是 :PiTour load <path>。
9. 渲染成 HTML 地图：node ~/.pi/agent/tour-spec/render.mjs /tmp/pi-tours/<slug>.json --open（--out 可指定输出路径）。
10. 交付时只说三件事：怎么走（]T / [T，<leader>Tt 看全部站点）、怎么停（<leader>Ts）、HTML 在哪。不要复述整条链——用户就是要自己看。
## Pitfalls
- 行号会漂：不写 anchor 的 spec 在用户改动代码后就变成一堆错位的高亮，必填。
- 行号字段是 start / end，不是 line——写错字段名不会报错，只会静默退到第 1 行，靠 anchor 勉强救回来；所以交付前必跑 :PiTour check。
- range 别贪大：单站 5～40 行为宜，整文件高亮等于没标重点。
- 别把 layer 当目录名：entry/api/service/data 是「调用深度」，不是文件所在文件夹。
- exec_lua 里不要拼大段 JSON：中文标题、引号、反斜杠会被转义吃掉。永远先落盘成文件，Lua 里只传路径。
- /tmp/pi-tours 会被系统清理（macOS 每天 00:00 删 3 天没被访问过的普通文件）：要长期留档就 --out 到仓内（如 docs/tours/x.html）并提交。
- HTML 与 nvim 用的是同一份 spec：改一处两边一起变，别手改生成的 HTML。
- 多份 spec 可以并存于磁盘，但 nvim 里同一时刻只有一份活跃导览：load 第二份会替换第一份。切回去用 :PiTour list（<leader>To）或 :PiTour load <path>，不要指望两份编号同时叠着。
## Verification
1. nvim 侧：:PiTour status 返回 current=1 / total=N；底部出现 why 浮条；:copen 里有 N 条带说明的条目；走到最后一站提示「已经是最后一站」。
2. HTML 侧：node 打印出输出路径，浏览器打开后右栏每个代码块的 range 与 spec 一致，点地图节点右栏会滚到对应片段。
3. 一致性：同一站的 nvim 行号与 HTML 行号相同（说明 anchor 解析没有跑偏）。
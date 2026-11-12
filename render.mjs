#!/usr/bin/env node
/**
 * render.mjs — tour spec → 一张能「一眼看全」的代码地图（自包含单文件 HTML）
 *
 * 用法：
 *   node ~/.pi/agent/tour-spec/render.mjs /tmp/pi-tours/xxx.json [--out /tmp/x.html] [--open]
 *
 * 地图怎么读：
 *   纵向 = 调用链顺序（从上往下就是执行流）
 *   横向 = 调用深度（entry 在最左，dao/infra 往右）→ 链往回折时会看出「回到上层」的拐点
 *   左栏悬停/点击任意节点，右栏跳到对应的真实代码片段
 *   键盘 ← → 或 ↑ ↓ 逐站走，f 切换「只看当前」
 *
 * 无依赖。输出 HTML 里已经内联了代码与样式，可以随便拷给别人。
 */

import fs from "node:fs";
import path from "node:path";
import { execFile } from "node:child_process";

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------

const argv = process.argv.slice(2);
const specPath = argv.find((a) => !a.startsWith("--"));
const outIdx = argv.indexOf("--out");
const outPath = outIdx >= 0 ? argv[outIdx + 1] : null;
const shouldOpen = argv.includes("--open");

if (!specPath) {
  console.error("用法: node render.mjs <spec.json> [--out out.html] [--open]");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// spec
// ---------------------------------------------------------------------------

const raw = fs.readFileSync(specPath, "utf8");
let spec;
try {
  spec = JSON.parse(raw);
} catch (err) {
  console.error(`spec 不是合法 JSON: ${specPath}\n${err.message}`);
  process.exit(1);
}

const repo = path.resolve(spec.repo || process.cwd());

const LAYER_ORDER = ["entry", "ui", "api", "service", "domain", "data", "infra", "client", "config", "test", "code"];
const LAYER_COLORS = {
  entry: "#89b4fa",
  ui: "#89dceb",
  api: "#74c7ec",
  service: "#a6e3a1",
  domain: "#f9e2af",
  data: "#f5c2c7",
  infra: "#fab387",
  client: "#cba6f7",
  config: "#94e2d5",
  test: "#b4befe",
  code: "#9399b2",
};
const FALLBACK_COLORS = ["#89b4fa", "#a6e3a1", "#f9e2af", "#f5c2c7", "#cba6f7", "#fab387"];

const layerColor = (layer) => LAYER_COLORS[layer] || FALLBACK_COLORS[hash(layer) % FALLBACK_COLORS.length];

function hash(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h;
}

const steps = (spec.steps || []).map((s, i) => {
  const rel = s.file || "";
  const abs = path.isAbsolute(rel) ? rel : path.join(repo, rel);
  let lines = [];
  try {
    lines = fs.readFileSync(abs, "utf8").split("\n");
  } catch {
    lines = [];
  }
  let start = Number(s.start || s.line || s.from || 1);
  let end = Number(s.end || s.to || start);
  const span = Math.max(0, end - start);
  if (s.anchor && lines.length) {
    const a = String(s.anchor).trim();
    // 和 nvim 侧 resolve_lnum 一致：多处命中时取离原行号最近的那一处
    if (lines[start - 1]?.trim() !== a) {
      let best = -1;
      let bestD = 0;
      lines.forEach((l, k) => {
        if (l.trim() === a) {
          const d = Math.abs(k + 1 - start);
          if (best < 0 || d < bestD) {
            best = k + 1;
            bestD = d;
          }
        }
      });
      if (best > 0) start = best;
    }
  }
  start = Math.max(1, Math.min(start, Math.max(lines.length, 1)));
  // 首行被 anchor 挪了多少，尾行就跟着挪多少：站的长度不因漂移缩水
  end = Math.max(start, Math.min(Math.max(lines.length, start), start + span));
  return {
    seq: i + 1,
    id: s.id || `s${i + 1}`,
    layer: (s.layer || "code").toLowerCase(),
    kind: s.kind === "side" ? "side" : "main",
    file: rel,
    abs,
    start,
    end,
    title: s.title || "",
    why: s.why || "",
    anchor: s.anchor || "",
    code: lines.length ? lines.slice(start - 1, end).map((l, k) => ({ n: start + k, text: l })) : [],
    missing: lines.length === 0,
  };
});

if (!steps.length) {
  console.error("spec 里没有 steps");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// 地图布局：纵向 = 链序号，横向 = 层深度
// ---------------------------------------------------------------------------

const presentLayers = [...new Set(steps.map((s) => s.layer))];
const orderedLayers = [
  ...LAYER_ORDER.filter((l) => presentLayers.includes(l)),
  ...presentLayers.filter((l) => !LAYER_ORDER.includes(l)),
];
const depthOf = new Map(orderedLayers.map((l, i) => [l, i]));
const maxDepth = Math.max(0, orderedLayers.length - 1);

const NODE_W = 246;
const ROW_H = 100;
const NODE_H = 78;
const MAP_PAD_TOP = 48;
// 深度步长：列宽有限时压缩，保证节点不会整块飞出可视区
const DEPTH_W = maxDepth === 0 ? 0 : Math.min(54, Math.round(150 / maxDepth));
const mapW = NODE_W + maxDepth * DEPTH_W + 12;
const mapH = MAP_PAD_TOP + steps.length * ROW_H + 8;

const posOf = (s) => ({
  x: (depthOf.get(s.layer) || 0) * DEPTH_W,
  y: MAP_PAD_TOP + (s.seq - 1) * ROW_H,
});

const byId = new Map(steps.map((s) => [s.id, s]));
const edges = (spec.edges && spec.edges.length
  ? spec.edges.map((e) => ({ from: byId.get(e.from), to: byId.get(e.to), label: e.label || "" }))
  : steps.slice(1).map((s, i) => ({ from: steps[i], to: s, label: "" }))
).filter((e) => e.from && e.to);

function edgePath(a, b) {
  const pa = posOf(a);
  const pb = posOf(b);
  const x1 = pa.x + NODE_W / 2;
  const y1 = pa.y + NODE_H;
  const x2 = pb.x + NODE_W / 2;
  const y2 = pb.y;
  const dy = Math.max(18, (y2 - y1) / 2 + 8);
  return { d: `M${x1},${y1} C${x1},${y1 + dy} ${x2},${y2 - dy} ${x2},${y2}`, mid: [(x1 + x2) / 2, (y1 + y2) / 2] };
}

const edgeSvg = edges
  .map((e, i) => {
    const { d, mid } = edgePath(e.from, e.to);
    const dash = e.to.kind === "side" ? ' stroke-dasharray="5 5"' : "";
    const label = e.label
      ? `<text class="elabel" x="${mid[0] + 9}" y="${mid[1] + 3}" text-anchor="start">${esc(e.label)}</text>`
      : "";
    return `<path class="edge${e.to.kind === "side" ? " side" : ""}" d="${d}" marker-end="url(#arrow${e.to.kind === "side" ? "Side" : ""})"${dash} data-edge="${i}"/>${label}`;
  })
  .join("\n      ");

const laneHtml = orderedLayers
  .map((layer, i) => {
    const left = i * DEPTH_W + 12;
    const c = layerColor(layer);
    const showText = DEPTH_W >= 42;
    return `<div class="lane" style="left:${left}px;color:${c}" title="${esc(layer)}">${showText ? `<span>${esc(layer)}</span>` : ""}</div>`;
  })
  .join("\n    ");

const nodeHtml = steps
  .map((s) => {
    const p = posOf(s);
    const c = layerColor(s.layer);
    return `<div class="node${s.kind === "side" ? " side" : ""}" data-seq="${s.seq}" tabindex="0"
      style="left:${p.x}px;top:${p.y}px;color:${c}">
      <div class="nhdr">
        <span class="badge">${s.seq}</span>
        <span class="lchip">${esc(s.layer)}</span>
        <span class="npath">${esc(path.basename(s.file))}:${s.start}</span>
      </div>
      <div class="ntitle">${esc(s.title)}</div>
    </div>`;
  })
  .join("\n    ");

// ---------------------------------------------------------------------------
// 代码切片
// ---------------------------------------------------------------------------

const EXT_KW = {
  ts: "abstract as async await break case catch class const continue declare default do else enum export extends false finally for from function if implements import in instanceof interface keyof let new null of private protected public readonly return satisfies static super switch this throw true try type typeof undefined var void while with yield",
  tsx: "",
  js: "async await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while with yield",
  ts_: "",
  py: "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield",
  go: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false",
  java: "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null",
  rs: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while",
  lua: "and break do else elseif end false for function goto if in local nil not or repeat return then true until while",
  sh: "case do done elif else esac fi for function if in select then until while",
  rb: "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield",
  yaml: "true false null",
  json: "true false null",
  sql: "select from where join left right inner outer on group by order having limit offset insert into values update set delete create table alter add column index primary key foreign references not null default as and or distinct union all case when then else end",
};
const COMMENT_PREFIX = { py: "#", rb: "#", sh: "#", yaml: "#", toml: "#", conf: "#" };

const extOf = (file) => {
  const e = path.extname(file).toLowerCase().replace(".", "");
  return EXT_KW[e] !== undefined ? e : e.slice(0, 2) || "";
};

function esc(s) {
  return String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function highlight(text, ext) {
  const kw = new Set((EXT_KW[ext] ?? EXT_KW.ts).split(/\s+/).filter(Boolean));
  const hashComment = COMMENT_PREFIX[ext] !== undefined;
  const commentAlt = hashComment ? "#[^\\n]*|" : "";
  const re = new RegExp(
    `(${commentAlt}\\/\\/[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/)|('(?:\\\\.|[^'\\\\])*'|"(?:\\\\.|[^"\\\\])*"|\`(?:\\\\.|[^\`\\\\])*\`)|(\\b\\d+(?:\\.\\d+)?\\b)|([A-Za-z_$][\\w$]*)(?=\\s*\\()|([A-Za-z_$][\\w$]*)`,
    "g",
  );
  let out = "";
  let last = 0;
  let m;
  while ((m = re.exec(text))) {
    out += esc(text.slice(last, m.index));
    const [all, comment, str, num, fn, ident] = m;
    if (comment) out += `<span class="c">${esc(all)}</span>`;
    else if (str) out += `<span class="s">${esc(all)}</span>`;
    else if (num) out += `<span class="n">${esc(all)}</span>`;
    else if (fn) out += kw.has(fn) ? `<span class="k">${esc(all)}</span>` : `<span class="f">${esc(all)}</span>`;
    else if (ident) {
      if (kw.has(ident)) out += `<span class="k">${esc(all)}</span>`;
      else if (/^[A-Z]/.test(ident) && ident.length > 1) out += `<span class="t">${esc(all)}</span>`;
      else out += esc(all);
    } else out += esc(all);
    last = m.index + all.length;
    if (all.length === 0) re.lastIndex++;
  }
  out += esc(text.slice(last));
  return out;
}

const sliceHtml = steps
  .map((s) => {
    const ext = extOf(s.file);
    const codeLines = s.missing
      ? `<div class="ln"><span class="no">!</span><span class="src">读不到文件: ${esc(s.abs)}</span></div>`
      : s.code
          .map(
            (l) =>
              `<div class="ln${l.n === s.start ? " first" : ""}"><span class="no">${l.n}</span><span class="src">${highlight(l.text, ext) || " "}</span></div>`,
          )
          .join("");

    return `<article class="slice" data-seq="${s.seq}" id="s-${s.seq}">
      <header class="shead">
        <span class="badge">${s.seq}</span>
        <div class="stitles">
          <div class="stitle">${esc(s.title)}</div>
          <div class="spath"><span class="chip-sm">${esc(s.layer)}</span> ${esc(s.file)} · ${s.start}–${s.end}</div>
        </div>
        <button class="copy" data-copy="${esc(s.file)}:${s.start}" title="复制 file:line">copy</button>
      </header>
      ${s.why ? `<div class="swhy"><span class="bar" style="background:${layerColor(s.layer)}"></span>${esc(s.why)}</div>` : ""}
      <pre class="code">${codeLines}</pre>
    </article>`;
  })
  .join("\n");

// ---------------------------------------------------------------------------
// 页面
// ---------------------------------------------------------------------------

const total = steps.length;
const title = spec.title || spec.name || path.basename(specPath, ".json");
const repoName = path.basename(repo);
const generated = new Date().toISOString().slice(0, 16).replace("T", " ");

const clientJs = String.raw`
(function () {
  var nodes = Array.prototype.slice.call(document.querySelectorAll('.node'));
  var slices = Array.prototype.slice.call(document.querySelectorAll('.slice'));
  var whyText = document.getElementById('why-text');
  var whyTitle = document.getElementById('why-title');
  var whyPath = document.getElementById('why-path');
  var whyChip = document.getElementById('why-chip');
  var counter = document.getElementById('cur');
  var progress = document.getElementById('progress-fill');
  var total = slices.length;
  var cur = 0;

  function setActive(seq, scrollCode) {
    cur = seq;
    nodes.forEach(function (n) {
      var on = Number(n.dataset.seq) === seq;
      n.classList.toggle('active', on);
      if (on) n.scrollIntoView({ block: 'nearest' });
    });
    slices.forEach(function (s) {
      var on = Number(s.dataset.seq) === seq;
      s.classList.toggle('active', on);
      if (on && scrollCode) s.scrollIntoView({ behavior: 'smooth', block: 'start' });
      if (on) {
        whyText.textContent = s.dataset.why || '';
        whyTitle.textContent = s.dataset.title || '';
        whyPath.textContent = s.dataset.path || '';
        whyChip.textContent = s.dataset.layer || '';
        whyChip.style.color = s.dataset.color || '';
        whyChip.style.borderColor = (s.dataset.color || '#888') + '55';
      }
    });
    counter.textContent = seq;
    progress.style.width = (seq / total) * 100 + '%';
  }

  nodes.forEach(function (n) {
    var seq = Number(n.dataset.seq);
    n.addEventListener('click', function () { setActive(seq, true); });
    n.addEventListener('mouseenter', function () {
      var s = document.querySelector('.slice[data-seq="' + seq + '"]');
      if (!s) return;
      whyText.textContent = s.dataset.why || '';
      whyTitle.textContent = s.dataset.title || '';
      whyPath.textContent = s.dataset.path || '';
      whyChip.textContent = s.dataset.layer || '';
      whyChip.style.color = s.dataset.color || '';
    });
    n.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setActive(seq, true); }
    });
  });

  slices.forEach(function (s) {
    var seq = Number(s.dataset.seq);
    var head = s.querySelector('.shead');
    head.addEventListener('click', function (e) {
      if (e.target.closest('.copy')) return;
      setActive(seq, false);
    });
    var cp = s.querySelector('.copy');
    if (cp) cp.addEventListener('click', function (e) {
      e.stopPropagation();
      var text = cp.dataset.copy;
      var done = function () { cp.textContent = 'ok'; setTimeout(function () { cp.textContent = 'copy'; }, 900); };
      if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, done);
      else { window.prompt('复制:', text); }
    });
  });

  document.addEventListener('keydown', function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown' || e.key === 'j') {
      e.preventDefault();
      setActive(Math.min(total, cur + 1), true);
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp' || e.key === 'k') {
      e.preventDefault();
      setActive(Math.max(1, cur - 1), true);
    } else if (e.key === 'f') {
      document.body.classList.toggle('focus');
    }
  });

  var focusBtn = document.getElementById('focus-btn');
  if (focusBtn) focusBtn.addEventListener('click', function () { document.body.classList.toggle('focus'); });

  setActive(1, false);

  // 代码行点击 → 复制 file:line（和 nvim 里 :e 对齐）
  slices.forEach(function (s) {
    s.querySelectorAll('.ln').forEach(function (ln) {
      ln.addEventListener('click', function () {
        var no = ln.querySelector('.no').textContent;
        var file = s.dataset.path.split(':')[0];
        var text = file + ':' + no;
        if (navigator.clipboard) navigator.clipboard.writeText(text);
      });
    });
  });
})();
`;

const css = String.raw`
:root {
  --bg: #11111b;
  --panel: #181825;
  --panel2: #1e1e2e;
  --line: #2a2a3c;
  --fg: #cdd6f4;
  --dim: #7f849c;
  --dimmer: #585b70;
  --accent: #89b4fa;
}
* { box-sizing: border-box; }
html, body { height: 100%; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 13px/1.55 -apple-system, "SF Pro Text", "PingFang SC", "Helvetica Neue", Arial, sans-serif;
  display: flex; flex-direction: column; overflow: hidden;
}
header.top {
  display: flex; align-items: flex-end; gap: 22px;
  padding: 16px 22px 14px; border-bottom: 1px solid var(--line); background: var(--panel);
}
.eyebrow { font-size: 10px; letter-spacing: .18em; color: var(--dimmer); text-transform: uppercase; }
h1 { font-size: 17px; font-weight: 600; margin: 4px 0 3px; letter-spacing: -.01em; }
.meta { font-size: 11.5px; color: var(--dim); font-variant-numeric: tabular-nums; }
.top-right { margin-left: auto; display: flex; align-items: center; gap: 14px; }
.counter { font: 600 13px/1 ui-monospace, "SF Mono", Menlo, monospace; color: var(--dim); }
.counter b { color: var(--fg); font-size: 17px; }
#focus-btn {
  background: var(--panel2); color: var(--dim); border: 1px solid var(--line);
  border-radius: 6px; padding: 5px 10px; font-size: 11.5px; cursor: pointer;
}
#focus-btn:hover { color: var(--fg); border-color: var(--dimmer); }
.progress { position: fixed; left: 0; right: 0; top: 0; height: 2px; background: transparent; z-index: 20; }
#progress-fill { height: 2px; width: 0; background: var(--accent); transition: width .22s ease; }

main { flex: 1; display: flex; min-height: 0; }

/* ---------------- 地图 ---------------- */
.map-pane {
  width: 400px; flex: 0 0 400px; min-width: 0;
  border-right: 1px solid var(--line); background: var(--panel);
  display: flex; flex-direction: column;
}
.map-scroll { flex: 1; overflow: auto; padding: 0 14px 20px; }
.map-inner { position: relative; margin: 0 auto; }
.map-inner svg.edges { position: absolute; inset: 0; overflow: visible; pointer-events: none; }
.edge { fill: none; stroke: #313244; stroke-width: 1.4; }
.edge.side { stroke: #45475a; }
.elabel {
  font: 9.5px ui-monospace, Menlo, monospace; fill: #6c7086;
  paint-order: stroke; stroke: #181825; stroke-width: 3px; stroke-linejoin: round;
}

.lane { position: absolute; top: 0; bottom: 0; width: 1px; background: linear-gradient(#ffffff10, #ffffff00 60%); }
.lane span {
  position: absolute; top: 2px; left: 3px; font: 9.5px/1 ui-monospace, Menlo, monospace;
  letter-spacing: .12em; text-transform: uppercase; opacity: .7; white-space: nowrap;
  writing-mode: vertical-rl; text-orientation: mixed;
}

.node {
  position: absolute; width: 246px; height: 78px; padding: 9px 11px 8px 12px;
  background: var(--panel2); border: 1px solid var(--line); border-left: 3px solid currentColor;
  border-radius: 8px; cursor: pointer; transition: border-color .15s, background .15s, transform .15s;
  overflow: hidden;
}
.node:hover { background: #222235; }
.node.active {
  background: #232338; border-color: currentColor;
  box-shadow: 0 0 0 1px currentColor33, 0 6px 18px #0006;
  transform: translateX(2px);
}
.node.side { border-style: dashed; opacity: .82; }
.badge {
  display: inline-flex; align-items: center; justify-content: center;
  min-width: 18px; height: 18px; padding: 0 4px; border-radius: 5px;
  background: #ffffff0f; color: currentColor;
  font: 600 11px/1 ui-monospace, Menlo, monospace;
}
.lchip {
  margin-left: 6px; font: 9.5px/1 ui-monospace, Menlo, monospace;
  letter-spacing: .07em; text-transform: uppercase; opacity: .8;
}
.chip-sm { padding: 1px 4px; border: 1px solid currentColor; border-radius: 4px; text-transform: uppercase; letter-spacing: .06em; color: var(--dim); }
.nhdr { display: flex; align-items: center; gap: 6px; }
.nhdr .npath { margin-left: auto; }
.ntitle {
  margin-top: 6px; font-size: 12.5px; font-weight: 550; color: var(--fg); line-height: 1.35;
  display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
}
.npath { font: 10px/1.3 ui-monospace, Menlo, monospace; color: var(--dimmer); white-space: nowrap; }

.inspector { border-top: 1px solid var(--line); padding: 11px 16px 12px; background: #14141f; }
.insp-head { display: flex; align-items: center; gap: 8px; margin-bottom: 3px; }
#why-title { font-weight: 600; font-size: 12.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
#why-chip { flex: 0 0 auto; font: 9.5px/1 ui-monospace, Menlo, monospace; padding: 2px 5px; border: 1px solid; border-radius: 4px; text-transform: uppercase; letter-spacing: .06em; }
#why-path { font: 10px/1.5 ui-monospace, Menlo, monospace; color: var(--dimmer); }
#why-text { font-size: 12px; color: #a6adc8; margin-top: 6px; }
.hint { margin-top: 9px; font-size: 10.5px; color: var(--dimmer); }
kbd { font: 10px/1 ui-monospace, Menlo, monospace; background: #ffffff10; border: 1px solid var(--line); border-radius: 3px; padding: 1px 4px; }

/* ---------------- 代码 ---------------- */
.code-pane { flex: 1; overflow: auto; padding: 18px 22px 40vh; scroll-behavior: smooth; }
.slice { border: 1px solid var(--line); border-radius: 10px; margin-bottom: 16px; background: var(--panel); overflow: hidden; transition: border-color .15s; }
.slice.active { border-color: #45475a; box-shadow: 0 4px 22px #0005; }
.shead { display: flex; align-items: center; gap: 10px; padding: 10px 12px; background: var(--panel2); border-bottom: 1px solid var(--line); cursor: pointer; }
.slice .badge { background: #ffffff12; }
.stitles { min-width: 0; }
.stitle { font-weight: 600; font-size: 12.5px; }
.spath { margin-top: 2px; font: 10.5px/1.4 ui-monospace, Menlo, monospace; color: var(--dim); display: flex; align-items: center; gap: 6px; }
.copy { margin-left: auto; background: transparent; color: var(--dimmer); border: 1px solid var(--line); border-radius: 5px; font: 10.5px/1 ui-monospace, Menlo, monospace; padding: 4px 7px; cursor: pointer; opacity: 0; transition: opacity .15s; }
.shead:hover .copy { opacity: 1; }
.copy:hover { color: var(--fg); border-color: var(--dimmer); }
.swhy { padding: 9px 13px; font-size: 12px; color: #a6adc8; background: #14141f; display: flex; gap: 9px; align-items: flex-start; }
.swhy .bar { flex: 0 0 2px; align-self: stretch; border-radius: 2px; opacity: .8; }
pre.code { margin: 0; padding: 8px 0; overflow-x: auto; font: 12px/1.62 ui-monospace, "SF Mono", Menlo, monospace; }
.ln { display: flex; padding: 0 12px; }
.ln:hover { background: #ffffff06; cursor: copy; }
.ln .no { flex: 0 0 44px; text-align: right; padding-right: 14px; color: #45475a; user-select: none; font-variant-numeric: tabular-nums; }
.ln .src { white-space: pre; }
.ln.first { background: #89b4fa0d; }
.k { color: #cba6f7; }
.s { color: #a6e3a1; }
.c { color: #585b70; font-style: italic; }
.n { color: #fab387; }
.f { color: #89b4fa; }
.t { color: #f9e2af; }

body.focus .slice:not(.active) pre.code,
body.focus .slice:not(.active) .swhy { display: none; }
body.focus .slice:not(.active) { opacity: .55; }

@media (max-width: 1080px) {
  main { flex-direction: column; }
  .map-pane { width: auto; flex: 0 0 auto; max-height: 46vh; }
  .code-pane { padding-bottom: 40vh; }
}
`;

const html = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} · code tour</title>
<style>${css}</style>
</head>
<body>
<div class="progress"><div id="progress-fill"></div></div>
<header class="top">
  <div>
    <div class="eyebrow">code tour</div>
    <h1>${esc(title)}</h1>
    <div class="meta">${esc(repoName)} · ${total} 站 · ${esc(spec.subtitle || "")}${spec.subtitle ? " · " : ""}生成于 ${esc(generated)}</div>
  </div>
  <div class="top-right">
    <button id="focus-btn">只看当前 (f)</button>
    <div class="counter"><b id="cur">1</b>/${total}</div>
  </div>
</header>

<main>
  <section class="map-pane">
    <div class="map-scroll">
      <div class="map-inner" style="width:${mapW}px;height:${mapH}px">
        <svg class="edges" width="${mapW}" height="${mapH}" viewBox="0 0 ${mapW} ${mapH}">
          <defs>
            <marker id="arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto">
              <path d="M0,0 L8,4 L0,8 z" fill="#45475a"/>
            </marker>
            <marker id="arrowSide" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto">
              <path d="M0,0 L8,4 L0,8 z" fill="#585b70"/>
            </marker>
          </defs>
          ${edgeSvg}
        </svg>
        ${laneHtml}
        ${nodeHtml}
      </div>
    </div>
    <div class="inspector">
      <div class="insp-head">
        <span id="why-chip"></span>
        <span id="why-title"></span>
      </div>
      <div id="why-path"></div>
      <div id="why-text"></div>
      <div class="hint"><kbd>j</kbd> <kbd>k</kbd> 逐站 · <kbd>f</kbd> 只看当前 · 纵向=调用顺序，横向=调用深度</div>
    </div>
  </section>

  <section class="code-pane">
    ${sliceHtml}
  </section>
</main>

<script>${clientJs}</script>
</body>
</html>
`;

// 给每块 slice 补上交互用的 data-*
const finalHtml = html.replace(
  /<article class="slice" data-seq="(\d+)" id="s-\d+">/g,
  (m0, seq) => {
    const s = steps[Number(seq) - 1];
    return `<article class="slice" data-seq="${seq}" id="s-${seq}" data-title="${esc(s.title)}" data-why="${esc(s.why)}" data-path="${esc(s.file + ":" + s.start)}" data-layer="${esc(s.layer)}" data-color="${layerColor(s.layer)}">`;
  },
);

const out = outPath || path.join(path.dirname(path.resolve(specPath)), `${path.basename(specPath, ".json")}.html`);
fs.writeFileSync(out, finalHtml, "utf8");
console.log(out);

if (shouldOpen) {
  execFile(process.platform === "darwin" ? "open" : "xdg-open", [out], () => {});
}

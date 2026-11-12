--- pi_tour — 把一份 tour spec（JSON）渲染成 Neovim 里「可以走」的链路导览
---
--- 和「让 agent 随手 mark 几行」的区别：
---   * 每一站都有编号 + 层级 + 一句话说明，直接以 virtual text 写在函数上方
---   * quickfix 里是一份带说明的站点清单（:copen 看全貌，]q 逐站走）
---   * 底部浮条永远告诉你 现在第几站 / 为什么走到这里
---   * 走过的站会变暗，不会迷路
---
--- 用法（由 agent 或你自己调用）：
---   require("pi_tour").load("/tmp/pi-tours/xxx.json")
---   :PiTour load /tmp/pi-tours/xxx.json | list | check | sync | rm | next | prev | pick | stop | status
---   (:PiTour! rm <path> = 跳过确认直接删，无 UI 时只能用这个)
---
--- 多份 spec 可以同时存在于磁盘，但同一时刻只有一份「活跃」导览：
---   :PiTour list（<leader>To）列出 spec_dirs 下的所有 spec，选中即切换。
---
--- spec 格式见 ~/.pi/agent/pi-hermes-memory/skills/code-tour/SKILL.md

local M = {}

local ns = vim.api.nvim_create_namespace("pi_tour")

local CIRCLED = {
	"①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩",
	"⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳",
}

local S = {
	spec = nil,
	root = nil,
	steps = {},
	current = 0,
	visited = {},
	line_marks = {},
	float = nil,
	fbuf = nil,
	last_path = nil,
}

local function badge(i)
	return CIRCLED[i] or ("(" .. i .. ")")
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- is_mapped 判断某个键位上是否已经有 normal 模式映射（用于让底部提示只说真能按的键）。
local function is_mapped(lhs)
	return vim.fn.maparg(lhs, "n") ~= ""
end

local function define_hl()
	local function set(name, spec)
		vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, spec))
	end
	set("PiTourBadge", { link = "DiagnosticInfo" })
	set("PiTourTitle", { link = "Title" })
	set("PiTourLayer", { link = "Comment" })
	set("PiTourCurrent", { link = "DiagnosticWarn", bold = true })
	set("PiTourVisited", { link = "Comment" })
	set("PiTourLine", { link = "CursorLine" })
	set("PiTourFloatTitle", { link = "Title", bold = true })
	set("PiTourFloatWhy", { link = "NormalFloat" })
	set("PiTourFloatBar", { link = "DiagnosticInfo" })
	set("PiTourFloatHint", { link = "Comment" })
	set("PiTourFloatMeta", { link = "DiagnosticInfo" })
end

-- ---------------------------------------------------------------------------
-- 定位：文件改动后 spec 里的行号会漂，用 anchor（首行原文）重新校准
-- ---------------------------------------------------------------------------

local function resolve_lnum(lines, lnum, anchor)
	local n = #lines
	lnum = math.max(1, math.min(tonumber(lnum) or 1, math.max(n, 1)))
	if not anchor or anchor == "" then
		return lnum
	end
	local a = trim(anchor)
	if trim(lines[lnum] or "") == a then
		return lnum
	end
	local best, best_d
	for i, line in ipairs(lines) do
		if trim(line) == a then
			local d = math.abs(i - lnum)
			if not best_d or d < best_d then
				best, best_d = i, d
			end
		end
	end
	return best or lnum
end

-- spec 里的起止行有三种写法：start/end（agent 实际产出）、line/from + end/to（早期写法）。
-- 只认一种的话，另一种会静默退到第 1 行——这比报错危险得多。
local function step_span(step)
	local lnum = tonumber(step.start or step.line or step["from"]) or 1
	local endl = tonumber(step["end"] or step["to"]) or lnum
	return lnum, math.max(lnum, endl)
end

local function spec_name(spec, fallback)
	return (spec and (spec.title or spec.name)) or fallback
end

-- ---------------------------------------------------------------------------
-- extmark 渲染
-- ---------------------------------------------------------------------------

local function label_chunks(s, i, hl_title, hl_badge)
	return {
		{ " " .. badge(i) .. " " .. i .. "/" .. #S.steps .. " ", hl_badge },
		{ (s.layer or "code") .. " · ", "PiTourLayer" },
		{ s.title or vim.fn.fnamemodify(s.file, ":t"), hl_title },
	}
end

local function clear_line_marks()
	for _, m in ipairs(S.line_marks) do
		pcall(vim.api.nvim_buf_del_extmark, m.buf, ns, m.id)
	end
	S.line_marks = {}
end

local function paint_step(i)
	local s = S.steps[i]
	if not s or not vim.api.nvim_buf_is_valid(s.buf) then
		return
	end
	local cur = S.current == i
	local visited = S.visited[i]
	local hl_title = cur and "PiTourCurrent" or (visited and "PiTourVisited") or "PiTourTitle"
	local hl_badge = cur and "PiTourCurrent" or (visited and "PiTourVisited") or "PiTourBadge"
	if s.mark then
		pcall(vim.api.nvim_buf_del_extmark, s.buf, ns, s.mark)
	end
	s.mark = vim.api.nvim_buf_set_extmark(s.buf, ns, s.lnum - 1, 0, {
		virt_lines = { label_chunks(s, i, hl_title, hl_badge) },
		virt_lines_above = true,
	})
end

-- ---------------------------------------------------------------------------
-- 底部浮条
-- ---------------------------------------------------------------------------

local function wrap_text(text, width)
	local out, line, w = {}, "", 0
	for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
		local cw = vim.fn.strdisplaywidth(ch)
		if w + cw > width and line ~= "" then
			out[#out + 1] = line
			line, w = "", 0
		end
		line = line .. ch
		w = w + cw
	end
	if line ~= "" then
		out[#out + 1] = line
	end
	return out
end

function M.close_float()
	if S.float and vim.api.nvim_win_is_valid(S.float) then
		pcall(vim.api.nvim_win_close, S.float, true)
	end
	S.float, S.fbuf = nil, nil
end

local function update_float()
	local s = S.steps[S.current]
	if not s then
		M.close_float()
		return
	end

	local width = math.min(96, math.max(34, vim.o.columns - 16))
	local inner = width - 4

	local lines, hl = {}, {}
	local head = string.format(" %d/%d  %s · %s", S.current, #S.steps, s.layer or "code", s.title or "")
	lines[1] = head
	hl[#hl + 1] = { 0, 0, #head, "PiTourFloatTitle" }

	if s.why and s.why ~= "" then
		for _, l in ipairs(wrap_text(s.why, inner)) do
			lines[#lines + 1] = " ▏ " .. l
			hl[#hl + 1] = { #lines - 1, 0, -1, "PiTourFloatWhy" }
			hl[#hl + 1] = { #lines - 1, 1, 2, "PiTourFloatBar" }
		end
	end

	local rel = s.rel or s.file
	local meta = string.format(" %s:%s%s", rel, s.lnum, (s.end_lnum and s.end_lnum ~= s.lnum) and ("-" .. s.end_lnum) or "")
	lines[#lines + 1] = meta
	hl[#hl + 1] = { #lines - 1, 0, -1, "PiTourFloatMeta" }

	-- 双键前缀在 timeoutlen 较短（如 300ms）时很难按出来，因此同时给出单键别名。
	if is_mapped("<F9>") then
		lines[#lines + 1] = " <F9>/]T 下一站   <F10>/[T 上一站   <leader>Tt 站点   <leader>To 换导览"
	else
		lines[#lines + 1] = " ]T 下一站   [T 上一站   <leader>Tt 站点   <leader>To 换导览"
	end
	hl[#hl + 1] = { #lines - 1, 0, -1, "PiTourFloatHint" }

	if not (S.float and vim.api.nvim_win_is_valid(S.float)) then
		S.fbuf = vim.api.nvim_create_buf(false, true)
		vim.bo[S.fbuf].bufhidden = "wipe"
		S.float = vim.api.nvim_open_win(S.fbuf, false, {
			relative = "editor",
			anchor = "SW",
			row = vim.o.lines - 2,
			col = math.floor((vim.o.columns - width) / 2),
			width = width,
			height = #lines,
			style = "minimal",
			border = "rounded",
			title = " pi-tour ",
			title_pos = "center",
			focusable = false,
			noautocmd = true,
			zindex = 60,
		})
	else
		vim.api.nvim_win_set_config(S.float, {
			relative = "editor",
			anchor = "SW",
			row = vim.o.lines - 2,
			col = math.floor((vim.o.columns - width) / 2),
			width = width,
			height = #lines,
		})
	end

	vim.bo[S.fbuf].modifiable = true
	vim.api.nvim_buf_set_lines(S.fbuf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(S.fbuf, -1, 0, -1)
	for _, h in ipairs(hl) do
		pcall(vim.api.nvim_buf_add_highlight, S.fbuf, -1, h[4], h[1], h[2], h[3])
	end
	vim.bo[S.fbuf].modifiable = false
end

M.update_float = update_float

-- ---------------------------------------------------------------------------
-- 导航
-- ---------------------------------------------------------------------------

function M.goto(i, opts)
	opts = opts or {}
	if #S.steps == 0 or not i or i < 1 or i > #S.steps then
		return
	end
	if S.current > 0 and S.current ~= i then
		S.visited[S.current] = true
		paint_step(S.current)
	end

	clear_line_marks()
	S.current = i

	local s = S.steps[i]
	local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
	s.lnum = resolve_lnum(lines, s.lnum, s.anchor)
	s.end_lnum = math.max(s.lnum, math.min(tonumber(s.end_lnum) or s.lnum, math.max(#lines, 1)))

	if not opts.no_jump then
		vim.api.nvim_set_current_buf(s.buf)
		vim.api.nvim_win_set_cursor(0, { s.lnum, 0 })
		pcall(vim.cmd, "normal! zvzz")
	end

	paint_step(i)

	for r = s.lnum - 1, s.end_lnum - 1 do
		local id = vim.api.nvim_buf_set_extmark(s.buf, ns, r, 0, { line_hl_group = "PiTourLine", priority = 30 })
		S.line_marks[#S.line_marks + 1] = { buf = s.buf, id = id }
	end

	update_float()
end

function M.next()
	if S.current == 0 then
		return M.goto(1)
	end
	if S.current >= #S.steps then
		vim.notify("pi-tour: 已经是最后一站", vim.log.levels.INFO)
		return
	end
	M.goto(S.current + 1)
end

function M.prev()
	if S.current <= 1 then
		vim.notify("pi-tour: 已经是第一站", vim.log.levels.INFO)
		return
	end
	M.goto(S.current - 1)
end

function M.pick()
	if #S.steps == 0 then
		vim.notify("pi-tour: 还没有加载 tour", vim.log.levels.WARN)
		return
	end
	local items = {}
	for i, s in ipairs(S.steps) do
		items[#items + 1] = { seq = i, step = s }
	end
	vim.ui.select(items, {
		prompt = string.format("tour · %d 站", #S.steps),
		format_item = function(it)
			local s = it.step
			local mark = (it.seq == S.current) and "▶" or (S.visited[it.seq] and " " or "·")
			return string.format("%s %s %-10s %s  (%s:%d)", mark, badge(it.seq), s.layer or "", s.title or "",
				vim.fn.fnamemodify(s.file, ":t"), s.lnum)
		end,
	}, function(choice)
		if choice then
			M.goto(choice.seq)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- 加载 / 停止
-- ---------------------------------------------------------------------------

local function clear_qf()
	local ok, qf = pcall(vim.fn.getqflist, { title = 1 })
	if ok and qf and type(qf.title) == "string" and qf.title:match("^pi%-tour: ") then
		pcall(vim.fn.setqflist, {}, "r")
	end
end

function M.stop()
	clear_line_marks()
	for _, s in ipairs(S.steps) do
		if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
			pcall(vim.api.nvim_buf_clear_namespace, s.buf, ns, 0, -1)
		end
	end
	M.close_float()
	clear_qf()
	S.steps, S.current, S.visited, S.spec = {}, 0, {}, nil
end

-- 打开文件 buffer 并返回编号；读不出来返回 nil。
-- 残留的 .swp（上次崩溃或另一个 nvim 实例）会让 bufload 抛 E325 / 刷一堆 ATTENTION，
-- 导览会半途中断：读取期间临时加上 shortmess 的 A（不报 ATTENTION），读完还原。
local function open_buf(abs)
	local buf = vim.fn.bufadd(abs)
	if vim.api.nvim_buf_is_loaded(buf) then
		return buf
	end
	local sm = vim.o.shortmess
	local patched = sm:find("A", 1, true) == nil
	if patched then
		vim.o.shortmess = sm .. "A"
	end
	local ok = pcall(vim.fn.bufload, buf)
	if patched then
		vim.o.shortmess = sm
	end
	if not ok and not vim.api.nvim_buf_is_loaded(buf) then
		return nil
	end
	return buf
end

function M.load(path)
	if not path or path == "" then
		vim.notify("pi-tour: 缺少 spec 路径", vim.log.levels.ERROR)
		return
	end
	path = vim.fn.expand(path)
	local ok_read, raw = pcall(vim.fn.readfile, path)
	if not ok_read or not raw or #raw == 0 then
		vim.notify("pi-tour: 读不到 spec: " .. path, vim.log.levels.ERROR)
		return
	end
	local ok_dec, spec = pcall(vim.json.decode, table.concat(raw, "\n"))
	if not ok_dec or type(spec) ~= "table" or type(spec.steps) ~= "table" or #spec.steps == 0 then
		vim.notify("pi-tour: spec 解析失败或没有 steps: " .. path, vim.log.levels.ERROR)
		return
	end

	M.stop()
	define_hl()

	S.spec = spec
	S.last_path = path
	S.root = (spec.repo and spec.repo ~= "" and vim.fn.fnamemodify(spec.repo, ":p")) or vim.fn.getcwd() .. "/"
	S.root = S.root:gsub("/+$", "") .. "/"

	local missing = {}
	for idx, raw_step in ipairs(spec.steps) do
		local rel = raw_step.file or ""
		if rel:sub(1, 1) ~= "/" then
			rel = S.root .. rel
		end
		local abs = vim.fn.fnamemodify(rel, ":p")
		local buf = (vim.fn.filereadable(abs) == 1) and open_buf(abs) or nil
		if buf then
			vim.api.nvim_buf_call(buf, function()
				pcall(vim.cmd, "filetype detect")
			end)
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			local raw_lnum, raw_end = step_span(raw_step)
			local lnum = resolve_lnum(lines, raw_lnum, raw_step.anchor)
			-- anchor 把首行往后推了几行，尾行也跟着推，站的长度不该因漂移缩水
			local end_lnum = math.min(#lines, math.max(lnum, raw_end + (lnum - raw_lnum)))
			S.steps[#S.steps + 1] = {
				buf = buf,
				file = abs,
				rel = (abs:sub(1, #S.root) == S.root) and abs:sub(#S.root + 1) or vim.fn.fnamemodify(abs, ":."),
				lnum = lnum,
				end_lnum = end_lnum,
				layer = raw_step.layer,
				title = raw_step.title,
				why = raw_step.why,
				anchor = raw_step.anchor,
			}
		else
			missing[#missing + 1] = rel
		end
	end

	if #S.steps == 0 then
		vim.notify("pi-tour: 所有文件都不存在\n" .. table.concat(missing, "\n"), vim.log.levels.ERROR)
		return
	end

	-- 站点清单进 quickfix：:copen 看全貌，]q 逐站走
	local qf = {}
	for i, s in ipairs(S.steps) do
		qf[#qf + 1] = {
			filename = s.file,
			lnum = s.lnum,
			end_lnum = s.end_lnum,
			col = 1,
			text = string.format("%d. [%s] %s", i, s.layer or "code", s.title or ""),
		}
	end
	pcall(vim.fn.setqflist, {}, " ", { title = "pi-tour: " .. spec_name(spec, vim.fn.fnamemodify(path, ":t")), items = qf })

	for i = 1, #S.steps do
		paint_step(i)
	end

	vim.notify(
		string.format("pi-tour: %d 站 · %s", #S.steps, spec_name(spec, vim.fn.fnamemodify(path, ":t:r"))),
		vim.log.levels.INFO
	)

	M.goto(1)
end

function M.reload()
	if S.last_path then
		M.load(S.last_path)
	else
		vim.notify("pi-tour: 没有可重载的 spec", vim.log.levels.WARN)
	end
end

function M.status()
	local s = S.steps[S.current]
	return {
		current = S.current,
		total = #S.steps,
		title = S.spec and spec_name(S.spec, nil) or nil,
		file = s and s.rel or nil,
		line = s and s.lnum or nil,
		layer = s and s.layer or nil,
		step = s and s.title or nil,
	}
end

-- ---------------------------------------------------------------------------
-- 多份 spec 的浏览（磁盘上并存，运行时仍只活跃一份）
-- ---------------------------------------------------------------------------

M.config = { spec_dirs = { "/tmp/pi-tours" } }

local function spec_dirs()
	local seen, dirs = {}, {}
	local function add(d)
		if not d or d == "" then
			return
		end
		local abs = vim.fn.fnamemodify(d, ":p"):gsub("/+$", "")
		if not seen[abs] and vim.fn.isdirectory(abs) == 1 then
			seen[abs] = true
			dirs[#dirs + 1] = abs
		end
	end
	for _, d in ipairs(M.config.spec_dirs or {}) do
		add(d)
	end
	-- 当前 tour 可能来自 --out 到仓库里的长期留档，切回去时也要能看到
	if S.last_path and S.last_path ~= "" then
		add(vim.fn.fnamemodify(S.last_path, ":p:h"))
	end
	return dirs
end

-- 按 mtime 倒序：最近生成的那份排最前面，通常就是想切回去的那份
local function spec_files()
	local seen, out = {}, {}
	for _, dir in ipairs(spec_dirs()) do
		for _, p in ipairs(vim.fn.globpath(dir, "*.json", false, true)) do
			local abs = vim.fn.fnamemodify(p, ":p")
			if not seen[abs] then
				seen[abs] = true
				out[#out + 1] = { path = abs, mtime = vim.fn.getftime(abs) }
			end
		end
	end
	table.sort(out, function(a, b)
		if a.mtime ~= b.mtime then
			return a.mtime > b.mtime
		end
		return a.path < b.path
	end)
	return out
end

-- spec 里 title 是可选的（现有 spec 基本都没写），所以退到「第一站标题 + repo 名」，
-- 否则选择器里四份 spec 全都长成同一个 slug。
local function spec_summary(path)
	local fallback = vim.fn.fnamemodify(path, ":t:r")
	local bad = { title = fallback, n = 0, repo = "", broken = true }
	local ok, raw = pcall(vim.fn.readfile, path)
	if not ok or not raw or #raw == 0 then
		return bad
	end
	local ok_dec, spec = pcall(vim.json.decode, table.concat(raw, "\n"))
	if not ok_dec or type(spec) ~= "table" or type(spec.steps) ~= "table" then
		return bad
	end
	local first = type(spec.steps[1]) == "table" and spec.steps[1].title or nil
	return {
		title = spec_name(spec, first) or fallback,
		n = #spec.steps,
		repo = spec.repo and vim.fn.fnamemodify(spec.repo, ":t") or "",
		broken = false,
	}
end

local function clip(s, n)
	s = (s or ""):gsub("%s+", " ")
	if vim.fn.strchars(s) <= n then
		return s
	end
	return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

function M.list()
	local files = spec_files()
	if #files == 0 then
		vim.notify("pi-tour: 没找到 spec（" .. table.concat(spec_dirs(), ", ") .. "/*.json）", vim.log.levels.WARN)
		return
	end

	local by_line, lines = {}, {}
	local current = S.last_path and vim.fn.fnamemodify(S.last_path, ":p") or nil
	for _, f in ipairs(files) do
		local info = spec_summary(f.path)
		local slug = vim.fn.fnamemodify(f.path, ":t:r")
		local mark = (f.path == current) and "▶" or " "
		local age = (f.mtime > 0) and os.date("%m-%d %H:%M", f.mtime) or "--"
		local line = string.format(
			"%s %-28s %2d 站  %s  %-20s  %s%s",
			mark,
			slug,
			info.n,
			age,
			clip(info.repo, 20),
			clip(info.title, 44),
			info.broken and "  [解析失败]" or ""
		)
		if by_line[line] then -- 理论上不会重名，兜底保证选中项可反查
			line = line .. "  #" .. (#lines + 1)
		end
		by_line[line] = f.path
		lines[#lines + 1] = line
	end

	local function open(path)
		if path then
			M.load(path)
		end
	end

	-- 列表里的删除：删完把列表重新拉一遍，方便连着清好几份
	local function remove(path)
		if path and M.delete(path) then
			vim.schedule(function()
				M.list()
			end)
		end
	end

	-- 有 fzf-lua 就用它的选择器，没有就退回 ui.select（LazyVim/Snacks 下同样是浮窗）
	local ok_fzf, fzf = pcall(require, "fzf-lua")
	if ok_fzf and type(fzf) == "table" and type(fzf.fzf_exec) == "function" then
		fzf.fzf_exec(lines, {
			prompt = "tour> ",
			actions = {
				["default"] = function(selected)
					open(by_line[selected and selected[1] or ""])
				end,
				["ctrl-d"] = function(selected)
					remove(by_line[selected and selected[1] or ""])
				end,
			},
		})
		return
	end

	vim.ui.select(lines, { prompt = "pi-tour · 选择导览" }, function(choice)
		open(by_line[choice or ""])
	end)
end

-- ---------------------------------------------------------------------------
-- 体检：anchor 还能不能命中（不能命中的导览看起来正常，但高亮会指错行）
-- ---------------------------------------------------------------------------

local function find_anchor(lines, lnum, anchor)
	local a = trim(anchor)
	local hit, best_d
	for i, line in ipairs(lines) do
		if trim(line) == a then
			local d = math.abs(i - lnum)
			if not best_d or d < best_d then
				hit, best_d = i, d
			end
		end
	end
	return hit
end

--- 检查一份或全部 spec，结果进当前窗口的 location list（不抢导览的 quickfix）
--- @param target? string 指定 spec 路径；不传则体检 spec_dirs 里的全部
function M.check(target)
	local files
	if target and target ~= "" then
		files = { { path = vim.fn.fnamemodify(vim.fn.expand(target), ":p") } }
	else
		files = spec_files()
	end
	if #files == 0 then
		vim.notify("pi-tour check: 没找到 spec（" .. table.concat(spec_dirs(), ", ") .. "/*.json）", vim.log.levels.WARN)
		return
	end

	local items, n_err, n_warn, n_steps, n_files_ok, n_skipped = {}, 0, 0, 0, 0, 0
	local bulk = not (target and target ~= "")

	for _, f in ipairs(files) do
		local slug = vim.fn.fnamemodify(f.path, ":t:r")
		local function add(level, abs, lnum, i, msg)
			if level == "err" then
				n_err = n_err + 1
			else
				n_warn = n_warn + 1
			end
			items[#items + 1] = {
				filename = abs,
				lnum = math.max(1, lnum or 1),
				col = 1,
				type = (level == "err") and "E" or "W",
				text = string.format("[%s] %s%s", slug, i and ("站 " .. i .. " ") or "", msg),
			}
		end

		local ok_read, raw = pcall(vim.fn.readfile, f.path)
		local ok_dec, spec = false, nil
		if ok_read and raw and #raw > 0 then
			ok_dec, spec = pcall(vim.json.decode, table.concat(raw, "\n"))
		end
		if not ok_dec or type(spec) ~= "table" or type(spec.steps) ~= "table" or #spec.steps == 0 then
			if bulk then
				-- 目录里混进来的普通 JSON（不是 spec）不算问题，不然 /tmp 里几十个文件全成了报错
				n_skipped = n_skipped + 1
			else
				add("err", f.path, 1, nil, "spec 读不到或解析失败（没有 steps）")
			end
		else
			local repo = vim.fn.fnamemodify((spec.repo and spec.repo ~= "") and spec.repo or vim.fn.getcwd(), ":p")
			local before = n_err
			for i, st in ipairs(spec.steps) do
				n_steps = n_steps + 1
				local rel = st.file or ""
				local abs = vim.fn.fnamemodify(rel:sub(1, 1) == "/" and rel or (repo .. rel), ":p")
				local lnum, endl = step_span(st)

				if vim.fn.filereadable(abs) == 0 then
					add("err", abs, lnum, i, "文件不存在: " .. rel)
				else
					local lines = vim.fn.readfile(abs)
					local nlines = #lines
					if endl > nlines then
						add("warn", abs, lnum, i, string.format("range 超出文件末尾: %d-%d，文件共 %d 行", lnum, endl, nlines))
					end
					if not st.anchor or st.anchor == "" then
						add("err", abs, lnum, i, "没有 anchor：代码一改行号就失准")
					else
						local hit = find_anchor(lines, lnum, st.anchor)
						if not hit then
							add(
								"err",
								abs,
								lnum,
								i,
								string.format("锚点失效：找不到 %q，只能用原行号 %d（高亮可能指错）", trim(st.anchor), lnum)
							)
						elseif hit ~= lnum then
							add("warn", abs, hit, i, string.format("行号漂移: %d → %d（锚点已命中，导览会自动跟）", lnum, hit))
						end
					end
				end
			end
			if n_err == before then
				n_files_ok = n_files_ok + 1
			end
		end
	end

	local skipped_note = n_skipped > 0 and string.format("，跳过 %d 个非 spec JSON", n_skipped) or ""
	vim.fn.setloclist(0, {}, " ", { title = "pi-tour check", items = items })
	if #items == 0 then
		vim.notify(string.format("pi-tour check: %d 份 spec · %d 站全部可用%s", #files, n_steps, skipped_note), vim.log.levels.INFO)
		return
	end

	pcall(vim.cmd, "silent! lopen")
	vim.notify(
		string.format(
			"pi-tour check: %d/%d 份可用 · %d 站失效 / %d 处漂移（列表已进 loclist，Enter 跳转）%s",
			n_files_ok,
			#files,
			n_err,
			n_warn,
			skipped_note
		),
		n_err > 0 and vim.log.levels.WARN or vim.log.levels.INFO
	)
end

-- ---------------------------------------------------------------------------
-- 同步：把锚点解出来的真实行号写回 spec（源码一改，行号就旧了）
-- ---------------------------------------------------------------------------

-- 只改「一串数字」，不重新编码整个 JSON：spec 是人工可读的、一次一行一字段。
-- 排版不符合预期就拒绝，而不是把文件重排成看不出改了什么的样子。
local function patch_spans(lines, updates)
	local total = #updates
	local n_start, n_end = 0, 0
	for _, l in ipairs(lines) do
		if l:match('^%s*"start":%s*%d+,?%s*$') then
			n_start = n_start + 1
		elseif l:match('^%s*"end":%s*%d+,?%s*$') then
			n_end = n_end + 1
		end
	end
	if n_start ~= total or n_end ~= total then
		return nil,
			string.format("排版不是一行一个字段（start=%d / end=%d / steps=%d），不改写", n_start, n_end, total)
	end

	local changed = {}
	local si, ei = 0, 0
	for i, line in ipairs(lines) do
		local key
		if line:match('^%s*"start":%s*%d+,?%s*$') then
			si = si + 1
			key = "start"
			local want = updates[si].start
			local new = line:gsub('("start":%s*)%d+', "%1" .. want, 1)
			if new ~= line then
				changed[#changed + 1] = { station = si, key = key, before = trim(line), after = trim(new) }
				lines[i] = new
			end
		elseif line:match('^%s*"end":%s*%d+,?%s*$') then
			ei = ei + 1
			key = "end"
			local want = updates[ei]["end"]
			local new = line:gsub('("end":%s*)%d+', "%1" .. want, 1)
			if new ~= line then
				changed[#changed + 1] = { station = ei, key = key, before = trim(line), after = trim(new) }
				lines[i] = new
			end
		end
	end
	return changed
end

--- 把每站锚点解出的真实行号写回 spec。
--- 锚点失效 / 文件缺失 / 没写 anchor 的站一律不动（不猜），单独列出等人改。
--- @param target? string 指定 spec 路径；不传则同步 spec_dirs 里的全部
function M.sync(target)
	local files
	if target and target ~= "" then
		files = { { path = vim.fn.fnamemodify(vim.fn.expand(target), ":p") } }
	else
		files = spec_files()
	end
	if #files == 0 then
		vim.notify("pi-tour sync: 没找到 spec（" .. table.concat(spec_dirs(), ", ") .. "/*.json）", vim.log.levels.WARN)
		return
	end

	local touched, unchanged, total_fixes, problems = 0, 0, 0, {}
	for _, f in ipairs(files) do
		local slug = vim.fn.fnamemodify(f.path, ":t:r")
		local lines = vim.fn.readfile(f.path)
		local ok_dec, spec = false, nil
		if #lines > 0 then
			ok_dec, spec = pcall(vim.json.decode, table.concat(lines, "\n"))
		end
		if not ok_dec or type(spec) ~= "table" or type(spec.steps) ~= "table" or #spec.steps == 0 then
			problems[#problems + 1] = string.format("[%s] spec 解析失败，跳过", slug)
		else
			local repo = vim.fn.fnamemodify((spec.repo and spec.repo ~= "") and spec.repo or vim.fn.getcwd(), ":p")
			local updates = {}
			for i, st in ipairs(spec.steps) do
				local rel = st.file or ""
				local abs = vim.fn.fnamemodify(rel:sub(1, 1) == "/" and rel or (repo .. rel), ":p")
				local old_start, old_end = step_span(st)
				updates[i] = { start = old_start, ["end"] = old_end }

				if vim.fn.filereadable(abs) == 0 then
					problems[#problems + 1] = string.format("[%s] 站 %d 文件不存在: %s", slug, i, rel)
				elseif not st.anchor or st.anchor == "" then
					problems[#problems + 1] = string.format("[%s] 站 %d 没有 anchor，行号不会自愈", slug, i)
				else
					local tlines = vim.fn.readfile(abs)
					local hit = find_anchor(tlines, old_start, st.anchor)
					if not hit then
						problems[#problems + 1] = string.format("[%s] 站 %d 锚点失效（不猜）: %s", slug, i, rel)
					else
						updates[i].start = hit
						updates[i]["end"] = math.min(#tlines, math.max(hit, hit + (old_end - old_start)))
					end
				end
			end

			local changed, err = patch_spans(lines, updates)
			if not changed then
				problems[#problems + 1] = string.format("[%s] %s", slug, err)
			elseif #changed == 0 then
				unchanged = unchanged + 1
			else
				vim.fn.writefile(lines, f.path)
				touched = touched + 1
				total_fixes = total_fixes + #changed
				for _, c in ipairs(changed) do
					problems[#problems + 1] = string.format(
						"[%s] 站 %d  %s: %d → %d",
						slug,
						c.station,
						c.key,
							tonumber(c.before:match("%d+")),
							tonumber(c.after:match("%d+"))
					)
				end
			end
		end
	end

	if #problems == 0 then
		vim.notify(string.format("pi-tour sync: %d 份 spec 无需改动", #files), vim.log.levels.INFO)
		return
	end

	vim.notify(
		string.format(
			"pi-tour sync: %d/%d 份已更新 · %d 处行号 · %d 份无变化",
			touched,
			#files,
			total_fixes,
			unchanged
		),
		total_fixes > 0 and vim.log.levels.INFO or vim.log.levels.WARN
	)
	for _, p in ipairs(problems) do
		print("  " .. p)
	end
end

-- ---------------------------------------------------------------------------
-- 删除：spec 和它的同名 HTML 产物一起清
-- ---------------------------------------------------------------------------

--- @param path string spec 路径
--- @param force? boolean 跳过确认（:PiTour rm! / 无 UI 时的唯一办法）
--- @return boolean 是否真的删了
function M.delete(path, force)
	if not path or path == "" then
		vim.notify("pi-tour: 缺少 spec 路径", vim.log.levels.ERROR)
		return false
	end
	local spec_path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
	if vim.fn.filereadable(spec_path) == 0 then
		vim.notify("pi-tour: 文件不存在: " .. spec_path, vim.log.levels.ERROR)
		return false
	end

	local targets = { spec_path }
	local html_path = spec_path:gsub("%.[Jj][Ss][Oo][Nn]$", "") .. ".html"
	if html_path ~= spec_path and vim.fn.filereadable(html_path) == 1 then
		targets[#targets + 1] = html_path
	end

	if not force then
		-- headless / 无 UI 时 confirm() 拿不到输入，会直接当取消；给个明确说法
		if #vim.api.nvim_list_uis() == 0 then
			vim.notify("pi-tour: 当前没有 UI，需用 :PiTour! rm " .. spec_path, vim.log.levels.WARN)
			return false
		end
		local msg = string.format("删除这份 tour？\n%s", table.concat(targets, "\n"))
		if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
			vim.notify("pi-tour: 已取消删除", vim.log.levels.INFO)
			return false
		end
	end

	local failed = {}
	for _, t in ipairs(targets) do
		if vim.fn.delete(t) ~= 0 then
			failed[#failed + 1] = t
		end
	end
	if #failed > 0 then
		vim.notify("pi-tour: 删除失败\n" .. table.concat(failed, "\n"), vim.log.levels.ERROR)
		return false
	end

	-- 删的正是当前活跃那份：直接收摊，否则 S.steps 会指向已删的 spec
	local was_current = S.last_path and vim.fn.fnamemodify(S.last_path, ":p") == spec_path
	if was_current then
		M.stop()
		S.last_path = nil
	end

	vim.notify(
		string.format("pi-tour: 已删除 %s（%d 个文件）%s", vim.fn.fnamemodify(spec_path, ":t"), #targets, was_current and "，当前导览已结束" or ""),
		vim.log.levels.INFO
	)
	return true
end

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

function M.setup(opts)
	opts = opts or {}
	define_hl()

	if opts.spec_dirs then
		M.config.spec_dirs = opts.spec_dirs
	end

	local keys = vim.tbl_extend("force", {
		next = "]T",
		prev = "[T",
		pick = "<leader>Tt",
		list = "<leader>To",
		stop = "<leader>Ts",
		reload = "<leader>Tr",
	}, opts.keys or {})

	local map = function(lhs, fn, desc)
		if lhs and lhs ~= "" then
			vim.keymap.set("n", lhs, fn, { desc = desc })
		end
	end

	map(keys.next, M.next, "tour: 下一站")
	map(keys.prev, M.prev, "tour: 上一站")
	map(keys.pick, M.pick, "tour: 站点列表")
	map(keys.list, M.list, "tour: 切换导览（多份 spec）")
	map(keys.stop, M.stop, "tour: 结束导览")
	map(keys.reload, M.reload, "tour: 重载 spec")

	vim.api.nvim_create_user_command("PiTour", function(c)
		local args = c.fargs
		local sub = args[1] or "status"
		if sub == "load" then
			M.load(table.concat(args, " ", 2))
		elseif sub == "next" then
			M.next()
		elseif sub == "prev" then
			M.prev()
		elseif sub == "pick" then
			M.pick()
		elseif sub == "list" or sub == "tours" then
			M.list()
		elseif sub == "check" then
			M.check(args[2])
		elseif sub == "sync" then
			M.sync(args[2])
		elseif sub == "rm" or sub == "delete" then
			M.delete(args[2], c.bang)
		elseif sub == "stop" then
			M.stop()
		elseif sub == "reload" then
			M.reload()
		elseif sub == "goto" then
			M.goto(tonumber(args[2]) or 1)
		else
			vim.print(M.status())
		end
	end, {
		nargs = "*",
		bang = true, -- :PiTour! rm <path> = 跳过确认
		desc = "pi-tour: load <path> | list | check [path] | sync [path] | rm <path> | next | prev | pick | stop | reload | goto <n>",
		-- 第一个参数是 ArgLead（正在输入的当前参数），不是子命令：子命令要从 cmdline 里取。
		complete = function(arglead, cmdline)
			local sub = (vim.split(cmdline or "", "%s+", { trimempty = true }))[2]
			if sub == "load" or sub == "reload" or sub == "check" or sub == "sync" or sub == "rm" or sub == "delete" then
				local paths = {}
				for _, f in ipairs(spec_files()) do
					paths[#paths + 1] = f.path
				end
				return paths
			end
			return { "load", "list", "check", "sync", "rm", "next", "prev", "pick", "stop", "reload", "goto", "status" }
		end,
	})
end

return M

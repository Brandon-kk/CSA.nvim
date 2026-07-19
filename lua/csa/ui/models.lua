local config = require("csa.config")

local M = {}

local LIST_HEIGHT = 8
-- Current CSA model marker, packed into the row (right side). No left caret.
local ICON_CURRENT = "●"

---@class CSA.ModelPickState
---@field open boolean
---@field query string
---@field items string[]
---@field all string[]
---@field idx integer
---@field timer uv.uv_timer_t|nil
---@field ns integer
---@field saved_guicursor string|nil
---@field job integer|nil
---@field bufs { search: integer|nil, list: integer|nil }
---@field wins { search: integer|nil, list: integer|nil }

---@type CSA.ModelPickState
local pick = {
	open = false,
	query = "",
	items = {},
	all = {},
	idx = 1,
	timer = nil,
	ns = vim.api.nvim_create_namespace("csa_model_pick"),
	saved_guicursor = nil,
	job = nil,
	bufs = {},
	wins = {},
}

local function win_valid(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function buf_valid(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

function M.is_open()
	return pick.open
end

function M.list_height()
	return LIST_HEIGHT
end

---@return integer[]
function M.wins()
	local out = {}
	if win_valid(pick.wins.search) then
		out[#out + 1] = pick.wins.search
	end
	if win_valid(pick.wins.list) then
		out[#out + 1] = pick.wins.list
	end
	return out
end

local function cancel_timer()
	if pick.timer then
		pcall(function()
			pick.timer:stop()
			pick.timer:close()
		end)
		pick.timer = nil
	end
end

local function restore_cursor()
	if pick.saved_guicursor ~= nil then
		vim.o.guicursor = pick.saved_guicursor
		pick.saved_guicursor = nil
	end
end

local function hide_list_cursor()
	if pick.saved_guicursor == nil then
		pick.saved_guicursor = vim.o.guicursor
	end
	vim.opt.guicursor:append("a:CSAHiddenCursor/lCursor")
end

local function clamp_idx()
	if #pick.items == 0 then
		pick.idx = 1
		return
	end
	if pick.idx < 1 then
		pick.idx = 1
	elseif pick.idx > #pick.items then
		pick.idx = #pick.items
	end
end

local function filter_items()
	local q = vim.trim(pick.query or ""):lower()
	if q == "" then
		pick.items = vim.deepcopy(pick.all)
	else
		local out = {}
		for _, name in ipairs(pick.all) do
			if name:lower():find(q, 1, true) then
				out[#out + 1] = name
			end
		end
		pick.items = out
	end
	clamp_idx()
end

local function render_list()
	local buf = pick.bufs.list
	if not buf_valid(buf) then
		return
	end
	filter_items()
	local current = require("csa.ui.picker").model()
	local win_w = win_valid(pick.wins.list) and vim.api.nvim_win_get_width(pick.wins.list) or 40
	local pad_l, pad_r = 1, 1
	local icon_w = vim.fn.strdisplaywidth(ICON_CURRENT)
	-- name … [spaces] ●  with left/right inset so content isn't flush to the border.
	local inner_w = math.max(1, win_w - pad_l - pad_r)
	local name_max = math.max(1, inner_w - icon_w - 1)

	---@type { line: string, icon_col: integer|nil }[]
	local rows = {}
	local left = string.rep(" ", pad_l)
	local right = string.rep(" ", pad_r)
	for _, name in ipairs(pick.items) do
		local display = name
		if vim.fn.strdisplaywidth(display) > name_max then
			while #display > 0 and vim.fn.strdisplaywidth(display) > name_max - 1 do
				display = display:sub(1, -2)
			end
			display = display .. "…"
		end
		if name == current then
			local gap = math.max(1, inner_w - vim.fn.strdisplaywidth(display) - icon_w)
			local line = left .. display .. string.rep(" ", gap) .. ICON_CURRENT .. right
			rows[#rows + 1] = { line = line, icon_col = #left + #display + gap }
		else
			rows[#rows + 1] = { line = left .. display, icon_col = nil }
		end
	end

	local lines = {}
	for _, row in ipairs(rows) do
		lines[#lines + 1] = row.line
	end
	if #lines == 0 then
		lines = { "(no models)" }
		rows = {}
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, pick.ns, 0, -1)
	if #pick.items > 0 then
		clamp_idx()
		for i, row in ipairs(rows) do
			if row.icon_col then
				pcall(vim.api.nvim_buf_set_extmark, buf, pick.ns, i - 1, row.icon_col, {
					end_col = row.icon_col + #ICON_CURRENT,
					hl_group = "DiagnosticOk",
					hl_mode = "combine",
				})
			end
		end
		-- Full-row highlight for the focused entry (not just the name span).
		pcall(vim.api.nvim_buf_set_extmark, buf, pick.ns, pick.idx - 1, 0, {
			line_hl_group = "CursorLine",
			hl_eol = true,
		})
	end
	if win_valid(pick.wins.list) then
		pcall(vim.api.nvim_win_set_cursor, pick.wins.list, { pick.idx, 0 })
	end
end

local function move_idx(step)
	if #pick.items == 0 then
		return
	end
	pick.idx = pick.idx + step
	if pick.idx < 1 then
		pick.idx = #pick.items
	elseif pick.idx > #pick.items then
		pick.idx = 1
	end
	render_list()
end

local function focus_search()
	if not win_valid(pick.wins.search) then
		return
	end
	restore_cursor()
	pcall(vim.api.nvim_set_current_win, pick.wins.search)
	vim.schedule(function()
		if win_valid(pick.wins.search) then
			pcall(vim.api.nvim_set_current_win, pick.wins.search)
			pcall(vim.cmd, "startinsert!")
		end
	end)
end

local function confirm()
	if #pick.items == 0 then
		return
	end
	clamp_idx()
	local name = pick.items[pick.idx]
	if name == "…" or name == "..." then
		return
	end
	local picker = require("csa.ui.picker")
	M.close()
	if type(name) == "string" and name ~= "" then
		picker.set_model(name)
	end
	picker.focus("input", { insert = false })
end

function M.close()
	if not pick.open then
		return
	end
	cancel_timer()
	restore_cursor()
	if pick.job then
		pcall(vim.fn.jobstop, pick.job)
		pick.job = nil
	end
	pick.open = false
	local picker = require("csa.ui.picker")
	for _, kind in ipairs({ "search", "list" }) do
		local win = pick.wins[kind]
		if win_valid(win) then
			picker.suppress_close(true)
			pcall(vim.api.nvim_win_close, win, true)
			picker.suppress_close(false)
		end
		pick.wins[kind] = nil
	end
	for _, kind in ipairs({ "search", "list" }) do
		local buf = pick.bufs[kind]
		if buf_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
		pick.bufs[kind] = nil
	end
	pick.query = ""
	pick.items = {}
	pick.all = {}
	pick.idx = 1
	if picker.state().picking then
		picker.set_picking(false)
	end
end

---@type fun(opts?: { force?: boolean, silent?: boolean })
local fetch_models

local function bind_pick_maps()
	local search = pick.bufs.search
	local list = pick.bufs.list
	if not (buf_valid(search) and buf_valid(list)) then
		return
	end

	local function cancel()
		local picker = require("csa.ui.picker")
		M.close()
		picker.focus("input", { insert = false })
	end

	local function map_ni(buf, lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = desc,
		})
		vim.keymap.set("i", lhs, function()
			vim.b.completion = false
			pcall(function()
				require("blink.cmp").hide()
			end)
			vim.schedule(fn)
			return ""
		end, {
			buffer = buf,
			expr = true,
			silent = true,
			nowait = true,
			noremap = true,
			desc = desc,
		})
	end

	for _, buf in ipairs({ search, list }) do
		vim.keymap.set({ "n", "i" }, "<Esc>", cancel, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA cancel model pick",
		})
		vim.keymap.set("n", "q", cancel, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA cancel model pick",
		})
		-- Force re-fetch from cursor-agent (updates disk cache).
		vim.keymap.set("n", "R", function()
			vim.notify("CSA: refreshing models…", vim.log.levels.INFO, { title = "CSA" })
			fetch_models({ force = true })
		end, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA refresh models",
		})
		map_ni(buf, "<CR>", confirm, "CSA select model")
		map_ni(buf, "<Tab>", function()
			move_idx(1)
		end, "CSA next model")
		map_ni(buf, "<S-Tab>", function()
			move_idx(-1)
		end, "CSA prev model")
		map_ni(buf, "<Down>", function()
			move_idx(1)
		end, "CSA list down")
		map_ni(buf, "<Up>", function()
			move_idx(-1)
		end, "CSA list up")
		map_ni(buf, "<C-n>", function()
			move_idx(1)
		end, "CSA list down")
		map_ni(buf, "<C-p>", function()
			move_idx(-1)
		end, "CSA list up")
		map_ni(buf, "<C-j>", function()
			move_idx(1)
		end, "CSA list down")
		map_ni(buf, "<C-k>", function()
			move_idx(-1)
		end, "CSA list up")
	end

	vim.keymap.set("n", "i", focus_search, {
		buffer = list,
		silent = true,
		nowait = true,
		noremap = true,
		desc = "CSA focus search",
	})

	vim.api.nvim_create_autocmd({ "BufEnter", "InsertEnter" }, {
		buffer = search,
		callback = function()
			vim.b.completion = false
			pcall(function()
				require("blink.cmp").hide()
			end)
		end,
	})
end

local function open_pick_float(buf, border, geo, width, col, title, enter)
	local picker = require("csa.ui.picker")
	local pad = picker.state().wins.pad
	local opts = {
		relative = "win",
		win = pad,
		width = width,
		height = geo.height,
		row = geo.row,
		col = col,
		style = "minimal",
		border = border,
		zindex = 46,
		noautocmd = true,
	}
	if title then
		opts.title = title
		opts.title_pos = "center"
	end
	local win = vim.api.nvim_open_win(buf, enter, opts)
	vim.w[win].csa_panel = "pick"
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = false
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].scrolloff = 0
	vim.wo[win].list = false
	vim.wo[win].winhighlight = table.concat({
		"Normal:CSANormal",
		"NormalFloat:CSANormal",
		"FloatBorder:CSABorder",
		"FloatTitle:CSATitle",
		"CursorLine:CursorLine",
	}, ",")
	return win
end

--- Normalize CLI/cache names (`auto` always first).
---@param names string[]
---@return string[]
local function normalize_model_names(names)
	local seen = { auto = true }
	local all = { "auto" }
	for _, name in ipairs(names or {}) do
		name = vim.trim(tostring(name or ""))
		if name ~= "" and name:lower() ~= "auto" and not seen[name] then
			seen[name] = true
			all[#all + 1] = name
		end
	end
	return all
end

---@param names string[]
---@param opts? { persist?: boolean }
local function set_models(names, opts)
	opts = opts or {}
	local all = normalize_model_names(names)
	pick.all = all
	local current = require("csa.ui.picker").model()
	pick.idx = 1
	for i, name in ipairs(all) do
		if name == current then
			pick.idx = i
			break
		end
	end
	if opts.persist then
		local cached = {}
		for _, name in ipairs(names or {}) do
			name = vim.trim(tostring(name or ""))
			if name ~= "" and name:lower() ~= "auto" then
				cached[#cached + 1] = name
			end
		end
		pcall(require("csa.storage").save_models_cache, cached)
	end
	render_list()
end

---@param line string
---@return string|nil
local function parse_model_line(line)
	line = tostring(line or "")
	-- Strip ANSI / CR.
	line = line:gsub("\27%[[0-9;]*m", ""):gsub("\r", "")
	line = vim.trim(line)
	if line == "" then
		return nil
	end
	local lower = line:lower()
	if
		lower:find("available models", 1, true)
		or lower:find("authentication", 1, true)
		or lower:find("error:", 1, true)
		or lower:find("usage:", 1, true)
		or lower == "model"
		or lower == "models"
		or lower:find("^%-") and #line < 3
	then
		return nil
	end
	-- Bullets / columns: "- id", "* id", "id  label", "id (default)"
	line = line:gsub("^[•%*%+%-]+%s*", "")
	line = line:gsub("^%d+[%.%)]%s*", "")
	local id = line:match("^([%w][%w%._:%-]+)")
	if not id or id == "" then
		return nil
	end
	if id:lower() == "auto" then
		return nil
	end
	return id
end

---@param lines string[]
---@return string[]
local function parse_model_lines(lines)
	local names = {}
	local seen = {}
	for _, line in ipairs(lines) do
		local id = parse_model_line(line)
		if id and not seen[id] then
			seen[id] = true
			names[#names + 1] = id
		end
	end
	return names
end

---@param args string[]
---@param on_done fun(names: string[], err?: string)
local function run_models_cmd(args, on_done)
	local cmd = config.provider_command()
	local full = { cmd }
	for _, a in ipairs(args) do
		full[#full + 1] = a
	end
	local stdout = {}
	local stderr = {}
	local job = vim.fn.jobstart(full, {
		cwd = config.provider_workspace(),
		env = require("csa.ai.cursor").job_env(),
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data, _)
			if type(data) == "table" then
				for _, line in ipairs(data) do
					if line and line ~= "" then
						stdout[#stdout + 1] = line
					end
				end
			end
		end,
		on_stderr = function(_, data, _)
			if type(data) == "table" then
				for _, line in ipairs(data) do
					if line and line ~= "" then
						stderr[#stderr + 1] = line
					end
				end
			end
		end,
		on_exit = function(job_id, code, _)
			if pick.job == job_id then
				pick.job = nil
			end
			local names = parse_model_lines(stdout)
			if #names == 0 then
				names = parse_model_lines(stderr)
			end
			local err
			if #names == 0 then
				err = vim.trim(table.concat(stderr, "\n"))
				if err == "" then
					err = vim.trim(table.concat(stdout, "\n"))
				end
				if code ~= 0 and err == "" then
					err = "exit " .. tostring(code)
				end
			end
			on_done(names, err)
		end,
	})
	if type(job) ~= "number" or job <= 0 then
		on_done({}, "failed to start " .. cmd)
		return
	end
	pick.job = job
end

---@param opts? { force?: boolean, silent?: boolean }
fetch_models = function(opts)
	opts = opts or {}
	local storage = require("csa.storage")
	local cached = storage.load_models_cache()
	if cached and not opts.force then
		-- Instant open from disk; no CLI round-trip.
		set_models(cached)
		return
	end

	local cmd = config.provider_command()
	if vim.fn.executable(cmd) ~= 1 then
		set_models(cached or {})
		if not opts.silent then
			vim.notify("CSA: provider command not found (`" .. cmd .. "`)", vim.log.levels.WARN, { title = "CSA" })
		end
		return
	end

	-- Prefer non-interactive --list-models; fall back to `models`.
	run_models_cmd({ "--list-models" }, function(names, err)
		if not pick.open then
			return
		end
		if #names > 0 then
			vim.schedule(function()
				if pick.open then
					set_models(names, { persist = true })
				end
			end)
			return
		end
		run_models_cmd({ "models" }, function(names2, err2)
			if not pick.open then
				return
			end
			vim.schedule(function()
				if not pick.open then
					return
				end
				if #names2 > 0 then
					set_models(names2, { persist = true })
					return
				end
				-- Keep disk cache if the CLI fails.
				set_models(cached or {})
				if opts.silent then
					return
				end
				local msg = err2 or err or "no models returned"
				if msg:lower():find("auth") then
					msg = msg .. "\n(hint: `cursor-agent login` or set provider.auth.env)"
				end
				vim.notify("CSA: failed to list models\n" .. msg, vim.log.levels.WARN, { title = "CSA" })
			end)
		end)
	end)
end

function M.pick()
	local picker = require("csa.ui.picker")
	if not picker.is_open() or picker.is_stream_locked() then
		return
	end
	if pick.open then
		focus_search()
		return
	end

	local files = require("csa.ui.files")
	local history = require("csa.ui.history")
	if files.is_open() then
		files.close()
	end
	if history.is_open() then
		history.close()
	end

	if picker.state().show_files then
		picker.set_files_visible(false)
	end

	pick.query = ""
	pick.idx = 1
	pick.open = true
	-- Prefer cache immediately; placeholder only on first-ever fetch.
	local cached = require("csa.storage").load_models_cache()
	if cached then
		pick.all = normalize_model_names(cached)
		pick.items = vim.deepcopy(pick.all)
	else
		pick.all = normalize_model_names({ "…" })
		pick.items = vim.deepcopy(pick.all)
	end

	local search = vim.api.nvim_create_buf(false, true)
	local list = vim.api.nvim_create_buf(false, true)
	pick.bufs.search = search
	pick.bufs.list = list
	for _, buf in ipairs({ search, list }) do
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "csa-pick"
		vim.b[buf].completion = false
	end
	vim.bo[search].modifiable = true
	vim.api.nvim_buf_set_lines(search, 0, -1, false, { "" })
	vim.bo[list].modifiable = false

	picker.set_picking(true)
	local geo = picker.layout_geo()
	if not geo or not geo.pick_search then
		M.close()
		return
	end

	local title = " Model "
	local top_border, mid_border = picker.pick_borders()
	pick.wins.search = open_pick_float(search, top_border, geo.pick_search, geo.width, geo.col, title, true)
	pick.wins.list = open_pick_float(list, mid_border, geo.pick_list, geo.width, geo.col, nil, false)

	bind_pick_maps()

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = search,
		callback = function()
			if not pick.open then
				return
			end
			local line = vim.api.nvim_buf_get_lines(search, 0, 1, false)[1] or ""
			if line ~= pick.query then
				pick.query = line
				render_list()
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinEnter", {
		buffer = list,
		callback = function()
			if pick.open then
				hide_list_cursor()
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = list,
		callback = function()
			restore_cursor()
		end,
	})

	render_list()
	fetch_models()
	focus_search()
end

function M.apply_layout(geo)
	if not pick.open or not geo or not geo.pick_search then
		return
	end
	local picker = require("csa.ui.picker")
	local top_border, mid_border = picker.pick_borders()
	local pad = picker.state().wins.pad
	if win_valid(pick.wins.search) then
		vim.api.nvim_win_set_config(pick.wins.search, {
			relative = "win",
			win = pad,
			width = geo.width,
			height = geo.pick_search.height,
			row = geo.pick_search.row,
			col = geo.col,
			border = top_border,
			title = " Model ",
			title_pos = "center",
		})
	end
	if win_valid(pick.wins.list) then
		vim.api.nvim_win_set_config(pick.wins.list, {
			relative = "win",
			win = pad,
			width = geo.width,
			height = geo.pick_list.height,
			row = geo.pick_list.row,
			col = geo.col,
			border = mid_border,
		})
	end
end

return M

local config = require("csa.config")

local M = {}

local LIST_HEIGHT = 8
local MAX_RESULTS = 500
local ICON_SELECTED = ""
local ICON_UNSELECTED = ""

---@class CSA.FilePickState
---@field open boolean
---@field query string
---@field results string[]
---@field selected table<string, boolean>
---@field select_order string[]
---@field idx integer current highlight row (1-based)
---@field cwd string
---@field job integer|nil
---@field timer uv.uv_timer_t|nil
---@field ns integer
---@field saved_guicursor string|nil
---@field bufs { search: integer|nil, list: integer|nil }
---@field wins { search: integer|nil, list: integer|nil }

---@type CSA.FilePickState
local pick = {
	open = false,
	query = "",
	results = {},
	selected = {},
	select_order = {},
	idx = 1,
	cwd = "",
	job = nil,
	timer = nil,
	ns = vim.api.nvim_create_namespace("csa_file_pick"),
	saved_guicursor = nil,
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

local function cancel_job()
	if pick.job then
		pcall(vim.fn.jobstop, pick.job)
		pick.job = nil
	end
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
	vim.api.nvim_set_hl(0, "CSAHiddenCursor", { blend = 100, nocombine = true })
	vim.o.guicursor = "a:CSAHiddenCursor"
end

local function abs_path(rel)
	if rel:sub(1, 1) == "/" or rel:match("^%a:[/\\]") then
		return vim.fs.normalize(rel)
	end
	return vim.fs.normalize(vim.fn.fnamemodify(pick.cwd .. "/" .. rel, ":p"))
end

local function clamp_idx()
	if #pick.results == 0 then
		pick.idx = 1
		return
	end
	pick.idx = math.max(1, math.min(pick.idx, #pick.results))
end

local function file_icon(path)
	local name = vim.fn.fnamemodify(path, ":t")
	if rawget(_G, "MiniIcons") and MiniIcons.get then
		local icon, hl = MiniIcons.get("file", name)
		if icon and icon ~= "" then
			return vim.trim(icon), hl or "Normal"
		end
	end
	local ok, devicons = pcall(require, "nvim-web-devicons")
	if ok and devicons.get_icon then
		local icon, hl = devicons.get_icon(name, nil, { default = true })
		if icon and icon ~= "" then
			return icon, hl or "Normal"
		end
	end
	return "󰈙", "Comment"
end

local function render_list()
	local buf = pick.bufs.list
	if not buf_valid(buf) then
		return
	end
	clamp_idx()

	---@type { line: string, check_end: integer, file_hl: string, file_start: integer, file_end: integer }[]
	local meta = {}
	local lines = {}

	local any_selected = #pick.select_order > 0
	for _, rel in ipairs(pick.results) do
		local path = abs_path(rel)
		local ficon, fhl = file_icon(path)
		local selected = pick.selected[path] and true or false
		-- No checkbox column until something is selected; then show  /  for all rows.
		local prefix = ""
		if any_selected then
			prefix = (selected and ICON_SELECTED or ICON_UNSELECTED) .. " "
		end
		local line = prefix .. ficon .. " " .. rel
		lines[#lines + 1] = line
		meta[#meta + 1] = {
			file_hl = fhl,
			file_start = #prefix,
			file_end = #line,
			selected = selected,
			any_selected = any_selected,
		}
	end

	vim.bo[buf].modifiable = true
	-- Empty results: clear buffer entirely (no placeholder text).
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(buf, pick.ns, 0, -1)
	if #pick.results == 0 then
		return
	end

	for i, m in ipairs(meta) do
		if m.any_selected then
			local mark = m.selected and ICON_SELECTED or ICON_UNSELECTED
			vim.api.nvim_buf_set_extmark(buf, pick.ns, i - 1, 0, {
				end_col = #mark,
				hl_group = m.selected and "DiagnosticOk" or "Comment",
			})
		end
		-- File icon + name share the same filetype color.
		vim.api.nvim_buf_set_extmark(buf, pick.ns, i - 1, m.file_start, {
			end_col = m.file_end,
			hl_group = m.file_hl,
			hl_mode = "combine",
		})
		if i == pick.idx then
			vim.api.nvim_buf_set_extmark(buf, pick.ns, i - 1, 0, {
				line_hl_group = "CursorLine",
				hl_eol = true,
			})
		end
	end

	-- Keep list scroll in sync without focusing it (no block cursor flash).
	if win_valid(pick.wins.list) then
		pcall(vim.api.nvim_win_set_cursor, pick.wins.list, { pick.idx, 0 })
	end
end

local function move_idx(delta)
	if #pick.results == 0 then
		return
	end
	local n = #pick.results
	pick.idx = ((pick.idx - 1 + delta) % n) + 1
	render_list()
end

local function toggle_current()
	if #pick.results == 0 then
		return
	end
	clamp_idx()
	local rel = pick.results[pick.idx]
	if not rel then
		return
	end
	local path = abs_path(rel)
	if pick.selected[path] then
		pick.selected[path] = nil
		for i, p in ipairs(pick.select_order) do
			if p == path then
				table.remove(pick.select_order, i)
				break
			end
		end
	else
		pick.selected[path] = true
		pick.select_order[#pick.select_order + 1] = path
	end
	-- Tab only toggles — never move idx.
	render_list()
end

local function run_fd()
	cancel_job()
	if vim.fn.executable("fd") ~= 1 then
		pick.results = {}
		render_list()
		vim.notify("CSA: fd not found in PATH", vim.log.levels.ERROR, { title = "CSA" })
		return
	end

	local query = pick.query
	local cmd = {
		"fd",
		"--type",
		"f",
		"--hidden",
		"--exclude",
		".git",
		"--color",
		"never",
		"--max-results",
		tostring(MAX_RESULTS),
	}
	if query ~= "" then
		cmd[#cmd + 1] = "--"
		cmd[#cmd + 1] = query
	end

	local chunks = {}
	pick.job = vim.fn.jobstart(cmd, {
		cwd = pick.cwd,
		stdout_buffered = true,
		on_stdout = function(_, data)
			if type(data) == "table" then
				for _, line in ipairs(data) do
					if line ~= "" then
						chunks[#chunks + 1] = line
					end
				end
			end
		end,
		on_exit = function(_, code)
			pick.job = nil
			if not pick.open then
				return
			end
			if code ~= 0 and #chunks == 0 then
				pick.results = {}
			else
				pick.results = chunks
			end
			-- Keep highlight near top after filter changes.
			pick.idx = 1
			vim.schedule(render_list)
		end,
	})
end

local function schedule_fd()
	if pick.timer then
		pcall(function()
			pick.timer:stop()
			pick.timer:close()
		end)
		pick.timer = nil
	end
	pick.timer = vim.uv.new_timer()
	pick.timer:start(60, 0, function()
		vim.schedule(function()
			if pick.open then
				run_fd()
			end
		end)
	end)
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
	local paths = vim.deepcopy(pick.select_order)
	if #paths == 0 and #pick.results > 0 then
		-- No explicit multi-select: take the highlighted row only.
		local rel = pick.results[pick.idx]
		if rel then
			paths[1] = abs_path(rel)
		end
	end
	local picker = require("csa.ui.picker")
	M.close()
	if #paths > 0 then
		picker.add_files(paths)
	end
	picker.focus("input", { insert = false })
end

function M.close()
	if not pick.open then
		return
	end
	cancel_job()
	restore_cursor()
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
	pick.results = {}
	pick.selected = {}
	pick.select_order = {}
	pick.idx = 1
	if picker.state().picking then
		picker.set_picking(false)
	end
end

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

	-- Insert-mode maps must be expr + return "" so blink/defaults cannot eat the key.
	-- (Esc already worked as a plain map; Tab/CR often lose to completion plugins.)
	local function map_ni(buf, lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = desc,
		})
		-- Insert expr maps are textlocked; defer buffer/window changes.
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
		-- Esc: keep non-expr (known working).
		vim.keymap.set({ "n", "i" }, "<Esc>", cancel, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA cancel file pick",
		})
		vim.keymap.set("n", "q", cancel, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA cancel file pick",
		})

		map_ni(buf, "<Tab>", function()
			move_idx(1)
		end, "CSA next row")
		map_ni(buf, "<S-Tab>", function()
			move_idx(-1)
		end, "CSA prev row")
		map_ni(buf, "<CR>", toggle_current, "CSA toggle select")
		map_ni(buf, "<C-CR>", confirm, "CSA confirm file pick")
		map_ni(buf, "<C-Enter>", confirm, "CSA confirm file pick")
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
	vim.keymap.set("n", "a", focus_search, {
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

---@param border table
---@param geo { row: integer, height: integer }
---@param width integer
---@param col integer
---@param title string|nil
---@param enter boolean
---@param is_search boolean
local function open_pick_float(buf, border, geo, width, col, title, enter, is_search)
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
	if not is_search then
		-- List never shows a block cursor; highlight comes from extmarks.
		vim.wo[win].cursorline = false
	end
	return win
end

--- Open the fd file picker between output and input. Files panel stays closed.
function M.pick()
	local picker = require("csa.ui.picker")
	if not picker.is_open() or picker.is_stream_locked() then
		return
	end
	if pick.open then
		focus_search()
		return
	end
	if vim.fn.executable("fd") ~= 1 then
		vim.notify("CSA: fd not found in PATH", vim.log.levels.ERROR, { title = "CSA" })
		return
	end

	local history = require("csa.ui.history")
	local models = require("csa.ui.models")
	if history.is_open() then
		history.close()
	end
	if models.is_open() then
		models.close()
	end

	if picker.state().show_files then
		picker.set_files_visible(false)
	end

	pick.cwd = vim.fn.getcwd()
	pick.query = ""
	pick.results = {}
	pick.selected = {}
	pick.select_order = {}
	pick.idx = 1
	pick.open = true

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

	local title = string.format(" %s  Select ", config.icon("file"))
	local top_border, mid_border = picker.pick_borders()

	pick.wins.search = open_pick_float(search, top_border, geo.pick_search, geo.width, geo.col, title, true, true)
	pick.wins.list = open_pick_float(list, mid_border, geo.pick_list, geo.width, geo.col, nil, false, false)

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
				schedule_fd()
			end
		end,
	})

	-- If focus lands on the list, hide the cursor and keep using idx highlight.
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
	run_fd()
	focus_search()
end

--- Reposition picker floats after layout changes.
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
			title = string.format(" %s  Select ", config.icon("file")),
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

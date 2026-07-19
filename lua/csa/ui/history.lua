local config = require("csa.config")
local storage = require("csa.storage")

local M = {}

local LIST_HEIGHT = 8

---@class CSA.HistoryPickState
---@field open boolean
---@field query string
---@field items CSA.HistoryListItem[]
---@field idx integer
---@field timer uv.uv_timer_t|nil
---@field ns integer
---@field saved_guicursor string|nil
---@field confirmed boolean
---@field resume_session_id string|nil
---@field resume_output CSA.OutputSnapshot|nil
---@field bufs { search: integer|nil, list: integer|nil }
---@field wins { search: integer|nil, list: integer|nil }

---@type CSA.HistoryPickState
local pick = {
	open = false,
	query = "",
	items = {},
	idx = 1,
	timer = nil,
	ns = vim.api.nvim_create_namespace("csa_history_pick"),
	saved_guicursor = nil,
	confirmed = false,
	resume_session_id = nil,
	resume_output = nil,
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
	vim.api.nvim_set_hl(0, "CSAHiddenCursor", { blend = 100, nocombine = true })
	vim.o.guicursor = "a:CSAHiddenCursor"
end

local function clamp_idx()
	if #pick.items == 0 then
		pick.idx = 1
		return
	end
	pick.idx = math.max(1, math.min(pick.idx, #pick.items))
end

local function render_list()
	local buf = pick.bufs.list
	if not buf_valid(buf) then
		return
	end
	clamp_idx()

	local lines = {}
	for _, item in ipairs(pick.items) do
		lines[#lines + 1] = "󰋚 " .. item.label
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(buf, pick.ns, 0, -1)
	if #pick.items == 0 then
		return
	end

	local icon = "󰋚"
	for i, _ in ipairs(pick.items) do
		vim.api.nvim_buf_set_extmark(buf, pick.ns, i - 1, 0, {
			end_col = #icon,
			hl_group = "DiagnosticInfo",
		})
		if i == pick.idx then
			vim.api.nvim_buf_set_extmark(buf, pick.ns, i - 1, 0, {
				line_hl_group = "CursorLine",
				hl_eol = true,
			})
		end
	end

	if win_valid(pick.wins.list) then
		pcall(vim.api.nvim_win_set_cursor, pick.wins.list, { pick.idx, 0 })
	end
end

local function preview_current()
	local picker = require("csa.ui.picker")
	if #pick.items == 0 then
		-- Empty filter: clear preview to blank rather than stale content.
		picker.restore_output({ lines = { "" }, marks = {} })
		return
	end
	clamp_idx()
	local item = pick.items[pick.idx]
	if not item then
		return
	end
	local entry = storage.load_history(item.path)
	if entry then
		picker.show_history(entry)
	end
end

local function refresh()
	pick.items = storage.list_history(pick.query)
	pick.idx = 1
	render_list()
	preview_current()
end

local function schedule_refresh()
	cancel_timer()
	pick.timer = vim.uv.new_timer()
	pick.timer:start(60, 0, function()
		vim.schedule(function()
			if pick.open then
				refresh()
			end
		end)
	end)
end

local function move_idx(delta)
	if #pick.items == 0 then
		return
	end
	local n = #pick.items
	pick.idx = ((pick.idx - 1 + delta) % n) + 1
	render_list()
	preview_current()
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

local function open_current()
	if #pick.items == 0 then
		return
	end
	clamp_idx()
	local item = pick.items[pick.idx]
	-- Preview already shows the session; keep it and continue that session.
	local picker = require("csa.ui.picker")
	pick.confirmed = true
	if item and item.id then
		picker.set_session_id(item.id)
	end
	M.close()
	picker.focus("input", { insert = false })
end

local function delete_current()
	if #pick.items == 0 then
		return
	end
	clamp_idx()
	local item = pick.items[pick.idx]
	if not item then
		return
	end
	local picker = require("csa.ui.picker")
	local deleting_active = picker.session_id() == item.id
	if not storage.delete_history(item.path) then
		vim.notify("CSA: failed to delete history", vim.log.levels.WARN, { title = "CSA" })
		return
	end
	if deleting_active then
		picker.set_session_id(storage.random_id())
	end
	-- Remove from list; later rows shift up into the same highlight slot.
	local old_idx = pick.idx
	pick.items = storage.list_history(pick.query)
	if #pick.items == 0 then
		pick.idx = 1
	else
		pick.idx = math.min(old_idx, #pick.items)
	end
	render_list()
	preview_current()
end

function M.close()
	if not pick.open then
		return
	end
	cancel_timer()
	restore_cursor()
	pick.open = false
	local picker = require("csa.ui.picker")
	-- Esc / cancel without selecting: keep the session that was active before preview.
	if not pick.confirmed then
		if pick.resume_output then
			picker.restore_output(pick.resume_output)
		end
		if pick.resume_session_id then
			picker.set_session_id(pick.resume_session_id)
		end
	end
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
	pick.idx = 1
	pick.confirmed = false
	pick.resume_session_id = nil
	pick.resume_output = nil
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
		vim.keymap.set({ "n", "i" }, "<Esc>", cancel, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA cancel history",
		})
		vim.keymap.set("n", "q", cancel, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA cancel history",
		})
		-- No multi-select: Enter opens the highlighted history.
		map_ni(buf, "<CR>", open_current, "CSA open history")
		map_ni(buf, "<Tab>", function()
			move_idx(1)
		end, "CSA next row")
		map_ni(buf, "<S-Tab>", function()
			move_idx(-1)
		end, "CSA prev row")
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

	-- Normal-mode delete (same idea as Files panel `d`).
	for _, buf in ipairs({ search, list }) do
		vim.keymap.set("n", "d", delete_current, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA delete history",
		})
	end

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

--- Open history browser (same chrome as file picker; no multi-select).
function M.pick()
	local picker = require("csa.ui.picker")
	if not picker.is_open() or picker.is_stream_locked() then
		return
	end
	if pick.open then
		focus_search()
		return
	end

	-- Close other pickers if open.
	local files = require("csa.ui.files")
	local models = require("csa.ui.models")
	if files.is_open() then
		files.close()
	end
	if models.is_open() then
		models.close()
	end
	if picker.state().show_files then
		picker.set_files_visible(false)
	end

	storage.ensure()
	pick.query = ""
	pick.items = {}
	pick.idx = 1
	pick.confirmed = false
	-- Snapshot current chat so cancel can restore it after list previews.
	pick.resume_session_id = picker.session_id()
	pick.resume_output = picker.snapshot_output()
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

	local title = " 󰋚  History "
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
				schedule_refresh()
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

	refresh()
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
			title = " 󰋚  History ",
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

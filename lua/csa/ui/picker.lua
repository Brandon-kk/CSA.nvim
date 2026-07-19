local config = require("csa.config")
local highlights = require("csa.highlights")

local M = {}

---@alias CSA.Panel "output"|"files"|"input"

---@class CSA.PickerState
---@field open boolean
---@field show_files boolean
---@field picking boolean
---@field session_id string|nil current chat session (one history file)
---@field stream_lock boolean lock CSA shortcuts while AI streams
---@field follow_output boolean auto-stick Output to bottom while streaming
---@field ai_mode "ask"|"agent"|"plan" runtime provider mode
---@field mode_locked boolean when true (CSAsk / CSAgents), `[`/`]` cannot change mode
---@field model string selected model id (`auto` omits --model)
---@field files string[]
---@field bufs { output: integer|nil, files: integer|nil, input: integer|nil, pad: integer|nil }
---@field wins { output: integer|nil, files: integer|nil, input: integer|nil, pad: integer|nil }
---@field prev_win integer|nil
---@field augroup integer|nil
---@field suppress_close boolean
---@field suspended boolean hide floats under LazyGit / other overlays
---@field saved_guicursor string|nil
---@field saved_fillchars string|nil
---@field saved_equalalways boolean|nil
---@field msg_spans { role: string, start_row: integer, end_row: integer }[] Output message ranges (0-based)
---@field active_msg_idx integer|nil selected message in Output (1-based); used by [ ] / regen / edit
---@field seed_history_once boolean next ask should seed local history (after edit-resend)
---@field usage { last: CSA.TokenUsage|nil, session_input: integer, session_output: integer, context_limit: integer }|nil

---@type CSA.PickerState
local state = {
	open = false,
	show_files = false,
	picking = false,
	session_id = nil,
	stream_lock = false,
	follow_output = true,
	ai_mode = "agent",
	mode_locked = false,
	model = "auto",
	files = {},
	bufs = {},
	wins = {},
	prev_win = nil,
	augroup = nil,
	suppress_close = false,
	suspended = false,
	saved_guicursor = nil,
	saved_fillchars = nil,
	saved_equalalways = nil,
	msg_spans = {},
	active_msg_idx = nil,
	seed_history_once = false,
	usage = nil,
}

-- Stay below Snacks defaults (50+) so LazyGit / pickers cover CSA.
local CSA_ZINDEX = 45

local model_tag_ns = vim.api.nvim_create_namespace("csa_model_tag")
-- Nerd Font round caps (U+E0B6 / U+E0B4). Plain ASCII space parks the cursor after the pill.
local TAG_CAP_L = vim.fn.nr2char(0xe0b6)
local TAG_CAP_R = vim.fn.nr2char(0xe0b4)
local TAG_CURSOR_PAD = " "

local AI_MODES = { "plan", "agent", "ask" }

---@param mode any
---@return "ask"|"agent"|"plan"
local function normalize_ai_mode(mode)
	if mode == "ask" or mode == "agent" or mode == "plan" then
		return mode
	end
	return "agent"
end

local PANEL_ORDER = { "output", "files", "input" }

local function win_valid(win)
	return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function buf_valid(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

--- Attach render-markdown to the Output buffer (handles ft lazy-load skip).
local function attach_output_markdown()
	local buf = state.bufs.output
	if not buf_valid(buf) then
		return
	end
	-- .md suffix helps tools that key off extension; filetype is the attach key.
	pcall(vim.api.nvim_buf_set_name, buf, "csa://output.md")
	vim.b[buf].csa_panel = "output"
	vim.bo[buf].filetype = "markdown"

	local win = state.wins.output
	if win_valid(win) then
		vim.wo[win].conceallevel = 2
		vim.wo[win].concealcursor = "nvc"
	end

	vim.schedule(function()
		if not buf_valid(buf) then
			return
		end
		local owin = state.wins.output
		local saved_view = nil
		if win_valid(owin) and not state.follow_output then
			local ok, view = pcall(vim.api.nvim_win_call, owin, function()
				return vim.fn.winsaveview()
			end)
			if ok then
				saved_view = view
			end
		end
		local ok_rm, rm = pcall(require, "render-markdown")
		if not ok_rm then
			return
		end
		local manager = require("render-markdown.core.manager")
		-- Lazy ft load often skips the buffer that triggered load; re-fire + attach.
		if not manager.attached(buf) then
			pcall(vim.api.nvim_exec_autocmds, "FileType", {
				buffer = buf,
				modeline = false,
			})
		end
		if not manager.attached(buf) then
			pcall(manager.attach, buf)
		end
		if manager.attached(buf) then
			pcall(manager.set_buf, buf, true)
		end
		pcall(rm.render, {
			buf = buf,
			win = owin,
			event = "CSAAttach",
		})
		if saved_view and win_valid(owin) then
			pcall(vim.api.nvim_win_call, owin, function()
				vim.fn.winrestview(saved_view)
			end)
		elseif state.follow_output and win_valid(owin) and buf_valid(buf) then
			local last = vim.api.nvim_buf_line_count(buf)
			pcall(vim.api.nvim_win_set_cursor, owin, { last, 0 })
		end
	end)
end

---@param kind string
---@param name string
---@param lines string[]
local function ensure_buf(kind, name, lines)
	local buf = state.bufs[kind]
	if not buf_valid(buf) then
		buf = vim.api.nvim_create_buf(false, true)
		state.bufs[kind] = buf
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		if kind == "output" then
			pcall(vim.api.nvim_buf_set_name, buf, "csa://output.md")
			vim.bo[buf].filetype = "markdown"
			vim.b[buf].csa_panel = "output"
		else
			pcall(vim.api.nvim_buf_set_name, buf, "csa://" .. name)
			vim.bo[buf].filetype = "csa-" .. kind
		end
		-- Set lines before locking output/files as non-modifiable.
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		if kind ~= "input" then
			vim.bo[buf].modifiable = false
			if kind == "output" then
				vim.bo[buf].readonly = true
			end
		end
		-- Avoid blink.cmp / path completion popups in CSA panels.
		vim.b[buf].completion = false
	elseif kind == "output" then
		pcall(vim.api.nvim_buf_set_name, buf, "csa://output.md")
		vim.bo[buf].filetype = "markdown"
		vim.b[buf].csa_panel = "output"
	end
	return buf
end

local function titled(icon, title)
	return string.format(" %s  %s ", icon, title)
end

local function mode_label(mode)
	mode = normalize_ai_mode(mode)
	return mode:sub(1, 1):upper() .. mode:sub(2)
end

---@param hl? string highlight group for border glyphs
local function border_chars(hl)
	hl = hl or "CSABorder"
	local b = config.border()
	if type(b) == "table" then
		return b
	end
	local chars = {
		rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
		single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
		double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
	}
	local c = chars[b] or chars.rounded
	return {
		{ c[1], hl },
		{ c[2], hl },
		{ c[3], hl },
		{ c[4], hl },
		{ c[5], hl },
		{ c[6], hl },
		{ c[7], hl },
		{ c[8], hl },
	}
end

local function input_border_hl()
	return "CSABorder" .. mode_label(state.ai_mode)
end

--- Infer context window size from model id / bracket overrides.
---@param model? string
---@return integer
local function context_limit_for_model(model)
	if type(model) ~= "string" or model == "" or model:lower() == "auto" then
		return 200000
	end
	local m = model:lower()
	local bracket = m:match("%[context=([^,%]]+)")
	if bracket then
		if bracket:find("m", 1, true) then
			local n = tonumber((bracket:gsub("m", "")))
			if n then
				return math.floor(n * 1000000)
			end
		end
		local n = tonumber(bracket)
		if n then
			return n >= 10000 and math.floor(n) or math.floor(n * 1000)
		end
	end
	if m:find("context=1m", 1, true) or m:find("1m", 1, true) then
		return 1000000
	end
	if m:find("gemini%-2") or m:find("gemini%-3") then
		return 1000000
	end
	return 200000
end

---@param n integer
---@return string
local function fmt_tokens(n)
	n = math.max(0, math.floor(tonumber(n) or 0))
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	end
	if n >= 10000 then
		return string.format("%dk", math.floor(n / 1000 + 0.5))
	end
	if n >= 1000 then
		return string.format("%.1fk", n / 1000)
	end
	return tostring(n)
end

---@return string|nil
local function usage_title_suffix()
	local u = state.usage
	if not u or not u.last then
		return nil
	end
	local last = u.last
	local used = last.context_used or 0
	local limit = u.context_limit or context_limit_for_model(state.model)
	if used <= 0 and (last.total_tokens or 0) <= 0 then
		return nil
	end
	if used <= 0 then
		used = last.total_tokens or 0
	end
	if limit > 0 then
		local pct = math.min(100, math.floor((used / limit) * 100 + 0.5))
		return string.format("%s/%s · %d%%", fmt_tokens(used), fmt_tokens(limit), pct)
	end
	return string.format("↑%s ↓%s", fmt_tokens(last.input_tokens), fmt_tokens(last.output_tokens))
end

local function input_title()
	local label = "Input · " .. mode_label(state.ai_mode)
	local usage = usage_title_suffix()
	if usage then
		label = label .. " · " .. usage
	end
	return titled(config.icon("input"), label)
end

local function panel_winhighlight(kind)
	if kind == "input" then
		local suffix = mode_label(state.ai_mode)
		return table.concat({
			"Normal:CSANormal",
			"NormalFloat:CSANormal",
			"FloatBorder:CSABorder" .. suffix,
			"FloatTitle:CSATitle" .. suffix,
		}, ",")
	end
	return table.concat({
		"Normal:CSANormal",
		"NormalFloat:CSANormal",
		"FloatBorder:CSABorder",
		"FloatTitle:CSATitle",
	}, ",")
end

local function refresh_input_mode_ui()
	local win = state.wins.input
	if not win_valid(win) then
		return
	end
	pcall(vim.api.nvim_win_set_config, win, {
		border = border_chars(input_border_hl()),
		title = input_title(),
		title_pos = "center",
	})
	vim.wo[win].winhighlight = panel_winhighlight("input")
	M.refresh_model_tag()
end

--- Apply token usage from the provider stream (last turn + session totals).
---@param usage CSA.TokenUsage
function M.set_usage(usage)
	if type(usage) ~= "table" then
		return
	end
	local limit = context_limit_for_model(state.model)
	local prev = state.usage
	state.usage = {
		last = usage,
		session_input = (prev and prev.session_input or 0) + (usage.input_tokens or 0),
		session_output = (prev and prev.session_output or 0) + (usage.output_tokens or 0),
		context_limit = limit,
	}
	if state.open then
		refresh_input_mode_ui()
	end
end

function M.clear_usage()
	state.usage = nil
	if state.open then
		refresh_input_mode_ui()
	end
end

--- Cycle plan ↔ agent ↔ ask. No-op when locked (CSAsk / CSAgents) or streaming.
---@param step integer +1 or -1
function M.cycle_ai_mode(step)
	if not state.open or state.mode_locked or state.stream_lock or state.picking then
		return
	end
	local idx = 1
	for i, m in ipairs(AI_MODES) do
		if m == state.ai_mode then
			idx = i
			break
		end
	end
	local n = #AI_MODES
	idx = ((idx - 1 + (step or 1)) % n) + 1
	state.ai_mode = AI_MODES[idx]
	refresh_input_mode_ui()
end

function M.ai_mode()
	return state.ai_mode
end

function M.is_mode_locked()
	return state.mode_locked
end

--- Keep a single ASCII space so the cursor can sit after the inline pill.
local function ensure_tag_cursor_pad(buf)
	local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
	local mod = vim.bo[buf].modifiable
	if line == nil then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { TAG_CURSOR_PAD })
		vim.bo[buf].modifiable = mod
		return
	end
	if line == "" then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { TAG_CURSOR_PAD })
		vim.bo[buf].modifiable = mod
	end
end

--- Refresh the rounded model pill (caps + body). Colors match the mode border.
function M.refresh_model_tag()
	local buf = state.bufs.input
	if not buf_valid(buf) then
		return
	end
	ensure_tag_cursor_pad(buf)
	vim.api.nvim_buf_clear_namespace(buf, model_tag_ns, 0, -1)
	local label = state.model or "auto"
	local body = highlights.model_tag_group(state.ai_mode)
	local edge = highlights.model_tag_edge_group(state.ai_mode)
	pcall(vim.api.nvim_buf_set_extmark, buf, model_tag_ns, 0, 0, {
		virt_text = {
			{ TAG_CAP_L, edge },
			{ label, body },
			{ TAG_CAP_R, edge },
			-- One cell gap between the pill and the cursor.
			{ " ", "CSANormal" },
		},
		virt_text_pos = "inline",
		right_gravity = false,
	})
end

--- Park cursor on the pad space — one character after the pill.
function M.cursor_after_model_tag()
	local win = state.wins.input
	local buf = state.bufs.input
	if not (win_valid(win) and buf_valid(buf)) then
		return
	end
	ensure_tag_cursor_pad(buf)
	M.refresh_model_tag()
	-- Buffer col 0 sits after virt_text (pill + gap space).
	pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

--- After leaving insert, Esc often lands on/before the inline pill. Re-park
--- only when the line has no real user text.
local function restore_cursor_after_tag_if_blank()
	local win = state.wins.input
	local buf = state.bufs.input
	if not state.open or not (win_valid(win) and buf_valid(buf)) then
		return
	end
	if vim.api.nvim_get_current_win() ~= win then
		return
	end
	local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
	if vim.trim(line) ~= "" then
		return
	end
	M.cursor_after_model_tag()
end

---@return string
function M.model()
	return state.model or "auto"
end

---@param name string
function M.set_model(name)
	if type(name) ~= "string" or vim.trim(name) == "" then
		return
	end
	state.model = vim.trim(name)
	pcall(require("csa.storage").save_selected_model, state.model)
	if state.usage then
		state.usage.context_limit = context_limit_for_model(state.model)
	end
	M.refresh_model_tag()
	refresh_input_mode_ui()
end

local function editor_size()
	local ui = vim.api.nvim_list_uis()[1]
	if ui then
		return ui.width, ui.height
	end
	return vim.o.columns, vim.o.lines
end

---@return CSA.Panel[]
local function visible_panels()
	if state.picking then
		return { "output", "input" }
	end
	if state.show_files then
		return { "output", "files", "input" }
	end
	return { "output", "input" }
end

--- Target total columns taken from the editor (pad width + 1 separator).
local function target_total_width()
	local editor_width = editor_size()
	return math.max(24, math.floor(editor_width * config.width()))
end

--- Layout floats inside the pad window (relative="win") so borders stay in-column.
local function layout()
	if not win_valid(state.wins.pad) then
		return nil
	end

	local pad_w = vim.api.nvim_win_get_width(state.wins.pad)
	local pad_h = vim.api.nvim_win_get_height(state.wins.pad)
	-- Fit L/R borders inside the pad: border@0, content@1..(pad_w-2), border@(pad_w-1)
	local width = math.max(10, pad_w - 2)
	local col = 1

	local input_h = math.max(1, config.input_height())
	local max_files = math.max(1, config.files_num())
	local list_h = require("csa.ui.files").list_height()
	local search_h = 1

	local output_h, files_h = 3, 0
	local pick_search, pick_list

	if state.picking then
		-- output + search + list + input → 4 bordered stacks (8 chrome rows)
		local chrome = 8
		local usable = math.max(6, pad_h - chrome)
		local pick_block = search_h + list_h
		output_h = math.max(3, usable - input_h - pick_block)
		local row_output = 0
		local row_search = row_output + output_h + 2
		local row_list = row_search + search_h + 1 -- shared connector border
		local row_input = row_list + list_h + 2
		pick_search = { row = row_search, height = search_h }
		pick_list = { row = row_list, height = list_h }
		return {
			pad = pad_w,
			width = width,
			col = col,
			output = { row = row_output, height = output_h },
			files = { row = row_search, height = 0 },
			pick_search = pick_search,
			pick_list = pick_list,
			input = { row = row_input, height = input_h },
		}
	end

	local panels = visible_panels()
	local chrome = #panels * 2
	local usable = math.max(6, pad_h - chrome)
	if state.show_files then
		local n = math.max(1, #state.files)
		files_h = math.min(max_files, n)
		output_h = math.max(3, usable - input_h - files_h)
	else
		files_h = 0
		output_h = math.max(3, usable - input_h)
	end

	local row_output = 0
	local row_files = row_output + output_h + 2
	local row_input = state.show_files and (row_files + files_h + 2) or (row_output + output_h + 2)

	return {
		pad = pad_w,
		width = width,
		col = col,
		output = { row = row_output, height = output_h },
		files = { row = row_files, height = files_h },
		input = { row = row_input, height = input_h },
	}
end

local panel_style = {
	output = { title = "Output", icon_key = "output" },
	files = { title = "Files", icon_key = "files" },
	input = { title = "Input", icon_key = "input" },
}

---@param kind CSA.Panel
---@param buf integer
---@param geo { row: integer, height: integer }
---@param width integer
---@param col integer
---@param enter boolean
local function open_float(kind, buf, geo, width, col, enter)
	local style = panel_style[kind]
	local title = kind == "input" and input_title() or titled(config.icon(style.icon_key), style.title)
	local border_hl = kind == "input" and input_border_hl() or "CSABorder"
	local win = vim.api.nvim_open_win(buf, enter, {
		relative = "win",
		win = state.wins.pad,
		width = width,
		height = geo.height,
		row = geo.row,
		col = col,
		style = "minimal",
		border = border_chars(border_hl),
		title = title,
		title_pos = "center",
		zindex = CSA_ZINDEX,
		-- Output is focusable so [ ] / regen / edit can target the cursor message.
		-- <C-w>* is rebound to the main editor (see bind_leave_to_main).
		focusable = true,
		noautocmd = true,
	})
	vim.w[win].csa_panel = kind
	-- Output/Input wrap long prose. Wide pipe tables are still reflowed to the
	-- panel width by csa.ui.tables so they stay readable with wrap on.
	local wrap = kind == "output" or kind == "input"
	vim.wo[win].wrap = wrap
	vim.wo[win].linebreak = wrap
	vim.wo[win].breakindent = kind == "output"
	vim.wo[win].cursorline = false
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].scrolloff = 0
	vim.wo[win].list = false
	if kind == "output" then
		-- Required for render-markdown conceal-based rendering.
		vim.wo[win].conceallevel = 2
		vim.wo[win].concealcursor = "nvc"
	end
	vim.wo[win].winhighlight = panel_winhighlight(kind)
	state.wins[kind] = win
	if kind == "output" then
		attach_output_markdown()
	end
	return win
end

--- Placeholder vsplit: this width (+ separator) is the only squeeze.
local function open_pad(pad_width)
	state.prev_win = vim.api.nvim_get_current_win()
	ensure_buf("pad", "pad", { "" })
	-- Keep equalalways off while CSA is open; restoring it would 50/50 the split.
	if state.saved_equalalways == nil then
		state.saved_equalalways = vim.o.equalalways
	end
	vim.o.equalalways = false
	vim.cmd("botright vnew")
	local pad = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(pad, state.bufs.pad)
	vim.api.nvim_win_set_width(pad, pad_width)
	vim.wo[pad].winhighlight = "Normal:CSAPad,EndOfBuffer:CSAPad,WinSeparator:CSAPadSep,VertSplit:CSAPadSep"
	vim.wo[pad].number = false
	vim.wo[pad].relativenumber = false
	vim.wo[pad].signcolumn = "no"
	vim.wo[pad].foldcolumn = "0"
	vim.wo[pad].list = false
	vim.wo[pad].statusline = "%#CSAPad#"
	vim.wo[pad].winbar = ""
	state.wins.pad = pad
	-- Hide the vertical split glyph while CSA reserves the column.
	if state.saved_fillchars == nil then
		state.saved_fillchars = vim.o.fillchars
		pcall(function()
			local fc = vim.opt.fillchars:get()
			fc.vert = " "
			vim.opt.fillchars = fc
		end)
	end
	-- Re-assert width after split machinery settles.
	vim.api.nvim_win_set_width(pad, pad_width)
	if win_valid(state.prev_win) then
		pcall(vim.api.nvim_set_current_win, state.prev_win)
	end
end



local function restore_cursor()
	if state.saved_guicursor ~= nil then
		vim.o.guicursor = state.saved_guicursor
		state.saved_guicursor = nil
	end
end

local function hide_cursor()
	if state.saved_guicursor == nil then
		state.saved_guicursor = vim.o.guicursor
	end
	vim.api.nvim_set_hl(0, "CSAHiddenCursor", { blend = 100, nocombine = true })
	vim.o.guicursor = "a:CSAHiddenCursor"
end

local function sync_files_focus()
	local files_win = state.wins.files
	local output_win = state.wins.output
	local cur = vim.api.nvim_get_current_win()
	if win_valid(files_win) then
		local focused = cur == files_win
		vim.wo[files_win].cursorline = focused
		if focused then
			hide_cursor()
		end
	end
	if win_valid(output_win) then
		vim.wo[output_win].cursorline = cur == output_win
	end
	-- Restore block cursor when leaving Files (Output keeps a normal cursor).
	if not (win_valid(files_win) and cur == files_win) then
		restore_cursor()
	end
end

local function close_wins()
	restore_cursor()
	pcall(function()
		local files = require("csa.ui.files")
		if files.is_open() then
			files.close()
		end
	end)
	pcall(function()
		local history = require("csa.ui.history")
		if history.is_open() then
			history.close()
		end
	end)
	pcall(function()
		local models = require("csa.ui.models")
		if models.is_open() then
			models.close()
		end
	end)
	if state.saved_fillchars ~= nil then
		vim.o.fillchars = state.saved_fillchars
		state.saved_fillchars = nil
	end
	state.suppress_close = true
	for _, kind in ipairs({ "output", "files", "input", "pad" }) do
		local win = state.wins[kind]
		if win_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		state.wins[kind] = nil
	end
	state.suppress_close = false
	state.suspended = false
	if state.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
		state.augroup = nil
	end
	state.open = false
	state.picking = false
	if state.saved_equalalways ~= nil then
		vim.o.equalalways = state.saved_equalalways
		state.saved_equalalways = nil
	end
	if win_valid(state.prev_win) then
		pcall(vim.api.nvim_set_current_win, state.prev_win)
	end
end


--- Indices of user-sent messages only (Tab / [ ] land here).
---@return integer[]
local function user_message_indices()
	local out = {}
	for i, span in ipairs(state.msg_spans) do
		if span.role == "user" then
			out[#out + 1] = i
		end
	end
	return out
end

--- Prefer `prefer` if it is a user message; else nearest user at/before it; else last user.
---@param prefer? integer
---@return integer|nil
local function resolve_user_msg_idx(prefer)
	local users = user_message_indices()
	if #users == 0 then
		return nil
	end
	if prefer and state.msg_spans[prefer] and state.msg_spans[prefer].role == "user" then
		return prefer
	end
	local cur = prefer or users[#users]
	local pos = 1
	for i, idx in ipairs(users) do
		if idx <= cur then
			pos = i
		else
			break
		end
	end
	return users[pos]
end

--- Place Output cursor on a user message header.
---@param win integer
---@param idx? integer preferred span index
---@param opts? { zt?: boolean }
local function land_on_user_message(win, idx, opts)
	opts = opts or {}
	idx = resolve_user_msg_idx(idx)
	if not idx or not win_valid(win) then
		return
	end
	local span = state.msg_spans[idx]
	if not span then
		return
	end
	state.active_msg_idx = idx
	local row = span.start_row + 1
	pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
	if opts.zt then
		pcall(vim.api.nvim_win_call, win, function()
			vim.cmd("normal! zt")
		end)
	end
end

---@param kind CSA.Panel
---@param opts? { insert?: boolean }
local function focus_panel(kind, opts)
	opts = opts or {}
	local win = state.wins[kind]
	if not win_valid(win) then
		return
	end
	-- Input defaults to normal mode; pass insert=true only when explicitly wanted.
	local want_insert = opts.insert == true
	if not want_insert and vim.fn.mode():find("[iR]") then
		pcall(vim.cmd, "stopinsert")
	end
	pcall(vim.api.nvim_set_current_win, win)
	sync_files_focus()
	if kind == "input" then
		M.cursor_after_model_tag()
		if want_insert then
			vim.schedule(function()
				if win_valid(win) then
					pcall(vim.api.nvim_set_current_win, win)
					M.cursor_after_model_tag()
					-- Insert at end of pad so Esc leaves the cursor on the pad
					-- (after the pill), not on the virt-text itself.
					pcall(vim.cmd, "startinsert!")
					sync_files_focus()
				end
			end)
		end
	elseif kind == "output" then
		-- Tab into Output always lands on a user-sent message.
		land_on_user_message(win, state.active_msg_idx or #state.msg_spans, { zt = true })
	end
end

function M.focus(kind, opts)
	if not state.open then
		return
	end
	focus_panel(kind, opts)
end

function M.focus_input_after(opts)
	opts = opts or { insert = false }
	vim.schedule(function()
		vim.schedule(function()
			if not M.is_open() then
				return
			end
			focus_panel("input", opts)
		end)
	end)
end

--- Cycle focus among visible CSA panels only (never the main editor).
---@param step integer|nil +1 Tab, -1 S-Tab
function M.focus_next(step)
	if not state.open or state.picking or state.stream_lock then
		return
	end
	step = (type(step) == "number" and step < 0) and -1 or 1
	local panels = visible_panels()
	if #panels == 0 then
		return
	end
	local cur = vim.api.nvim_get_current_win()
	local idx = 1
	for i, kind in ipairs(panels) do
		if state.wins[kind] == cur then
			idx = i
			break
		end
	end
	local next_kind = panels[((idx - 1 + step) % #panels) + 1]
	focus_panel(next_kind, { insert = false })
end

---@deprecated use focus_next
function M.focus_toggle_main()
	M.focus_next(1)
end

local files_ns = vim.api.nvim_create_namespace("csa_files")

local function display_name(path)
	local rel = vim.fn.fnamemodify(path, ":.")
	if rel:sub(1, 1) ~= "/" and not rel:match("^%a:[/\\]") then
		return rel
	end
	return vim.fn.fnamemodify(path, ":t")
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


local function truncate_width(text, max_width)
	if max_width < 1 then
		return ""
	end
	if vim.fn.strdisplaywidth(text) <= max_width then
		return text
	end
	if max_width <= 1 then
		return "…"
	end
	local ellipsis = "…"
	local budget = max_width - vim.fn.strdisplaywidth(ellipsis)
	local out = {}
	local w = 0
	for _, chars in ipairs(vim.fn.str2list(text)) do
		local ch = vim.fn.nr2char(chars)
		local cw = vim.fn.strdisplaywidth(ch)
		if w + cw > budget then
			break
		end
		out[#out + 1] = ch
		w = w + cw
	end
	return table.concat(out) .. ellipsis
end

local function render_files()
	local buf = state.bufs.files
	if not buf_valid(buf) then
		return
	end

	local win_w = win_valid(state.wins.files) and vim.api.nvim_win_get_width(state.wins.files) or 40
	local left_pad = 1
	local right_pad = 1
	local lines = {}
	---@type { hl: string, end_col: integer, stats?: table[] }[]
	local meta = {}
	local review = require("csa.review")

	if #state.files == 0 then
		lines[1] = " (no files)"
		meta[1] = { hl = "Comment", end_col = #lines[1] }
	else
		for _, path in ipairs(state.files) do
			local icon, hl = file_icon(path)
			local icon_w = vim.fn.strdisplaywidth(icon)
			local edit = review.get(path)
			local stats_chunks = nil
			local stats_w = 0
			if edit then
				local _, chunks = review.format_stats(edit.added, edit.removed)
				stats_chunks = chunks
				for _, c in ipairs(chunks) do
					stats_w = stats_w + vim.fn.strdisplaywidth(c[1])
				end
				stats_w = stats_w + 1 -- gap before right-aligned stats
			end
			local name_max = win_w - left_pad - icon_w - 1 - right_pad - stats_w
			local name = truncate_width(display_name(path), math.max(1, name_max))
			local line = string.rep(" ", left_pad) .. icon .. " " .. name
			lines[#lines + 1] = line
			meta[#meta + 1] = { hl = hl, end_col = #line, stats = stats_chunks }
		end
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(buf, files_ns, 0, -1)
	for i, m in ipairs(meta) do
		vim.api.nvim_buf_set_extmark(buf, files_ns, i - 1, 0, {
			end_col = m.end_col,
			hl_group = m.hl,
			hl_mode = "combine",
		})
		if m.stats then
			vim.api.nvim_buf_set_extmark(buf, files_ns, i - 1, 0, {
				virt_text = m.stats,
				virt_text_pos = "right_align",
				-- replace: avoid combining Diff* backgrounds from theme links
				hl_mode = "replace",
			})
		end
	end
end

function M.refresh_files()
	if state.open and state.show_files then
		render_files()
	end
end

local function target_edit_win()
	if win_valid(state.prev_win) and state.prev_win ~= state.wins.pad then
		local cfg = vim.api.nvim_win_get_config(state.prev_win)
		if cfg.relative == "" then
			return state.prev_win
		end
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if win ~= state.wins.pad and win ~= state.wins.output and win ~= state.wins.files and win ~= state.wins.input then
			local cfg = vim.api.nvim_win_get_config(win)
			if cfg.relative == "" and not vim.w[win].csa_panel then
				return win
			end
		end
	end
	return nil
end

local function is_csa_ui_win(win)
	if not win_valid(win) then
		return false
	end
	for _, kind in ipairs({ "output", "files", "input", "pad" }) do
		if state.wins[kind] == win then
			return true
		end
	end
	if vim.w[win].csa_panel then
		return true
	end
	return false
end

--- LazyGit / Snacks / other fullscreen floats should cover CSA.
local function is_foreign_overlay(win)
	if not win_valid(win) or is_csa_ui_win(win) then
		return false
	end
	local cfg = vim.api.nvim_win_get_config(win)
	if cfg.relative == "" then
		return false
	end
	if vim.w[win].snacks_win then
		return true
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if vim.bo[buf].buftype == "terminal" then
		return true
	end
	-- Full-editor floats (LazyGit style).
	if cfg.relative == "editor" then
		local w = cfg.width or 0
		local h = cfg.height or 0
		if w == 0 or h == 0 or (w >= vim.o.columns - 2 and h >= vim.o.lines - 2) then
			return true
		end
	end
	return false
end

local function set_floats_hidden(hidden)
	for _, kind in ipairs({ "output", "files", "input" }) do
		local win = state.wins[kind]
		if win_valid(win) then
			pcall(vim.api.nvim_win_set_config, win, { hide = hidden and true or false })
		end
	end
end

local function suspend_for_overlay()
	if not state.open or state.suspended or state.picking then
		return
	end
	state.suspended = true
	set_floats_hidden(true)
end

local function resume_from_overlay()
	if not state.open or not state.suspended then
		return
	end
	state.suspended = false
	set_floats_hidden(false)
	render_files()
end

local function focus_main()
	if vim.fn.mode():find("[iR]") then
		pcall(vim.cmd, "stopinsert")
	end
	local main = target_edit_win()
	if main then
		pcall(vim.api.nvim_set_current_win, main)
	end
end

function M.focus_main()
	focus_main()
end

--- Native <C-w> from floats cycles other CSA floats first; bind common chords to the editor.
local LEAVE_WIN_KEYS = {
	"<C-w>w",
	"<C-w><C-w>",
	"<C-w>W",
	"<C-w>p",
	"<C-w>h",
	"<C-w>j",
	"<C-w>k",
	"<C-w>l",
	"<C-w>t",
	"<C-w>b",
	"<C-w><C-h>",
	"<C-w><C-j>",
	"<C-w><C-k>",
	"<C-w><C-l>",
}

local function bind_leave_to_main(buf)
	if not buf_valid(buf) then
		return
	end
	for _, lhs in ipairs(LEAVE_WIN_KEYS) do
		vim.keymap.set("n", lhs, function()
			focus_main()
		end, {
			buffer = buf,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA: focus main editor",
		})
	end
end

local output_ns = vim.api.nvim_create_namespace("csa_output")

--- Start an assistant block: icon + model, blank line, then body streamed below.
---@return string header
function M.begin_ai_response()
	local model = (type(state.model) == "string" and state.model ~= "" and state.model) or "auto"
	local header = string.format("%s %s", config.icon("output"), model)
	-- Header, blank separator, then an empty body line for status/stream.
	M.append_output_block({ header, "", "" }, header, "assistant")
	return header
end

local md_refresh_pending = false

--- True when Output view is already pinned near the last line.
local function output_at_bottom()
	local owin = state.wins.output
	local obuf = state.bufs.output
	if not (win_valid(owin) and buf_valid(obuf)) then
		return true
	end
	local ok, at_bottom = pcall(vim.api.nvim_win_call, owin, function()
		local height = vim.api.nvim_win_get_height(0)
		local last = vim.api.nvim_buf_line_count(obuf)
		local view = vim.fn.winsaveview()
		local max_top = math.max(1, last - height + 1)
		return (view.topline or 1) >= (max_top - 1)
	end)
	return ok and at_bottom
end

local function sync_follow_output()
	state.follow_output = output_at_bottom()
end

--- Move Output to the last line and enable stick-to-bottom.
local function jump_output_bottom()
	state.follow_output = true
	local owin = state.wins.output
	local obuf = state.bufs.output
	if not (win_valid(owin) and buf_valid(obuf)) then
		return
	end
	local last = vim.api.nvim_buf_line_count(obuf)
	pcall(vim.api.nvim_win_set_cursor, owin, { last, 0 })
end

--- Stick Output to the bottom only while follow_output is on (cleared by scroll).
local function follow_output_bottom()
	if not state.follow_output then
		return
	end
	jump_output_bottom()
end

local function refresh_output_markdown()
	local obuf = state.bufs.output
	local owin = state.wins.output
	if not buf_valid(obuf) then
		return
	end
	-- Preserve scroll position when the user has scrolled away from the bottom.
	local saved_view = nil
	if not state.follow_output and win_valid(owin) then
		local ok, view = pcall(vim.api.nvim_win_call, owin, function()
			return vim.fn.winsaveview()
		end)
		if ok then
			saved_view = view
		end
	end
	pcall(function()
		local rm = require("render-markdown")
		local manager = require("render-markdown.core.manager")
		if not manager.attached(obuf) then
			attach_output_markdown()
			return
		end
		rm.render({
			buf = obuf,
			win = owin,
			event = "CSAStream",
		})
	end)
	if state.follow_output then
		follow_output_bottom()
	elseif saved_view and win_valid(owin) then
		pcall(vim.api.nvim_win_call, owin, function()
			vim.fn.winrestview(saved_view)
		end)
	end
end

local function schedule_md_refresh()
	if md_refresh_pending then
		return
	end
	md_refresh_pending = true
	vim.defer_fn(function()
		md_refresh_pending = false
		refresh_output_markdown()
	end, 80)
end

--- Replace the last Output line (used for status / first stream chunk).
--- Splits embedded newlines — nvim_buf_set_lines rejects them in a single item.
---@param text string
function M.set_stream_tail(text)
	local obuf = state.bufs.output
	if not buf_valid(obuf) then
		return
	end
	text = tostring(text or ""):gsub("\r", "")
	local parts = vim.split(text, "\n", { plain = true })
	if #parts == 0 then
		parts = { "" }
	end
	vim.bo[obuf].modifiable = true
	vim.bo[obuf].readonly = false
	local last = vim.api.nvim_buf_line_count(obuf)
	vim.api.nvim_buf_set_lines(obuf, last - 1, last, false, parts)
	vim.bo[obuf].modifiable = false
	vim.bo[obuf].readonly = true
	if #state.msg_spans > 0 then
		state.msg_spans[#state.msg_spans].end_row = vim.api.nvim_buf_line_count(obuf)
	end
	follow_output_bottom()
	schedule_md_refresh()
end

--- Append streamed assistant text into Output (handles embedded newlines).
---@param delta string
function M.append_stream_text(delta)
	if type(delta) ~= "string" or delta == "" then
		return
	end
	local obuf = state.bufs.output
	if not buf_valid(obuf) then
		return
	end
	vim.bo[obuf].modifiable = true
	vim.bo[obuf].readonly = false
	local last = vim.api.nvim_buf_line_count(obuf)
	local cur = vim.api.nvim_buf_get_lines(obuf, last - 1, last, false)[1] or ""
	local parts = vim.split(delta, "\n", { plain = true })
	if #parts == 1 then
		vim.api.nvim_buf_set_lines(obuf, last - 1, last, false, { cur .. parts[1] })
	else
		local new_lines = { cur .. parts[1] }
		for i = 2, #parts do
			new_lines[#new_lines + 1] = parts[i]
		end
		vim.api.nvim_buf_set_lines(obuf, last - 1, last, false, new_lines)
	end
	vim.bo[obuf].modifiable = false
	vim.bo[obuf].readonly = true
	if #state.msg_spans > 0 then
		state.msg_spans[#state.msg_spans].end_row = vim.api.nvim_buf_line_count(obuf)
	end
	follow_output_bottom()
	schedule_md_refresh()
end

--- Finish assistant block with a trailing blank line.
function M.finish_ai_response()
	local obuf = state.bufs.output
	if not buf_valid(obuf) then
		return
	end
	vim.bo[obuf].modifiable = true
	vim.bo[obuf].readonly = false
	vim.api.nvim_buf_set_lines(obuf, -1, -1, false, { "" })
	-- Fit wide pipe tables into the Output width; keep them as real md tables
	-- so render-markdown can still beautify borders/alignment.
	pcall(require("csa.ui.tables").reflow_buf, obuf, state.wins.output)
	vim.bo[obuf].modifiable = false
	vim.bo[obuf].readonly = true
	if #state.msg_spans > 0 then
		state.msg_spans[#state.msg_spans].end_row = vim.api.nvim_buf_line_count(obuf)
	end
	-- Only stick if still at bottom; never force after the user scrolled away.
	follow_output_bottom()
	refresh_output_markdown()
end

--- Reload Output from the current session file (after truncate).
local function reload_session_output()
	local storage = require("csa.storage")
	if not state.session_id then
		state.msg_spans = {}
		M.restore_output({ lines = { "" }, marks = {} })
		return
	end
	local session = storage.load_history(state.session_id)
	if session and type(session.messages) == "table" and #session.messages > 0 then
		M.show_history(session)
	else
		state.msg_spans = {}
		M.restore_output({ lines = { "" }, marks = {} })
	end
end

---@return integer|nil idx, { role: string, start_row: integer, end_row: integer }|nil span
local function message_at_cursor()
	if #state.msg_spans == 0 then
		return nil, nil
	end
	local row
	if win_valid(state.wins.output) and vim.api.nvim_get_current_win() == state.wins.output then
		row = vim.api.nvim_win_get_cursor(state.wins.output)[1] - 1
		for i, span in ipairs(state.msg_spans) do
			if row >= span.start_row and row < span.end_row then
				state.active_msg_idx = i
				return i, span
			end
		end
	end
	-- Prefer the message selected with [ ] / ] in Output.
	if state.active_msg_idx and state.msg_spans[state.active_msg_idx] then
		return state.active_msg_idx, state.msg_spans[state.active_msg_idx]
	end
	-- Fallback: last message (e.g. Input `R`).
	state.active_msg_idx = #state.msg_spans
	return #state.msg_spans, state.msg_spans[#state.msg_spans]
end

--- Move Output cursor to prev/next *user* message (wraps). Used by `[` / `]`.
---@param step integer -1 previous, +1 next
function M.goto_message(step)
	if not state.open or state.picking or state.stream_lock then
		return
	end
	local users = user_message_indices()
	if #users == 0 then
		vim.notify("CSA: no user messages", vim.log.levels.INFO, { title = "CSA" })
		return
	end
	step = (type(step) == "number" and step < 0) and -1 or 1
	local cur = select(1, message_at_cursor()) or state.active_msg_idx or users[#users]
	local pos = 1
	for i, idx in ipairs(users) do
		if idx <= cur then
			pos = i
		else
			break
		end
	end
	pos = ((pos - 1 + step) % #users) + 1
	state.follow_output = false
	local owin = state.wins.output
	if not win_valid(owin) then
		return
	end
	-- Focus Output first, then place on the target user message (avoid focus_panel snap).
	pcall(vim.api.nvim_set_current_win, owin)
	land_on_user_message(owin, users[pos], { zt = true })
	sync_files_focus()
end

---@param idx integer
---@return integer|nil user_idx
local function user_index_for(idx)
	local storage = require("csa.storage")
	local session = state.session_id and storage.load_history(state.session_id)
	local msgs = session and session.messages or nil
	if type(msgs) ~= "table" or #msgs == 0 then
		-- Fall back to spans when history is missing (e.g. mid-stream).
		local span = state.msg_spans[idx]
		if not span then
			return nil
		end
		if span.role == "user" then
			return idx
		end
		for i = idx - 1, 1, -1 do
			if state.msg_spans[i] and state.msg_spans[i].role == "user" then
				return i
			end
		end
		return nil
	end
	idx = math.max(1, math.min(idx, #msgs))
	if msgs[idx].role == "user" then
		return idx
	end
	for i = idx - 1, 1, -1 do
		if msgs[i].role == "user" then
			return i
		end
	end
	return nil
end

---@param idx integer
---@return string[]
local function message_body_lines(idx)
	local span = state.msg_spans[idx]
	local obuf = state.bufs.output
	if not span or not buf_valid(obuf) then
		return {}
	end
	local lines = vim.api.nvim_buf_get_lines(obuf, span.start_row, span.end_row, false)
	if #lines > 0 then
		table.remove(lines, 1) -- header
	end
	-- Drop the blank line between header and body.
	if #lines > 0 and lines[1] == "" then
		table.remove(lines, 1)
	end
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	return lines
end

--- Copy message body under cursor (or last message) to clipboard + unnamed register.
function M.copy_message()
	if not state.open or state.stream_lock then
		return
	end
	local idx = message_at_cursor()
	if not idx then
		vim.notify("CSA: no message to copy", vim.log.levels.INFO, { title = "CSA" })
		return
	end
	local lines = message_body_lines(idx)
	if #lines == 0 then
		local storage = require("csa.storage")
		local session = state.session_id and storage.load_history(state.session_id)
		local msg = session and session.messages and session.messages[idx]
		if msg then
			if type(msg.lines) == "table" and #msg.lines > 0 then
				lines = msg.lines
			elseif type(msg.content) == "string" then
				lines = vim.split(msg.content, "\n", { plain = true })
			end
		end
	end
	if #lines == 0 then
		vim.notify("CSA: empty message", vim.log.levels.INFO, { title = "CSA" })
		return
	end
	local text = table.concat(lines, "\n")
	vim.fn.setreg('"', text)
	pcall(vim.fn.setreg, "+", text)
	vim.notify("CSA: copied message", vim.log.levels.INFO, { title = "CSA" })
end

--- Run an AI turn without appending a new user bubble (regenerate path).
---@param prompt string
---@param opts? { seed_history?: boolean }
local function run_ai_request(prompt, opts)
	opts = opts or {}
	if not config.provider_enabled() then
		return
	end
	local cursor_ai = require("csa.ai.cursor")
	if cursor_ai.is_busy() then
		vim.notify("CSA: AI request in progress", vim.log.levels.WARN, { title = "CSA" })
		return
	end
	local storage = require("csa.storage")
	if not state.session_id then
		state.session_id = storage.random_id()
	end
	local files = vim.deepcopy(state.files)
	local seed = opts.seed_history and true or false
	local review = require("csa.review")
	review.begin_turn()
	M.begin_ai_response()
	jump_output_bottom()
	M.set_stream_lock(true)
	local status_pending = true
	M.set_stream_tail("starting…")
	local workspace = config.provider_workspace()
	---@param path string
	---@return string
	local function resolve_edit_path(path)
		if type(path) ~= "string" or path == "" then
			return path
		end
		if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
			return path
		end
		return vim.fs.joinpath(workspace, path)
	end
	cursor_ai.ask({
		session_id = state.session_id,
		prompt = prompt,
		files = files,
		mode = state.ai_mode,
		model = state.model,
		seed_history = seed,
		on_status = function(msg)
			if status_pending then
				M.set_stream_tail(msg)
			end
		end,
		on_delta = function(delta)
			if status_pending then
				status_pending = false
				M.set_stream_tail(delta)
			else
				M.append_stream_text(delta)
			end
		end,
		on_usage = function(usage)
			M.set_usage(usage)
		end,
		on_file_snapshot = function(path)
			if state.ai_mode ~= "agent" then
				return
			end
			review.snapshot(resolve_edit_path(path))
		end,
		on_file_edit = function(ev)
			if state.ai_mode ~= "agent" or type(ev) ~= "table" then
				return
			end
			local abs = resolve_edit_path(ev.path)
			if #files > 0 then
				local allowed = false
				local abs_norm = vim.fn.fnamemodify(abs, ":p")
				for _, f in ipairs(files) do
					if vim.fn.fnamemodify(f, ":p") == abs_norm then
						allowed = true
						break
					end
				end
				if not allowed then
					review.record({
						path = abs_norm,
						kind = ev.kind,
						after = ev.after,
						added = ev.added,
						removed = ev.removed,
						call_id = ev.call_id,
						attach = false,
						decorate = false,
					})
					review.reject(abs_norm)
					vim.notify(
						"CSA: blocked edit outside attached files\n" .. vim.fn.fnamemodify(abs_norm, ":."),
						vim.log.levels.WARN,
						{ title = "CSA" }
					)
					return
				end
			end
			review.record({
				path = abs,
				kind = ev.kind,
				after = ev.after,
				added = ev.added,
				removed = ev.removed,
				call_id = ev.call_id,
			})
		end,
		on_done = function(ok, text, err)
			if status_pending then
				status_pending = false
				if not text or text == "" then
					M.set_stream_tail("")
				end
			end
			if not ok then
				local msg = err or "AI request failed"
				if msg == "cancelled" then
					M.append_stream_text((text ~= "" and "\n" or "") .. "⚠ cancelled")
				else
					M.append_stream_text((text ~= "" and "\n" or "") .. "⚠ " .. msg)
				end
			elseif text == "" then
				M.append_stream_text("(empty response)")
			end
			local pending_n = review.count()
			if pending_n > 0 then
				M.append_stream_text(
					string.format("\n_Pending file edits: %d — `ca` accept · `cr` reject_", pending_n)
				)
			end
			M.finish_ai_response()
			M.set_stream_lock(false)
			M.refresh_files()
			local edits = review.drain_turn_edits()
			if ok and text ~= "" then
				local model = (type(state.model) == "string" and state.model ~= "" and state.model) or "auto"
				pcall(function()
					storage.append_message(state.session_id, {
						sender = model,
						role = "assistant",
						content = text,
						edits = edits,
					})
				end)
			end
			-- Failed/cancelled turns keep pending edits so the next rewind can restore files.
		end,
	})
end

--- Revert agent file edits belonging to messages that will be dropped, then truncate.
---@param keep_n integer keep first N history messages
local function rewind_and_truncate(keep_n)
	local storage = require("csa.storage")
	local review = require("csa.review")
	if not state.session_id then
		review.rewind_files({})
		return
	end
	local discarded = storage.messages_after(state.session_id, keep_n)
	review.rewind_files(discarded)
	storage.truncate_messages(state.session_id, keep_n)
	storage.clear_cursor_chat_id(state.session_id)
end

--- Regenerate the turn under the Output cursor (or active [ ] message).
--- Keeps that turn's user message; deletes it and everything below from Output,
--- reverts file edits from the deleted range, then streams a new reply.
function M.regenerate_message()
	if not state.open or state.picking or state.stream_lock then
		return
	end
	if not config.provider_enabled() then
		vim.notify("CSA: provider disabled", vim.log.levels.WARN, { title = "CSA" })
		return
	end
	local idx = message_at_cursor()
	if not idx then
		vim.notify("CSA: no message to regenerate", vim.log.levels.INFO, { title = "CSA" })
		return
	end
	local user_idx = user_index_for(idx)
	if not user_idx then
		vim.notify("CSA: no user message to regenerate from", vim.log.levels.INFO, { title = "CSA" })
		return
	end
	local storage = require("csa.storage")
	local session = state.session_id and storage.load_history(state.session_id)
	local msg = session and session.messages and session.messages[user_idx]
	local prompt
	if msg then
		prompt = msg.content
		if type(prompt) ~= "string" or prompt == "" then
			prompt = table.concat(msg.lines or {}, "\n")
		end
	else
		prompt = table.concat(message_body_lines(user_idx), "\n")
	end
	if type(prompt) ~= "string" or vim.trim(prompt) == "" then
		vim.notify("CSA: empty user message", vim.log.levels.INFO, { title = "CSA" })
		return
	end
	if not state.session_id then
		state.session_id = storage.random_id()
	end
	-- Keep user bubble; drop this reply + all later turns; revert their file edits.
	rewind_and_truncate(user_idx)
	state.active_msg_idx = user_idx
	reload_session_output()
	jump_output_bottom()
	run_ai_request(prompt, { seed_history = true })
end

--- Edit the user turn under the Output cursor, then resend.
--- Deletes that user message and every later turn, reverts their file edits,
--- and loads the user text into Input for editing.
function M.edit_message()
	if not state.open or state.picking or state.stream_lock then
		return
	end
	local idx = message_at_cursor()
	if not idx then
		vim.notify("CSA: no message to edit", vim.log.levels.INFO, { title = "CSA" })
		return
	end
	local user_idx = user_index_for(idx)
	if not user_idx then
		vim.notify("CSA: no user message to edit", vim.log.levels.INFO, { title = "CSA" })
		return
	end
	local storage = require("csa.storage")
	local session = state.session_id and storage.load_history(state.session_id)
	local msg = session and session.messages and session.messages[user_idx]
	local lines
	if msg then
		if type(msg.lines) == "table" and #msg.lines > 0 then
			lines = vim.deepcopy(msg.lines)
		elseif type(msg.content) == "string" then
			lines = vim.split(msg.content, "\n", { plain = true })
		end
	end
	if not lines or #lines == 0 then
		lines = message_body_lines(user_idx)
	end
	if not lines or #lines == 0 then
		vim.notify("CSA: empty user message", vim.log.levels.INFO, { title = "CSA" })
		return
	end
	if not state.session_id then
		state.session_id = storage.random_id()
	end
	-- Drop this user turn and everything below; revert file edits in that range.
	rewind_and_truncate(user_idx - 1)
	state.active_msg_idx = math.max(0, user_idx - 1)
	if state.active_msg_idx == 0 then
		state.active_msg_idx = nil
	end
	state.seed_history_once = true
	reload_session_output()

	local ibuf = state.bufs.input
	if not buf_valid(ibuf) then
		return
	end
	vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, lines)
	M.refresh_model_tag()
	focus_panel("input", { insert = true })
	vim.notify("CSA: edit message, then <CR> to resend", vim.log.levels.INFO, { title = "CSA" })
end

--- Submit Input buffer to Output: header, body lines, trailing blank; then clear Input.
function M.submit_input()
	if not state.open or state.picking then
		return
	end
	local ibuf = state.bufs.input
	local obuf = state.bufs.output
	if not (buf_valid(ibuf) and buf_valid(obuf)) then
		return
	end

	local cursor_ai = require("csa.ai.cursor")
	if config.provider_enabled() and cursor_ai.is_busy() then
		vim.notify("CSA: AI request in progress", vim.log.levels.WARN, { title = "CSA" })
		return
	end

	local lines = vim.api.nvim_buf_get_lines(ibuf, 0, -1, false)
	for i, line in ipairs(lines) do
		lines[i] = vim.trim(line)
	end
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	while #lines > 0 and lines[1] == "" do
		table.remove(lines, 1)
	end
	if #lines == 0 then
		return
	end

	local sender = config.user_name()
	local header = string.format("%s %s", config.user_icon(), sender)
	local block = { header, "" }
	for _, line in ipairs(lines) do
		block[#block + 1] = line
	end
	block[#block + 1] = ""

	local storage = require("csa.storage")
	if not state.session_id then
		state.session_id = storage.random_id()
	end
	-- Persist into the current session file (one window → one history file).
	pcall(function()
		storage.append_message(state.session_id, {
			sender = sender,
			role = "user",
			content = lines,
		})
	end)

	M.append_output_block(block, header, "user")
	-- Sending always jumps to the latest message and re-enables stream follow.
	jump_output_bottom()
	vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { TAG_CURSOR_PAD })
	M.refresh_model_tag()

	if vim.fn.mode():find("[iR]") then
		pcall(vim.cmd, "stopinsert")
	end
	focus_panel("input", { insert = false })
	M.cursor_after_model_tag()

	if not config.provider_enabled() then
		return
	end

	local prompt = table.concat(lines, "\n")
	local seed = state.seed_history_once
	state.seed_history_once = false
	run_ai_request(prompt, { seed_history = seed })
end

--- Append a message block to Output and highlight the header line.
---@param block string[]
---@param header string
---@param role? string
function M.append_output_block(block, header, role)
	local obuf = state.bufs.output
	if not buf_valid(obuf) or type(block) ~= "table" or #block == 0 then
		return
	end
	vim.bo[obuf].modifiable = true
	vim.bo[obuf].readonly = false
	local existing = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
	local empty = #existing == 0 or (#existing == 1 and existing[1] == "")
	local start_row = empty and 0 or #existing
	if empty then
		state.msg_spans = {}
		vim.api.nvim_buf_set_lines(obuf, 0, -1, false, block)
	else
		vim.api.nvim_buf_set_lines(obuf, -1, -1, false, block)
	end
	local last = vim.api.nvim_buf_line_count(obuf)
	local header_row = last - #block
	if header_row >= 0 and type(header) == "string" then
		vim.api.nvim_buf_set_extmark(obuf, output_ns, header_row, 0, {
			end_col = #header,
			hl_group = "Title",
			hl_mode = "combine",
		})
	end
	state.msg_spans[#state.msg_spans + 1] = {
		role = role or "user",
		start_row = start_row,
		end_row = last,
	}
	state.active_msg_idx = #state.msg_spans
	vim.bo[obuf].modifiable = false
	vim.bo[obuf].readonly = true
	follow_output_bottom()
end

---@class CSA.OutputSnapshot
---@field lines string[]
---@field marks { row: integer, col: integer, end_col: integer, hl_group: string }[]

--- Snapshot Output buffer lines + Title marks (for history preview restore).
---@return CSA.OutputSnapshot
function M.snapshot_output()
	local obuf = state.bufs.output
	if not buf_valid(obuf) then
		return { lines = {}, marks = {} }
	end
	local lines = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
	local marks = {}
	local raw = vim.api.nvim_buf_get_extmarks(obuf, output_ns, 0, -1, { details = true })
	for _, mark in ipairs(raw) do
		local details = mark[4] or {}
		marks[#marks + 1] = {
			row = mark[2],
			col = mark[3],
			end_col = details.end_col or mark[3],
			hl_group = details.hl_group or "Title",
		}
	end
	return { lines = lines, marks = marks }
end

--- Restore Output from a previous snapshot.
---@param snap CSA.OutputSnapshot|string[]
function M.restore_output(snap)
	local obuf = state.bufs.output
	if not buf_valid(obuf) or type(snap) ~= "table" then
		return
	end
	-- Accept legacy string[] snapshots.
	local lines = snap.lines or snap
	local marks = snap.marks or {}
	if type(lines) ~= "table" then
		return
	end
	vim.bo[obuf].modifiable = true
	vim.bo[obuf].readonly = false
	vim.api.nvim_buf_clear_namespace(obuf, output_ns, 0, -1)
	vim.api.nvim_buf_set_lines(obuf, 0, -1, false, lines)
	for _, m in ipairs(marks) do
		if type(m) == "table" and type(m.row) == "number" then
			pcall(vim.api.nvim_buf_set_extmark, obuf, output_ns, m.row, m.col or 0, {
				end_col = m.end_col or (m.col or 0),
				hl_group = m.hl_group or "Title",
				hl_mode = "combine",
			})
		end
	end
	vim.bo[obuf].modifiable = false
	vim.bo[obuf].readonly = true
	-- Prefer span rebuild from the active session after history-preview cancel.
	if state.session_id then
		local storage = require("csa.storage")
		local session = storage.load_history(state.session_id)
		if session and type(session.messages) == "table" and #session.messages > 0 then
			local row = 0
			local spans = {}
			for _, msg in ipairs(session.messages) do
				local body = msg.lines
				if type(body) ~= "table" or #body == 0 then
					body = vim.split(msg.content or "", "\n", { plain = true })
				end
				local start_row = row
				-- header + blank + body + trailing blank
				row = row + 1 + 1 + #body + 1
				spans[#spans + 1] = {
					role = msg.role == "assistant" and "assistant" or "user",
					start_row = start_row,
					end_row = row,
				}
			end
			state.msg_spans = spans
		else
			state.msg_spans = {}
		end
	end
end

--- Replace Output with a stored history session (all messages).
---@param session CSA.HistorySession|table
function M.show_history(session)
	if not state.open or type(session) ~= "table" then
		return
	end
	local obuf = state.bufs.output
	if not buf_valid(obuf) then
		return
	end
	local storage = require("csa.storage")
	session = storage.normalize_session(session)
	local user_icon = config.user_icon()
	local ai_icon = config.icon("output")
	local block = {}
	---@type { row: integer, header: string }[]
	local headers = {}
	---@type { role: string, start_row: integer, end_row: integer }[]
	local spans = {}
	for _, msg in ipairs(session.messages or {}) do
		local is_assistant = msg.role == "assistant"
		local icon = is_assistant and ai_icon or user_icon
		local name = msg.sender or (is_assistant and "auto" or "user")
		-- Legacy assistant rows used sender "Cursor".
		if is_assistant and (name == "Cursor" or name == "cursor") then
			name = "auto"
		end
		local header = string.format("%s %s", icon, name)
		local body = msg.lines
		if type(body) ~= "table" or #body == 0 then
			body = vim.split(msg.content or "", "\n", { plain = true })
		end
		local start_row = #block
		headers[#headers + 1] = { row = start_row, header = header }
		block[#block + 1] = header
		block[#block + 1] = ""
		for _, line in ipairs(body) do
			block[#block + 1] = line
		end
		block[#block + 1] = ""
		spans[#spans + 1] = {
			role = is_assistant and "assistant" or "user",
			start_row = start_row,
			end_row = #block,
		}
	end
	if #block == 0 then
		block = { "" }
	end
	state.msg_spans = spans
	state.active_msg_idx = #spans > 0 and #spans or nil

	vim.bo[obuf].modifiable = true
	vim.bo[obuf].readonly = false
	vim.api.nvim_buf_clear_namespace(obuf, output_ns, 0, -1)
	vim.api.nvim_buf_set_lines(obuf, 0, -1, false, block)
	for _, h in ipairs(headers) do
		vim.api.nvim_buf_set_extmark(obuf, output_ns, h.row, 0, {
			end_col = #h.header,
			hl_group = "Title",
			hl_mode = "combine",
		})
	end
	pcall(require("csa.ui.tables").reflow_buf, obuf, state.wins.output)
	vim.bo[obuf].modifiable = false
	vim.bo[obuf].readonly = true
	-- Preview defaults to the bottom of the session.
	state.follow_output = true
	if win_valid(state.wins.output) then
		local last = vim.api.nvim_buf_line_count(obuf)
		pcall(vim.api.nvim_win_set_cursor, state.wins.output, { last, 0 })
		pcall(vim.api.nvim_win_call, state.wins.output, function()
			vim.cmd("normal! zb")
		end)
	end
	refresh_output_markdown()
end

---@param id string|nil
function M.set_session_id(id)
	if id ~= state.session_id then
		-- New / restored chat: drop stale context meter until the next turn.
		state.usage = nil
		if state.open then
			refresh_input_mode_ui()
		end
	end
	state.session_id = id
	if type(id) == "string" and id ~= "" then
		local storage = require("csa.storage")
		local session = storage.load_history(id)
		if session and type(session.messages) == "table" and #session.messages > 0 then
			pcall(storage.save_last_session_id, id)
		end
	end
end

---@return string|nil
function M.session_id()
	return state.session_id
end

--- Scroll Output from Input (or any CSA panel) without leaving focus.
---@param dir "up"|"down"
function M.scroll_output(dir)
	local owin = state.wins.output
	local obuf = state.bufs.output
	if not (win_valid(owin) and buf_valid(obuf)) then
		return
	end
	local height = vim.api.nvim_win_get_height(owin)
	local step = math.max(1, math.floor(height / 2))
	local delta = dir == "up" and -step or step
	local last = vim.api.nvim_buf_line_count(obuf)
	local max_top = math.max(1, last - height + 1)
	pcall(vim.api.nvim_win_call, owin, function()
		local view = vim.fn.winsaveview()
		local topline = math.max(1, math.min(max_top, (view.topline or 1) + delta))
		view.topline = topline
		-- Cursor must stay inside the visible window. Leaving lnum on the last
		-- stream line makes Neovim pull the viewport back down on winrestview.
		view.lnum = math.max(topline, math.min(last, topline + math.floor(height / 2)))
		view.col = 0
		view.curswant = 0
		vim.fn.winrestview(view)
	end)
	-- Scrolling away from the bottom pauses stream stickiness; back to bottom resumes.
	sync_follow_output()
end

local function bind_input_output_scroll(buf)
	if not buf_valid(buf) then
		return
	end
	vim.keymap.set({ "n", "v" }, "<C-u>", function()
		M.scroll_output("up")
	end, {
		buffer = buf,
		silent = true,
		nowait = true,
		noremap = true,
		desc = "CSA scroll output up",
	})
	vim.keymap.set({ "n", "v" }, "<C-d>", function()
		M.scroll_output("down")
	end, {
		buffer = buf,
		silent = true,
		nowait = true,
		noremap = true,
		desc = "CSA scroll output down",
	})
	-- Insert: expr maps are textlocked — defer window scroll, swallow the key.
	vim.keymap.set("i", "<C-u>", function()
		vim.schedule(function()
			M.scroll_output("up")
		end)
		return ""
	end, {
		buffer = buf,
		expr = true,
		silent = true,
		nowait = true,
		noremap = true,
		desc = "CSA scroll output up",
	})
	vim.keymap.set("i", "<C-d>", function()
		vim.schedule(function()
			M.scroll_output("down")
		end)
		return ""
	end, {
		buffer = buf,
		expr = true,
		silent = true,
		nowait = true,
		noremap = true,
		desc = "CSA scroll output down",
	})
end

-- Insert-safe stream locks (editing the next prompt must still work).
local STREAM_LOCK_INSERT = {
	"<Tab>",
	"<S-Tab>",
	"<CR>",
	"<S-CR>",
	"[",
	"]",
}
-- Normal/visual-only: panel actions — never Nop these in insert (sticky maps).
local STREAM_LOCK_NORMAL = {
	"A",
	"R",
	"f",
	"h",
	"d",
	"e",
	"q",
	"y",
	"r",
	"<BS>",
}

local function apply_stream_lock()
	for _, kind in ipairs(PANEL_ORDER) do
		local buf = state.bufs[kind]
		if buf_valid(buf) then
			for _, lhs in ipairs(STREAM_LOCK_INSERT) do
				vim.keymap.set({ "n", "i", "v", "x", "o" }, lhs, "<Nop>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA locked while streaming",
				})
			end
			for _, lhs in ipairs(STREAM_LOCK_NORMAL) do
				vim.keymap.set({ "n", "v", "x", "o" }, lhs, "<Nop>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA locked while streaming",
				})
				-- Clear any leftover insert Nops from older CSA versions.
				pcall(vim.keymap.del, "i", lhs, { buffer = buf })
			end
			pcall(vim.keymap.del, "i", "<BS>", { buffer = buf })
			pcall(vim.keymap.del, "i", "<Del>", { buffer = buf })
			-- Escape hatch: cancel the running Cursor job.
			vim.keymap.set({ "n", "i" }, "<C-c>", function()
				require("csa.ai.cursor").cancel()
			end, {
				buffer = buf,
				silent = true,
				nowait = true,
				noremap = true,
				desc = "CSA cancel AI stream",
			})
			-- Keep Output scroll available from Input while streaming.
			if kind == "input" then
				bind_input_output_scroll(buf)
			end
		end
	end
end

local bind_maps

--- Lock / unlock CSA panel shortcuts while Cursor streams.
---@param on boolean
function M.set_stream_lock(on)
	state.stream_lock = on and true or false
	if state.stream_lock then
		apply_stream_lock()
	else
		bind_maps()
	end
end

function M.is_stream_locked()
	return state.stream_lock
end

bind_maps = function()
	-- Tab / S-Tab: cycle CSA panels only (never the main editor).
	-- <C-w>* from Input/Files: jump to the main editor.
	for _, kind in ipairs(PANEL_ORDER) do
		local buf = state.bufs[kind]
		if buf_valid(buf) then
			-- Override global FileType maps (e.g. treesitter select on <CR>/<BS>) —
			-- those hang on CSA nofile buffers with no parser.
			if kind == "input" then
				vim.keymap.set({ "n", "i" }, "<CR>", "<Cmd>lua require('csa.ui.picker').submit_input()<CR>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA submit input",
				})
				-- Shift-Enter inserts a newline while typing.
				vim.keymap.set("i", "<S-CR>", "<CR>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA input newline",
				})
				vim.keymap.set({ "x", "o" }, "<CR>", "<Nop>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA: no treesitter CR",
				})
				bind_input_output_scroll(buf)
			else
				vim.keymap.set({ "n", "x", "o" }, "<CR>", "<Nop>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA: no treesitter CR",
				})
			end
			vim.keymap.set({ "n", "x", "o" }, "<BS>", "<Nop>", {
				buffer = buf,
				silent = true,
				nowait = true,
				noremap = true,
				desc = "CSA: no treesitter BS",
			})
			-- Stream-lock may have left insert letter maps as <Nop>; restore typing.
			for _, lhs in ipairs({ "<BS>", "<Del>", "A", "f", "h", "d", "e", "q" }) do
				pcall(vim.keymap.del, "i", lhs, { buffer = buf })
			end
			vim.keymap.set({ "n", "i" }, "<Tab>", "<Cmd>lua require('csa.ui.picker').focus_next(1)<CR>", {
				buffer = buf,
				silent = true,
				nowait = true,
				noremap = true,
				desc = "CSA next panel",
			})
			vim.keymap.set({ "n", "i" }, "<S-Tab>", "<Cmd>lua require('csa.ui.picker').focus_next(-1)<CR>", {
				buffer = buf,
				silent = true,
				nowait = true,
				noremap = true,
				desc = "CSA previous panel",
			})
			if kind == "input" or kind == "files" or kind == "output" then
				bind_leave_to_main(buf)
			end
			if kind == "input" then
				vim.keymap.set("n", "f", "<Cmd>lua require('csa.ui.files').pick()<CR>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA add files",
				})
				vim.keymap.set("n", "h", "<Cmd>lua require('csa.ui.history').pick()<CR>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA history",
				})
				-- Shift+A (A): open model picker.
				vim.keymap.set("n", "A", "<Cmd>lua require('csa.ui.models').pick()<CR>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA select model",
				})
				-- Blank input: enter insert after the model pill (not on it).
				vim.keymap.set("n", "i", function()
					local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
					if vim.trim(line) == "" then
						M.cursor_after_model_tag()
						vim.cmd("startinsert!")
					else
						vim.cmd("startinsert")
					end
				end, {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA insert after model tag",
				})
				vim.keymap.set("n", "I", function()
					M.cursor_after_model_tag()
					vim.cmd("startinsert!")
				end, {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA insert after model tag",
				})
				-- `[` / `]` cycle provider mode (plan ↔ agent ↔ ask); locked under CSAsk / CSAgents.
				vim.keymap.set("n", "[", "<Cmd>lua require('csa.ui.picker').cycle_ai_mode(-1)<CR>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA previous AI mode",
				})
				vim.keymap.set("n", "]", "<Cmd>lua require('csa.ui.picker').cycle_ai_mode(1)<CR>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA next AI mode",
				})
				vim.keymap.set("n", "R", "<Cmd>lua require('csa.ui.picker').regenerate_message()<CR>", {
					buffer = buf,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA regenerate last reply",
				})
				vim.keymap.set("i", "[", function()
					vim.schedule(function()
						M.cycle_ai_mode(-1)
					end)
					return ""
				end, {
					buffer = buf,
					expr = true,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA previous AI mode",
				})
				vim.keymap.set("i", "]", function()
					vim.schedule(function()
						M.cycle_ai_mode(1)
					end)
					return ""
				end, {
					buffer = buf,
					expr = true,
					silent = true,
					nowait = true,
					noremap = true,
					desc = "CSA next AI mode",
				})
			end
		end
	end
	local files = state.bufs.files
	if buf_valid(files) then
		vim.keymap.set("n", "d", "<Cmd>lua require('csa.ui.picker').remove_file_at_cursor()<CR>", {
			buffer = files,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA remove file",
		})
		vim.keymap.set("n", "e", "<Cmd>lua require('csa.ui.picker').open_file_at_cursor()<CR>", {
			buffer = files,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA open file",
		})
		-- Esc leaves Files → Input (same idea as picker cancel).
		vim.keymap.set({ "n", "v" }, "<Esc>", function()
			if vim.fn.mode():find("[vV\22]") then
				local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
				vim.api.nvim_feedkeys(esc, "nx", false)
			end
			focus_panel("input", { insert = false })
		end, {
			buffer = files,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA leave files to input",
		})
	end

	local output = state.bufs.output
	if buf_valid(output) then
		-- Output: normal + visual only — block entering insert/replace/etc.
		local block_insert = {
			"i",
			"I",
			"a",
			"A",
			"o",
			"O",
			"c",
			"C",
			"s",
			"S",
			"gI",
			"gi",
			"gR",
		}
		for _, lhs in ipairs(block_insert) do
			vim.keymap.set("n", lhs, "<Nop>", {
				buffer = output,
				silent = true,
				nowait = true,
				noremap = true,
				desc = "CSA output: no insert",
			})
		end
		vim.keymap.set("n", "y", "<Cmd>lua require('csa.ui.picker').copy_message()<CR>", {
			buffer = output,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA copy message",
		})
		vim.keymap.set("n", "r", "<Cmd>lua require('csa.ui.picker').regenerate_message()<CR>", {
			buffer = output,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA regenerate message",
		})
		vim.keymap.set("n", "e", "<Cmd>lua require('csa.ui.picker').edit_message()<CR>", {
			buffer = output,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA edit message and resend",
		})
		-- Prev / next user-sent message only.
		vim.keymap.set("n", "[", "<Cmd>lua require('csa.ui.picker').goto_message(-1)<CR>", {
			buffer = output,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA previous user message",
		})
		vim.keymap.set("n", "]", "<Cmd>lua require('csa.ui.picker').goto_message(1)<CR>", {
			buffer = output,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA next user message",
		})
		-- Esc leaves Output → Input.
		vim.keymap.set({ "n", "v" }, "<Esc>", function()
			if vim.fn.mode():find("[vV\22]") then
				local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
				vim.api.nvim_feedkeys(esc, "nx", false)
			end
			focus_panel("input", { insert = false })
		end, {
			buffer = output,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA leave output to input",
		})
		-- Keep Replace-mode keys disabled; regenerate is `r` / Input `R`.
		vim.keymap.set("n", "R", "<Nop>", {
			buffer = output,
			silent = true,
			nowait = true,
			noremap = true,
			desc = "CSA output: no replace",
		})
		-- Visual: keep native yank for selections.
		vim.keymap.set("x", "y", "y", {
			buffer = output,
			silent = true,
			noremap = true,
			desc = "CSA visual yank",
		})
	end
end

local function apply_layout()
	if not state.open then
		return
	end
	-- Always pin pad to configured fraction (guards against equalalways / other splits).
	local pad_w = target_total_width() - 1
	if win_valid(state.wins.pad) then
		vim.o.equalalways = false
		pcall(vim.api.nvim_win_set_width, state.wins.pad, pad_w)
	end

	local geo = layout()
	if not geo then
		return
	end

	if state.show_files and not state.picking then
		if not win_valid(state.wins.files) then
			ensure_buf("files", "files", { " (no files)" })
			open_float("files", state.bufs.files, geo.files, geo.width, geo.col, false)
			bind_maps()
		end
	elseif win_valid(state.wins.files) then
		state.suppress_close = true
		pcall(vim.api.nvim_win_close, state.wins.files, true)
		state.wins.files = nil
		state.suppress_close = false
	end

	for _, kind in ipairs(visible_panels()) do
		local win = state.wins[kind]
		local style = panel_style[kind]
		local g = geo[kind]
		if win_valid(win) and g and g.height > 0 then
			local title = kind == "input" and input_title()
				or titled(config.icon(style.icon_key), style.title)
			local border_hl = kind == "input" and input_border_hl() or "CSABorder"
			vim.api.nvim_win_set_config(win, {
				relative = "win",
				win = state.wins.pad,
				width = geo.width,
				height = g.height,
				row = g.row,
				col = geo.col,
				border = border_chars(border_hl),
				title = title,
				title_pos = "center",
				focusable = true,
			})
			vim.wo[win].winhighlight = panel_winhighlight(kind)
		end
	end

	if state.picking then
		require("csa.ui.files").apply_layout(geo)
		require("csa.ui.history").apply_layout(geo)
		require("csa.ui.models").apply_layout(geo)
	end
end

function M.layout_geo()
	return layout()
end

function M.suppress_close(on)
	state.suppress_close = on and true or false
end

--- Connected borders for search (top unit) + list (bottom unit).
function M.pick_borders()
	local hl = "CSABorder"
	local top = {
		{ "╭", hl },
		{ "─", hl },
		{ "╮", hl },
		{ "│", hl },
		{ "┤", hl },
		{ "─", hl },
		{ "├", hl },
		{ "│", hl },
	}
	local bottom = {
		{ "├", hl },
		{ "─", hl },
		{ "┤", hl },
		{ "│", hl },
		{ "╯", hl },
		{ "─", hl },
		{ "╰", hl },
		{ "│", hl },
	}
	return top, bottom
end

function M.set_picking(on)
	local was = state.picking
	state.picking = on and true or false
	if not state.open then
		return
	end
	-- File/history/model pickers hide Files while open; restore when leaving if still attached.
	if was and not state.picking and #state.files > 0 and not state.show_files then
		state.show_files = true
	end
	apply_layout()
	if state.show_files then
		render_files()
	end
end


function M.open_file_at_cursor()
	if not state.open or not state.show_files then
		return
	end
	local win = state.wins.files
	if not win_valid(win) or #state.files == 0 then
		return
	end
	local row = vim.api.nvim_win_get_cursor(win)[1]
	local path = state.files[row]
	if type(path) ~= "string" or path == "" then
		return
	end
	if not vim.uv.fs_stat(path) then
		vim.notify("CSA: file not found: " .. path, vim.log.levels.WARN, { title = "CSA" })
		return
	end
	local edit_win = target_edit_win()
	if not edit_win then
		vim.notify("CSA: no editor window to open file", vim.log.levels.WARN, { title = "CSA" })
		return
	end
	pcall(vim.api.nvim_set_current_win, edit_win)
	vim.cmd.edit(vim.fn.fnameescape(path))
end

function M.remove_file_at_cursor()
	if not state.open or not state.show_files then
		return
	end
	local win = state.wins.files
	if not win_valid(win) or #state.files == 0 then
		return
	end
	local row = vim.api.nvim_win_get_cursor(win)[1]
	if row < 1 or row > #state.files then
		return
	end

	local max_files = math.max(1, config.files_num())
	local before_count = #state.files
	local before_h = math.min(max_files, before_count)
	local view = vim.api.nvim_win_call(win, function()
		return vim.fn.winsaveview()
	end)

	table.remove(state.files, row)
	local after_count = #state.files
	if after_count == 0 then
		M.set_files_visible(false)
		focus_panel("input", { insert = false })
		return
	end

	local after_h = math.min(max_files, after_count)
	if after_h ~= before_h then
		apply_layout()
	end
	render_files()

	win = state.wins.files
	if not win_valid(win) then
		return
	end

	local new_row = math.min(row, after_count)
	local h = vim.api.nvim_win_get_height(win)
	view.lnum = new_row
	view.col = 0
	view.curswant = 0
	if view.topline + h - 1 > after_count then
		view.topline = math.max(1, after_count - h + 1)
	end
	pcall(vim.api.nvim_win_call, win, function()
		vim.fn.winrestview(view)
	end)
	sync_files_focus()
end

function M.is_open()
	if not state.open then
		return false
	end
	if not (win_valid(state.wins.output) and win_valid(state.wins.input) and win_valid(state.wins.pad)) then
		return false
	end
	if state.show_files and not win_valid(state.wins.files) then
		return false
	end
	return true
end

function M.set_files_visible(visible)
	if visible == nil then
		visible = not state.show_files
	end
	state.show_files = visible and true or false
	if state.open then
		apply_layout()
		bind_maps()
		render_files()
	end
end

---@param paths string[]
---@param opts? { allow_missing?: boolean }
function M.add_files(paths, opts)
	if type(paths) ~= "table" then
		return
	end
	opts = opts or {}
	local seen = {}
	for _, path in ipairs(state.files) do
		seen[path] = true
	end
	local added = 0
	for _, path in ipairs(paths) do
		if type(path) == "string" and path ~= "" then
			path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
			local ok = not seen[path] and (opts.allow_missing or vim.uv.fs_stat(path))
			if ok then
				seen[path] = true
				state.files[#state.files + 1] = path
				added = added + 1
			end
		end
	end
	if added == 0 then
		return
	end
	if not state.show_files then
		M.set_files_visible(true)
	else
		apply_layout()
		render_files()
	end
end

function M.get_files()
	return vim.deepcopy(state.files)
end

---@param opts? { mode?: "ask"|"agent"|"plan", mode_locked?: boolean, fresh?: boolean }
function M.open(opts)
	opts = opts or {}
	local want_mode = opts.mode ~= nil and normalize_ai_mode(opts.mode) or nil
	local want_locked = opts.mode_locked == true

	if M.is_open() then
		if want_mode then
			state.ai_mode = want_mode
			state.mode_locked = want_locked
			refresh_input_mode_ui()
		end
		focus_panel("input")
		return
	end

	-- CSAToggle → agent (switchable); CSAsk / CSAgents → locked mode.
	state.ai_mode = want_mode or "agent"
	state.mode_locked = want_locked
	local storage = require("csa.storage")
	state.model = storage.load_selected_model()

	highlights.apply()
	close_wins()
	state.show_files = (#state.files > 0) or config.show_files()
	-- Reopen restores the last non-empty chat; otherwise start a fresh session.
	local restored = opts.fresh and nil or storage.load_last_session()
	if restored then
		state.session_id = restored.id
	else
		state.session_id = storage.random_id()
	end
	state.msg_spans = {}
	state.active_msg_idx = nil
	state.seed_history_once = false
	state.usage = nil
	-- Prefetch provider chat id / warm CLI so the first Enter is faster.
	vim.schedule(function()
		pcall(function()
			require("csa.ai.cursor").warmup(state.session_id)
		end)
	end)

	ensure_buf("output", "output", {})
	ensure_buf("files", "files", { " (no files)" })
	ensure_buf("input", "input", { TAG_CURSOR_PAD })
	-- Output starts empty (content written from line 1).
	if buf_valid(state.bufs.output) then
		vim.bo[state.bufs.output].modifiable = true
		vim.bo[state.bufs.output].readonly = false
		vim.api.nvim_buf_set_lines(state.bufs.output, 0, -1, false, {})
		vim.bo[state.bufs.output].modifiable = false
		vim.bo[state.bufs.output].readonly = true
	end
	vim.bo[state.bufs.input].modifiable = true

	-- Squeeze exactly `width` of columns: pad + 1 separator = target_total_width().
	open_pad(target_total_width() - 1)

	local geo = layout()
	if not geo then
		close_wins()
		return
	end

	-- Floats live inside the pad window — no editor-relative overflow.
	open_float("output", state.bufs.output, geo.output, geo.width, geo.col, false)
	if state.show_files then
		open_float("files", state.bufs.files, geo.files, geo.width, geo.col, false)
	end
	open_float("input", state.bufs.input, geo.input, geo.width, geo.col, true)
	M.refresh_model_tag()
	M.cursor_after_model_tag()

	render_files()
	state.open = true
	state.follow_output = true
	if restored then
		M.show_history(restored)
		pcall(storage.save_last_session_id, restored.id)
	end
	bind_maps()
	-- Re-apply after FileType buffer maps (e.g. global treesitter <CR>) settle.
	vim.schedule(function()
		bind_maps()
		M.refresh_model_tag()
		M.cursor_after_model_tag()
	end)

	state.augroup = vim.api.nvim_create_augroup("CSAPicker", { clear = true })
	vim.api.nvim_create_autocmd("VimResized", {
		group = state.augroup,
		callback = function()
			if M.is_open() then
				apply_layout()
				render_files()
			end
		end,
	})
	-- Mouse / native scrolls in Output also pause/resume stick-to-bottom.
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = state.augroup,
		callback = function()
			if not state.open or not win_valid(state.wins.output) then
				return
			end
			local scrolled = vim.v.event
			if type(scrolled) ~= "table" then
				return
			end
			local id = tostring(state.wins.output)
			if scrolled[id] then
				sync_follow_output()
			end
		end,
	})
	-- Keep active message index in sync when moving inside Output (j/k, mouse).
	if buf_valid(state.bufs.output) then
		vim.api.nvim_create_autocmd("CursorMoved", {
			group = state.augroup,
			buffer = state.bufs.output,
			callback = function()
				if not state.open or #state.msg_spans == 0 then
					return
				end
				if vim.api.nvim_get_current_win() ~= state.wins.output then
					return
				end
				message_at_cursor()
			end,
		})
	end
	vim.api.nvim_create_autocmd("WinEnter", {
		group = state.augroup,
		callback = function()
			if not state.open then
				return
			end
			local cur = vim.api.nvim_get_current_win()
			-- File/history pickers own their own wins while open.
			if state.picking then
				return
			end
			-- LazyGit / Snacks / terminal floats: hide CSA so it cannot stack on top.
			if is_foreign_overlay(cur) then
				suspend_for_overlay()
				return
			end
			if state.suspended and not is_foreign_overlay(cur) then
				resume_from_overlay()
			end
			-- Pad hosts the floats. Route focus by where we came from:
			-- CSA float → pad means "leave" → main editor;
			-- editor → pad means "enter CSA" → Input.
			if cur == state.wins.pad then
				local prev = vim.fn.win_getid(vim.fn.winnr("#"))
				local from_csa = prev == state.wins.input
					or prev == state.wins.output
					or prev == state.wins.files
				if from_csa then
					focus_main()
				else
					focus_panel("input", { insert = false })
				end
				return
			end
			-- Remember last non-CSA window as the main editor target.
			if not is_csa_ui_win(cur) then
				local cfg = vim.api.nvim_win_get_config(cur)
				if cfg.relative == "" then
					state.prev_win = cur
				end
			end
			sync_files_focus()
		end,
	})
	vim.api.nvim_create_autocmd("ModeChanged", {
		group = state.augroup,
		callback = function()
			if not state.open or state.picking then
				return
			end
			if vim.api.nvim_get_current_win() ~= state.wins.output then
				return
			end
			-- Allow only normal + visual in Output.
			local mode = vim.fn.mode(1)
			if mode:find("^[vV\22]") or mode == "n" or mode == "no" or mode:sub(1, 2) == "no" then
				return
			end
			if mode:find("[iR]") or mode:sub(1, 1) == "t" then
				pcall(vim.cmd, "stopinsert")
			end
			-- Select / cmdline-ish: force back to normal.
			if mode:find("[sS\19c]") then
				local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
				vim.api.nvim_feedkeys(esc, "nx", false)
			end
		end,
	})
	-- Esc from insert can land on/before the inline model pill; re-park after tag.
	if buf_valid(state.bufs.input) then
		vim.api.nvim_create_autocmd("InsertLeave", {
			group = state.augroup,
			buffer = state.bufs.input,
			callback = function()
				vim.schedule(restore_cursor_after_tag_if_blank)
			end,
		})
	end
	vim.api.nvim_create_autocmd("WinLeave", {
		group = state.augroup,
		callback = function()
			if not state.open or not win_valid(state.wins.files) then
				return
			end
			if vim.api.nvim_get_current_win() == state.wins.files then
				vim.wo[state.wins.files].cursorline = false
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = state.augroup,
		callback = function(args)
			if state.suppress_close or not state.open then
				return
			end
			local closed = tonumber(args.match)
			for _, win in ipairs(require("csa.ui.files").wins()) do
				if win == closed then
					return
				end
			end
			for _, win in ipairs(require("csa.ui.history").wins()) do
				if win == closed then
					return
				end
			end
			for _, win in ipairs(require("csa.ui.models").wins()) do
				if win == closed then
					return
				end
			end
			for _, kind in ipairs({ "output", "files", "input", "pad" }) do
				if state.wins[kind] == closed then
					if kind == "files" and not state.show_files then
						return
					end
					close_wins()
					return
				end
			end
		end,
	})

	focus_panel("input")
end

function M.close()
	if not state.open and not win_valid(state.wins.input) then
		return
	end
	if vim.fn.mode():find("[iR]") then
		vim.cmd("stopinsert")
	end
	-- Remember this chat for the next reopen (only if it has messages).
	if type(state.session_id) == "string" and state.session_id ~= "" then
		local storage = require("csa.storage")
		local session = storage.load_history(state.session_id)
		if session and type(session.messages) == "table" and #session.messages > 0 then
			pcall(storage.save_last_session_id, state.session_id)
		end
	end
	close_wins()
end

function M.toggle()
	if M.is_open() then
		M.close()
	else
		M.open({ mode = "agent", mode_locked = false })
	end
end

function M.state()
	return state
end

return M

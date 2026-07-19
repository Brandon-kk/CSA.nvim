--- Agent file-edit review: inline diff in buffers + accept/reject.
local M = {}

local diff_ns = vim.api.nvim_create_namespace("csa_review_diff")
local sign_group = "csa_review_signs"

---@class CSA.PendingEdit
---@field path string absolute path
---@field before string
---@field after string
---@field added integer
---@field removed integer
---@field kind "write"|"edit"|"delete"
---@field call_id string|nil

---@type table<string, CSA.PendingEdit>
local pending = {}

---@type table<string, string> path -> before text (tool start snapshots)
local snapshots = {}

--- Per-turn earliest-before / latest-after (attached to the assistant history message).
---@type table<string, { path: string, before: string, after: string, kind: string }>
local turn_edits = {}

local bind_buf_maps

local function abs_path(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	return vim.fn.fnamemodify(path, ":p")
end

local function read_file(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local data = fd:read("*a")
	fd:close()
	return type(data) == "string" and data or ""
end

local function write_file(path, text)
	local dir = vim.fn.fnamemodify(path, ":h")
	if dir ~= "" then
		vim.fn.mkdir(dir, "p")
	end
	local fd, err = io.open(path, "w")
	if not fd then
		return false, err
	end
	fd:write(text or "")
	fd:close()
	return true
end

local function ensure_signs()
	pcall(vim.fn.sign_define, "CSAReviewAdd", { text = "┃", texthl = "CSADiffAdd", numhl = "" })
	pcall(vim.fn.sign_define, "CSAReviewDel", { text = "┃", texthl = "CSADiffDelete", numhl = "" })
	pcall(vim.fn.sign_define, "CSAReviewChange", { text = "┃", texthl = "CSADiffChange", numhl = "" })
end

---@param path string
local function clear_buffer_diff(path)
	path = abs_path(path)
	if not path then
		return
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local name = vim.api.nvim_buf_get_name(buf)
			if name ~= "" and abs_path(name) == path then
				vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
				pcall(vim.fn.sign_unplace, sign_group, { buffer = buf })
			end
		end
	end
end

--- Start collecting file edits for the current AI turn.
function M.begin_turn()
	turn_edits = {}
end

--- Snapshot of file edits made this turn (for history / rewind).
---@return { path: string, before: string, after: string, kind: string }[]
function M.drain_turn_edits()
	local out = {}
	for _, e in pairs(turn_edits) do
		out[#out + 1] = {
			path = e.path,
			before = e.before,
			after = e.after,
			kind = e.kind,
		}
	end
	table.sort(out, function(a, b)
		return a.path < b.path
	end)
	turn_edits = {}
	return out
end

---@param path string
---@param before string
---@param kind? string
local function restore_path(path, before, kind)
	path = abs_path(path)
	if not path then
		return false
	end
	clear_buffer_diff(path)
	pending[path] = nil
	snapshots[path] = nil
	before = before or ""
	-- New file created by the agent: remove it instead of leaving an empty stub.
	if before == "" then
		local st = vim.uv.fs_stat(path)
		if st then
			pcall(vim.fn.delete, path)
		end
		local buf = vim.fn.bufnr(path)
		if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
		return true
	end
	write_file(path, before)
	local buf = vim.fn.bufnr(path)
	if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
		local lines = vim.split(before, "\n", { plain = true })
		if #lines > 0 and lines[#lines] == "" then
			table.remove(lines)
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modified = false
	end
	return true
end

--- Revert file changes from discarded assistant turns + any still-pending edits.
--- For each path, restores the earliest `before` in the discarded range.
---@param messages table[]|nil discarded history messages (after the keep point)
---@return integer reverted count
function M.rewind_files(messages)
	---@type table<string, { before: string, kind?: string }>
	local first = {}
	if type(messages) == "table" then
		for _, msg in ipairs(messages) do
			if type(msg) == "table" and msg.role == "assistant" and type(msg.edits) == "table" then
				for _, e in ipairs(msg.edits) do
					if type(e) == "table" and type(e.path) == "string" then
						local p = abs_path(e.path)
						if p and first[p] == nil and type(e.before) == "string" then
							first[p] = { before = e.before, kind = e.kind }
						end
					end
				end
			end
		end
	end
	-- Pending edits not yet (or never) persisted on a message.
	for p, edit in pairs(pending) do
		if first[p] == nil then
			first[p] = { before = edit.before or "", kind = edit.kind }
		end
	end
	local n = 0
	for path, info in pairs(first) do
		if restore_path(path, info.before, info.kind) then
			n = n + 1
		end
	end
	pending = {}
	snapshots = {}
	turn_edits = {}
	if n > 0 then
		pcall(function()
			require("csa.ui.picker").refresh_files()
		end)
		vim.notify("CSA: reverted " .. n .. " file edit(s)", vim.log.levels.INFO, { title = "CSA" })
	end
	return n
end

--- Apply inline diff decorations for before/after in an open buffer.
---@param buf integer
---@param before string
---@param after string
local function decorate_buf(buf, before, after)
	ensure_signs()
	vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
	pcall(vim.fn.sign_unplace, sign_group, { buffer = buf })

	local ok, hunks = pcall(vim.diff, before or "", after or "", {
		result_type = "indices",
		algorithm = "histogram",
	})
	if not ok or type(hunks) ~= "table" then
		return
	end

	local before_lines = vim.split(before or "", "\n", { plain = true })
	-- trailing empty from split
	if #before_lines > 0 and before_lines[#before_lines] == "" then
		table.remove(before_lines)
	end

	for _, h in ipairs(hunks) do
		local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
		-- Added / changed lines in the new file (1-based b_start).
		if b_count > 0 then
			local sign = (a_count > 0) and "CSAReviewChange" or "CSAReviewAdd"
			for row = b_start, b_start + b_count - 1 do
				if row >= 1 then
					-- Sign gutter only — no line background (lualine-style, not DiffAdd wash).
					pcall(vim.fn.sign_place, 0, sign_group, sign, buf, { lnum = row, priority = 90 })
				end
			end
		end
		-- Removed lines: show as virtual lines above the next surviving line.
		if a_count > 0 then
			local virt = {}
			for i = 0, a_count - 1 do
				local line = before_lines[a_start + i] or ""
				virt[#virt + 1] = { { "− " .. line, "CSADiffDelete" } }
			end
			local anchor = b_start -- 1-based; virt_lines_above on this row
			if b_count == 0 then
				-- Pure deletion: attach above the line that followed the deletion.
				anchor = math.max(1, b_start)
			end
			local row0 = math.max(0, anchor - 1)
			pcall(vim.api.nvim_buf_set_extmark, buf, diff_ns, row0, 0, {
				virt_lines = virt,
				virt_lines_above = true,
			})
			if b_count == 0 then
				pcall(vim.fn.sign_place, 0, sign_group, "CSAReviewDel", buf, {
					lnum = math.max(1, anchor),
					priority = 90,
				})
			end
		end
	end
end

---@param path string
local function reload_and_decorate(path)
	path = abs_path(path)
	local edit = path and pending[path]
	if not edit then
		return
	end
	-- Prefer already-open buffer; else edit in background then decorate.
	local buf = vim.fn.bufnr(path, true)
	if buf <= 0 then
		return
	end
	if not vim.api.nvim_buf_is_loaded(buf) then
		pcall(vim.fn.bufload, buf)
	end
	-- Sync from disk (agent already wrote).
	pcall(vim.cmd, "checktime " .. buf)
	if vim.api.nvim_buf_get_name(buf) == "" then
		pcall(vim.api.nvim_buf_set_name, buf, path)
	end
	-- If buffer is empty/stale vs after, load after content when it matches disk.
	local disk = read_file(path)
	if type(disk) == "string" then
		edit.after = disk
	end
	local lines = vim.split(edit.after or "", "\n", { plain = true })
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	local modifiable = vim.bo[buf].modifiable
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = modifiable
	vim.bo[buf].modified = false
	decorate_buf(buf, edit.before or "", edit.after or "")
	bind_buf_maps(buf)
	-- Focus an editor window on this file when possible.
	local picker = require("csa.ui.picker")
	local st = picker.state()
	local target = st.prev_win
	if not (type(target) == "number" and vim.api.nvim_win_is_valid(target)) then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			local cfg = vim.api.nvim_win_get_config(win)
			if cfg.relative == "" and not vim.w[win].csa_panel then
				target = win
				break
			end
		end
	end
	if type(target) == "number" and vim.api.nvim_win_is_valid(target) then
		pcall(vim.api.nvim_win_set_buf, target, buf)
	end
end

---@param buf integer
bind_buf_maps = function(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	-- Buffer-local so global `ca`/`cr` text-objects stay intact elsewhere.
	vim.keymap.set("n", "ca", function()
		M.accept(vim.api.nvim_buf_get_name(buf))
	end, { buffer = buf, silent = true, nowait = true, desc = "CSA: accept agent edit" })
	vim.keymap.set("n", "cr", function()
		M.reject(vim.api.nvim_buf_get_name(buf))
	end, { buffer = buf, silent = true, nowait = true, desc = "CSA: reject agent edit" })
end

---@param a integer
---@param d integer
---@return string, table[]
function M.format_stats(a, d)
	a = a or 0
	d = d or 0
	local chunks = {}
	local label = {}
	-- lualine-style: icon + count with fg-only color (never Diff* background wash).
	if a > 0 then
		chunks[#chunks + 1] = { "󰐕" .. tostring(a), "CSADiffAdd" }
		label[#label + 1] = "+" .. a
	end
	if d > 0 then
		if #chunks > 0 then
			chunks[#chunks + 1] = { " ", "Normal" }
		end
		chunks[#chunks + 1] = { "󰍴" .. tostring(d), "CSADiffDelete" }
		label[#label + 1] = "-" .. d
	end
	if #chunks == 0 then
		chunks[1] = { "󰆗0", "Comment" }
		label[1] = "0"
	end
	return table.concat(label, " "), chunks
end

---@param path string
---@return CSA.PendingEdit|nil
function M.get(path)
	path = abs_path(path)
	return path and pending[path] or nil
end

---@return CSA.PendingEdit[]
function M.list()
	local out = {}
	for _, e in pairs(pending) do
		out[#out + 1] = e
	end
	table.sort(out, function(x, y)
		return x.path < y.path
	end)
	return out
end

function M.count()
	local n = 0
	for _ in pairs(pending) do
		n = n + 1
	end
	return n
end

--- Snapshot file before a tool writes (call on tool_call started).
---@param path string
function M.snapshot(path)
	path = abs_path(path)
	if not path then
		return
	end
	local text = read_file(path)
	if text == nil then
		snapshots[path] = "" -- new file
	else
		snapshots[path] = text
	end
end

local function count_diff(before, after)
	local added, removed = 0, 0
	local ok, hunks = pcall(vim.diff, before or "", after or "", {
		result_type = "indices",
		algorithm = "histogram",
	})
	if ok and type(hunks) == "table" then
		for _, h in ipairs(hunks) do
			removed = removed + (h[2] or 0)
			added = added + (h[4] or 0)
		end
	end
	return added, removed
end

--- Record a completed file edit and show inline diff.
---@param opts { path: string, kind?: string, after?: string, added?: integer, removed?: integer, call_id?: string, diff?: string, attach?: boolean, decorate?: boolean }
function M.record(opts)
	local path = abs_path(opts and opts.path)
	if not path then
		return
	end
	local before = snapshots[path]
	if before == nil then
		before = ""
	end
	local after = opts.after
	if type(after) ~= "string" then
		after = read_file(path) or ""
	end
	local added = opts.added
	local removed = opts.removed
	if type(added) ~= "number" or type(removed) ~= "number" then
		added, removed = count_diff(before, after)
	end
	local kind = opts.kind or "edit"
	pending[path] = {
		path = path,
		before = before,
		after = after,
		added = added or 0,
		removed = removed or 0,
		kind = kind,
		call_id = opts.call_id,
	}
	-- Keep earliest before for this turn (multi-edit same file).
	if not turn_edits[path] then
		turn_edits[path] = {
			path = path,
			before = before,
			after = after,
			kind = kind,
		}
	else
		turn_edits[path].after = after
		turn_edits[path].kind = kind
	end
	snapshots[path] = nil
	local do_attach = opts.attach ~= false
	local do_decorate = opts.decorate ~= false
	vim.schedule(function()
		if do_decorate then
			reload_and_decorate(path)
		end
		if not do_attach then
			return
		end
		local picker = require("csa.ui.picker")
		if not picker.is_open() then
			return
		end
		-- Auto-attach edited files into Files panel (even when user attached none).
		picker.add_files({ path }, { allow_missing = true })
		if not picker.state().show_files then
			picker.set_files_visible(true)
		else
			pcall(picker.refresh_files)
		end
	end)
end

---@param path? string nil = current buffer / all if no match
---@return boolean
function M.accept(path)
	if path == nil or path == "" then
		local cur = vim.api.nvim_buf_get_name(0)
		path = abs_path(cur)
		if not path or not pending[path] then
			-- accept all
			local n = 0
			for p in pairs(pending) do
				clear_buffer_diff(p)
				pending[p] = nil
				n = n + 1
			end
			if n == 0 then
				vim.notify("CSA: no pending file edits", vim.log.levels.INFO, { title = "CSA" })
				return false
			end
			vim.notify("CSA: accepted " .. n .. " edit(s)", vim.log.levels.INFO, { title = "CSA" })
			pcall(function()
				require("csa.ui.picker").refresh_files()
			end)
			return true
		end
	else
		path = abs_path(path)
	end
	if not path or not pending[path] then
		vim.notify("CSA: no pending edit for this file", vim.log.levels.INFO, { title = "CSA" })
		return false
	end
	clear_buffer_diff(path)
	pending[path] = nil
	vim.notify("CSA: accepted " .. vim.fn.fnamemodify(path, ":."), vim.log.levels.INFO, { title = "CSA" })
	pcall(function()
		require("csa.ui.picker").refresh_files()
	end)
	return true
end

---@param path? string
---@return boolean
function M.reject(path)
	if path == nil or path == "" then
		local cur = vim.api.nvim_buf_get_name(0)
		path = abs_path(cur)
		if not path or not pending[path] then
			local n = 0
			for p, edit in pairs(pending) do
				clear_buffer_diff(p)
				write_file(p, edit.before or "")
				local buf = vim.fn.bufnr(p)
				if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
					local lines = vim.split(edit.before or "", "\n", { plain = true })
					if #lines > 0 and lines[#lines] == "" then
						table.remove(lines)
					end
					vim.bo[buf].modifiable = true
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
					vim.bo[buf].modified = false
				end
				pending[p] = nil
				n = n + 1
			end
			if n == 0 then
				vim.notify("CSA: no pending file edits", vim.log.levels.INFO, { title = "CSA" })
				return false
			end
			vim.notify("CSA: rejected " .. n .. " edit(s)", vim.log.levels.WARN, { title = "CSA" })
			pcall(function()
				require("csa.ui.picker").refresh_files()
			end)
			return true
		end
	else
		path = abs_path(path)
	end
	local edit = path and pending[path]
	if not edit then
		vim.notify("CSA: no pending edit for this file", vim.log.levels.INFO, { title = "CSA" })
		return false
	end
	clear_buffer_diff(path)
	write_file(path, edit.before or "")
	local buf = vim.fn.bufnr(path)
	if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
		local lines = vim.split(edit.before or "", "\n", { plain = true })
		if #lines > 0 and lines[#lines] == "" then
			table.remove(lines)
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modified = false
	end
	pending[path] = nil
	vim.notify("CSA: rejected " .. vim.fn.fnamemodify(path, ":."), vim.log.levels.WARN, { title = "CSA" })
	pcall(function()
		require("csa.ui.picker").refresh_files()
	end)
	return true
end

function M.clear_all()
	for p in pairs(pending) do
		clear_buffer_diff(p)
	end
	pending = {}
	snapshots = {}
	turn_edits = {}
end

return M

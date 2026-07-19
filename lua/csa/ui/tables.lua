--- Reflow wide markdown pipe tables so they fit the CSA Output width while
--- staying valid pipe-tables (render-markdown can still beautify them).
local M = {}

local function disp_w(s)
	return vim.fn.strdisplaywidth(s or "")
end

---@param line string
---@return string[]|nil
local function parse_row(line)
	if type(line) ~= "string" or not line:find("|", 1, true) then
		return nil
	end
	local trimmed = vim.trim(line)
	if trimmed == "" or not trimmed:find("^|") then
		-- also allow rows without leading |
		if not line:find("|", 1, true) then
			return nil
		end
	end
	local cells = vim.split(line, "|", { plain = true })
	-- drop empty edge cells from leading/trailing |
	if cells[1] and vim.trim(cells[1]) == "" then
		table.remove(cells, 1)
	end
	if cells[#cells] and vim.trim(cells[#cells]) == "" then
		table.remove(cells, #cells)
	end
	if #cells == 0 then
		return nil
	end
	for i, c in ipairs(cells) do
		cells[i] = vim.trim(c)
	end
	return cells
end

---@param cells string[]
---@return boolean
local function is_delim_row(cells)
	if #cells == 0 then
		return false
	end
	for _, c in ipairs(cells) do
		if not c:match("^:?%-+:?$") and not c:match("^%-+$") then
			return false
		end
	end
	return true
end

---@param text string
---@param width integer
---@return string[]
local function wrap_text(text, width)
	width = math.max(4, width)
	text = tostring(text or "")
	if disp_w(text) <= width then
		return { text }
	end
	local out = {}
	local chars = vim.fn.strchars(text)
	local buf = ""
	local last_break = 0 -- char index in buf preferring space/punctuation breaks
	for i = 0, chars - 1 do
		local ch = vim.fn.strcharpart(text, i, 1)
		if disp_w(buf .. ch) > width then
			if buf ~= "" then
				local cut = (last_break > 0) and last_break or vim.fn.strchars(buf)
				out[#out + 1] = vim.trim(vim.fn.strcharpart(buf, 0, cut))
				buf = vim.trim(vim.fn.strcharpart(buf, cut) .. ch)
				last_break = 0
			else
				buf = ch
			end
			while disp_w(buf) > width do
				local take = 1
				while take < vim.fn.strchars(buf) and disp_w(vim.fn.strcharpart(buf, 0, take + 1)) <= width do
					take = take + 1
				end
				out[#out + 1] = vim.fn.strcharpart(buf, 0, take)
				buf = vim.fn.strcharpart(buf, take)
			end
		else
			buf = buf .. ch
			if ch:match("[%s,;，。、/%-]") then
				last_break = vim.fn.strchars(buf)
			end
		end
	end
	if buf ~= "" then
		out[#out + 1] = buf
	end
	return #out > 0 and out or { "" }
end

---@param cells string[]
---@return string
local function format_row(cells)
	return "| " .. table.concat(cells, " | ") .. " |"
end

---@param n integer
---@return string
local function delim_row(n)
	local parts = {}
	for _ = 1, n do
		parts[#parts + 1] = "---"
	end
	return format_row(parts)
end

---@param rows string[][] header + body (no delim)
---@param col_idxs integer[] 1-based column indexes to keep
---@param col_widths integer[] max display width per kept column
---@return string[]
local function build_table(rows, col_idxs, col_widths)
	local out = {}
	local ncol = #col_idxs
	for r, row in ipairs(rows) do
		local picked = {}
		for i, idx in ipairs(col_idxs) do
			picked[i] = row[idx] or ""
		end
		-- wrap each cell, expand to multiple visual rows
		local wrapped = {}
		local height = 1
		for i, cell in ipairs(picked) do
			wrapped[i] = wrap_text(cell, col_widths[i] or 20)
			height = math.max(height, #wrapped[i])
		end
		for h = 1, height do
			local line_cells = {}
			for i = 1, ncol do
				line_cells[i] = wrapped[i][h] or ""
			end
			out[#out + 1] = format_row(line_cells)
		end
		if r == 1 then
			out[#out + 1] = delim_row(ncol)
		end
	end
	return out
end

---@param rows string[][]
---@return integer[]
local function natural_widths(rows)
	local widths = {}
	for _, row in ipairs(rows) do
		for i, cell in ipairs(row) do
			widths[i] = math.max(widths[i] or 0, disp_w(cell))
		end
	end
	return widths
end

--- Approximate rendered pipe-table width (cells + padding + borders).
---@param widths integer[]
---@return integer
local function table_pixel_width(widths)
	local total = 1 -- leading border
	for _, w in ipairs(widths) do
		total = total + 1 + w + 1 + 1 -- pad + cell + pad + |
	end
	return total
end

---@param lines string[]
---@param start_i integer
---@return integer end_i, string[][] rows
local function read_table(lines, start_i)
	local rows = {}
	local i = start_i
	while i <= #lines do
		local cells = parse_row(lines[i])
		if not cells then
			break
		end
		if not is_delim_row(cells) then
			rows[#rows + 1] = cells
		end
		i = i + 1
		-- stop at blank line after at least header+one
		if i <= #lines and vim.trim(lines[i]) == "" then
			break
		end
		-- stop if next non-empty isn't a table row
		if i <= #lines then
			local nxt = parse_row(lines[i])
			if not nxt then
				break
			end
		end
	end
	return i - 1, rows
end

---@param rows string[][]
---@param max_width integer
---@return string[]
local function reflow_rows(rows, max_width)
	if #rows == 0 then
		return {}
	end
	local ncol = 0
	for _, row in ipairs(rows) do
		ncol = math.max(ncol, #row)
	end
	if ncol == 0 then
		return {}
	end
	-- normalize ragged rows
	for _, row in ipairs(rows) do
		while #row < ncol do
			row[#row + 1] = ""
		end
	end

	local natural = natural_widths(rows)
	if table_pixel_width(natural) <= max_width then
		-- still wrap any single cell that alone would overflow
		local widths = {}
		local budget = math.max(8, max_width - (ncol * 4 + 1))
		local base = math.floor(budget / ncol)
		for i = 1, ncol do
			widths[i] = math.max(4, math.min(natural[i], base + (i == ncol and (budget - base * ncol) or 0)))
		end
		-- redistribute to prefer natural when possible
		local idxs = {}
		for i = 1, ncol do
			idxs[i] = i
		end
		return build_table(rows, idxs, widths)
	end

	-- Wide multi-column tables (e.g. 维度|Vue|React): emit key+each-col tables.
	if ncol >= 3 then
		local out = {}
		local key_w = math.max(4, math.min(natural[1] or 8, math.floor(max_width * 0.28)))
		local val_w = math.max(8, max_width - key_w - 9)
		for c = 2, ncol do
			if #out > 0 then
				out[#out + 1] = ""
			end
			local part = build_table(rows, { 1, c }, { key_w, val_w })
			for _, line in ipairs(part) do
				out[#out + 1] = line
			end
		end
		return out
	end

	-- 1–2 columns: squeeze into max_width with wrapped cells.
	local idxs = {}
	for i = 1, ncol do
		idxs[i] = i
	end
	local widths = {}
	if ncol == 1 then
		widths[1] = math.max(4, max_width - 5)
	else
		local key_w = math.max(4, math.min(natural[1] or 8, math.floor(max_width * 0.28)))
		widths[1] = key_w
		widths[2] = math.max(8, max_width - key_w - 9)
	end
	return build_table(rows, idxs, widths)
end

---@class CSA.TablePatch
---@field start_i integer 1-based inclusive
---@field end_i integer 1-based inclusive
---@field lines string[]

--- Find wide pipe tables that need reflow.
---@param lines string[]
---@param max_width integer
---@return CSA.TablePatch[]
function M.find_patches(lines, max_width)
	local patches = {}
	if type(lines) ~= "table" or #lines == 0 then
		return patches
	end
	max_width = math.max(24, max_width or 40)
	local i = 1
	while i <= #lines do
		local cells = parse_row(lines[i])
		local next_cells = i < #lines and parse_row(lines[i + 1]) or nil
		if cells and next_cells and is_delim_row(next_cells) then
			local end_i, rows = read_table(lines, i)
			local natural = natural_widths(rows)
			local needs = table_pixel_width(natural) > max_width
			if not needs then
				for _, row in ipairs(rows) do
					for _, cell in ipairs(row) do
						if disp_w(cell) > max_width - 8 then
							needs = true
							break
						end
					end
					if needs then
						break
					end
				end
			end
			if needs and #rows > 0 then
				patches[#patches + 1] = {
					start_i = i,
					end_i = end_i,
					lines = reflow_rows(rows, max_width),
				}
			end
			i = end_i + 1
		else
			i = i + 1
		end
	end
	return patches
end

--- Rewrite wide pipe tables in `lines` to fit `max_width`.
---@param lines string[]
---@param max_width integer
---@return string[]
---@return boolean changed
function M.reflow_lines(lines, max_width)
	local patches = M.find_patches(lines, max_width)
	if #patches == 0 then
		return lines, false
	end
	local out = {}
	local pi = 1
	local i = 1
	while i <= #lines do
		local p = patches[pi]
		if p and i == p.start_i then
			for _, line in ipairs(p.lines) do
				out[#out + 1] = line
			end
			i = p.end_i + 1
			pi = pi + 1
		else
			out[#out + 1] = lines[i]
			i = i + 1
		end
	end
	return out, true
end

--- Reflow pipe tables in-place (only table ranges) so header extmarks survive.
---@param buf integer
---@param win integer|nil
---@return boolean changed
function M.reflow_buf(buf, win)
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	local width = 40
	if type(win) == "number" and vim.api.nvim_win_is_valid(win) then
		width = vim.api.nvim_win_get_width(win)
	end
	-- leave a little margin for float borders / padding
	width = math.max(24, width - 2)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local patches = M.find_patches(lines, width)
	if #patches == 0 then
		return false
	end
	local mod = vim.bo[buf].modifiable
	local ro = vim.bo[buf].readonly
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	-- Apply bottom-up so later patches keep stable line numbers.
	for i = #patches, 1, -1 do
		local p = patches[i]
		vim.api.nvim_buf_set_lines(buf, p.start_i - 1, p.end_i, false, p.lines)
	end
	vim.bo[buf].modifiable = mod
	vim.bo[buf].readonly = ro
	return true
end

return M

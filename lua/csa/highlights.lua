local M = {}

local groups = {
	-- Quiet shared chrome (no Diagnostic rainbow).
	CSABorder = { link = "FloatBorder" },
	CSATitle = { link = "Title" },
	CSANormal = { link = "NormalFloat" },
	CSAPad = { link = "Normal" },
	CSAHiddenCursor = { blend = 100, nocombine = true },
}

--- Theme-aware mode accents (Input border + title).
--- ask=blue-ish, agent=green-ish, plan=amber-ish.
local mode_links = {
	ask = { "DiagnosticInfo", "Function" },
	agent = { "DiagnosticOk", "DiagnosticHint", "DiffAdded" },
	plan = { "DiagnosticWarn", "WarningMsg" },
}

local function sync_pad_sep()
	-- Make the pad/main vertical split line invisible.
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	local bg = normal.bg
	if bg then
		vim.api.nvim_set_hl(0, "CSAPadSep", { fg = bg, bg = bg })
	else
		vim.api.nvim_set_hl(0, "CSAPadSep", { link = "Normal" })
	end
end

---@param name string
---@return table
local function resolve_hl(name)
	local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
	if hl and (hl.fg or hl.bg or hl.ctermfg or hl.ctermbg) then
		return hl
	end
	return vim.api.nvim_get_hl(0, { name = name }) or {}
end

--- Pick a text color from a highlight: prefer fg; many Diff* groups only set bg.
---@param name string
---@return integer|nil, integer|nil
local function fg_from_hl(name)
	local hl = resolve_hl(name)
	if hl.fg then
		return hl.fg, hl.ctermfg
	end
	-- Theme used background-only DiffAdd/DiffDelete — reuse that as text color.
	if hl.bg then
		return hl.bg, hl.ctermbg
	end
	return nil, nil
end

---@param from string
---@param to string
---@param opts? { bold?: boolean }
local function copy_fg(from, to, opts)
	local fg, ctermfg = fg_from_hl(from)
	if fg then
		vim.api.nvim_set_hl(0, to, {
			fg = fg,
			bg = "NONE",
			bold = opts and opts.bold or nil,
			ctermfg = ctermfg,
			ctermbg = "NONE",
		})
	else
		-- Never link Diff* (they often paint backgrounds). Soft fallback.
		vim.api.nvim_set_hl(0, to, { link = "Normal" })
	end
end

--- Define fg-only diff accents (lualine-style), never inherit Diff* backgrounds.
local function sync_diff_fg()
	local add_sources = { "DiffAdded", "Added", "GitSignsAdd", "DiagnosticOk", "DiffAdd" }
	local del_sources = { "DiffRemoved", "Removed", "GitSignsDelete", "DiagnosticError", "DiffDelete" }
	local chg_sources = { "DiffChanged", "Changed", "GitSignsChange", "DiagnosticWarn", "DiffChange" }

	local function first_fg(names, fallback)
		for _, name in ipairs(names) do
			local fg, ctermfg = fg_from_hl(name)
			if fg then
				return fg, ctermfg
			end
		end
		return fallback, nil
	end

	local add_fg, add_ct = first_fg(add_sources, 0xa6e3a1)
	local del_fg, del_ct = first_fg(del_sources, 0xf38ba8)
	local chg_fg, chg_ct = first_fg(chg_sources, 0xf9e2af)

	vim.api.nvim_set_hl(0, "CSADiffAdd", { fg = add_fg, bg = "NONE", ctermfg = add_ct, ctermbg = "NONE" })
	vim.api.nvim_set_hl(0, "CSADiffDelete", { fg = del_fg, bg = "NONE", ctermfg = del_ct, ctermbg = "NONE" })
	vim.api.nvim_set_hl(0, "CSADiffChange", { fg = chg_fg, bg = "NONE", ctermfg = chg_ct, ctermbg = "NONE" })
end

---@param names string[]
---@return string
local function first_hl(names)
	for _, name in ipairs(names) do
		local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
		if hl and hl.fg then
			return name
		end
		hl = vim.api.nvim_get_hl(0, { name = name })
		if hl and hl.fg then
			return name
		end
	end
	return names[1]
end

---@param color integer|nil
---@return number
local function luminance(color)
	if type(color) ~= "number" then
		return 0.5
	end
	local r = math.floor(color / 65536) % 256
	local g = math.floor(color / 256) % 256
	local b = color % 256
	return (0.299 * r + 0.587 * g + 0.114 * b) / 255
end

local function sync_mode_accents()
	local float = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
	if not float or (not float.bg and not float.fg) then
		float = vim.api.nvim_get_hl(0, { name = "NormalFloat" })
	end
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	if not normal or (not normal.bg and not normal.fg) then
		normal = vim.api.nvim_get_hl(0, { name = "Normal" })
	end

	for mode, candidates in pairs(mode_links) do
		local link = first_hl(candidates)
		local suffix = mode:sub(1, 1):upper() .. mode:sub(2)
		copy_fg(link, "CSABorder" .. suffix, {})
		copy_fg(link, "CSATitle" .. suffix, { bold = true })

		-- Model pill: body bg = mode border fg; round caps use same color as fg.
		local border = vim.api.nvim_get_hl(0, { name = "CSABorder" .. suffix, link = false })
		local chip_bg = border.fg
		local surface = float.bg or normal.bg
		local chip_fg
		if chip_bg and luminance(chip_bg) > 0.55 then
			chip_fg = surface or 0x111111
			if chip_fg and luminance(chip_fg) > 0.5 then
				chip_fg = 0x111111
			end
		else
			chip_fg = surface
			if not chip_fg or luminance(chip_fg) < 0.45 then
				chip_fg = 0xffffff
			end
		end
		vim.api.nvim_set_hl(0, "CSAModelTag" .. suffix, {
			fg = chip_fg,
			bg = chip_bg,
			bold = true,
		})
		-- Caps: glyph color = chip, sit on float surface → reads as round ends.
		vim.api.nvim_set_hl(0, "CSAModelTagEdge" .. suffix, {
			fg = chip_bg,
			bg = surface,
		})
		-- Skill mention pills in Input (`/name`) share the same chip look.
		vim.api.nvim_set_hl(0, "CSASkillTag" .. suffix, {
			fg = chip_fg,
			bg = chip_bg,
			bold = true,
		})
		vim.api.nvim_set_hl(0, "CSASkillTagEdge" .. suffix, {
			fg = chip_bg,
			bg = surface,
		})
	end
end

function M.apply()
	for name, spec in pairs(groups) do
		vim.api.nvim_set_hl(0, name, spec)
	end
	sync_diff_fg()
	sync_pad_sep()
	sync_mode_accents()
end

---@param mode "ask"|"agent"|"plan"|string|nil
---@return string
local function mode_suffix(mode)
	if mode == "ask" or mode == "agent" or mode == "plan" then
		return mode:sub(1, 1):upper() .. mode:sub(2)
	end
	return "Agent"
end

--- Body highlight for the model pill.
---@param mode "ask"|"agent"|"plan"|string|nil
---@return string
function M.model_tag_group(mode)
	return "CSAModelTag" .. mode_suffix(mode)
end

--- Round-cap highlight for the model pill.
---@param mode "ask"|"agent"|"plan"|string|nil
---@return string
function M.model_tag_edge_group(mode)
	return "CSAModelTagEdge" .. mode_suffix(mode)
end

--- Body highlight for `/skill` pills in Input.
---@param mode "ask"|"agent"|"plan"|string|nil
---@return string
function M.skill_tag_group(mode)
	return "CSASkillTag" .. mode_suffix(mode)
end

--- Round-cap highlight for `/skill` pills.
---@param mode "ask"|"agent"|"plan"|string|nil
---@return string
function M.skill_tag_edge_group(mode)
	return "CSASkillTagEdge" .. mode_suffix(mode)
end

function M.setup()
	M.apply()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("CSAHighlights", { clear = true }),
		callback = M.apply,
	})
end

return M

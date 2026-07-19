local config = require("csa.config")
local highlights = require("csa.highlights")
local picker = require("csa.ui.picker")
local storage = require("csa.storage")

local M = {}
local setup_done = false

local function ensure_init()
	storage.ensure()
	if setup_done then
		return
	end
	setup_done = true
	highlights.setup()
end

--- Configure CSA. Pass a table to set options; omit args to only ensure highlights.
---@param opts CSA.Config|nil
function M.setup(opts)
	config.setup(opts)
	ensure_init()
	return M
end

--- Resolved options (after setup).
---@return CSA.Config
function M.config()
	return config.get()
end

function M.toggle()
	ensure_init()
	picker.toggle()
end

---@param opts? { mode?: "ask"|"agent"|"plan", mode_locked?: boolean }
function M.open(opts)
	ensure_init()
	picker.open(opts)
end

function M.close()
	picker.close()
end

--- Show/hide the files panel (`nil` toggles).
---@param visible boolean|nil
function M.set_files_visible(visible)
	ensure_init()
	picker.set_files_visible(visible)
end

---@return string[]
function M.get_files()
	return picker.get_files()
end

---@param mode "ask"|"agent"
---@param prefill? string
---@param opts? { submit?: boolean }
local function open_locked(mode, prefill, opts)
	opts = opts or {}
	ensure_init()
	picker.open({ mode = mode, mode_locked = true })
	if type(prefill) == "string" and vim.trim(prefill) ~= "" then
		local ibuf = picker.state().bufs.input
		if ibuf and vim.api.nvim_buf_is_valid(ibuf) then
			local lines = vim.split(prefill, "\n", { plain = true })
			vim.bo[ibuf].modifiable = true
			vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, lines)
			picker.refresh_model_tag()
		end
	end
	if opts.submit then
		picker.focus("input", { insert = false })
		vim.schedule(function()
			picker.submit_input()
		end)
		return
	end
	picker.focus("input", { insert = true })
end

--- Open CSA in ask mode (mode locked). Optional prefill (visual / range / args).
--- When `opts.submit` is true, send immediately (used by `:CSAsk {text}`).
---@param prefill? string
---@param opts? { submit?: boolean }
function M.ask(prefill, opts)
	open_locked("ask", prefill, opts)
end

--- Open CSA in agent mode (mode locked). Optional prefill (visual / range) goes into Input.
---@param prefill? string
---@param opts? { submit?: boolean }
function M.agents(prefill, opts)
	open_locked("agent", prefill, opts)
end

return M

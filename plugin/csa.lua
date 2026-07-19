if vim.g.loaded_csa then
	return
end
vim.g.loaded_csa = true

-- Keep :help csa available without asking users to run :helptags.
do
	local src = debug.getinfo(1, "S").source
	if type(src) == "string" and src:sub(1, 1) == "@" then
		local doc = vim.fs.joinpath(vim.fn.fnamemodify(src:sub(2), ":p:h:h"), "doc")
		if vim.uv.fs_stat(doc) then
			pcall(vim.cmd, "silent! helptags " .. vim.fn.fnameescape(doc))
		end
	end
end

---@return string|nil
local function visual_text()
	local mode = vim.fn.mode(1)
	if not mode:find("[vV\22]") then
		return nil
	end
	local reg = vim.fn.getreg('"')
	local regtype = vim.fn.getregtype('"')
	vim.cmd('normal! "zy')
	local text = vim.fn.getreg("z")
	vim.fn.setreg('"', reg, regtype)
	if type(text) == "string" and vim.trim(text) ~= "" then
		return text
	end
	return nil
end

local function run(fn)
	return function(cmd_opts)
		-- Ensure stdpath("data")/site/csa/{history,agents,cache} (+ agent md files).
		pcall(function()
			require("csa.storage").ensure()
		end)

		local prefill = visual_text()
		if not prefill and cmd_opts and (cmd_opts.range or 0) > 0 then
			local lines = vim.api.nvim_buf_get_lines(0, cmd_opts.line1 - 1, cmd_opts.line2, false)
			if #lines > 0 then
				prefill = table.concat(lines, "\n")
			end
		end

		local mode = vim.fn.mode(1)
		-- Leave visual / select so the command always applies.
		if mode:find("[vV\22sS\19]") then
			local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
			vim.api.nvim_feedkeys(esc, "nx", false)
		end
		-- Terminal mode must return to normal before focusing the float.
		if mode:sub(1, 1) == "t" then
			local esc = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
			vim.api.nvim_feedkeys(esc, "n", false)
			vim.schedule(function()
				require("csa")[fn](prefill)
			end)
			return
		end
		require("csa")[fn](prefill)
	end
end

vim.api.nvim_create_user_command("CSAToggle", run("toggle"), {
	desc = "Toggle CSA side picker",
})

vim.api.nvim_create_user_command("CSAsk", run("ask"), {
	desc = "Open CSA ask (Cursor CLI)",
	range = true,
})

vim.api.nvim_create_user_command("CSAgents", run("agents"), {
	desc = "Open CSA agent (Cursor CLI)",
	range = true,
})

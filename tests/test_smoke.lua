local H = require("tests.harness")

H.describe("csa smoke", function()
	H.it("loads public modules", function()
		for _, mod in ipairs({
			"csa",
			"csa.config",
			"csa.storage",
			"csa.review",
			"csa.highlights",
			"csa.ai.cursor",
			"csa.ui.picker",
			"csa.ui.files",
			"csa.ui.history",
			"csa.ui.models",
			"csa.ui.tables",
		}) do
			package.loaded[mod] = nil
			local ok, err = pcall(require, mod)
			if not ok then
				error(mod .. " failed: " .. tostring(err))
			end
		end
	end)

	H.it("csa.setup returns module", function()
		package.loaded["csa"] = nil
		package.loaded["csa.config"] = nil
		package.loaded["csa.highlights"] = nil
		local csa = require("csa")
		local ret = csa.setup({ ui = { width = 0.33 } })
		H.expect(ret).to_eq(csa)
		H.expect(csa.config().ui.width).to_eq(0.33)
	end)

	H.it("help file exists and is readable", function()
		local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
		local path = root .. "/doc/csa.txt"
		H.expect(vim.uv.fs_stat(path) ~= nil).to_be_truthy(path)
		local lines = vim.fn.readfile(path)
		H.expect(#lines > 20).to_be_truthy()
		local text = table.concat(lines, "\n")
		H.expect(text).to_contain("*csa.txt*")
		H.expect(text).to_contain("*csa-keymaps*")
		H.expect(text).to_contain("*csa-regen*")
		H.expect(text).to_contain(":CSAToggle")
	end)

	H.it("README files exist", function()
		local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
		H.expect(vim.uv.fs_stat(root .. "/README.md") ~= nil).to_be_truthy()
		H.expect(vim.uv.fs_stat(root .. "/README.zh-CN.md") ~= nil).to_be_truthy()
	end)

	H.it("ask and agents APIs exist", function()
		package.loaded["csa"] = nil
		local csa = require("csa")
		H.expect(type(csa.ask)).to_eq("function")
		H.expect(type(csa.agents)).to_eq("function")
	end)

	H.it("picker exposes message / usage APIs", function()
		package.loaded["csa.ui.picker"] = nil
		local picker = require("csa.ui.picker")
		H.expect(type(picker.goto_message)).to_eq("function")
		H.expect(type(picker.regenerate_message)).to_eq("function")
		H.expect(type(picker.edit_message)).to_eq("function")
		H.expect(type(picker.copy_message)).to_eq("function")
		H.expect(type(picker.set_usage)).to_eq("function")
		H.expect(type(picker.open)).to_eq("function")
	end)
end)

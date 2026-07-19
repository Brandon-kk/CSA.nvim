local H = require("tests.harness")

H.describe("csa.config", function()
	H.it("exposes defaults", function()
		package.loaded["csa.config"] = nil
		local config = require("csa.config")
		H.expect(config.defaults.ui.width).to_eq(0.30)
		H.expect(config.defaults.language).to_eq("en")
		H.expect(config.defaults.provider.command).to_eq("cursor-agent")
		H.expect(config.defaults.provider.stream).to_eq(true)
	end)

	H.it("setup merges options", function()
		package.loaded["csa.config"] = nil
		local config = require("csa.config")
		config.setup({
			ui = { width = 0.42, files = { enabled = true, max_visible = 2 } },
			provider = { force = true },
		})
		H.expect(config.width()).to_eq(0.42)
		H.expect(config.show_files()).to_eq(true)
		H.expect(config.files_num()).to_eq(2)
		H.expect(config.provider().force).to_eq(true)
		-- untouched defaults remain
		H.expect(config.input_height()).to_eq(3)
	end)

	H.it("language supports 18 codes and aliases", function()
		package.loaded["csa.config"] = nil
		local config = require("csa.config")
		H.expect(#config.language_codes()).to_eq(18)
		config.setup({ language = "zh-CN" })
		H.expect(config.language()).to_eq("zh-CN")
		H.expect(config.language_label()).to_eq("Simplified Chinese")
		config.setup({ language = "zh" })
		H.expect(config.language()).to_eq("zh-CN")
		config.setup({ language = "jp" })
		H.expect(config.language()).to_eq("ja")
		config.setup({ language = "nope" })
		H.expect(config.language()).to_eq("en")
	end)

	H.it("icons resolve by kind", function()
		package.loaded["csa.config"] = nil
		local config = require("csa.config")
		config.setup({})
		H.expect(config.icon("input")).to_be_truthy()
		H.expect(config.icon("files")).to_be_truthy()
		H.expect(config.icon("output")).to_be_truthy()
		H.expect(config.user_icon()).to_be_truthy()
	end)

	H.it("provider_auth_key reads env name", function()
		package.loaded["csa.config"] = nil
		local config = require("csa.config")
		local key = "CSA_TEST_KEY_" .. tostring(vim.uv.hrtime())
		vim.env[key] = "secret-value"
		config.setup({ provider = { auth = { env = key } } })
		H.expect(config.provider_auth_key()).to_eq("secret-value")
		vim.env[key] = nil
	end)
end)

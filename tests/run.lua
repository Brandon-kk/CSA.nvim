-- Entry: nvim --headless -u tests/minimal_init.lua -l tests/run.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

-- Allow `require("tests.harness")`
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local H = require("tests.harness")

require("tests.test_config")
require("tests.test_storage")
require("tests.test_review")
require("tests.test_smoke")

local ok = H.summary()
if not ok then
	vim.cmd("cquit 1")
else
	vim.cmd("quit")
end

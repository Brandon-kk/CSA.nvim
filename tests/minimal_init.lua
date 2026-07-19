-- Isolated runtime for CSA.nvim tests (no user config).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local data = root .. "/.testdata"
vim.fn.delete(data, "rf")
vim.fn.mkdir(data, "p")
vim.env.XDG_DATA_HOME = data
vim.env.XDG_STATE_HOME = data .. "/state"
vim.env.XDG_CACHE_HOME = data .. "/cache"

vim.opt.runtimepath:prepend(root)
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")

-- Avoid packing user plugins.
vim.opt.packpath = { data .. "/site" }

local M = {}

---@class CSA.UIInputConfig
---@field height? integer
---@field icon? string

---@class CSA.UIFilesConfig
---@field enabled? boolean
---@field max_visible? integer
---@field icon? string

---@class CSA.UIOutputConfig
---@field icon? string

---@class CSA.UIConfig
---@field width? number fraction of editor columns (0–1) or absolute columns (>1)
---@field border? string|table
---@field input? CSA.UIInputConfig
---@field files? CSA.UIFilesConfig
---@field output? CSA.UIOutputConfig

---@class CSA.IdentityConfig
---@field name? string display name in Output headers (default: git user.name / $USER)
---@field icon? string

---@class CSA.ProviderAuthConfig
---@field env? string environment variable name that holds the API key
---@field key? string optional direct key (prefer env instead)

---@class CSA.ProviderConfig
---@field enabled? boolean
---@field command? string CLI executable name/path
---@field workspace? string|nil working directory; nil → vim.fn.getcwd()
---@field auth? CSA.ProviderAuthConfig
---@field force? boolean allow file edits when session mode is agent
---@field stream? boolean use stream-json + partial deltas
---@field trust? boolean pass --trust for headless runs

---@class CSA.Config
---@field language? string reply language code (see |csa-config| / M.languages)
---@field ui? CSA.UIConfig
---@field identity? CSA.IdentityConfig
---@field provider? CSA.ProviderConfig

--- Supported reply languages: code → English label (18).
---@type table<string, string>
M.languages = {
	["en"] = "English",
	["zh-CN"] = "Simplified Chinese",
	["zh-TW"] = "Traditional Chinese",
	["ja"] = "Japanese",
	["ko"] = "Korean",
	["fr"] = "French",
	["de"] = "German",
	["es"] = "Spanish",
	["pt"] = "Portuguese",
	["ru"] = "Russian",
	["it"] = "Italian",
	["nl"] = "Dutch",
	["pl"] = "Polish",
	["tr"] = "Turkish",
	["ar"] = "Arabic",
	["hi"] = "Hindi",
	["vi"] = "Vietnamese",
	["th"] = "Thai",
}

local LANGUAGE_ALIASES = {
	["en-us"] = "en",
	["en-gb"] = "en",
	["eng"] = "en",
	["english"] = "en",
	["zh"] = "zh-CN",
	["zh-cn"] = "zh-CN",
	["zh_cn"] = "zh-CN",
	["cn"] = "zh-CN",
	["chinese"] = "zh-CN",
	["zh-tw"] = "zh-TW",
	["zh_tw"] = "zh-TW",
	["zh-hk"] = "zh-TW",
	["jp"] = "ja",
	["jpn"] = "ja",
	["japanese"] = "ja",
	["kr"] = "ko",
	["kor"] = "ko",
	["korean"] = "ko",
	["fra"] = "fr",
	["french"] = "fr",
	["deu"] = "de",
	["german"] = "de",
	["spa"] = "es",
	["spanish"] = "es",
	["por"] = "pt",
	["portuguese"] = "pt",
	["rus"] = "ru",
	["russian"] = "ru",
	["ita"] = "it",
	["italian"] = "it",
	["nld"] = "nl",
	["dutch"] = "nl",
	["pol"] = "pl",
	["polish"] = "pl",
	["tur"] = "tr",
	["turkish"] = "tr",
	["ara"] = "ar",
	["arabic"] = "ar",
	["hin"] = "hi",
	["hindi"] = "hi",
	["vie"] = "vi",
	["vietnamese"] = "vi",
	["tha"] = "th",
	["thai"] = "th",
}

---@param code any
---@return string|nil
local function normalize_language(code)
	if type(code) ~= "string" then
		return nil
	end
	local raw = vim.trim(code)
	if raw == "" then
		return nil
	end
	if M.languages[raw] then
		return raw
	end
	local key = raw:lower():gsub("_", "-")
	if M.languages[key] then
		return key
	end
	local alias = LANGUAGE_ALIASES[key] or LANGUAGE_ALIASES[raw:lower()]
	if alias and M.languages[alias] then
		return alias
	end
	-- Case-insensitive match against canonical codes (e.g. ZH-CN).
	for canon, _ in pairs(M.languages) do
		if canon:lower() == key then
			return canon
		end
	end
	return nil
end

---@type CSA.Config
M.defaults = {
	language = "en",
	ui = {
		width = 0.30,
		border = "rounded",
		input = {
			height = 3,
			icon = "󰏫",
		},
		files = {
			enabled = false,
			max_visible = 5,
			icon = "󰈙",
		},
		output = {
			icon = "󰚩",
		},
	},
	identity = {
		name = nil,
		icon = "",
	},
	provider = {
		enabled = true,
		command = "cursor-agent",
		workspace = nil,
		auth = {
			env = "CURSOR_API_KEY",
			key = nil,
		},
		force = false,
		stream = true,
		trust = true,
	},
}

---@type CSA.Config
M.options = vim.deepcopy(M.defaults)

--- Apply user options. No-op when `opts` is nil.
---@param opts CSA.Config|nil
function M.setup(opts)
	if opts == nil then
		return
	end
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
	local lang = normalize_language(M.options.language)
	if not lang then
		vim.notify(
			("CSA: unknown language %q; falling back to en"):format(tostring(M.options.language)),
			vim.log.levels.WARN,
			{ title = "CSA" }
		)
		lang = "en"
	end
	M.options.language = lang
end

---@return CSA.Config
function M.get()
	return M.options
end

--- Canonical reply language code (one of M.languages keys).
---@return string
function M.language()
	return normalize_language(M.options.language) or "en"
end

--- English label for the configured reply language.
---@return string
function M.language_label()
	local code = M.language()
	return M.languages[code] or M.languages.en
end

--- Sorted list of supported language codes.
---@return string[]
function M.language_codes()
	local codes = vim.tbl_keys(M.languages)
	table.sort(codes)
	return codes
end

function M.width()
	local ui = M.options.ui
	return (ui and ui.width) or 0.30
end

function M.border()
	local ui = M.options.ui
	return (ui and ui.border) or "rounded"
end

function M.show_files()
	local files = M.options.ui and M.options.ui.files
	return files and files.enabled and true or false
end

function M.input_height()
	local input = M.options.ui and M.options.ui.input
	return (input and input.height) or 3
end

function M.files_num()
	local files = M.options.ui and M.options.ui.files
	return (files and files.max_visible) or 5
end

function M.icon(kind)
	local ui = M.options.ui or {}
	if kind == "input" then
		return (ui.input and ui.input.icon) or "󰏫"
	elseif kind == "files" or kind == "file" then
		return (ui.files and ui.files.icon) or "󰈙"
	elseif kind == "user" then
		return M.user_icon()
	end
	return (ui.output and ui.output.icon) or "󰚩"
end

function M.user_icon()
	local id = M.options.identity
	if id and type(id.icon) == "string" and id.icon ~= "" then
		return id.icon
	end
	return ""
end

function M.user_name()
	local id = M.options.identity
	if id and type(id.name) == "string" and id.name ~= "" then
		return id.name
	end
	local ok, name = pcall(function()
		return vim.fn.systemlist({ "git", "config", "user.name" })[1]
	end)
	if ok and type(name) == "string" and name ~= "" then
		return name
	end
	local user = vim.fn.expand("$USER")
	if type(user) == "string" and user ~= "" then
		return user
	end
	return "user"
end

---@return CSA.ProviderConfig
function M.provider()
	return M.options.provider or M.defaults.provider
end

function M.provider_enabled()
	local p = M.provider()
	return p.enabled ~= false
end

function M.provider_command()
	local p = M.provider()
	local cmd = (p and p.command) or "cursor-agent"
	if vim.fn.executable(cmd) == 1 then
		return cmd
	end
	if cmd ~= "cursor-agent" and vim.fn.executable("cursor-agent") == 1 then
		return "cursor-agent"
	end
	if cmd ~= "agent" and vim.fn.executable("agent") == 1 then
		return "agent"
	end
	return cmd
end

function M.provider_workspace()
	local p = M.provider()
	if p and type(p.workspace) == "string" and p.workspace ~= "" then
		return vim.fn.fnamemodify(p.workspace, ":p")
	end
	return vim.fn.getcwd()
end

---@return string|nil
function M.provider_auth_key()
	local p = M.provider()
	local auth = p and p.auth or {}
	if type(auth.key) == "string" and auth.key ~= "" then
		return auth.key
	end
	local key_env = auth.env or "CURSOR_API_KEY"
	if type(key_env) == "string" and (key_env:match("^crsr_") or key_env:match("^cursor_")) then
		return key_env
	end
	local from_vim = vim.env[key_env]
	if type(from_vim) == "string" and from_vim ~= "" then
		return from_vim
	end
	local from_env = vim.fn.environ()[key_env]
	if type(from_env) == "string" and from_env ~= "" then
		return from_env
	end
	return nil
end

return M

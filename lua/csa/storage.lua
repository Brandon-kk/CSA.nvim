local M = {}

--- Preferred load order for persona / identity docs.
local AGENT_FILES = {
	"soul.md",
	"identity.md",
	"user.md",
	"agents.md",
	"bootstrap.md",
	"memory.md",
}

local ensured = false
local AGENT_DOC_MAX_BYTES = 48 * 1024
local SKILL_DOC_MAX_BYTES = 64 * 1024

--- Chat ids from warmup before the first persisted message (no empty history files).
---@type table<string, string>
local pending_chat_ids = {}

---@return string
function M.root()
	return vim.fs.joinpath(vim.fn.stdpath("data"), "site", "csa")
end

function M.history_dir()
	return vim.fs.joinpath(M.root(), "history")
end

function M.agents_dir()
	return vim.fs.joinpath(M.root(), "agents")
end

function M.skills_dir()
	return vim.fs.joinpath(M.root(), "skills")
end

function M.cache_dir()
	return vim.fs.joinpath(M.root(), "cache")
end

local function mkdir(path)
	vim.fn.mkdir(path, "p")
end

local SKILLS_README = [[
# CSA skills

Drop Cursor-compatible skills here. In the CSA Input panel, type `/` to
complete a skill name. Only skills you mention with `/name` are injected into
that turn's provider prompt (nothing is auto-injected).

Layout (either form works):

```text
skills/
  my-skill/
    SKILL.md          # preferred (Cursor / agentskills.io)
  other-skill.md      # flat markdown also accepted
```

`SKILL.md` may start with YAML frontmatter (`name`, `description`).
]]

--- Ensure csa/{history,agents,skills,cache} and default agent markdown files exist.
function M.ensure()
	if ensured then
		return M.root()
	end
	mkdir(M.root())
	mkdir(M.history_dir())
	mkdir(M.agents_dir())
	mkdir(M.skills_dir())
	mkdir(M.cache_dir())
	local agents = M.agents_dir()
	for _, name in ipairs(AGENT_FILES) do
		local path = vim.fs.joinpath(agents, name)
		if vim.uv.fs_stat(path) == nil then
			-- Create empty stubs only; content is user-defined.
			local fd = io.open(path, "w")
			if fd then
				fd:write("")
				fd:close()
			end
		end
	end
	local skills_readme = vim.fs.joinpath(M.skills_dir(), "README.md")
	if vim.uv.fs_stat(skills_readme) == nil then
		local fd = io.open(skills_readme, "w")
		if fd then
			fd:write(SKILLS_README)
			fd:close()
		end
	end
	ensured = true
	return M.root()
end

---@param path string
---@param max_bytes? integer
---@return string|nil
local function read_file_limited(path, max_bytes)
	max_bytes = max_bytes or AGENT_DOC_MAX_BYTES
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local data = fd:read(max_bytes + 1)
	fd:close()
	if type(data) ~= "string" then
		return nil
	end
	if #data > max_bytes then
		data = data:sub(1, max_bytes) .. "\n\n…(truncated)…"
	end
	return data
end

--- Ordered agent markdown docs (known files first, then other *.md).
---@return { name: string, path: string, content: string }[]
function M.list_agent_docs()
	M.ensure()
	local dir = M.agents_dir()
	---@type { name: string, path: string, content: string }[]
	local out = {}
	local seen = {}

	local function push(name)
		if seen[name] then
			return
		end
		local path = vim.fs.joinpath(dir, name)
		local st = vim.uv.fs_stat(path)
		if not st or st.type ~= "file" then
			return
		end
		local content = read_file_limited(path)
		if type(content) ~= "string" then
			return
		end
		-- Skip empty / whitespace-only docs.
		if vim.trim(content) == "" then
			return
		end
		seen[name] = true
		out[#out + 1] = { name = name, path = path, content = content }
	end

	for _, name in ipairs(AGENT_FILES) do
		push(name)
	end

	local handle = vim.uv.fs_scandir(dir)
	if handle then
		local extras = {}
		while true do
			local name, typ = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if (typ == nil or typ == "file") and name:match("%.md$") and not seen[name] then
				extras[#extras + 1] = name
			end
		end
		table.sort(extras)
		for _, name in ipairs(extras) do
			push(name)
		end
	end

	return out
end

--- Build the agent-profile block injected into every provider prompt.
---@return string
function M.agent_context_prompt()
	local docs = M.list_agent_docs()
	if #docs == 0 then
		return ""
	end
	local parts = {
		"# CSA agent profile",
		"",
		"You MUST follow the documents below to determine your identity, personality, relationship to the user, and operating rules.",
		"Treat them as authoritative system instructions for this session.",
		"",
		"Agents directory: `" .. M.agents_dir() .. "`",
		"",
	}
	for _, doc in ipairs(docs) do
		parts[#parts + 1] = "## " .. doc.name
		parts[#parts + 1] = ""
		parts[#parts + 1] = doc.content
		parts[#parts + 1] = ""
	end
	return vim.trim(table.concat(parts, "\n"))
end

---@param content string
---@return string|nil name
---@return string body
---@return string|nil description
local function parse_skill_markdown(content)
	local block, remainder = content:match("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n(.*)$")
	if not block then
		return nil, content, nil
	end
	local name = block:match("name:%s*[\"']?([%w._%-]+)[\"']?")
	local description = block:match("description:%s*[\"'](.-)[\"']")
	if not description then
		description = block:match("description:%s*(%S[^\n]*)")
	end
	if description then
		description = vim.trim(description)
		if description == "" then
			description = nil
		end
	end
	return name, remainder or content, description
end

--- Installed skills under skills/ (folder/SKILL.md or flat *.md, excluding README.md).
---@return { name: string, path: string, content: string, description?: string }[]
function M.list_skills()
	M.ensure()
	local dir = M.skills_dir()
	---@type { name: string, path: string, content: string, description?: string }[]
	local out = {}
	local seen = {}

	local function push(id, path)
		if seen[id] or seen[path] then
			return
		end
		local st = vim.uv.fs_stat(path)
		if not st or st.type ~= "file" then
			return
		end
		local raw = read_file_limited(path, SKILL_DOC_MAX_BYTES)
		if type(raw) ~= "string" or vim.trim(raw) == "" then
			return
		end
		local fm_name, body, description = parse_skill_markdown(raw)
		local name = fm_name or id
		if vim.trim(body) == "" then
			return
		end
		seen[id] = true
		seen[path] = true
		out[#out + 1] = {
			name = name,
			path = path,
			content = vim.trim(body),
			description = description,
		}
	end

	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return out
	end
	local flat = {}
	local folders = {}
	while true do
		local name, typ = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if name == "." or name == ".." or name == "README.md" then
			goto continue
		end
		local path = vim.fs.joinpath(dir, name)
		local st = vim.uv.fs_stat(path)
		local kind = typ
		if st then
			kind = st.type
		end
		if kind == "file" and name:match("%.md$") then
			flat[#flat + 1] = name
		elseif kind == "directory" then
			folders[#folders + 1] = name
		end
		::continue::
	end
	table.sort(folders)
	table.sort(flat)
	for _, name in ipairs(folders) do
		local skill_md = vim.fs.joinpath(dir, name, "SKILL.md")
		if vim.uv.fs_stat(skill_md) then
			push(name, skill_md)
		else
			-- Allow skill.md lowercase.
			local alt = vim.fs.joinpath(dir, name, "skill.md")
			if vim.uv.fs_stat(alt) then
				push(name, alt)
			end
		end
	end
	for _, name in ipairs(flat) do
		push(name:gsub("%.md$", ""), vim.fs.joinpath(dir, name))
	end
	return out
end

--- Skill names mentioned as `/name` in text (order preserved, deduped).
---@param text string|string[]|nil
---@return string[]
function M.skill_mentions_in_text(text)
	local blob
	if type(text) == "table" then
		blob = table.concat(text, "\n")
	elseif type(text) == "string" then
		blob = text
	else
		return {}
	end
	---@type string[]
	local out = {}
	local seen = {}
	for name in blob:gmatch("/([%w._%-]+)") do
		if not seen[name] then
			seen[name] = true
			out[#out + 1] = name
		end
	end
	return out
end

--- Build the skills block for a prompt. Only names listed in `names` are included.
--- Empty / nil `names` → no skills injected (mentions are opt-in via `/name` in Input).
---@param names string[]|nil
---@return string
function M.skills_context_prompt(names)
	if type(names) ~= "table" or #names == 0 then
		return ""
	end
	local want = {}
	for _, name in ipairs(names) do
		if type(name) == "string" and name ~= "" then
			want[name] = true
		end
	end
	if vim.tbl_isempty(want) then
		return ""
	end
	local skills = M.list_skills()
	---@type { name: string, path: string, content: string, description?: string }[]
	local picked = {}
	for _, skill in ipairs(skills) do
		if want[skill.name] then
			picked[#picked + 1] = skill
		end
	end
	if #picked == 0 then
		return ""
	end
	local parts = {
		"# CSA selected skills",
		"",
		"The user invoked the skills below with `/name` in Input.",
		"Apply each skill's instructions for this request.",
		"Treat them as authoritative workflow guidance for this turn.",
		"",
	}
	for _, skill in ipairs(picked) do
		parts[#parts + 1] = "## Skill: " .. skill.name
		if type(skill.description) == "string" and skill.description ~= "" then
			parts[#parts + 1] = ""
			parts[#parts + 1] = "_" .. skill.description .. "_"
		end
		parts[#parts + 1] = ""
		parts[#parts + 1] = skill.content
		parts[#parts + 1] = ""
	end
	return vim.trim(table.concat(parts, "\n"))
end
--- Random 18-char alphanumeric hash.
---@return string
function M.random_id()
	local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	local out = {}
	for _ = 1, 18 do
		local n = math.random(1, #chars)
		out[#out + 1] = chars:sub(n, n)
	end
	return table.concat(out)
end

local function now()
	return os.date("%Y-%m-%dT%H:%M:%S")
end

---@param content string|string[]|nil
---@return string[], string
local function normalize_lines(content)
	local lines
	if type(content) == "table" then
		lines = vim.deepcopy(content)
	else
		lines = vim.split(content or "", "\n", { plain = true })
	end
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	while #lines > 0 and lines[1] == "" do
		table.remove(lines, 1)
	end
	return lines, table.concat(lines, "\n")
end

---@class CSA.HistoryFileEdit
---@field path string
---@field before string
---@field after string
---@field kind string

---@class CSA.HistoryMessage
---@field role string
---@field sender string
---@field time string
---@field content string
---@field lines string[]
---@field edits? CSA.HistoryFileEdit[] agent file edits in this turn (for rewind)

---@class CSA.HistorySession
---@field id string
---@field time string created
---@field updated string
---@field cursor_chat_id? string Cursor CLI chat id for --resume
---@field messages CSA.HistoryMessage[]

---@param session CSA.HistorySession
---@return boolean empty
local function session_is_empty(session)
	return type(session.messages) ~= "table" or #session.messages == 0
end

---@param session CSA.HistorySession
---@return boolean, string|nil err
local function write_session(session)
	local path = vim.fs.joinpath(M.history_dir(), session.id .. ".json")
	-- Never persist sessions with no messages (warmup / abandoned panels).
	if session_is_empty(session) then
		if vim.uv.fs_stat(path) then
			pcall(vim.fn.delete, path)
		end
		return true, nil
	end
	local ok, encoded = pcall(vim.json.encode, session)
	if not ok or type(encoded) ~= "string" then
		return false, "encode"
	end
	local fd, err = io.open(path, "w")
	if not fd then
		return false, err or "open"
	end
	fd:write(encoded)
	fd:write("\n")
	fd:close()
	return true, nil
end

--- Normalize legacy single-message files into a session with messages[].
---@param entry table
---@return CSA.HistorySession
function M.normalize_session(entry)
	if type(entry.messages) == "table" then
		return {
			id = entry.id or "",
			time = entry.time or now(),
			updated = entry.updated or entry.time or now(),
			cursor_chat_id = entry.cursor_chat_id,
			messages = entry.messages,
		}
	end
	local lines, content = normalize_lines(entry.lines or entry.content)
	return {
		id = entry.id or "",
		time = entry.time or now(),
		updated = entry.updated or entry.time or now(),
		cursor_chat_id = entry.cursor_chat_id,
		messages = {
			{
				role = entry.role or "user",
				sender = entry.sender or "user",
				time = entry.time or now(),
				content = content,
				lines = lines,
			},
		},
	}
end

--- Ensure a session shell exists in memory (does not create empty files).
---@param session_id string
---@return CSA.HistorySession
function M.ensure_session(session_id)
	M.ensure()
	local session = M.load_history(session_id)
	if session then
		return session
	end
	local t = now()
	return {
		id = session_id,
		time = t,
		updated = t,
		cursor_chat_id = pending_chat_ids[session_id],
		messages = {},
	}
end

---@param session_id string
---@return string|nil
function M.get_cursor_chat_id(session_id)
	local session = M.load_history(session_id)
	if session and type(session.cursor_chat_id) == "string" and session.cursor_chat_id ~= "" then
		return session.cursor_chat_id
	end
	local pending = pending_chat_ids[session_id]
	if type(pending) == "string" and pending ~= "" then
		return pending
	end
	return nil
end

---@param session_id string
---@param chat_id string
---@return boolean
function M.set_cursor_chat_id(session_id, chat_id)
	if type(session_id) ~= "string" or session_id == "" then
		return false
	end
	if type(chat_id) ~= "string" or chat_id == "" then
		return false
	end
	local session = M.load_history(session_id)
	if session and not session_is_empty(session) then
		session.cursor_chat_id = chat_id
		session.updated = now()
		return write_session(session) and true or false
	end
	-- No messages yet — keep in memory until the first append_message.
	pending_chat_ids[session_id] = chat_id
	return true
end

--- Append a message to a session file (create session on first message).
---@param session_id string
---@param opts { sender: string, content: string|string[], role?: string, edits?: CSA.HistoryFileEdit[] }
---@return CSA.HistorySession|nil, string|nil path, string|nil err
function M.append_message(session_id, opts)
	M.ensure()
	if type(session_id) ~= "string" or session_id == "" then
		return nil, nil, "session"
	end
	local lines, content = normalize_lines(opts.content)
	if #lines == 0 then
		return nil, nil, "empty"
	end

	local path = vim.fs.joinpath(M.history_dir(), session_id .. ".json")
	local session = M.load_history(path)
	if not session then
		local t = now()
		session = {
			id = session_id,
			time = t,
			updated = t,
			cursor_chat_id = pending_chat_ids[session_id],
			messages = {},
		}
	elseif not session.cursor_chat_id and pending_chat_ids[session_id] then
		session.cursor_chat_id = pending_chat_ids[session_id]
	end
	pending_chat_ids[session_id] = nil

	local entry = {
		role = opts.role or "user",
		sender = opts.sender or "user",
		time = now(),
		content = content,
		lines = lines,
	}
	if type(opts.edits) == "table" and #opts.edits > 0 then
		entry.edits = opts.edits
	end
	session.messages[#session.messages + 1] = entry
	session.updated = now()

	local ok, err = write_session(session)
	if not ok then
		return nil, nil, err
	end
	pcall(M.save_last_session_id, session_id)
	return session, path, nil
end

--- Messages that would be dropped by truncate_messages(keep_n).
---@param session_id string
---@param keep_n integer
---@return CSA.HistoryMessage[]
function M.messages_after(session_id, keep_n)
	local session = M.load_history(session_id)
	if not session or type(session.messages) ~= "table" then
		return {}
	end
	keep_n = math.max(0, math.floor(tonumber(keep_n) or 0))
	local out = {}
	for i = keep_n + 1, #session.messages do
		out[#out + 1] = session.messages[i]
	end
	return out
end

--- Keep the first `keep_n` messages; drop the rest (for regenerate / edit-resend).
---@param session_id string
---@param keep_n integer
---@return boolean, CSA.HistoryMessage[] discarded
function M.truncate_messages(session_id, keep_n)
	M.ensure()
	if type(session_id) ~= "string" or session_id == "" then
		return false, {}
	end
	local session = M.load_history(session_id)
	if not session then
		return keep_n <= 0, {}
	end
	keep_n = math.max(0, math.floor(tonumber(keep_n) or 0))
	local msgs = session.messages or {}
	if keep_n >= #msgs then
		return true, {}
	end
	local discarded = {}
	for i = keep_n + 1, #msgs do
		discarded[#discarded + 1] = msgs[i]
	end
	local kept = {}
	for i = 1, keep_n do
		kept[i] = msgs[i]
	end
	session.messages = kept
	session.updated = now()
	return write_session(session) and true or false, discarded
end

--- Drop Cursor CLI resume id so the next ask can seed a fresh chat.
---@param session_id string
---@return boolean
function M.clear_cursor_chat_id(session_id)
	if type(session_id) ~= "string" or session_id == "" then
		return false
	end
	pending_chat_ids[session_id] = nil
	local session = M.load_history(session_id)
	if not session then
		return true
	end
	if session.cursor_chat_id == nil then
		return true
	end
	session.cursor_chat_id = nil
	session.updated = now()
	return write_session(session) and true or false
end

--- Messages to inject when starting a new Cursor chat after a local rewind.
---@param session_id string
---@param prompt? string current user prompt (excluded if it matches the last user msg)
---@return CSA.HistoryMessage[]
function M.history_for_seed(session_id, prompt)
	local session = M.load_history(session_id)
	if not session or type(session.messages) ~= "table" then
		return {}
	end
	local msgs = session.messages
	local end_i = #msgs
	if end_i == 0 then
		return {}
	end
	if type(prompt) == "string" and msgs[end_i].role == "user" then
		local last = msgs[end_i].content
		if type(last) ~= "string" and type(msgs[end_i].lines) == "table" then
			last = table.concat(msgs[end_i].lines, "\n")
		end
		if last == prompt then
			end_i = end_i - 1
		end
	end
	local out = {}
	for i = 1, end_i do
		out[i] = msgs[i]
	end
	return out
end

--- @deprecated use append_message with a stable session id
---@param opts { sender: string, content: string|string[], role?: string, session_id?: string }
---@return CSA.HistorySession|nil, string|nil path, string|nil err
function M.save_history(opts)
	local id = opts.session_id or M.random_id()
	return M.append_message(id, opts)
end

---@param id_or_path string
---@return CSA.HistorySession|nil
function M.load_history(id_or_path)
	M.ensure()
	local path = id_or_path
	if not path:find("%.json$") and not path:find("[/\\]") then
		path = vim.fs.joinpath(M.history_dir(), id_or_path .. ".json")
	elseif not path:find("[/\\]") then
		path = vim.fs.joinpath(M.history_dir(), path)
	end
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local raw = fd:read("*a")
	fd:close()
	if not raw or raw == "" then
		return nil
	end
	local ok, entry = pcall(vim.json.decode, raw)
	if not ok or type(entry) ~= "table" then
		return nil
	end
	local session = M.normalize_session(entry)
	if session.id == "" then
		session.id = vim.fs.basename(path):gsub("%.json$", "")
	end
	return session
end

--- Delete a history session file by id or path.
---@param id_or_path string
---@return boolean ok
function M.delete_history(id_or_path)
	M.ensure()
	if type(id_or_path) ~= "string" or id_or_path == "" then
		return false
	end
	local path = id_or_path
	if not path:find("%.json$") and not path:find("[/\\]") then
		path = vim.fs.joinpath(M.history_dir(), id_or_path .. ".json")
	elseif not path:find("[/\\]") then
		path = vim.fs.joinpath(M.history_dir(), path)
	end
	local ok = vim.fn.delete(path) == 0
	return ok
end

---@class CSA.HistoryListItem
---@field id string
---@field path string
---@field label string filename only (e.g. <id>.json)

--- List history session files, newest first. Optional query filters by filename.
---@param query? string
---@return CSA.HistoryListItem[]
function M.list_history(query)
	M.ensure()
	local dir = M.history_dir()
	local files = vim.fn.glob(vim.fs.joinpath(dir, "*.json"), false, true)
	---@type CSA.HistoryListItem[]
	local items = {}
	for _, path in ipairs(files) do
		local name = vim.fs.basename(path)
		local id = name:gsub("%.json$", "")
		local session = M.load_history(path)
		-- Drop empty leftovers from older builds / abandoned warmups.
		if not session or session_is_empty(session) then
			pcall(vim.fn.delete, path)
		else
			local stat = vim.uv.fs_stat(path)
			local mtime = 0
			if stat and stat.mtime then
				mtime = stat.mtime.sec or 0
			end
			items[#items + 1] = {
				id = id,
				path = path,
				label = name,
				mtime = mtime,
			}
		end
	end
	table.sort(items, function(a, b)
		return (a.mtime or 0) > (b.mtime or 0)
	end)

	query = vim.trim(query or "")
	if query == "" then
		return items
	end
	local q = query:lower()
	local filtered = {}
	for _, item in ipairs(items) do
		if item.label:lower():find(q, 1, true) or (item.id or ""):lower():find(q, 1, true) then
			filtered[#filtered + 1] = item
		end
	end
	return filtered
end

--- Cached model ids from `cursor-agent --list-models`.
---@return string[]|nil
function M.load_models_cache()
	M.ensure()
	local path = vim.fs.joinpath(M.cache_dir(), "models.json")
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local raw = fd:read("*a")
	fd:close()
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local models = data.models
	if type(models) ~= "table" or #models == 0 then
		return nil
	end
	local out = {}
	for _, name in ipairs(models) do
		if type(name) == "string" and name ~= "" then
			out[#out + 1] = name
		end
	end
	return #out > 0 and out or nil
end

---@param models string[]
---@return boolean
function M.save_models_cache(models)
	if type(models) ~= "table" then
		return false
	end
	M.ensure()
	local clean = {}
	local seen = {}
	for _, name in ipairs(models) do
		name = vim.trim(tostring(name or ""))
		if name ~= "" and name:lower() ~= "auto" and not seen[name] then
			seen[name] = true
			clean[#clean + 1] = name
		end
	end
	local path = vim.fs.joinpath(M.cache_dir(), "models.json")
	local ok, encoded = pcall(vim.json.encode, {
		updated = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		models = clean,
	})
	if not ok or type(encoded) ~= "string" then
		return false
	end
	local fd = io.open(path, "w")
	if not fd then
		return false
	end
	fd:write(encoded)
	fd:write("\n")
	fd:close()
	return true
end

--- Last selected model id for the Input pill / --model.
---@return string
function M.load_selected_model()
	M.ensure()
	local path = vim.fs.joinpath(M.cache_dir(), "selected_model.json")
	local fd = io.open(path, "r")
	if not fd then
		return "auto"
	end
	local raw = fd:read("*a")
	fd:close()
	if type(raw) ~= "string" or raw == "" then
		return "auto"
	end
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or type(data) ~= "table" then
		return "auto"
	end
	local model = data.model
	if type(model) == "string" then
		model = vim.trim(model)
		if model ~= "" then
			return model
		end
	end
	return "auto"
end

---@param model string
---@return boolean
function M.save_selected_model(model)
	if type(model) ~= "string" then
		return false
	end
	model = vim.trim(model)
	if model == "" then
		model = "auto"
	end
	M.ensure()
	local path = vim.fs.joinpath(M.cache_dir(), "selected_model.json")
	local ok, encoded = pcall(vim.json.encode, {
		updated = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		model = model,
	})
	if not ok or type(encoded) ~= "string" then
		return false
	end
	local fd = io.open(path, "w")
	if not fd then
		return false
	end
	fd:write(encoded)
	fd:write("\n")
	fd:close()
	return true
end

--- Last active chat session (reopen CSA → restore this conversation).
---@return string|nil
function M.load_last_session_id()
	M.ensure()
	local path = vim.fs.joinpath(M.cache_dir(), "last_session.json")
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local raw = fd:read("*a")
	fd:close()
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local id = data.id or data.session_id
	if type(id) == "string" then
		id = vim.trim(id)
		if id ~= "" then
			return id
		end
	end
	return nil
end

---@param session_id string
---@return boolean
function M.save_last_session_id(session_id)
	if type(session_id) ~= "string" then
		return false
	end
	session_id = vim.trim(session_id)
	if session_id == "" then
		return false
	end
	M.ensure()
	local path = vim.fs.joinpath(M.cache_dir(), "last_session.json")
	local ok, encoded = pcall(vim.json.encode, {
		updated = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		id = session_id,
	})
	if not ok or type(encoded) ~= "string" then
		return false
	end
	local fd = io.open(path, "w")
	if not fd then
		return false
	end
	fd:write(encoded)
	fd:write("\n")
	fd:close()
	return true
end

--- Load the last session that still has messages (for panel reopen).
---@return CSA.HistorySession|nil
function M.load_last_session()
	local id = M.load_last_session_id()
	if not id then
		return nil
	end
	local session = M.load_history(id)
	if not session or session_is_empty(session) then
		return nil
	end
	return session
end

-- Seed RNG once for hash generation.
math.randomseed(vim.uv.hrtime() % 2147483647)

return M

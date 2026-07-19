local config = require("csa.config")
local storage = require("csa.storage")

local M = {}

---@class CSA.TokenUsage
---@field input_tokens integer
---@field output_tokens integer
---@field cache_read_tokens integer
---@field cache_write_tokens integer
---@field reasoning_tokens integer
---@field total_tokens integer
---@field context_used integer prompt-side tokens (input + cache)

---@class CSA.AIRun
---@field job integer|nil jobstart id
---@field busy boolean
---@field session_id string|nil
---@field buf_acc string stdout line buffer
---@field text string accumulated assistant text
---@field turn_snapshot string cumulative assistant snapshot for non-partial streams
---@field use_partial boolean
---@field chat_id string|nil
---@field saw_text boolean
---@field on_delta fun(text: string)|nil
---@field on_status fun(text: string)|nil
---@field on_done fun(ok: boolean, text: string, err?: string)|nil
---@field on_usage fun(usage: CSA.TokenUsage)|nil
---@field on_file_edit fun(ev: CSA.FileEditEvent)|nil
---@field on_file_snapshot fun(path: string)|nil

---@class CSA.FileEditEvent
---@field path string
---@field kind "write"|"edit"|"delete"
---@field after? string
---@field added? integer
---@field removed? integer
---@field call_id? string

---@type CSA.AIRun
local run = {
	job = nil,
	busy = false,
	session_id = nil,
	buf_acc = "",
	text = "",
	turn_snapshot = "",
	use_partial = false,
	chat_id = nil,
	saw_text = false,
	on_delta = nil,
	on_status = nil,
	on_done = nil,
	on_usage = nil,
	on_file_edit = nil,
	on_file_snapshot = nil,
}

---@type integer|nil
local warmup_job = nil

function M.is_busy()
	return run.busy
end

function M.cancel()
	if not run.busy then
		return
	end
	if run.job then
		pcall(vim.fn.jobstop, run.job)
	end
	local text = run.text
	local done = run.on_done
	run.busy = false
	run.job = nil
	run.on_delta = nil
	run.on_status = nil
	run.on_done = nil
	run.on_usage = nil
	run.on_file_edit = nil
	run.on_file_snapshot = nil
	if done then
		done(false, text or "", "cancelled")
	end
end

---@param raw table|nil
---@return CSA.TokenUsage|nil
local function normalize_usage(raw)
	if type(raw) ~= "table" then
		return nil
	end
	-- Nested `{ usage = { ... } }` from type:"usage" events.
	if type(raw.usage) == "table" and (raw.inputTokens or raw.input_tokens or raw.totalTokens) == nil then
		raw = raw.usage
	end
	local input = tonumber(raw.inputTokens or raw.input_tokens or raw.promptTokens or raw.prompt_tokens)
	local output = tonumber(raw.outputTokens or raw.output_tokens or raw.completionTokens or raw.completion_tokens)
	local cache_read = tonumber(raw.cacheReadTokens or raw.cache_read_tokens or raw.cached_tokens) or 0
	local cache_write = tonumber(raw.cacheWriteTokens or raw.cache_write_tokens) or 0
	local reasoning = tonumber(raw.reasoningTokens or raw.reasoning_tokens) or 0
	local total = tonumber(raw.totalTokens or raw.total_tokens)
	if not input and not output and not total and cache_read == 0 and cache_write == 0 then
		return nil
	end
	input = input or 0
	output = output or 0
	if not total then
		total = input + output + cache_read + cache_write
	end
	return {
		input_tokens = input,
		output_tokens = output,
		cache_read_tokens = cache_read,
		cache_write_tokens = cache_write,
		reasoning_tokens = reasoning,
		total_tokens = total,
		-- Context window fill ≈ prompt tokens (incl. cache).
		context_used = input + cache_read + cache_write,
	}
end

---@param obj table
local function emit_usage(obj)
	if not run.on_usage then
		return
	end
	local usage = normalize_usage(obj.usage) or normalize_usage(obj.token_usage) or normalize_usage(obj)
	if usage then
		run.on_usage(usage)
	end
end

--- Resolve API key from `provider.auth`.
---@return string|nil
local function resolve_api_key()
	return config.provider_auth_key()
end

---@return table
local function job_env()
	local env = vim.fn.environ()
	local key = resolve_api_key()
	if key then
		env.CURSOR_API_KEY = key
	end
	-- Encourage line-buffered / unbuffered Node stdio when PTY is unavailable.
	env.NODE_NO_READLINE = env.NODE_NO_READLINE or "1"
	return env
end

--- Shared env for provider CLI jobs (models list, warmup, ask).
function M.job_env()
	return job_env()
end

---@param path string
---@return string
local function normalize_path(path)
	return vim.fn.fnamemodify(path, ":p")
end

---@param prompt string
---@param files string[]|nil
---@param mode? "ask"|"agent"|"plan"
---@param prior? CSA.HistoryMessage[]
---@return string
local function build_prompt(prompt, files, mode, prior)
	local parts = {}

	-- Persona / identity from stdpath("data")/site/csa/agents/*.md
	local agent_ctx = storage.agent_context_prompt()
	if type(agent_ctx) == "string" and agent_ctx ~= "" then
		parts[#parts + 1] = agent_ctx
		parts[#parts + 1] = ""
		parts[#parts + 1] = "---"
		parts[#parts + 1] = ""
	end

	-- Skills mentioned as /name in the user request (opt-in only).
	local skill_names = storage.skill_mentions_in_text(prompt)
	local skills_ctx = storage.skills_context_prompt(skill_names)
	if type(skills_ctx) == "string" and skills_ctx ~= "" then
		parts[#parts + 1] = skills_ctx
		parts[#parts + 1] = ""
		parts[#parts + 1] = "---"
		parts[#parts + 1] = ""
	end

	parts[#parts + 1] = "Format your reply in Markdown (headings, lists, code fences when useful)."
	local lang = config.language()
	local label = config.language_label()
	parts[#parts + 1] = string.format(
		"Always reply in %s (%s). Keep code, paths, and identifiers unchanged.",
		label,
		lang
	)

	-- File allow-list: when the user attached files, scope ALL work to them.
	if type(files) == "table" and #files > 0 then
		local workspace = config.provider_workspace()
		parts[#parts + 1] = ""
		parts[#parts + 1] = "## Scoped files (mandatory)"
		parts[#parts + 1] =
			"The user attached specific files. You MUST stay inside this allow-list:"
		for _, f in ipairs(files) do
			local abs = normalize_path(f)
			local rel = vim.fn.fnamemodify(abs, ":.")
			if workspace and abs:sub(1, #workspace) == workspace then
				rel = abs:sub(#workspace + 2)
			end
			parts[#parts + 1] = string.format("- `%s`", rel ~= "" and rel or abs)
			parts[#parts + 1] = string.format("  absolute: `%s`", abs)
		end
		if mode == "agent" then
			parts[#parts + 1] = ""
			parts[#parts + 1] = "Editing rules:"
			parts[#parts + 1] = "- ONLY create/edit/delete files in the allow-list above."
			parts[#parts + 1] = "- Do NOT modify any other path in the workspace."
			parts[#parts + 1] = "- Do NOT create new files outside the allow-list."
			parts[#parts + 1] = "- Prefer editing the listed files in place to fulfill the request."
		else
			parts[#parts + 1] = ""
			parts[#parts + 1] = "Use ONLY these files as context for your answer (read-only)."
		end
	end

	-- Seed prior turns when local history was rewound onto a fresh Cursor chat.
	if type(prior) == "table" and #prior > 0 then
		parts[#parts + 1] = ""
		parts[#parts + 1] = "## Conversation so far"
		for _, msg in ipairs(prior) do
			local label = msg.role == "assistant" and "Assistant" or "User"
			local body = msg.content
			if type(body) ~= "string" or body == "" then
				if type(msg.lines) == "table" then
					body = table.concat(msg.lines, "\n")
				else
					body = ""
				end
			end
			parts[#parts + 1] = ""
			parts[#parts + 1] = label .. ":"
			parts[#parts + 1] = body
		end
	end

	parts[#parts + 1] = ""
	parts[#parts + 1] = "## User request"
	parts[#parts + 1] = prompt
	return table.concat(parts, "\n")
end

---@param obj table
---@return string|nil
local function text_from_assistant(obj)
	local content = obj.message and obj.message.content
	if type(content) ~= "table" then
		return nil
	end
	local out = {}
	for _, block in ipairs(content) do
		if type(block) == "table" and type(block.text) == "string" then
			out[#out + 1] = block.text
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out)
end

---@param delta string
local function emit_delta(delta)
	if type(delta) ~= "string" or delta == "" then
		return
	end
	run.saw_text = true
	run.text = run.text .. delta
	if run.on_delta then
		run.on_delta(delta)
	end
end

---@param obj table
local function maybe_capture_chat_id(obj)
	if run.chat_id then
		return
	end
	local candidates = {
		obj.chat_id,
		obj.session_id,
		obj.conversation_id,
		obj.id,
	}
	if obj.subtype == "init" or obj.type == "system" then
		for _, c in ipairs(candidates) do
			if type(c) == "string" and c ~= "" and c ~= "unknown" then
				run.chat_id = c
				return
			end
		end
	end
end

---@param obj table
local function handle_assistant(obj)
	local piece = text_from_assistant(obj)
	if not piece or piece == "" then
		return
	end

	-- Partial token deltas (stream-partial-output).
	local is_partial = obj.timestamp_ms ~= nil and obj.model_call_id == nil
	if is_partial then
		run.use_partial = true
		run.turn_snapshot = run.turn_snapshot .. piece
		emit_delta(piece)
		return
	end

	-- Once partial mode is active, ignore buffered full snapshots.
	if run.use_partial then
		return
	end

	-- Cumulative snapshots: emit only the new suffix.
	local prev = run.turn_snapshot
	if piece == prev then
		return
	end
	if #piece >= #prev and piece:sub(1, #prev) == prev then
		emit_delta(piece:sub(#prev + 1))
		run.turn_snapshot = piece
		return
	end
	emit_delta(piece)
	run.turn_snapshot = prev .. piece
end

---@param tc table|nil
---@return string|nil path, string|nil kind
local function tool_path_kind(tc)
	if type(tc) ~= "table" then
		return nil, nil
	end
	local write = tc.writeToolCall or tc.write_tool_call
	if type(write) == "table" then
		local args = write.args or write
		local path = args.path or args.file_path or args.filePath
		if type(path) == "string" and path ~= "" then
			return path, "write"
		end
	end
	local edit = tc.editToolCall or tc.edit_tool_call
	if type(edit) == "table" then
		local args = edit.args or edit
		local path = args.path or args.file_path or args.filePath
		if type(path) == "string" and path ~= "" then
			return path, "edit"
		end
	end
	local del = tc.deleteToolCall or tc.delete_tool_call
	if type(del) == "table" then
		local args = del.args or del
		local path = args.path or args.file_path or args.filePath
		if type(path) == "string" and path ~= "" then
			return path, "delete"
		end
	end
	return nil, nil
end

---@param obj table
local function handle_tool_call(obj)
	local tc = obj.tool_call or obj.toolCall or obj
	local path, kind = tool_path_kind(tc)
	-- Some payloads nest under tool_call.<name>
	if not path and type(obj.tool_call) == "table" then
		path, kind = tool_path_kind(obj.tool_call)
	end

	if obj.subtype == "started" then
		if run.on_status and not run.saw_text then
			run.on_status("working…")
		end
		if path and run.on_file_snapshot then
			run.on_file_snapshot(path)
		end
		return
	end

	if obj.subtype ~= "completed" or not path or not kind then
		return
	end

	local after, added, removed
	local write = (tc and (tc.writeToolCall or tc.write_tool_call))
		or (obj.tool_call and (obj.tool_call.writeToolCall or obj.tool_call.write_tool_call))
	local edit = (tc and (tc.editToolCall or tc.edit_tool_call))
		or (obj.tool_call and (obj.tool_call.editToolCall or obj.tool_call.edit_tool_call))
	local block = write or edit
	if type(block) == "table" then
		local result = block.result or block
		local success = type(result) == "table" and (result.success or result)
		if type(success) == "table" then
			after = success.afterFullFileContent
				or success.after_full_file_content
				or success.fileText
				or success.file_text
				or success.content
			added = success.linesAdded or success.lines_added or success.linesCreated or success.lines_created
			removed = success.linesRemoved or success.lines_removed
			if type(success.path) == "string" and success.path ~= "" then
				path = success.path
			end
		end
		local args = block.args
		if type(args) == "table" and type(after) ~= "string" then
			after = args.fileText or args.file_text or args.content
		end
	end

	if kind == "delete" then
		after = ""
	end

	if run.on_file_edit then
		run.on_file_edit({
			path = path,
			kind = kind,
			after = after,
			added = type(added) == "number" and added or nil,
			removed = type(removed) == "number" and removed or nil,
			call_id = obj.call_id or obj.callId,
		})
	end
end

---@param line string
local function handle_stream_line(line)
	line = vim.trim(line:gsub("\r", ""))
	if line == "" then
		return
	end
	local ok, obj = pcall(vim.json.decode, line)
	if not ok or type(obj) ~= "table" then
		return
	end
	maybe_capture_chat_id(obj)

	if obj.type == "system" and obj.subtype == "init" and run.on_status and not run.saw_text then
		local model = obj.model or ""
		run.on_status(model ~= "" and ("thinking (" .. model .. ")…") or "thinking…")
	elseif obj.type == "tool_call" then
		handle_tool_call(obj)
	elseif obj.type == "assistant" then
		handle_assistant(obj)
	elseif obj.type == "usage" then
		emit_usage(obj)
	elseif obj.type == "result" then
		if run.text == "" then
			local result_text = obj.result or obj.text
			if type(result_text) == "string" and result_text ~= "" then
				emit_delta(result_text)
			end
		end
		emit_usage(obj)
	end
end

---@param chunk string
local function on_stdout(chunk)
	if type(chunk) ~= "string" or chunk == "" then
		return
	end
	chunk = chunk:gsub("\r", "")
	run.buf_acc = run.buf_acc .. chunk
	while true do
		local idx = run.buf_acc:find("\n", 1, true)
		if not idx then
			break
		end
		local line = run.buf_acc:sub(1, idx - 1)
		run.buf_acc = run.buf_acc:sub(idx + 1)
		handle_stream_line(line)
	end
end

---@param ok boolean
---@param text string
---@param err? string
local function finish(ok, text, err)
	if run.chat_id and run.session_id then
		storage.set_cursor_chat_id(run.session_id, run.chat_id)
	end
	local done = run.on_done
	run.busy = false
	run.job = nil
	run.on_delta = nil
	run.on_status = nil
	run.on_done = nil
	run.on_usage = nil
	run.on_file_edit = nil
	run.on_file_snapshot = nil
	if done then
		done(ok, text or "", err)
	end
end

--- Prefetch chat id + warm CLI binary when the panel opens.
---@param session_id string
function M.warmup(session_id)
	if type(session_id) ~= "string" or session_id == "" then
		return
	end
	if storage.get_cursor_chat_id(session_id) then
		return
	end
	local cmd = config.provider_command()
	if vim.fn.executable(cmd) ~= 1 then
		return
	end
	if warmup_job then
		return
	end
	local acc = {}
	warmup_job = vim.fn.jobstart({ cmd, "create-chat" }, {
		cwd = config.provider_workspace(),
		env = job_env(),
		stdout_buffered = false,
		on_stdout = function(_, data, _)
			if type(data) == "table" then
				acc[#acc + 1] = table.concat(data, "\n")
			end
		end,
		on_exit = function(job_id, code, _)
			if warmup_job == job_id then
				warmup_job = nil
			end
			if code ~= 0 then
				return
			end
			local id = vim.trim(table.concat(acc, ""))
			if id:find("\n") then
				local lines = vim.split(id, "\n", { plain = true, trimempty = true })
				id = lines[#lines] or ""
			end
			id = vim.trim(id)
			if id ~= "" then
				vim.schedule(function()
					storage.set_cursor_chat_id(session_id, id)
				end)
			end
		end,
	})
	if type(warmup_job) ~= "number" or warmup_job <= 0 then
		warmup_job = nil
	end
end

---@param cmd string
---@param chat_id? string
---@param prompt string
---@param stream boolean
---@param mode? "ask"|"agent"|"plan"
---@param model? string
local function start_prompt(cmd, chat_id, prompt, stream, mode, model)
	local provider = config.provider()
	mode = mode or "ask"
	if mode ~= "ask" and mode ~= "agent" and mode ~= "plan" then
		mode = "ask"
	end
	local force = provider and provider.force
	local trust = provider == nil or provider.trust ~= false

	-- CLI `--mode` only accepts ask|plan. Agent is the default when omitted.
	---@type string[]
	local args = { cmd, "-p", "--workspace", config.provider_workspace() }
	if mode == "ask" or mode == "plan" then
		args[#args + 1] = "--mode"
		args[#args + 1] = mode
	end
	if type(chat_id) == "string" and chat_id ~= "" then
		args[#args + 1] = "--resume"
		args[#args + 1] = chat_id
	end
	if type(model) == "string" and model ~= "" and model:lower() ~= "auto" then
		args[#args + 1] = "--model"
		args[#args + 1] = model
	end
	if trust then
		args[#args + 1] = "--trust"
	end
	if force and mode == "agent" then
		args[#args + 1] = "--force"
	end
	if stream then
		args[#args + 1] = "--output-format"
		args[#args + 1] = "stream-json"
		args[#args + 1] = "--stream-partial-output"
	else
		args[#args + 1] = "--output-format"
		args[#args + 1] = "text"
	end
	args[#args + 1] = prompt

	run.chat_id = chat_id
	run.buf_acc = ""
	run.text = ""
	run.turn_snapshot = ""
	run.use_partial = false
	run.saw_text = false

	local stderr_acc = {}
	local stdout_raw = {}

	if run.on_status then
		run.on_status("starting…")
	end

	-- PTY is required: without a TTY, Node/CLI block-buffers stdout and
	-- "streaming" only appears when the process exits.
	local job_id = vim.fn.jobstart(args, {
		cwd = config.provider_workspace(),
		env = job_env(),
		pty = true,
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data, _)
			if type(data) ~= "table" or not run.busy then
				return
			end
			local chunk = table.concat(data, "\n")
			stdout_raw[#stdout_raw + 1] = chunk
			vim.schedule(function()
				if not run.busy then
					return
				end
				if stream then
					on_stdout(chunk)
				else
					emit_delta(chunk)
				end
			end)
		end,
		on_stderr = function(_, data, _)
			if type(data) == "table" then
				local s = table.concat(data, "\n")
				if s ~= "" and s ~= "\r" then
					stderr_acc[#stderr_acc + 1] = s
				end
			end
		end,
		on_exit = function(_, code, _)
			vim.schedule(function()
				if stream and run.buf_acc ~= "" then
					handle_stream_line(run.buf_acc)
					run.buf_acc = ""
				end
				local ok = code == 0
				local err
				if not ok then
					err = vim.trim(table.concat(stderr_acc, "\n"))
					-- With pty=true, CLI errors often land on stdout instead of stderr.
					if err == "" then
						local raw = vim.trim(table.concat(stdout_raw, ""))
						raw = raw:gsub("\r", "")
						local useful = {}
						for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
							local t = vim.trim(line)
							if
								t ~= ""
								and (
									t:lower():find("error", 1, true)
									or t:lower():find("auth", 1, true)
									or t:lower():find("invalid", 1, true)
									or t:lower():find("failed", 1, true)
									or t:lower():find("unknown", 1, true)
								)
							then
								useful[#useful + 1] = t
							end
						end
						if #useful > 0 then
							err = useful[#useful]
						elseif raw ~= "" and #raw < 400 then
							err = raw
						else
							err = "agent exited with code " .. tostring(code)
						end
					end
					if not resolve_api_key() then
						err = err
							.. "\n(未检测到 API Key：请 `export CURSOR_API_KEY=...` 或执行 `cursor-agent login`)"
					end
				end
				finish(ok, run.text, err)
			end)
		end,
	})

	if type(job_id) ~= "number" or job_id <= 0 then
		finish(false, "", "failed to start " .. cmd)
		return
	end
	run.job = job_id
end

---@param opts { session_id: string, prompt: string, files?: string[], mode?: "ask"|"agent"|"plan", model?: string, seed_history?: boolean, on_delta?: fun(string), on_status?: fun(string), on_usage?: fun(CSA.TokenUsage), on_done?: fun(boolean, string, string|nil), on_file_edit?: fun(CSA.FileEditEvent), on_file_snapshot?: fun(string) }
function M.ask(opts)
	if run.busy then
		if opts.on_done then
			opts.on_done(false, "", "AI request already in progress")
		end
		return
	end
	local session_id = opts.session_id
	if type(session_id) ~= "string" or session_id == "" then
		if opts.on_done then
			opts.on_done(false, "", "missing session")
		end
		return
	end
	local cmd = config.provider_command()
	if vim.fn.executable(cmd) ~= 1 then
		if opts.on_done then
			opts.on_done(
				false,
				"",
				"Provider CLI not found (`" .. cmd .. "`). Try: brew install --cask cursor-cli"
			)
		end
		return
	end

	local provider = config.provider()
	local stream = provider == nil or provider.stream ~= false
	local existing = storage.get_cursor_chat_id(session_id)
	local prior = nil
	-- After edit-resend rewind: seed dropped-away local turns into the prompt and
	-- skip --resume so Cursor does not still hold the removed messages.
	if opts.seed_history then
		prior = storage.history_for_seed(session_id, opts.prompt)
		existing = nil
	end
	local prompt = build_prompt(opts.prompt, opts.files, opts.mode, prior)

	run.busy = true
	run.session_id = session_id
	run.on_delta = opts.on_delta
	run.on_status = opts.on_status
	run.on_usage = opts.on_usage
	run.on_done = opts.on_done
	run.on_file_edit = opts.on_file_edit
	run.on_file_snapshot = opts.on_file_snapshot
	run.chat_id = nil
	run.text = ""
	run.buf_acc = ""
	run.turn_snapshot = ""
	run.use_partial = false
	run.saw_text = false

	start_prompt(cmd, existing, prompt, stream, opts.mode, opts.model)
end

return M

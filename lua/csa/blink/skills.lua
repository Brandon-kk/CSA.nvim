--- blink.cmp source: complete installed CSA skills after `/` in Input.

local source = {}

---@param opts table|nil
function source.new(opts)
	local self = setmetatable({}, { __index = source })
	self.opts = opts or {}
	return self
end

function source:enabled()
	return vim.bo.filetype == "csa-input"
end

function source:get_trigger_characters()
	return { "/" }
end

---@param ctx blink.cmp.Context
---@param callback fun(response: blink.cmp.CompletionResponse)
function source:get_completions(ctx, callback)
	local line = ctx.line or ""
	local col = (ctx.cursor and ctx.cursor[2]) or 0
	local before = line:sub(1, col)
	local start_byte = before:match("()%/[%w._%-]*$")
	if not start_byte then
		callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
		return
	end

	local storage = require("csa.storage")
	local skills = storage.list_skills()
	local kind = require("blink.cmp.types").CompletionItemKind.Text
	local plain = vim.lsp.protocol.InsertTextFormat.PlainText
	local row = ((ctx.cursor and ctx.cursor[1]) or 1) - 1
	local start_char = start_byte - 1
	---@type lsp.CompletionItem[]
	local items = {}
	for _, skill in ipairs(skills) do
		local insert = "/" .. skill.name
		items[#items + 1] = {
			label = insert,
			filterText = skill.name,
			sortText = skill.name,
			kind = kind,
			insertTextFormat = plain,
			detail = skill.description,
			documentation = skill.description and {
				kind = "markdown",
				value = skill.description,
			} or nil,
			textEdit = {
				newText = insert,
				range = {
					start = { line = row, character = start_char },
					["end"] = { line = row, character = col },
				},
			},
		}
	end

	callback({
		items = items,
		is_incomplete_forward = false,
		is_incomplete_backward = false,
	})
end

return source

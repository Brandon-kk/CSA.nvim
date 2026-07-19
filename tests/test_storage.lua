local H = require("tests.harness")

H.describe("csa.storage", function()
	local storage

	local function fresh()
		package.loaded["csa.storage"] = nil
		storage = require("csa.storage")
		storage.ensure()
	end

	H.it("ensure creates history/agents/skills/cache", function()
		fresh()
		local root = storage.root()
		H.expect(vim.uv.fs_stat(root) ~= nil).to_be_truthy("root")
		H.expect(vim.uv.fs_stat(storage.history_dir()) ~= nil).to_be_truthy("history")
		H.expect(vim.uv.fs_stat(storage.agents_dir()) ~= nil).to_be_truthy("agents")
		H.expect(vim.uv.fs_stat(storage.skills_dir()) ~= nil).to_be_truthy("skills")
		H.expect(vim.uv.fs_stat(storage.cache_dir()) ~= nil).to_be_truthy("cache")
	end)

	H.it("list_skills loads folder SKILL.md and flat md", function()
		fresh()
		local dir = storage.skills_dir()
		local nested = vim.fs.joinpath(dir, "demo-skill")
		vim.fn.mkdir(nested, "p")
		local skill_md = vim.fs.joinpath(nested, "SKILL.md")
		local fd = assert(io.open(skill_md, "w"))
		fd:write("---\nname: demo-skill\ndescription: Demo workflow\n---\n\nDo the demo thing.\n")
		fd:close()
		local flat = vim.fs.joinpath(dir, "flat-skill.md")
		fd = assert(io.open(flat, "w"))
		fd:write("# Flat\n\nFlat instructions.\n")
		fd:close()

		local skills = storage.list_skills()
		H.expect(#skills >= 2).to_be_truthy()
		local names = {}
		for _, s in ipairs(skills) do
			names[s.name] = s
		end
		H.expect(names["demo-skill"] ~= nil).to_be_truthy("demo-skill")
		H.expect(names["demo-skill"].description).to_eq("Demo workflow")
		H.expect(names["demo-skill"].content).to_contain("Do the demo thing")
		H.expect(names["flat-skill"] ~= nil).to_be_truthy("flat-skill")

		local all = storage.skills_context_prompt()
		H.expect(all).to_eq("")
		local none = storage.skills_context_prompt({})
		H.expect(none).to_eq("")
		local prompt = storage.skills_context_prompt({ "demo-skill" })
		H.expect(prompt).to_contain("demo-skill")
		H.expect(prompt).to_contain("Do the demo thing")
		H.expect(prompt:find("Flat instructions", 1, true) == nil).to_be_truthy("no flat skill")
		local mentions = storage.skill_mentions_in_text("use /demo-skill and /missing please")
		H.expect(#mentions).to_eq(2)
		H.expect(mentions[1]).to_eq("demo-skill")
		H.expect(mentions[2]).to_eq("missing")
		local from_mentions = storage.skills_context_prompt(mentions)
		H.expect(from_mentions).to_contain("demo-skill")
		H.expect(from_mentions:find("flat-skill", 1, true) == nil).to_be_truthy("no flat-skill")
	end)

	H.it("append_message persists user and assistant with edits", function()
		fresh()
		local id = "test_" .. storage.random_id()
		local sess, path = storage.append_message(id, {
			sender = "user",
			role = "user",
			content = { "hello", "world" },
		})
		H.expect(sess ~= nil).to_be_truthy()
		H.expect(path).to_contain(id)
		H.expect(#sess.messages).to_eq(1)
		H.expect(sess.messages[1].content).to_contain("hello")

		storage.append_message(id, {
			sender = "auto",
			role = "assistant",
			content = "reply",
			edits = {
				{
					path = "/tmp/csa_edit.txt",
					before = "old",
					after = "new",
					kind = "edit",
				},
			},
		})
		local loaded = storage.load_history(id)
		H.expect(#loaded.messages).to_eq(2)
		H.expect(loaded.messages[2].role).to_eq("assistant")
		H.expect(#loaded.messages[2].edits).to_eq(1)
		H.expect(loaded.messages[2].edits[1].before).to_eq("old")
		storage.delete_history(id)
	end)

	H.it("truncate_messages and messages_after", function()
		fresh()
		local id = "trunc_" .. storage.random_id()
		storage.append_message(id, { sender = "u", role = "user", content = "a" })
		storage.append_message(id, { sender = "a", role = "assistant", content = "b" })
		storage.append_message(id, { sender = "u", role = "user", content = "c" })
		storage.append_message(id, { sender = "a", role = "assistant", content = "d" })

		local after = storage.messages_after(id, 2)
		H.expect(#after).to_eq(2)
		H.expect(after[1].content).to_eq("c")

		local ok, discarded = storage.truncate_messages(id, 2)
		H.expect(ok).to_be_truthy()
		H.expect(#discarded).to_eq(2)
		local loaded = storage.load_history(id)
		H.expect(#loaded.messages).to_eq(2)
		H.expect(loaded.messages[2].content).to_eq("b")
		storage.delete_history(id)
	end)

	H.it("last_session save/load skips empty", function()
		fresh()
		local id = "last_" .. storage.random_id()
		H.expect(storage.save_last_session_id(id)).to_be_truthy()
		H.expect(storage.load_last_session_id()).to_eq(id)
		-- no messages yet → load_last_session is nil
		H.expect(storage.load_last_session()).to_be_falsy()

		storage.append_message(id, { sender = "u", role = "user", content = "hi" })
		local sess = storage.load_last_session()
		H.expect(sess ~= nil).to_be_truthy()
		H.expect(sess.id).to_eq(id)
		storage.delete_history(id)
	end)

	H.it("history_for_seed excludes matching trailing user prompt", function()
		fresh()
		local id = "seed_" .. storage.random_id()
		storage.append_message(id, { sender = "u", role = "user", content = "one" })
		storage.append_message(id, { sender = "a", role = "assistant", content = "two" })
		storage.append_message(id, { sender = "u", role = "user", content = "three" })
		local prior = storage.history_for_seed(id, "three")
		H.expect(#prior).to_eq(2)
		H.expect(prior[2].role).to_eq("assistant")
		storage.delete_history(id)
	end)

	H.it("selected model and models cache roundtrip", function()
		fresh()
		H.expect(storage.save_selected_model("sonnet-4")).to_be_truthy()
		H.expect(storage.load_selected_model()).to_eq("sonnet-4")
		H.expect(storage.save_models_cache({ "auto", "a", "a", "b" })).to_be_truthy()
		local models = storage.load_models_cache()
		H.expect(models).to_have_length(2)
		H.expect(models[1]).to_eq("a")
	end)

	H.it("cursor_chat_id pending then persisted", function()
		fresh()
		local id = "chat_" .. storage.random_id()
		H.expect(storage.set_cursor_chat_id(id, "cid-1")).to_be_truthy()
		H.expect(storage.get_cursor_chat_id(id)).to_eq("cid-1")
		storage.append_message(id, { sender = "u", role = "user", content = "x" })
		local loaded = storage.load_history(id)
		H.expect(loaded.cursor_chat_id).to_eq("cid-1")
		H.expect(storage.clear_cursor_chat_id(id)).to_be_truthy()
		H.expect(storage.load_history(id).cursor_chat_id).to_be_falsy()
		storage.delete_history(id)
	end)
end)

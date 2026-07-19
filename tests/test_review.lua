local H = require("tests.harness")

H.describe("csa.review", function()
	local review

	local function fresh()
		package.loaded["csa.review"] = nil
		package.loaded["csa.ui.picker"] = nil
		review = require("csa.review")
		review.clear_all()
		review.begin_turn()
	end

	local function tmpfile(name)
		local dir = vim.fn.stdpath("data") .. "/csa_review_tmp"
		vim.fn.mkdir(dir, "p")
		return dir .. "/" .. (name or "f.txt")
	end

	H.it("drain_turn_edits keeps earliest before", function()
		fresh()
		local path = tmpfile("multi.txt")
		local fd = io.open(path, "w")
		fd:write("v1")
		fd:close()

		review.snapshot(path)
		-- simulate first write
		local fd2 = io.open(path, "w")
		fd2:write("v2")
		fd2:close()
		review.record({ path = path, kind = "edit", after = "v2", attach = false, decorate = false })

		-- second edit same path in one turn — before must stay v1
		review.snapshot(path)
		review.record({ path = path, kind = "edit", after = "v3", attach = false, decorate = false })

		local edits = review.drain_turn_edits()
		H.expect(#edits).to_eq(1)
		H.expect(edits[1].before).to_eq("v1")
		H.expect(edits[1].after).to_eq("v3")
		os.remove(path)
		review.clear_all()
	end)

	H.it("rewind_files restores before from messages and pending", function()
		fresh()
		local path = tmpfile("rewind.txt")
		local fd = io.open(path, "w")
		fd:write("original")
		fd:close()

		review.snapshot(path)
		local fd2 = io.open(path, "w")
		fd2:write("changed")
		fd2:close()
		review.record({ path = path, kind = "edit", after = "changed", attach = false, decorate = false })

		local edits = review.drain_turn_edits()
		local n = review.rewind_files({
			{
				role = "assistant",
				edits = edits,
			},
		})
		H.expect(n >= 1).to_be_truthy()
		local fd3 = io.open(path, "r")
		local body = fd3:read("*a")
		fd3:close()
		H.expect(body).to_eq("original")
		os.remove(path)
		review.clear_all()
	end)

	H.it("rewind_files deletes newly created files (before empty)", function()
		fresh()
		local path = tmpfile("newfile.lua")
		-- agent created file: before ""
		local fd = io.open(path, "w")
		fd:write("print(1)")
		fd:close()
		review.record({
			path = path,
			kind = "write",
			before = "",
			after = "print(1)",
			attach = false,
			decorate = false,
		})
		-- force before empty on pending by recording with snapshot empty
		review.clear_all()
		review.begin_turn()
		-- manually via rewind messages
		local n = review.rewind_files({
			{
				role = "assistant",
				edits = { { path = path, before = "", after = "print(1)", kind = "write" } },
			},
		})
		H.expect(n).to_eq(1)
		H.expect(vim.uv.fs_stat(path)).to_be_falsy()
		review.clear_all()
	end)

	H.it("format_stats returns fg-only style chunks", function()
		fresh()
		local label, chunks = review.format_stats(3, 2)
		H.expect(label).to_contain("+3")
		H.expect(label).to_contain("-2")
		H.expect(#chunks >= 2).to_be_truthy()
		H.expect(chunks[1][2]).to_eq("CSADiffAdd")
	end)

	H.it("get/list/count track pending", function()
		fresh()
		local path = tmpfile("pending.txt")
		local fd = io.open(path, "w")
		fd:write("a")
		fd:close()
		review.snapshot(path)
		review.record({ path = path, kind = "edit", after = "b", attach = false, decorate = false })
		H.expect(review.count()).to_eq(1)
		H.expect(review.get(path) ~= nil).to_be_truthy()
		H.expect(#review.list()).to_eq(1)
		review.reject(path)
		H.expect(review.count()).to_eq(0)
		local fd2 = io.open(path, "r")
		H.expect(fd2:read("*a")).to_eq("a")
		fd2:close()
		os.remove(path)
		review.clear_all()
	end)
end)

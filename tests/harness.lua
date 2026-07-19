local H = {}

H.passed = 0
H.failed = 0
H.errors = {}

function H.describe(name, fn)
	print("\n## " .. name)
	fn()
end

function H.it(name, fn)
	local ok, err = pcall(fn)
	if ok then
		H.passed = H.passed + 1
		print("  ✓ " .. name)
	else
		H.failed = H.failed + 1
		local msg = name .. ": " .. tostring(err)
		H.errors[#H.errors + 1] = msg
		print("  ✗ " .. msg)
	end
end

function H.expect(actual)
	return {
		to_eq = function(expected, hint)
			if actual ~= expected then
				error(
					string.format(
						"%sexpected <%s>, got <%s>",
						hint and (hint .. ": ") or "",
						vim.inspect(expected),
						vim.inspect(actual)
					),
					2
				)
			end
		end,
		to_be_truthy = function(hint)
			if not actual then
				error((hint or "expected truthy") .. ", got " .. vim.inspect(actual), 2)
			end
		end,
		to_be_falsy = function(hint)
			if actual then
				error((hint or "expected falsy") .. ", got " .. vim.inspect(actual), 2)
			end
		end,
		to_contain = function(substr, hint)
			if type(actual) ~= "string" or not actual:find(substr, 1, true) then
				error(
					string.format(
						"%sexpected string containing %s, got %s",
						hint and (hint .. ": ") or "",
						vim.inspect(substr),
						vim.inspect(actual)
					),
					2
				)
			end
		end,
		to_have_length = function(n, hint)
			local len = type(actual) == "table" and #actual or (type(actual) == "string" and #actual or -1)
			if len ~= n then
				error(
					string.format(
						"%sexpected length %d, got %d (%s)",
						hint and (hint .. ": ") or "",
						n,
						len,
						vim.inspect(actual)
					),
					2
				)
			end
		end,
	}
end

function H.summary()
	print(string.format("\n== %d passed, %d failed ==", H.passed, H.failed))
	if #H.errors > 0 then
		print("Failures:")
		for _, e in ipairs(H.errors) do
			print("  - " .. e)
		end
	end
	return H.failed == 0
end

return H

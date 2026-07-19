--- Register the CSA skills source with blink.cmp when available.

local M = {}
local registered = false

--- Ensure `csa_skills` is registered and scoped to `csa-input` only.
function M.ensure()
	if registered then
		return true
	end
	local ok_cmp, cmp = pcall(require, "blink.cmp")
	if not ok_cmp or type(cmp.add_source_provider) ~= "function" then
		return false
	end
	local ok_cfg, blink_config = pcall(require, "blink.cmp.config")
	if not ok_cfg or type(blink_config) ~= "table" or type(blink_config.sources) ~= "table" then
		return false
	end

	pcall(function()
		cmp.add_source_provider("csa_skills", {
			name = "CSASkills",
			module = "csa.blink.skills",
			score_offset = 100,
		})
	end)

	blink_config.sources.per_filetype = blink_config.sources.per_filetype or {}
	-- Only the skills source in Input (avoid path completing on `/`).
	if blink_config.sources.per_filetype["csa-input"] == nil then
		blink_config.sources.per_filetype["csa-input"] = { "csa_skills" }
	else
		pcall(cmp.add_filetype_source, "csa-input", "csa_skills")
	end

	registered = true
	return true
end

return M

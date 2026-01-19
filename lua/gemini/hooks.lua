local M = {}

--- @alias gemini.HookSpecificOutput table<string, any>

--- @class gemini.HookResponse
--- @field hookSpecificOutput gemini.HookSpecificOutput|nil
--- @field systemMessage string

--- internal function that is called remotely by gemini-cli
--- @param hook_name string
--- @param json string
--- @return gemini.HookResponse
function M._trigger(hook_name, json)
	local ok, context = pcall(vim.json.decode, json)

	if not ok then
		return { systemMessage = "gemini.nvim " .. hook_name .. ": " .. context }
	end

	local autocmd_ok, autocmd_err = pcall(vim.api.nvim_exec_autocmds, "User", {
		pattern = "GeminiHook" .. hook_name,
		data = { context = context },
	})

	if not autocmd_ok and autocmd_err then
		vim.notify(autocmd_err, vim.log.levels.ERROR)
	end

	return { systemMessage = "" }
end

return M

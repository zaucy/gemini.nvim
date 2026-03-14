local M = {}

--- @class gemini.HookSpecificOutput table<string, any>

--- @class gemini.HookResponse
--- @field hookSpecificOutput gemini.HookSpecificOutput|nil
--- @field systemMessage string

--- @class gemini.HookInfo
--- @field name string
--- @field context gemini.HookContext

--- @class gemini.LlmRequest
--- @field messages any[]
--- @field model string

--- @class gemini.LlmResponseCandidate
--- @field content {parts: string[]}
--- @field role string
--- @field finishReason string|nil

--- @class gemini.LlmResponse
--- @field candidates gemini.LlmResponseCandidate[]
--- @field text string

--- @class gemini.HookContext
--- @field cwd string
--- @field hook_event_name string
--- @field session_id string
--- @field timestamp string
--- @field transcript_path string
--- @field llm_request gemini.LlmRequest|nil
--- @field llm_response gemini.LlmResponse|nil
--- @field message string|nil
--- @field notification_type string|nil only when hook event name is Notification
--- @field details {type: string, title: string, [string]: any}|nil
--- @field prompt_response string|nil

--- @type gemini.HookInfo[]
M.history = {}

--- @type gemini.HookInfo|nil
M.last_hook = nil

--- internal function that is called remotely by gemini-cli
--- @param hook_name string
--- @param json string
--- @return gemini.HookResponse
function M._trigger(hook_name, json)
	local ok, context = pcall(vim.json.decode, json)

	if not ok then
		return { systemMessage = "gemini.nvim " .. hook_name .. ": " .. context }
	end

	local hook = { name = hook_name, context = context }
	M.last_hook = hook
	table.insert(M.history, hook)

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

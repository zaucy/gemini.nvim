local M = {}

--- @param hook_name string
function M._trigger(hook_name)
	vim.notify("hook triggered " .. hook_name)
end

return M

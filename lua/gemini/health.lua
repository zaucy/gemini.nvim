local M = {}

function M.check()
	vim.health.start("gemini.nvim")

	-- Check for 'gemini' executable
	if vim.fn.executable("gemini") == 1 then
		vim.health.ok("gemini executable found in PATH")
	else
		vim.health.error("gemini executable not found in PATH")
	end

	-- Check for 'zaucy/mcp.nvim' plugin
	local mcp_loaded, _ = pcall(require, "mcp")
	if mcp_loaded then
		vim.health.ok("mcp.nvim plugin is installed")
	else
		vim.health.error("mcp.nvim plugin is not installed or cannot be loaded")
	end
end

return M

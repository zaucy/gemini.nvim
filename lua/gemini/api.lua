local M = {}

--- @class gemini.DiffAcceptedArgs
--- @field filePath string The absolute path to the file that was diffed
--- @field content string The full content of the file after acceptance

--- @class gemini.OpenDiffRequest
--- @field filePath string The absolute path to the file that was diffed
--- @field newContent string The full content of the file after acceptance

--- https://geminicli.com/docs/ide-integration/ide-companion-spec/#idediffaccepted-notification
--- @param args gemini.DiffAcceptedArgs
function M.send_diff_accepted(args)
	assert(type(args.filePath) == "string")
	assert(type(args.content) == "string")

	local mcp = require("mcp")
	mcp.notify_all("ide/diffAccepted", args)

	-- NOTE: gemini doesn't send close_diff - we trigger it manually for a more consistent experience using gemini.nvim
	require("gemini.diff").close_diff({ filePath = args.filePath })
end

--- @class gemini.DiffRejectedArgs
--- @field filePath string

--- @alias gemini.CloseDiffRequest gemini.DiffRejectedArgs

--- https://geminicli.com/docs/ide-integration/ide-companion-spec/#idediffrejected-notification
--- @param args gemini.DiffRejectedArgs
function M.send_diff_rejected(args)
	assert(type(args.filePath) == "string")

	local mcp = require("mcp")
	mcp.notify_all("ide/diffRejected", args)

	-- NOTE: gemini doesn't send close_diff - we trigger it manually for a more consistent experience using gemini.nvim
	require("gemini.diff").close_diff({ filePath = args.filePath })
end

--- get the context that gemini wants
function M.get_context(preferred_bufnr, cwd)
	local context = {
		workspaceState = {
			openFiles = {},
			workspaceFolders = { cwd },
			isTrusted = true,
		},
	}

	local current_buf = vim.api.nvim_get_current_buf()
	local buffers = vim.api.nvim_list_bufs()

	-- Determine effective active buffer
	local current_buftype = vim.api.nvim_get_option_value("buftype", { buf = current_buf })
	local effective_active_buf = current_buf
	if current_buftype ~= "" and preferred_bufnr and vim.api.nvim_buf_is_valid(preferred_bufnr) then
		effective_active_buf = preferred_bufnr
	end

	for _, bufnr in ipairs(buffers) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local name = vim.api.nvim_buf_get_name(bufnr)
			local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })

			if name ~= "" and buftype == "" then
				local file_info = {
					path = name,
					timestamp = os.time(),
					isActive = (bufnr == effective_active_buf),
				}

				if file_info.isActive then
					-- Attempt to find the window for the active buffer
					local winid = vim.fn.bufwinid(bufnr)
					if winid ~= -1 then
						local cursor = vim.api.nvim_win_get_cursor(winid)
						file_info.cursor = {
							line = cursor[1],
							character = cursor[2] + 1,
						}
					end

					-- Capture selected text
					-- If currently in the active buffer, use standard methods.
					local mode = vim.fn.mode()
					if mode == "v" or mode == "V" or mode == "\22" then
						local start_pos = vim.fn.getpos("v")
						local end_pos = vim.fn.getpos(".")
						local ok, region = pcall(vim.fn.getregion, start_pos, end_pos, { type = mode })
						if ok and region then
							file_info.selectedText = table.concat(region, "\n")
						end
					end
				end

				table.insert(context.workspaceState.openFiles, file_info)
			end
		end
	end

	return context
end

--- @param buf number|nil
--- @param cwd string|nil
function M.send_context(buf, cwd)
	assert(type(buf) == "number" or type(buf) == "nil", "expected number or nil and got " .. type(buf))
	assert(type(cwd) == "string" or type(cwd) == "nil", "expected string or nil and got " .. type(buf))

	local mcp = require("mcp")

	if not cwd then
		cwd = vim.fn.getcwd()
	end

	local server = mcp.get_server(cwd)
	if not server then
		return
	end

	if buf == nil or buf == 0 then
		buf = vim.api.nvim_get_current_buf()
	end
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })

	if buftype ~= "" then
		return
	end

	local context = M.get_context(buf, cwd)
	server.server_handle:notify_all("ide/contextUpdate", context)
end

return M

local M = {}

local function get_plugin_root()
	return vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h:h")
end

local function get_state_dir()
	return vim.fn.stdpath("state") .. "/gemini"
end

local function get_unique_settings_path(cwd)
	local unique_id = vim.fn.sha256(cwd)
	return get_state_dir() .. "/servers/" .. unique_id .. "/settings.json"
end

local function update_state()
	local mcp = require("mcp")
	local servers = mcp.get_servers_map()

	local client_script = get_plugin_root() .. "/cmd/gemini_client.lua"
	client_script = client_script:gsub("\\", "/")

	local hook_script = get_plugin_root() .. "/cmd/gemini_hook.lua"
	hook_script = hook_script:gsub("\\", "/")

	local forwarded_hook_names = {
		"SessionStart",
		"BeforeAgent",
		"BeforeToolSelection",
		"BeforeTool",
		"AfterTool",
		"AfterModel",
		"SessionEnd",
	}

	--- @type table<string, any>
	local hooks_config = {
		enabled = true,
	}
	local notify_command = string.format(
		"%s%s --clean -l %s -- --host-server %s --log-path %s",
		vim.fn.has("win32") == 1 and "& " or "", -- for powershell escape stuff
		vim.fn.shellescape(vim.v.progpath),
		vim.fn.shellescape(hook_script),
		vim.fn.shellescape(vim.v.servername),
		vim.fn.shellescape(get_state_dir() .. "/hooks.log")
	)

	for _, hook_name in ipairs(forwarded_hook_names) do
		hooks_config[hook_name] = {
			{
				matcher = "*",
				hooks = {
					{
						name = "nvim-" .. hook_name,
						type = "command",
						command = notify_command .. " --hook " .. hook_name,
						description = "notifies gemini.nvim plugin about " .. hook_name .. " hook",
					},
				},
			},
		}
	end

	-- Create a list of directories to update: servers + current cwd
	local dirs_to_update = {}
	for dir, s in pairs(servers) do
		dirs_to_update[dir] = s
	end

	local cwd = vim.fn.getcwd()
	if not dirs_to_update[cwd] then
		dirs_to_update[cwd] = false -- Mark as present but no server
	end

	for dir, s in pairs(dirs_to_update) do
		local settings_path = get_unique_settings_path(dir)
		local settings_content = {
			hooks = hooks_config,
			mcpServers = {},
		}

		if s then
			settings_content.mcpServers["gemini.nvim"] = {
				command = vim.v.progpath,
				args = { "--clean", "-l", client_script, "--", tostring(s.port) },
				-- excludeTools = { "openDiff", "closeDiff" },
			}
		end

		vim.fn.mkdir(vim.fn.fnamemodify(settings_path, ":h"), "p")

		local f_w = io.open(settings_path, "w")
		if f_w then
			f_w:write(vim.json.encode(settings_content))
			f_w:close()
		end
	end
end

local function on_mcp_server_created(cwd)
	update_state()
end

local function on_mcp_server_dir_changed(cwd)
	local mcp = require("mcp")
	local unique_settings_path = get_unique_settings_path(cwd)
	local server = mcp.get_server(cwd)
	assert(server)

	-- ALWAYS update env variables to current context
	vim.env.GEMINI_CLI_IDE_WORKSPACE_PATH = cwd
	vim.env.GEMINI_CLI_SYSTEM_SETTINGS_PATH = unique_settings_path

	-- Setup STDIO config for IDE Companion (used by /ide enable)
	local client_script = get_plugin_root() .. "/cmd/gemini_client.lua"
	client_script = client_script:gsub("\\", "/")

	vim.env.GEMINI_CLI_IDE_SERVER_STDIO_COMMAND = vim.v.progpath
	vim.env.GEMINI_CLI_IDE_SERVER_STDIO_ARGS = vim.json.encode({
		"--clean",
		"-l",
		client_script,
		"--",
		tostring(server.port),
	})
end

function M.setup(opts)
	local mcp = require("mcp")

	local group = vim.api.nvim_create_augroup("Gemini", { clear = true })

	-- TODO: do we really need this? gemini cli checks for it?
	vim.env.TERM_PROGRAM = "vscode"

	local state_dir = get_state_dir()
	vim.fn.mkdir(state_dir, "p")

	mcp.register_tool(require("gemini.diff").open_diff, {
		name = "openDiff",
		description = "Opens a diff view in Neovim to show proposed changes.",
		inputSchema = {
			type = "object",
			properties = {
				filePath = { type = "string" },
				newContent = { type = "string" },
			},
			required = { "filePath", "newContent" },
		},
	})

	mcp.register_tool(require("gemini.diff").close_diff, {
		name = "closeDiff",
		description = "Closes the diff view for a specific file.",
		inputSchema = {
			type = "object",
			properties = {
				filePath = { type = "string" },
			},
			required = { "filePath" },
		},
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "McpServerCreated",
		group = group,
		callback = function(args)
			local cwd = args.data.cwd
			on_mcp_server_created(cwd)
		end,
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "McpServerDirChange",
		group = group,
		callback = function(args)
			local cwd = args.data.cwd
			on_mcp_server_dir_changed(cwd)
		end,
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "GeminiHookAfterTool",
		group = group,
		callback = function(args)
			local context = args.data.context

			if context.tool_name == "replace" or context.tool_name == "write_file" then
				local file_path = context.tool_input.file_path
				vim.cmd("silent! checktime " .. vim.fn.fnameescape(file_path))
			end
		end,
	})

	local timer = vim.uv.new_timer()
	assert(timer)
	local send_context = vim.schedule_wrap(function()
		local api = require("gemini.api")
		local ok, err = pcall(api.send_context)
		if not ok then
			---@diagnostic disable-next-line: param-type-mismatch
			vim.notify_once(err, vim.log.levels.ERROR)
		end
	end)

	local function debounced_send_context()
		timer:stop()
		-- recommended 50ms
		-- https://geminicli.com/docs/ide-integration/ide-companion-spec/#idecontextupdate-notification
		timer:start(50, 0, send_context)
	end

	vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "CursorMovedI", "FocusGained", "ModeChanged" }, {
		group = group,
		callback = debounced_send_context,
	})

	update_state()
end

return M

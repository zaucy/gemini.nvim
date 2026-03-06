local M = {}

local ns_id = vim.api.nvim_create_namespace("gemini_follow")

local sticky_win = nil
local sticky_buf = nil
local sticky_timer_id = 0
local pulse_timer = nil

M.history_index = 0
M.follow_win = nil
M.config = {
	sticky_max_width = nil,
	sticky_max_height = 10,
}

local function scroll_to_bottom(win)
	if win and vim.api.nvim_win_is_valid(win) then
		local buf = vim.api.nvim_win_get_buf(win)
		local line_count = vim.api.nvim_buf_line_count(buf)
		if line_count > 0 then
			vim.api.nvim_win_set_cursor(win, { line_count, 0 })
		end
	end
end

function M.is_following(winid)
	if winid == nil or winid == 0 then
		winid = vim.api.nvim_get_current_win()
	end
	return M.follow_win ~= nil and M.follow_win == winid
end

function M.toggle_follow()
	local cur_win = vim.api.nvim_get_current_win()
	if M.follow_win == cur_win then
		M.follow_win = nil
		M.clear_sticky_action()
	else
		M.follow_win = cur_win
		-- set to live after following
		local hooks = require("gemini.hooks")
		M.replay(#hooks.history)
	end
	vim.cmd("redrawstatus")
end

local function stop_pulse()
	if pulse_timer then
		pulse_timer:stop()
		if not pulse_timer:is_closing() then
			pulse_timer:close()
		end
		pulse_timer = nil
	end
	vim.api.nvim_set_hl(0, "GeminiFollowPulse", {
		fg = "#ffffff",
		bg = "#505050",
	})
	vim.api.nvim_set_hl(0, "GeminiFollowRead", { link = "Visual" })
end

local function color_to_rgb(hex)
	local r = tonumber(hex:sub(2, 3), 16)
	local g = tonumber(hex:sub(4, 5), 16)
	local b = tonumber(hex:sub(6, 7), 16)
	return r, g, b
end

local function rgb_to_color(r, g, b)
	return string.format("#%02x%02x%02x", r, g, b)
end

local function get_hl_hex(name, attr)
	local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
	local color = hl[attr]
	if not color then
		return nil
	end
	return string.format("#%06x", color)
end

local function interpolate_color(color1, color2, t)
	local r1, g1, b1 = color_to_rgb(color1)
	local r2, g2, b2 = color_to_rgb(color2)
	local r = math.floor(r1 + (r2 - r1) * t)
	local g = math.floor(g1 + (g2 - g1) * t)
	local b = math.floor(b1 + (b2 - b1) * t)
	return rgb_to_color(r, g, b)
end

local function get_sticky_title()
	local hooks = require("gemini.hooks")
	local title = "󱚣 󰭹"
	if #hooks.history > 0 and M.history_index < #hooks.history then
		title = string.format("󱙺 HISTORY [%d/%d] ", M.history_index, #hooks.history)
	end
	return title
end

local function start_pulse()
	stop_pulse()
	local color1 = "#404040"
	local color2 = "#606080"

	local visual_bg = get_hl_hex("Visual", "bg") or "#404040"
	local normal_bg = get_hl_hex("Normal", "bg") or "#000000"

	local start_time = vim.uv.now()
	pulse_timer = vim.uv.new_timer()
	assert(pulse_timer)
	pulse_timer:start(
		0,
		16,
		vim.schedule_wrap(function()
			if not sticky_win or not vim.api.nvim_win_is_valid(sticky_win) then
				stop_pulse()
				return
			end
			local elapsed = vim.uv.now() - start_time
			-- Pulse period of 2 seconds
			local t = (math.sin(elapsed / 2000 * 2 * math.pi - math.pi / 2) + 1) / 2

			-- Pulse GeminiFollowPulse
			local color = interpolate_color(color1, color2, t)
			vim.api.nvim_set_hl(0, "GeminiFollowPulse", {
				fg = "#ffffff",
				bg = color,
				force = true,
			})

			-- Pulse GeminiFollowRead
			local read_color = interpolate_color(visual_bg, normal_bg, t)
			vim.api.nvim_set_hl(0, "GeminiFollowRead", {
				bg = read_color,
				force = true,
			})
		end)
	)
end

local function get_sticky_dims(target_win)
	local win_width = vim.api.nvim_win_get_width(target_win)
	local win_height = vim.api.nvim_win_get_height(target_win)

	local border = "solid"
	local has_border = border ~= nil and border ~= "none"
	local width_offset = has_border and 2 or 0

	local max_width = M.config.sticky_max_width or win_width
	local adjusted_width = math.min(win_width - width_offset, max_width)

	-- If the centering would be uneven, make the width 1 less to make it centered
	-- To be centered, (win_width - (adjusted_width + width_offset)) must be even.
	if (win_width - (adjusted_width + width_offset)) % 2 ~= 0 then
		adjusted_width = adjusted_width - 1
	end
	adjusted_width = math.max(1, adjusted_width)

	local col = math.floor((win_width - (adjusted_width + width_offset)) / 2)

	return adjusted_width, col, win_height, border, has_border
end

local function apply_win_options(win)
	if win == 0 then
		win = vim.api.nvim_get_current_win()
	end
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local opts = {
		wrap = true,
		linebreak = true,
		breakindent = false,
		breakindentopt = "",
		showbreak = "NONE",
		list = false,
		listchars = "eol: ,tab:  ,trail: ,extends: ,precedes: ,nbsp: ",
		fillchars = "eob: ",
		number = false,
		relativenumber = false,
		cursorline = false,
		cursorcolumn = false,
		foldcolumn = "0",
		signcolumn = "no",
		statuscolumn = "",
		spell = false,
		winbar = "",
		statusline = "",
	}

	for opt, val in pairs(opts) do
		vim.api.nvim_set_option_value(opt, val, { scope = "local", win = win })
	end
end

local function update_sticky_position()
	if not sticky_win or not vim.api.nvim_win_is_valid(sticky_win) then
		return
	end

	local target_win = M.follow_win
	if not target_win or not vim.api.nvim_win_is_valid(target_win) then
		M.clear_sticky_action()
		return
	end

	local adjusted_width, col, win_height, border, has_border = get_sticky_dims(target_win)

	-- Ensure width is updated before calculating text height
	if vim.api.nvim_win_get_width(sticky_win) ~= adjusted_width then
		vim.api.nvim_win_set_config(sticky_win, {
			width = adjusted_width,
			border = border,
			title = get_sticky_title(),
			title_pos = "center",
		})
	end

	-- Recalculate height based on content
	local total_lines = 0
	if vim.api.nvim_win_text_height then
		local ok, res = pcall(vim.api.nvim_win_text_height, sticky_win, { start_row = 0, end_row = -1 })
		if ok then
			total_lines = res.all
		end
	end

	if total_lines == 0 then
		total_lines = vim.api.nvim_buf_line_count(sticky_buf)
	end

	local height = math.min(total_lines, M.config.sticky_max_height, math.floor(win_height * 0.3))
	height = math.max(1, height)

	vim.api.nvim_win_set_config(sticky_win, {
		relative = "win",
		win = target_win,
		width = adjusted_width,
		height = height,
		row = win_height - height - (has_border and 1 or 0),
		col = col,
		border = border,
		title = get_sticky_title(),
		title_pos = "center",
	})

	apply_win_options(sticky_win)
	scroll_to_bottom(sticky_win)
end

function M.clear_sticky_action()
	stop_pulse()
	if sticky_win and vim.api.nvim_win_is_valid(sticky_win) then
		vim.api.nvim_win_close(sticky_win, true)
	end
	sticky_win = nil
end

function M.show_sticky_action(text, timeout, hl_group)
	if not M.follow_win or not vim.api.nvim_win_is_valid(M.follow_win) then
		return
	end

	stop_pulse()
	sticky_timer_id = sticky_timer_id + 1
	local current_timer_id = sticky_timer_id

	if not sticky_buf or not vim.api.nvim_buf_is_valid(sticky_buf) then
		sticky_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_option_value("filetype", "markdown", { buf = sticky_buf })
		vim.api.nvim_set_option_value("buftype", "nofile", { buf = sticky_buf })
	end

	local display_text = text:gsub("\r", "")
	local lines = vim.split(display_text, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(sticky_buf, 0, -1, false, lines)

	local target_win = M.follow_win
	local adjusted_width, col, win_height, border, has_border = get_sticky_dims(target_win)

	-- Estimate height with wrapping
	local total_lines = 0
	for _, line in ipairs(lines) do
		total_lines = total_lines + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / math.max(1, adjusted_width)))
	end
	local height = math.min(total_lines, M.config.sticky_max_height, math.floor(win_height * 0.3))
	height = math.max(1, height)

	if not sticky_win or not vim.api.nvim_win_is_valid(sticky_win) then
		sticky_win = vim.api.nvim_open_win(sticky_buf, false, {
			relative = "win",
			win = target_win,
			width = adjusted_width,
			height = height,
			row = win_height - height - (has_border and 1 or 0),
			col = col,
			border = border,
			title = get_sticky_title(),
			title_pos = "center",
			style = "minimal",
			focusable = true,
			noautocmd = true,
			zindex = 10,
		})
		apply_win_options(sticky_win)
		update_sticky_position()
	else
		update_sticky_position()
	end

	-- Force apply again after it's established
	vim.schedule(function()
		if sticky_win and vim.api.nvim_win_is_valid(sticky_win) then
			apply_win_options(sticky_win)
		end
	end)

	hl_group = hl_group or "GeminiFollowVirtualText"
	vim.api.nvim_set_option_value("winhl", "Normal:" .. hl_group .. ",NonText:Ignore", { win = sticky_win })

	if timeout ~= 0 then
		vim.defer_fn(function()
			if current_timer_id == sticky_timer_id then
				M.clear_sticky_action()
			end
		end, timeout or 4000)
	end
end

-- Define highlights if they don't exist
local function setup_highlights()
	vim.api.nvim_set_hl(0, "GeminiFollowRead", { link = "Visual", default = true })
	vim.api.nvim_set_hl(0, "GeminiFollowWrite", { link = "DiffAdd", default = true })
	vim.api.nvim_set_hl(0, "GeminiFollowVirtualText", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "GeminiFollowThought", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "GeminiFollowPulse", {
		fg = "#ffffff",
		bg = "#505050",
		default = true,
	})
end

local function jump_to_file(file_path, line, col, end_line)
	if not M.follow_win or not vim.api.nvim_win_is_valid(M.follow_win) then
		return nil
	end

	if not file_path or file_path == "" then
		return nil
	end

	-- Normalize path (gemini-cli might send Windows paths with backslashes)
	file_path = file_path:gsub("\\", "/")

	-- Ensure the file path is absolute if it's not already
	if not (file_path:match("^/") or file_path:match("^%a:")) then
		local cwd = vim.fn.getcwd()
		file_path = cwd .. "/" .. file_path
	end

	-- Don't jump if it's not a file (could be a directory)
	if vim.fn.isdirectory(file_path) == 1 then
		return nil
	end

	local bufnr = vim.fn.bufnr(file_path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(file_path)
	end

	if not vim.api.nvim_buf_is_loaded(bufnr) then
		vim.fn.bufload(bufnr)
	end

	vim.api.nvim_win_set_buf(M.follow_win, bufnr)

	if line then
		line = math.max(1, line)
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		line = math.min(line, line_count)

		local jump_line = line
		if end_line and end_line > line then
			local actual_end = math.min(end_line, line_count)
			-- Center the middle of the range to give it more context
			jump_line = math.floor((line + actual_end) / 2)
			-- But don't jump too far from the start
			local win_height = vim.api.nvim_win_get_height(M.follow_win)
			if jump_line > line + math.floor(win_height / 2) then
				jump_line = line + math.floor(win_height / 2)
			end
			jump_line = math.min(jump_line, line_count)
		end

		vim.api.nvim_win_set_cursor(M.follow_win, { jump_line, col or 0 })
		vim.api.nvim_win_call(M.follow_win, function()
			vim.cmd("normal! zz") -- Center the view
		end)

		if jump_line ~= line then
			vim.api.nvim_win_set_cursor(M.follow_win, { line, col or 0 })
		end
	end

	return bufnr
end

local function add_highlight(bufnr, start_line, end_line, hl_group)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Clear existing highlights in this namespace for this buffer
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	start_line = math.max(0, start_line)
	end_line = math.min(line_count - 1, end_line)

	if start_line > end_line then
		return
	end

	for i = start_line, end_line do
		vim.api.nvim_buf_add_highlight(bufnr, ns_id, hl_group, i, 0, -1)
	end

	-- Auto-clear after a delay
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
		end
	end, 3000)
end

function M.handle_before_tool(args)
	local context = args.data.context
	local tool_name = context.tool_name
	local tool_input = context.tool_input

	if not tool_name or not tool_input then
		return
	end

	if tool_name == "read_file" then
		local file_path = tool_input.file_path
		local start_line = tool_input.start_line or 1
		local end_line = tool_input.end_line
		local bufnr = jump_to_file(file_path, start_line, 0, end_line)
		if bufnr then
			add_highlight(bufnr, start_line - 1, (end_line or 1000000) - 1, "GeminiFollowRead")
		end
		M.show_sticky_action("󰛓 Reading: " .. file_path, 0)
		start_pulse()
	elseif tool_name == "write_file" then
		local file_path = tool_input.file_path
		jump_to_file(file_path, 1)
		M.show_sticky_action("󰏫 Writing: " .. file_path)
	elseif tool_name == "replace" then
		local file_path = tool_input.file_path
		-- For replace, we can try to find the old_string in the buffer
		local old_string = tool_input.old_string
		local line = 1
		local bufnr = jump_to_file(file_path, nil)
		if bufnr and old_string and old_string ~= "" then
			-- Very simple search for the first line of old_string
			local first_line = old_string:match("([^\n]+)")
			if first_line then
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				for i, l in ipairs(lines) do
					if l:find(first_line, 1, true) then
						line = i
						break
					end
				end
			end
		end
		jump_to_file(file_path, line)
		M.show_sticky_action("󰏫 Replacing in: " .. file_path)
	elseif tool_name == "grep_search" then
		local pattern = tool_input.pattern
		local dir_path = tool_input.dir_path or "."
		M.show_sticky_action(string.format("󰈭 Searching: %s in %s", pattern, dir_path))
	elseif tool_name == "glob" then
		local pattern = tool_input.pattern
		local dir_path = tool_input.dir_path or "."
		M.show_sticky_action(string.format("󰈭 Globbing: %s in %s", pattern, dir_path))
	elseif tool_name == "list_directory" then
		local dir_path = tool_input.dir_path
		M.show_sticky_action("󰉋 Listing: " .. dir_path)
	elseif tool_name == "run_shell_command" then
		local command = tool_input.command or ""
		M.show_sticky_action("󰆍 Running: " .. command)
	elseif tool_name == "ask_user" then
		M.show_sticky_action("󰈭 Waiting for your response...", 0)
	else
		M.show_sticky_action("󰈭 Using tool: " .. tool_name)
	end
end

function M.handle_before_model(args)
	-- M.show_sticky_action("󰈭 Thinking...", 0)
end

function M.handle_before_tool_selection(args)
	local context = args.data.context
	local thought = context.thought

	if not thought or thought == "" then
		return
	end

	M.show_sticky_action(thought, 0, "GeminiFollowThought")
end

function M.handle_after_model(args)
	--- @type gemini.HookContext
	local context = args.data.context
	local session_id = context.session_id
	local hooks = require("gemini.hooks")
	local parts = {}

	-- Traverse history backwards starting from the current hook
	for i = M.history_index, 1, -1 do
		local hook = hooks.history[i]
		-- Only combine contiguous AfterModel hooks for the same session
		if hook.name == "AfterModel" and hook.context.session_id == session_id then
			local hook_text = ""
			local response = hook.context.llm_response
			if response then
				if response.text ~= "" and response.text ~= nil then
					hook_text = response.text
				else
					for _, candidate in ipairs(response.candidates) do
						for _, part in ipairs(candidate.content.parts) do
							hook_text = hook_text .. part
						end
					end
				end
			end
			table.insert(parts, 1, hook_text)
		else
			-- Stop at the first non-AfterModel hook or different session
			break
		end
	end

	local combined_text = vim.trim(table.concat(parts, ""))
	if combined_text ~= "" then
		M.show_sticky_action(combined_text, 0)
	end
end

function M.handle_after_agent(args)
	--- @type gemini.HookContext
	local context = args.data.context
	if context.prompt_response then
		M.show_sticky_action(vim.trim(context.prompt_response), 0)
	else
		M.clear_sticky_action()
	end
end

function M.handle_notification(args)
	--- @type gemini.HookContext
	local context = args.data.context
	local message = context.message
	local notification_type = context.notification_type

	if message and message ~= "" then
		-- Use a more robust check for notification_type
		local is_pulse = notification_type == "ToolPermission"
			or (context.details and (context.details.type == "ask_user" or context.details.type == "edit"))

		local hl_group = is_pulse and "GeminiFollowPulse" or nil
		M.show_sticky_action(message, 0, hl_group)
		if is_pulse then
			start_pulse()
		end
	end
end

function M.replay(index)
	local hooks = require("gemini.hooks")
	local hook = hooks.history[index]
	if not hook then
		return
	end

	M.history_index = index

	local name = hook.name
	local context = hook.context
	local args = { data = { context = context } }

	if name == "BeforeTool" then
		M.handle_before_tool(args)
	elseif name == "BeforeModel" then
		M.handle_before_model(args)
	elseif name == "BeforeToolSelection" then
		M.handle_before_tool_selection(args)
	elseif name == "AfterModel" then
		M.handle_after_model(args)
	elseif name == "AfterAgent" then
		M.handle_after_agent(args)
	elseif name == "Notification" then
		M.handle_notification(args)
	end
end

function M.prev()
	if M.history_index > 1 then
		M.replay(M.history_index - 1)
	end
end

function M.next()
	local hooks = require("gemini.hooks")
	if M.history_index < #hooks.history then
		M.replay(M.history_index + 1)
	end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	setup_highlights()

	vim.api.nvim_create_user_command("GeminiFollow", function()
		M.toggle_follow()
	end, {})

	vim.api.nvim_create_user_command("GeminiStickyTest", function(opts)
		local args = vim.split(opts.args, " ")
		local is_pulse = args[1] == "pulse"
		local text = is_pulse and table.concat(args, " ", 2) or opts.args
		if text == "" then
			text = "Test sticky action!"
		end
		local hl_group = is_pulse and "GeminiFollowPulse" or nil
		M.show_sticky_action(text, 0, hl_group)
		if is_pulse then
			start_pulse()
		end
	end, { nargs = "?" })

	vim.api.nvim_create_user_command("GeminiNext", function()
		M.next()
	end, {})

	vim.api.nvim_create_user_command("GeminiPrev", function()
		M.prev()
	end, {})

	vim.api.nvim_create_user_command("GeminiLive", function()
		local hooks = require("gemini.hooks")
		if #hooks.history > 0 then
			M.replay(#hooks.history)
		end
	end, {})

	vim.api.nvim_create_user_command("GeminiClearHistory", function()
		local hooks = require("gemini.hooks")
		hooks.history = {}
		M.history_index = 0
		M.clear_sticky_action()
		vim.notify("Gemini history cleared.", vim.log.levels.INFO)
	end, {})

	vim.api.nvim_create_user_command("GeminiHistory", function()
		local hooks = require("gemini.hooks")
		if #hooks.history == 0 then
			vim.notify("No hooks recorded yet.", vim.log.levels.INFO)
			return
		end

		local list_buf = vim.api.nvim_create_buf(false, true)
		local preview_buf = vim.api.nvim_create_buf(false, true)

		local lines = {}
		for i, hook in ipairs(hooks.history) do
			local icon = "󰋙"
			local detail = ""
			if hook.name == "BeforeTool" then
				icon = "󰛓"
				detail = string.format(" %s", hook.context.tool_name)
			elseif hook.name == "Notification" then
				icon = "󰂜"
				detail = ": " .. (hook.context.message or ""):gsub("\n", " ")
			elseif hook.name == "BeforeToolSelection" then
				icon = "󰈭"
				detail = " thinking..."
			elseif hook.name == "AfterModel" then
				icon = "󰚩"
			elseif hook.name == "AfterAgent" then
				icon = "󰚩"
			end

			if #detail > 50 then
				detail = detail:sub(1, 47) .. "..."
			end

			table.insert(lines, string.format(" %s %-20s%s", icon, hook.name, detail))
		end

		vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = list_buf })
		vim.api.nvim_set_option_value("buftype", "nofile", { buf = list_buf })
		vim.api.nvim_set_option_value("modifiable", false, { buf = list_buf })

		-- Add highlighting to list
		local list_ns = vim.api.nvim_create_namespace("GeminiHistoryList")
		for i, hook in ipairs(hooks.history) do
			local hl_group = "Comment"
			if hook.name == "BeforeTool" then
				hl_group = "Function"
			elseif hook.name == "Notification" then
				hl_group = "String"
			elseif hook.name == "BeforeToolSelection" then
				hl_group = "Keyword"
			elseif hook.name:match("^After") then
				hl_group = "Comment"
			end
			vim.api.nvim_buf_add_highlight(list_buf, list_ns, hl_group, i - 1, 0, -1)
		end

		vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = preview_buf })
		vim.api.nvim_set_option_value("buftype", "nofile", { buf = preview_buf })
		vim.api.nvim_set_option_value("filetype", "lua", { buf = preview_buf })

		local width = math.floor(vim.o.columns * 0.9)
		local height = math.floor(vim.o.lines * 0.8)
		local list_width = math.floor(width * 0.4)
		local preview_width = width - list_width - 1

		local list_win = vim.api.nvim_open_win(list_buf, true, {
			relative = "editor",
			width = list_width,
			height = height,
			row = math.floor((vim.o.lines - height) / 2),
			col = math.floor((vim.o.columns - width) / 2),
			style = "minimal",
			border = "solid",
			title = " Gemini History ",
			title_pos = "center",
		})

		if M.history_index > 0 and M.history_index <= #hooks.history then
			vim.api.nvim_win_set_cursor(list_win, { M.history_index, 0 })
		end

		local preview_win = vim.api.nvim_open_win(preview_buf, false, {
			relative = "editor",
			width = preview_width,
			height = height,
			row = math.floor((vim.o.lines - height) / 2),
			col = math.floor((vim.o.columns - width) / 2) + list_width + 1,
			style = "minimal",
			border = "solid",
			title = " Preview ",
			title_pos = "center",
		})

		local function update_preview()
			if not vim.api.nvim_win_is_valid(list_win) then
				return
			end
			local cursor = vim.api.nvim_win_get_cursor(list_win)
			local idx = cursor[1]
			local hook = hooks.history[idx]
			if not hook then
				return
			end

			M.replay(idx)

			local content = {}
			table.insert(content, string.format("-- [%d] %s", idx, hook.name))
			table.insert(content, "")

			local inspect_str = vim.inspect(hook.context)
			for _, line in ipairs(vim.split(inspect_str, "\n", { plain = true })) do
				table.insert(content, (line:gsub("\r", "")))
			end

			vim.api.nvim_set_option_value("modifiable", true, { buf = preview_buf })
			vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, content)
			vim.api.nvim_set_option_value("modifiable", false, { buf = preview_buf })
		end

		update_preview()

		local group_id = vim.api.nvim_create_augroup("GeminiHistoryPreview", { clear = true })
		vim.api.nvim_create_autocmd("CursorMoved", {
			buffer = list_buf,
			group = group_id,
			callback = update_preview,
		})

		local function close_all()
			pcall(vim.api.nvim_del_augroup_by_id, group_id)
			if vim.api.nvim_win_is_valid(list_win) then
				vim.api.nvim_win_close(list_win, true)
			end
			if vim.api.nvim_win_is_valid(preview_win) then
				vim.api.nvim_win_close(preview_win, true)
			end
		end

		vim.keymap.set("n", "<CR>", function()
			local cursor = vim.api.nvim_win_get_cursor(list_win)
			local idx = cursor[1]
			close_all()
			M.replay(idx)
		end, { buffer = list_buf, silent = true })

		vim.keymap.set("n", "q", close_all, { buffer = list_buf, silent = true })
		vim.keymap.set("n", "<Esc>", close_all, { buffer = list_buf, silent = true })

		vim.api.nvim_create_autocmd("WinClosed", {
			pattern = tostring(list_win),
			callback = close_all,
		})
	end, {})

	vim.api.nvim_create_user_command("GeminiHookDebug", function()
		local hooks = require("gemini.hooks")
		if not hooks.last_hook then
			vim.notify("No hooks recorded yet.", vim.log.levels.INFO)
			return
		end

		local content = {}
		table.insert(content, "Last Hook: " .. tostring(hooks.last_hook.name))
		table.insert(content, "Context:")
		local inspect_str = vim.inspect(hooks.last_hook.context)
		for _, line in ipairs(vim.split(inspect_str, "\n", { plain = true })) do
			table.insert(content, (line:gsub("[\r\n]", "")))
		end

		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
		vim.api.nvim_set_option_value("filetype", "lua", { buf = bufnr })
		vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })

		vim.api.nvim_open_win(bufnr, true, {
			relative = "editor",
			width = math.floor(vim.o.columns * 0.8),
			height = math.floor(vim.o.lines * 0.8),
			row = math.floor(vim.o.lines * 0.1),
			col = math.floor(vim.o.columns * 0.1),
			style = "minimal",
			border = "solid",
		})
	end, {})

	local group = vim.api.nvim_create_augroup("GeminiFollow", { clear = true })

	local function on_hook(callback)
		return function(args)
			local hooks = require("gemini.hooks")

			vim.schedule(function()
				M.history_index = #hooks.history
				callback(args)
			end)
		end
	end

	vim.api.nvim_create_autocmd("User", {
		pattern = "GeminiHookBeforeTool",
		group = group,
		callback = on_hook(M.handle_before_tool),
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "GeminiHookBeforeModel",
		group = group,
		callback = on_hook(M.handle_before_model),
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "GeminiHookBeforeToolSelection",
		group = group,
		callback = on_hook(M.handle_before_tool_selection),
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "GeminiHookAfterModel",
		group = group,
		callback = on_hook(M.handle_after_model),
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "GeminiHookAfterAgent",
		group = group,
		callback = on_hook(M.handle_after_agent),
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "GeminiHookNotification",
		group = group,
		callback = on_hook(M.handle_notification),
	})

	vim.api.nvim_create_autocmd({ "WinEnter", "VimResized", "WinResized" }, {
		group = group,
		callback = function()
			update_sticky_position()
		end,
	})
end

return M

local M = {}

--- @type table<string, string>
local active_diffs = {}

local hl_cache = {}

local function get_combined_hl(fg_group, bg_group)
	local cache_key = fg_group .. "_" .. bg_group
	if hl_cache[cache_key] then
		return hl_cache[cache_key]
	end

	local fg_hl = vim.api.nvim_get_hl(0, { name = fg_group, link = false })
	local bg_hl = vim.api.nvim_get_hl(0, { name = bg_group, link = false })

	local new_group_name = "GeminiDiff_" .. fg_group:gsub("[^%w_]", "_")
	local new_hl = vim.deepcopy(fg_hl)

	if bg_hl.bg then
		new_hl.bg = bg_hl.bg
	end
	if bg_hl.ctermbg then
		new_hl.ctermbg = bg_hl.ctermbg
	end

	vim.api.nvim_set_hl(0, new_group_name, new_hl)
	hl_cache[cache_key] = new_group_name
	return new_group_name
end

local function get_syntax_lines(content, lang)
	if not vim.treesitter.get_string_parser then
		return nil
	end

	local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
	if not ok or not parser then
		return nil
	end

	local ok_tree, trees = pcall(function()
		return parser:parse()
	end)
	if not ok_tree or not trees or #trees == 0 then
		return nil
	end
	local tree = trees[1]

	local ok_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
	if not ok_query or not query then
		return nil
	end

	local lines = vim.split(content, "\n")
	local line_highlights = {}

	for id, node, _ in query:iter_captures(tree:root(), content, 0, -1) do
		local name = query.captures[id]
		local hl_group = "@" .. name .. "." .. lang
		local range = { node:range() }
		local start_row, start_col, end_row, end_col = range[1], range[2], range[3], range[4]

		for i = start_row, end_row do
			if not line_highlights[i + 1] then
				line_highlights[i + 1] = {}
			end
			local line_len = #(lines[i + 1] or "")
			local s_col = (i == start_row) and start_col or 0
			local e_col = (i == end_row) and end_col or line_len
			table.insert(line_highlights[i + 1], { s_col, e_col, hl_group })
		end
	end

	local result = {}
	for i, line in ipairs(lines) do
		local hls = line_highlights[i] or {}
		table.sort(hls, function(a, b)
			return a[1] < b[1]
		end)

		local chunks = {}
		local current_col = 0
		for _, hl in ipairs(hls) do
			local s, e, group = unpack(hl)
			if s > current_col then
				table.insert(chunks, { string.sub(line, current_col + 1, s), "DiffAdd" })
			end
			if e > s then
				if s < current_col then
					s = current_col
				end
				if e > s then
					table.insert(chunks, { string.sub(line, s + 1, e), get_combined_hl(group, "DiffAdd") })
					current_col = e
				end
			end
		end
		if current_col < #line then
			table.insert(chunks, { string.sub(line, current_col + 1), "DiffAdd" })
		end
		result[i] = chunks
	end

	return result
end

--- @param args gemini.OpenDiffRequest
function M.open_diff(args)
	local filePath = args.filePath
	local newContent = args.newContent

	active_diffs[filePath] = newContent

	assert(type(newContent) == "string")

	vim.api.nvim_exec_autocmds("User", {
		pattern = "GeminiOpenDiffPre",
	})

	vim.cmd.edit(filePath)
	local bufnr = vim.fn.bufnr(filePath)
	local currentContent = ""

	if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		currentContent = table.concat(lines, "\n") .. "\n"
	else
		-- Should be loaded by edit, but just in case
		local f = io.open(filePath, "r")
		if f then
			currentContent = f:read("*a")
			f:close()
		end
	end

	local indices = vim.text.diff(currentContent, newContent, {
		result_type = "indices",
	})

	local ft = vim.filetype.match({ filename = filePath })
	if not ft and bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
		ft = vim.bo[bufnr].filetype
	end

	local syntax_lines = nil
	if ft then
		syntax_lines = get_syntax_lines(newContent, ft)
	end

	local ns_id = vim.api.nvim_create_namespace("gemini_diff")
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

	local new_lines = vim.split(newContent, "\n")

	for _, idx in ipairs(indices) do
		local start_a, count_a, start_b, count_b = unpack(idx)

		-- Highlight deleted lines
		if count_a > 0 then
			for i = 0, count_a - 1 do
				local line_idx = start_a - 1 + i
				vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
					end_line = line_idx + 1,
					hl_group = "DiffDelete",
					hl_eol = true,
				})
			end
		end

		-- Add virtual text for added lines
		if count_b > 0 then
			local virt_lines = {}
			for i = 0, count_b - 1 do
				local line_idx = start_b + i
				if syntax_lines and syntax_lines[line_idx] then
					table.insert(virt_lines, syntax_lines[line_idx])
				else
					local line = new_lines[line_idx]
					table.insert(virt_lines, { { line, "DiffAdd" } })
				end
			end

			local attach_line
			local virt_lines_above = false

			if count_a == 0 then
				-- Insertion
				if start_a == 0 then
					attach_line = 0
					virt_lines_above = true
				else
					attach_line = start_a - 1
				end
			else
				-- Replacement / Deletion + Insertion
				-- Attach after the deleted block
				attach_line = start_a - 1 + count_a - 1
			end

			vim.api.nvim_buf_set_extmark(bufnr, ns_id, attach_line, 0, {
				virt_lines = virt_lines,
				virt_lines_above = virt_lines_above,
			})
		end
	end

	if #indices > 0 then
		local start_a = indices[1][1]
		local target_line = start_a
		if target_line == 0 then
			target_line = 1
		end
		vim.api.nvim_win_set_cursor(0, { target_line, 0 })
		vim.cmd("normal! zz")
	end

	vim.api.nvim_exec_autocmds("User", {
		pattern = "GeminiOpenDiff",
		data = { bufnr = bufnr },
	})
end

--- @param args gemini.CloseDiffRequest
function M.close_diff(args)
	local filePath = args.filePath
	active_diffs[filePath] = nil
	local bufnr = vim.fn.bufnr(filePath)

	if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
		local ns_id = vim.api.nvim_create_namespace("gemini_diff")
		vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

		-- Capture old content
		local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local old_content = table.concat(old_lines, "\n")

		-- Refresh buffer
		vim.cmd("silent! checktime " .. vim.fn.fnameescape(filePath))

		-- Capture new content
		local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local new_content = table.concat(new_lines, "\n")

		if old_content ~= new_content then
			local indices = vim.text.diff(old_content, new_content, {
				result_type = "indices",
			})

			local flash_ns = vim.api.nvim_create_namespace("gemini_flash")

			for _, idx in ipairs(indices) do
				local _, _, start_b, count_b = unpack(idx)

				if count_b > 0 then
					for i = 0, count_b - 1 do
						local line_idx = start_b - 1 + i
						-- Ensure line_idx is valid
						if line_idx >= 0 and line_idx < #new_lines then
							vim.api.nvim_buf_set_extmark(bufnr, flash_ns, line_idx, 0, {
								end_line = line_idx + 1,
								hl_group = "IncSearch",
							})
						end
					end
				end
			end

			vim.defer_fn(function()
				if vim.api.nvim_buf_is_valid(bufnr) then
					vim.api.nvim_buf_clear_namespace(bufnr, flash_ns, 0, -1)
				end
			end, 300)
		end
	end

	vim.api.nvim_exec_autocmds("User", {
		pattern = "GeminiCloseDiff",
		data = { bufnr = bufnr },
	})
end

function M.focus_next_diff()
	local diffs = vim.tbl_keys(active_diffs)
	if #diffs == 0 then
		vim.notify("No active diffs", vim.log.levels.INFO)
		return
	end

	table.sort(diffs)

	local current_buf = vim.api.nvim_get_current_buf()
	local current_path = vim.api.nvim_buf_get_name(current_buf)

	local next_path = diffs[1]
	for i, path in ipairs(diffs) do
		-- Normalize paths for comparison if needed, but usually exact match works for exact keys
		if path == current_path then
			next_path = diffs[(i % #diffs) + 1]
			break
		end
	end

	-- Check if buffer exists for the path
	local next_buf = vim.fn.bufnr(next_path)
	if next_buf ~= -1 then
		vim.api.nvim_set_current_buf(next_buf)
	else
		vim.cmd.edit(next_path)
	end
end

function M.accept_all_diffs()
	local api = require("gemini.api")
	for file_path, content in pairs(active_diffs) do
		api.send_diff_accepted({
			filePath = file_path,
			content = content,
		})
	end
end

function M.reject_all_diffs()
	local api = require("gemini.api")
	for file_path, _ in pairs(active_diffs) do
		api.send_diff_rejected({
			filePath = file_path,
		})
	end
end

return M

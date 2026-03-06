-- 1. Parse Arguments
local host_server = ""
local hook_name = ""
local log_path = ""

for i = 1, #arg do
	local v = arg[i]
	if v == "--host-server" then
		host_server = arg[i + 1]
	elseif v == "--hook" then
		hook_name = arg[i + 1]
	elseif v == "--log-path" then
		log_path = arg[i + 1]
	end
end

if not host_server or host_server == "" then
	local msg = "gemini.nvim hook: Error - --host-server argument required"
	io.write(vim.json.encode({ systemMessage = msg }))
	return
end

if not hook_name or hook_name == "" then
	local msg = "gemini.nvim hook: Error - --hook argument required"
	io.write(vim.json.encode({ systemMessage = msg }))
	return
end

-- 2. Read Stdin (Hook Context)
local input = io.read("*a")

-- 2.1 Log Hook (if log path provided)
if log_path ~= "" then
	local f_log = io.open(log_path, "a")
	if f_log then
		f_log:write(string.format("[%s] Hook: %s, Data: %s\n", os.date(), hook_name, input))
		f_log:close()
	end
end

-- 3. Connect to Host Server
local channel = vim.fn.sockconnect("pipe", host_server, { rpc = true })
if channel == 0 then
	local msg = "gemini.nvim hook: Failed to connect to host server at " .. host_server
	io.write(vim.json.encode({ systemMessage = msg }))
	return
end

-- 4. Trigger Hook on Host
-- Use arguments to avoid string injection issues
local lua_code = "return require('gemini.hooks')._trigger(...)"
local ok, res = pcall(vim.rpcrequest, channel, "nvim_exec_lua", lua_code, { hook_name, input })

vim.fn.chanclose(channel)

if not ok then
	local msg = "gemini.nvim hook: Error triggering hook on host: " .. tostring(res)
	io.write(vim.json.encode({ systemMessage = msg }))
	return
end

-- 5. Output Success JSON
io.write(vim.json.encode(res))

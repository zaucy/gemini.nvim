-- 1. Parse Arguments
local host_server
local hook_name
for i, v in ipairs(arg) do
	if v == "--host-server" then
		host_server = arg[i + 1]
	elseif v == "--hook" then
		hook_name = arg[i + 1]
	end
end

if not host_server then
	local msg = "gemini.nvim hook: Error - --host-server argument required"
	io.write(vim.json.encode({ systemMessage = msg }))
	return
end

if not hook_name then
	local msg = "gemini.nvim hook: Error - --hook argument required"
	io.write(vim.json.encode({ systemMessage = msg }))
	return
end

-- 2. Read Stdin (Hook Context)
local input = io.read("*a")

-- 3. Connect to Host Server
local channel = vim.fn.sockconnect("pipe", host_server, { rpc = true })
if channel == 0 then
	local msg = "gemini.nvim hook: Failed to connect to host server at " .. host_server
	io.write(vim.json.encode({ systemMessage = msg }))
	return
end

-- 4. Trigger Hook on Host
-- We call the internal function to notify the plugin
local lua_code = string.format("require('gemini.hooks')._trigger('%s', '%s')", hook_name, input)

local ok, res = pcall(vim.rpcrequest, channel, "nvim_exec_lua", lua_code, {})

vim.fn.chanclose(channel)

if not ok then
	local msg = "gemini.nvim hook: Error triggering hook on host: " .. tostring(res)
	io.write(vim.json.encode({ systemMessage = msg }))
	return
end

-- 5. Output Success JSON
-- The output here is displayed to the user by the Gemini CLI as a system message.
-- We can keep it minimal or informative.
local response = {
	systemMessage = "gemini.nvim: Hook synchronized",
}
io.write(vim.json.encode(response))

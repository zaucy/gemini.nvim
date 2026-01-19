-- Client bridge: Stdio <-> TCP
-- Usage: nvim --clean -l cmd/gemini_client.lua [port]

io.stdout:setvbuf("no")
io.stdin:setvbuf("no")

local uv = vim.uv

-- Setup Logging
local state_dir = vim.fn.stdpath("state")
state_dir = state_dir:gsub("\\", "/")
local log_file = state_dir .. "/gemini/client.log"
vim.fn.mkdir(vim.fn.fnamemodify(log_file, ":h"), "p")

local function log(msg)
	local f = io.open(log_file, "a")
	if f then
		f:write(os.date("%H:%M:%S") .. " [CLIENT] " .. msg .. "\n")
		f:close()
	end
end

log("Starting client. Args: " .. vim.inspect(_G.arg))

local args = _G.arg
local port = nil

assert(args)

-- 1. Try explicit port argument
for i, arg in ipairs(args) do
	if arg == "--" and args[i + 1] then
		port = tonumber(args[i + 1])
		break
	end
end

if not port then
	-- Fallback
	if #args > 0 then
		local p = tonumber(args[#args])
		if p and p > 1024 then
			port = p
		end
	end
end

if port then
	log("Port found in args: " .. port)
else
	local err = "gemini.nvim: could not determine server port for CWD: " .. vim.fn.getcwd()
	log(err)
	io.stderr:write(err .. "\n")
	os.exit(1)
end

log("Resolved Port: " .. port)

local stdin = uv.new_pipe(false)
local stdout = uv.new_pipe(false)
local client = uv.new_tcp()
assert(stdin)
assert(stdout)
assert(client)

local function cleanup()
	log("Cleaning up...")
	if not client:is_closing() then
		client:close()
	end
	if not stdin:is_closing() then
		stdin:close()
	end
	if not stdout:is_closing() then
		stdout:close()
	end
	os.exit(0)
end

client:connect("127.0.0.1", port, function(err)
	if err then
		local msg = "gemini.nvim: failed to connect to port " .. port .. ": " .. err
		log(msg)
		io.stderr:write(msg .. "\n")
		os.exit(1)
	end

	log("Connected to 127.0.0.1:" .. port)

	stdin:open(0)
	stdout:open(1)

	-- Stdin -> Socket
	stdin:read_start(function(err, chunk)
		if err then
			log("Stdin Read Error: " .. tostring(err))
			cleanup()
			return
		end
		if not chunk then
			log("Stdin EOF")
			cleanup()
			return
		end
		log("Stdin -> Socket: " .. #chunk .. " bytes")
		client:write(chunk)
	end)

	-- Socket -> Stdout
	client:read_start(function(err, chunk)
		if err then
			log("Socket Read Error: " .. tostring(err))
			cleanup()
			return
		end
		if not chunk then
			log("Socket EOF")
			cleanup()
			return
		end
		log("Socket -> Stdout: " .. #chunk .. " bytes")
		stdout:write(chunk)
	end)
end)

uv.run()

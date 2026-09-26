require "xlog"
require "xconfig"
require "xsocket"
require "xconst"
require "xpackage"
require "xregister"
require "xmatchlog"
require "xrecord"

-- QLadder: local machine API for the web app.
-- One request per connection, one line: TOKEN \t OP \t ARG... \n
-- Reply: "ok \t ..." or "err \t code".
--   create EMAIL NICKNAME PASSWORD STEAM_ACCOUNT_ID -> ok ID
--   passwd ID PASSWORD                             -> ok
--   pause MASTER_ID [FROM_ID]                      -> ok
--     toggles the pause of a running match: the room's host gets the record a
--     player's game sends when its pause key is pressed (a GUI record, ReadPause)

local log = xlog("xapi")

local MAX_LINE = 1024

-- 00 04: a record of the GUI machine (menu.aix); section 66 = ReadPause; its Boolean; 01 end.
-- The host toggles its pause whatever the Boolean says, and tells everyone.
local PAUSE_RECORD = "\0\4\66\0\0\1"

local function find_session(master_id)
	for _, server in pairs(servers or {}) do
		if server.sessions[master_id] then
			return server.sessions[master_id]
		end
	end
	return nil
end

local function valid_nickname(nick)
	return #nick >= 4 and #nick <= 16 and not nick:find("[^%w%(%)%+%-_%.%[%]]")
end

local function valid_email(email)
	return #email <= 64 and email:match("^[%w%._%+%-]+@[%w%.%-]+%.%a+$") ~= nil
end

local function valid_password(password)
	return #password >= 8 and #password <= 32 and not password:find("[^%w]")
end

local function nickname_taken(nick)
	nick = nick:lower()
	for _, account in register:pairs() do
		if (account.nickname or ""):lower() == nick then
			return true
		end
	end
	return false
end

local function online_client(id)
	for _, server in pairs(servers or {}) do
		if server.clients[id] then
			return server.clients[id]
		end
	end
	return nil
end

local ops =
{
	create = function (email, nick, password, steam)
		if not (email and nick and password and steam) then
			return "err\targs"
		end
		email = email:lower()
		if not valid_email(email) then
			return "err\temail_invalid"
		elseif not valid_nickname(nick) then
			return "err\tnickname_invalid"
		elseif not valid_password(password) then
			return "err\tpassword_invalid"
		elseif not tonumber(steam) then
			return "err\tsteam_invalid"
		elseif register:exist(email) then
			return "err\temail_taken"
		elseif nickname_taken(nick) then
			return "err\tnickname_taken"
		end
		local client = {}
		register:new(client, {
			email = email,
			password = password,
			cdkey = "",
			nickname = nick,
			country = "",
			info = ("sic|%d|src|web|"):format(tonumber(steam)),
		})
		log("info", "registered from web: #%d %s", client.id, nick)
		xmatchlog.account(client, client.id, "register")
		return "ok\t" .. client.id
	end,

	passwd = function (id, password)
		id = tonumber(id)
		local account = id and register[id]
		if not account then
			return "err\tnot_found"
		elseif not (password and valid_password(password)) then
			return "err\tpassword_invalid"
		end
		account.password = password
		-- an online client would write its old password back on the next profile update
		local client = online_client(id)
		if client then
			client.password = password
		end
		register:save()
		log("info", "password changed from web: #%d %s", id, account.nickname or "")
		return "ok"
	end,

	pause = function (master_id, from_id)
		local session = find_session(tonumber(master_id) or -1)
		local host = session and session.clients[session.master_id]
		if not host then
			return "err\tnot_found"
		elseif not session.locked then
			return "err\tnot_started"
		end
		local from = tonumber(from_id) or 0
		xrecord.marker(session, {ev = "server_pause", id = from})
		local packet = xpackage(xcmd.LAN_RECORD, from, session.master_id)
			:write_buffer(PAUSE_RECORD)
		-- ops run under pcall, and a socket send may yield: send from a coroutine of its own
		xsocket.spawn(function () packet:transmit(host) end)
		log("info", "pause toggled from the api: %s", session.real_name)
		return "ok"
	end,
}

local function handle(socket)
	local line = {}
	while #line < MAX_LINE do
		local char = socket:receive(1)
		if not char or char == "\n" then
			break
		end
		line[#line + 1] = char
	end
	line = table.concat(line):gsub("\r$", "")

	local words = {}
	for word in (line .. "\t"):gmatch("([^\t]*)\t") do
		table.insert(words, word)
	end
	local token, op = table.remove(words, 1), table.remove(words, 1)

	local reply
	if token ~= xconfig.api.token then
		log("warn", "bad token")
		reply = "err\tauth"
	elseif not ops[op or ""] then
		reply = "err\tunknown_op"
	else
		local ok, result = pcall(ops[op], unpack(words))
		if ok then
			reply = result
		else
			log("error", "%s failed: %s", op, tostring(result))
			reply = "err\tinternal"
		end
	end
	socket:send(reply .. "\n")
	socket:close()
end

if not (xconfig.api and xconfig.api.token and #xconfig.api.token >= 32) then
	log("info", "disabled")
else
	local host = xconfig.api.host or "127.0.0.1"
	local port = assert(xconfig.api.port, "no api.port")
	local server_socket = assert(xsocket.tcp())
	assert(server_socket:bind(host, port))
	assert(server_socket:listen(32))
	log("info", "listening at %s", tostring(server_socket))

	xsocket.spawn(
		function ()
			while true do
				xsocket.spawn(handle, assert(server_socket:accept()))
			end
		end)
end

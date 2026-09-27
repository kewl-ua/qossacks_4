require "xlog"
require "xconfig"
require "xsocket"
require "xconst"
require "xpackage"

-- Chat commands: a message that starts with "!" in the lobby chat, a private
-- message or a room's chat is answered by the server and not passed on.
--
-- config.store:
--   commands = {
--     ladder = "/var/lib/ladder/ladder.tsv", -- written by the ladder site (tab-separated, see below)
--     site = "https://example.com",          -- links in the answers
--   },
--
-- The ladder file: the first line names the columns (id nick rating games wins
-- losses position rank last_match last_result last_against); one player a line.
-- The server reads it when a command needs it: it never waits on the network.
--
-- Answers are ASCII for now: whether the game's chat shows Cyrillic, and how,
-- is what !test is for.

local log = xlog("xcommands")

local config = xconfig.commands
local site = config and config.site or ""
local MIN_INTERVAL = 1.0 -- seconds between two commands of a client

local function split_tabs(line)
	local fields = {}
	for field in (line .. "\t"):gmatch("([^\t]*)\t") do
		table.insert(fields, field)
	end
	return fields
end

local function read_ladder()
	local path = config and config.ladder
	local file = path and io.open(path, "rb")
	if not file then
		return nil
	end
	local rows, columns = {}, nil
	for line in file:lines() do
		line = line:gsub("\r$", "")
		if not columns then
			columns = split_tabs(line)
		elseif line ~= "" then
			local row = {}
			for i, value in ipairs(split_tabs(line)) do
				row[columns[i] or i] = value
			end
			table.insert(rows, row)
		end
	end
	file:close()
	return rows
end

local function find_player(rows, nick)
	nick = nick:lower()
	for _, row in ipairs(rows) do
		if (row.nick or ""):lower() == nick then
			return row
		end
	end
	return nil
end

local function link(path)
	return site ~= "" and (site .. path) or ""
end

local function online_clients()
	local list = {}
	for _, server in pairs(servers or {}) do
		for _, client in pairs(server.clients) do
			table.insert(list, client)
		end
	end
	table.sort(list, function (a, b) return (a.nickname or "") < (b.nickname or "") end)
	return list
end

local function rooms()
	local list = {}
	for _, server in pairs(servers or {}) do
		for _, session in pairs(server.sessions) do
			table.insert(list, session)
		end
	end
	return list
end

-- A command only collects its answer: reply() adds a line, and the lines are
-- sent after the command returns. Sending yields (xsocket), and Lua 5.1 cannot
-- yield through the pcall that guards a command.
local answer

local function reply(remote, text, in_room, code)
	table.insert(answer, {code or ((in_room and remote.session) and xcmd.USER_SESSION_MSG or xcmd.USER_MESSAGE), text})
end

local commands = {}

commands.help = function (remote, arg, in_room)
	reply(remote, "QLadder: !rating [nick]  !top  !online  !rooms  !last  !test", in_room)
	if site ~= "" then
		reply(remote, "Ladder, matches and stats: " .. site, in_room)
	end
end

commands.rating = function (remote, arg, in_room)
	local rows = read_ladder()
	if not rows then
		return reply(remote, "The ladder is not available right now.", in_room)
	end
	local nick = arg ~= "" and arg or (remote.nickname or "")
	local row = find_player(rows, nick)
	if not row then
		return reply(remote, nick .. ": no games on the ladder yet.", in_room)
	end
	local place = row.position ~= "" and (", #" .. row.position) or ""
	reply(remote, ("%s: %s, %s%s. Rated games %s (%s-%s). %s"):format(
		row.nick, row.rating, row.rank, place, row.games, row.wins, row.losses, link("/player/" .. row.id)), in_room)
end

commands.top = function (remote, arg, in_room)
	local rows = read_ladder()
	if not rows then
		return reply(remote, "The ladder is not available right now.", in_room)
	end
	local shown = 0
	for _, row in ipairs(rows) do
		if row.position ~= "" and shown < 5 then
			shown = shown + 1
			reply(remote, ("#%s %s %s (%s, %s-%s)"):format(row.position, row.nick, row.rating, row.rank, row.wins, row.losses), in_room)
		end
	end
	if shown == 0 then
		reply(remote, "Nobody is ranked yet: a player is ranked after 5 rated games.", in_room)
	end
	if site ~= "" then
		reply(remote, "Full ladder: " .. link("/ladder"), in_room)
	end
end

commands.online = function (remote, arg, in_room)
	local list = online_clients()
	local names = {}
	for i, client in ipairs(list) do
		if i <= 20 then
			table.insert(names, client.nickname or "?")
		end
	end
	reply(remote, ("Online %d: %s%s"):format(#list, table.concat(names, ", "), #list > 20 and ", ..." or ""), in_room)
end

commands.rooms = function (remote, arg, in_room)
	local list = rooms()
	if #list == 0 then
		return reply(remote, "No rooms open.", in_room)
	end
	for i, session in ipairs(list) do
		if i > 8 then
			return reply(remote, ("... and %d more"):format(#list - 8), in_room)
		end
		local count = 0
		for _ in pairs(session.clients) do
			count = count + 1
		end
		reply(remote, ("%s  %d/%d%s%s"):format(session.real_name or "?", count, session.max_players or 0,
			session.locked and "  playing" or "", (session.real_pass or "") ~= "" and "  password" or ""), in_room)
	end
end

commands.last = function (remote, arg, in_room)
	local rows = read_ladder()
	local row = rows and find_player(rows, arg ~= "" and arg or (remote.nickname or ""))
	if not row or (row.last_match or "") == "" then
		return reply(remote, "No finished match yet.", in_room)
	end
	local result = row.last_result == "win" and "won" or (row.last_result == "lose" and "lost" or "no result")
	local against = (row.last_against or "") ~= "" and (" vs " .. row.last_against) or ""
	reply(remote, ("%s, match #%s: %s%s. %s"):format(row.nick, row.last_match, result, against,
		link("/match/" .. row.last_match)), in_room)
end

-- how the game shows server messages: both kinds of message, ASCII and Cyrillic in both encodings
commands.test = function (remote, arg, in_room)
	local utf8 = "\208\159\209\128\208\190\208\178\208\181\209\128\208\186\208\176" -- "Проверка" in UTF-8
	local cp1251 = "\207\240\238\226\229\240\234\224"                          -- "Проверка" in cp1251
	for _, code in ipairs({xcmd.USER_MESSAGE, remote.session and xcmd.USER_SESSION_MSG or nil}) do
		local kind = code == xcmd.USER_MESSAGE and "private" or "room"
		for _, line in ipairs({
			"[" .. kind .. " 1] ASCII: test",
			"[" .. kind .. " 2] UTF-8: " .. utf8,
			"[" .. kind .. " 3] cp1251: " .. cp1251,
			"[" .. kind .. " 4] %color(00DD00)%colour%color(default)%",
		}) do
			reply(remote, line, in_room, code)
		end
	end
end

xcommands =
{
	enabled = (config ~= nil),

	-- true when the message was a command (answered here, not passed on)
	handle = function (remote, message, in_room)
		if not config or type(message) ~= "string" or message:sub(1, 1) ~= "!" then
			return false
		end
		local name, arg = message:match("^!(%a+)%s*(.-)%s*$")
		local command = name and commands[name:lower()]
		if not command then
			return false -- "!!!" and the like are just chat
		end
		local now = xsocket.gettime()
		if remote.command_time and now - remote.command_time < MIN_INTERVAL then
			return true
		end
		remote.command_time = now
		remote.log("info", "command: %s %s", name:lower(), arg)
		answer = {}
		local ok, err = pcall(command, remote, arg, in_room)
		local lines = answer
		answer = nil
		if not ok then
			log("error", "command %s: %s", name, tostring(err))
			lines = {{xcmd.USER_MESSAGE, "Sorry, that command failed."}}
		end
		for _, line in ipairs(lines) do
			xpackage(line[1], 0, remote.id)
				:write("s", line[2])
				:transmit(remote)
		end
		return true
	end,
}

if config then
	log("info", "chat commands on, ladder %s", tostring(config.ladder))
else
	log("info", "disabled")
end

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
-- losses position rank rank_ru last_match last_result last_against last_against_ru);
-- one player a line.
-- The server reads it when a command needs it: it never waits on the network.
--
-- Answers are in Russian (cp1251) for a game in Russian or Ukrainian, else in
-- English; the ladder file is UTF-8 with Russian columns (*_ru).

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

-- The game's text is cp1251: Russian answers are written here in UTF-8 and
-- converted when sent (!test, 2026-09-27: UTF-8 shows as mojibake, cp1251 reads).
local CP1251 = {[0x401] = 0xA8, [0x451] = 0xB8, [0x404] = 0xAA, [0x454] = 0xBA, [0x406] = 0xB2, [0x456] = 0xB3,
	[0x407] = 0xAF, [0x457] = 0xBF, [0x490] = 0xA5, [0x491] = 0xB4, [0xAB] = 0xAB, [0xBB] = 0xBB,
	[0x2013] = 0x96, [0x2014] = 0x97, [0x2116] = 0xB9}

local function cp1251(text)
	local out, i = {}, 1
	while i <= #text do
		local c = text:byte(i)
		local code, n = c, 1
		if c >= 0xF0 then
			code, n = nil, 4
		elseif c >= 0xE0 then
			code, n = (c % 16) * 4096 + ((text:byte(i + 1) or 0) % 64) * 64 + (text:byte(i + 2) or 0) % 64, 3
		elseif c >= 0xC0 then
			code, n = (c % 32) * 64 + (text:byte(i + 1) or 0) % 64, 2
		elseif c >= 0x80 then
			code = nil -- a stray continuation byte
		end
		if code and code < 0x80 then
			table.insert(out, string.char(code))
		elseif code and code >= 0x410 and code <= 0x44F then
			table.insert(out, string.char(code - 0x410 + 0xC0))
		elseif code and CP1251[code] then
			table.insert(out, string.char(CP1251[code]))
		else
			table.insert(out, "?")
		end
		i = i + n
	end
	return table.concat(out)
end

local TEXTS = {
	en = {
		help = "!rating [nick] - rating, !top - the best, !online - who is on, !rooms - rooms, !last - last match",
		site = "Ladder, matches and statistics: %s",
		unavailable = "The ladder is not available right now.",
		no_games = "%s: no games on the ladder yet.",
		rating = "%s: %s, %s%s. Rated games %s (%s-%s). %s",
		place = ", #%s",
		top = "%s. %s %s (%s, %s-%s)",
		nobody = "Nobody is ranked yet: a player is ranked after 5 rated games.",
		full = "The whole ladder: %s",
		online = "Online %d: %s%s",
		no_rooms = "No rooms open.",
		more = "... and %d more",
		room = "%s  %d/%d%s%s", playing = ", playing", password = ", password",
		no_match = "No finished match yet.",
		last = "%s, match #%s: %s%s. %s", won = "won", lost = "lost", none = "no result", vs = " vs %s",
		failed = "Sorry, that command failed.",
	},
	ru = {
		help = "!rating [ник] — рейтинг, !top — лучшие, !online — кто в лобби, !rooms — комнаты, !last — последний матч",
		site = "Ладдер, матчи и статистика: %s",
		unavailable = "Ладдер сейчас недоступен.",
		no_games = "%s: на ладдере пока нет игр.",
		rating = "%s: %s, %s%s. Рейтинговых игр %s (%s-%s). %s",
		place = ", место %s",
		top = "%s. %s %s (%s, %s-%s)",
		nobody = "В рейтинге пока никого: место дают после 5 рейтинговых игр.",
		full = "Весь ладдер: %s",
		online = "В лобби %d: %s%s",
		no_rooms = "Открытых комнат нет.",
		more = "... и ещё %d",
		room = "%s  %d/%d%s%s", playing = ", идёт игра", password = ", с паролем",
		no_match = "Сыгранных матчей пока нет.",
		last = "%s, матч №%s: %s%s. %s", won = "победа", lost = "поражение", none = "без результата", vs = " против: %s",
		failed = "Команда не сработала, извините.",
	},
}
for key, text in pairs(TEXTS.ru) do
	TEXTS.ru[key] = cp1251(text)
end
local TAG = "%color(E0B050)%[QLadder]%color(default)% "

-- A command only collects its answer: reply() adds a line, and the lines are
-- sent after the command returns. Sending yields (xsocket), and Lua 5.1 cannot
-- yield through the pcall that guards a command.
local answer, T, russian

-- a ladder value in the player's language: the Russian column converted, else the ASCII one
local function field(row, name)
	if russian and (row[name .. "_ru"] or "") ~= "" then
		return cp1251(row[name .. "_ru"])
	end
	return row[name] or ""
end

local function reply(remote, text, in_room, code)
	table.insert(answer, {code or ((in_room and remote.session) and xcmd.USER_SESSION_MSG or xcmd.USER_MESSAGE), text})
end

local commands = {}

commands.help = function (remote, arg, in_room)
	reply(remote, TAG .. T.help, in_room)
	if site ~= "" then
		reply(remote, T.site:format(site), in_room)
	end
end

commands.rating = function (remote, arg, in_room)
	local rows = read_ladder()
	if not rows then
		return reply(remote, TAG .. T.unavailable, in_room)
	end
	local nick = arg ~= "" and arg or (remote.nickname or "")
	local row = find_player(rows, nick)
	if not row then
		return reply(remote, TAG .. T.no_games:format(nick), in_room)
	end
	local place = row.position ~= "" and T.place:format(row.position) or ""
	reply(remote, TAG .. T.rating:format(row.nick, row.rating, field(row, "rank"), place, row.games, row.wins, row.losses,
		link("/player/" .. row.id)), in_room)
end

commands.top = function (remote, arg, in_room)
	local rows = read_ladder()
	if not rows then
		return reply(remote, TAG .. T.unavailable, in_room)
	end
	local shown = 0
	for _, row in ipairs(rows) do
		if row.position ~= "" and shown < 5 then
			shown = shown + 1
			reply(remote, (shown == 1 and TAG or "") .. T.top:format(row.position, row.nick, row.rating, field(row, "rank"),
				row.wins, row.losses), in_room)
		end
	end
	if shown == 0 then
		reply(remote, TAG .. T.nobody, in_room)
	end
	if site ~= "" then
		reply(remote, T.full:format(link("/ladder")), in_room)
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
	reply(remote, TAG .. T.online:format(#list, table.concat(names, ", "), #list > 20 and ", ..." or ""), in_room)
end

commands.rooms = function (remote, arg, in_room)
	local list = rooms()
	if #list == 0 then
		return reply(remote, TAG .. T.no_rooms, in_room)
	end
	for i, session in ipairs(list) do
		if i > 8 then
			return reply(remote, T.more:format(#list - 8), in_room)
		end
		local count = 0
		for _ in pairs(session.clients) do
			count = count + 1
		end
		-- the room's name is the game's own text (cp1251 already)
		reply(remote, (i == 1 and TAG or "") .. T.room:format(session.real_name or "?", count, session.max_players or 0,
			session.locked and T.playing or "", (session.real_pass or "") ~= "" and T.password or ""), in_room)
	end
end

commands.last = function (remote, arg, in_room)
	local rows = read_ladder()
	local row = rows and find_player(rows, arg ~= "" and arg or (remote.nickname or ""))
	if not row or (row.last_match or "") == "" then
		return reply(remote, TAG .. T.no_match, in_room)
	end
	local result = row.last_result == "win" and T.won or (row.last_result == "lose" and T.lost or T.none)
	local against = field(row, "last_against")
	reply(remote, TAG .. T.last:format(row.nick, row.last_match, result, against ~= "" and T.vs:format(against) or "",
		link("/match/" .. row.last_match)), in_room)
end

-- how the game shows server messages: both kinds of message, ASCII and Cyrillic in both encodings
commands.test = function (remote, arg, in_room)
	local utf8 = "\208\159\209\128\208\190\208\178\208\181\209\128\208\186\208\176" -- "Проверка" in UTF-8
	local win = "\207\240\238\226\229\240\234\224"                             -- "Проверка" in cp1251
	for _, code in ipairs({xcmd.USER_MESSAGE, remote.session and xcmd.USER_SESSION_MSG or nil}) do
		local kind = code == xcmd.USER_MESSAGE and "private" or "room"
		for _, line in ipairs({
			"[" .. kind .. " 1] ASCII: test",
			"[" .. kind .. " 2] UTF-8: " .. utf8,
			"[" .. kind .. " 3] cp1251: " .. win,
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
		if not config or type(message) ~= "string" then
			return false
		end
		-- the game sends "<lang>\7<text>" ("ru\7!top"), in a match's console "<mode>|<lang>\7<text>";
		-- it shows an incoming message by the same format (transliterating ru/uk for other languages)
		local prefix, text = message:match("^(.-\7)(.*)$")
		if not prefix then
			prefix, text = "", message
		end
		if text:sub(1, 1) ~= "!" then
			return false
		end
		local name, arg = text:match("^!(%a+)%s*(.-)%s*$")
		local command = name and commands[name:lower()]
		if not command then
			return false -- "!!!" and the like are just chat
		end
		-- the player's game language: Russian answers for ru and uk, English for the rest
		local lang = prefix:match("(%a%a)\7$") or "en"
		russian = (lang == "ru" or lang == "uk")
		T = russian and TEXTS.ru or TEXTS.en
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
			lines = {{xcmd.USER_MESSAGE, TAG .. T.failed}}
		end
		for _, line in ipairs(lines) do
			xpackage(line[1], 0, remote.id)
				:write("s", prefix .. line[2])
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

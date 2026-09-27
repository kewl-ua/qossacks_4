require "xlog"
require "xconfig"
require "xsocket"
require "xconst"
require "xpackage"
require "xmatchlog"
require "xrecord"

-- Chat commands: a message that starts with "!" in the lobby chat, a private
-- message or a room's chat is answered by the server and not passed on.
--
-- config.store:
--   commands = {
--     ladder = "/var/lib/ladder/ladder.tsv", -- written by the ladder site (tab-separated, see below)
--     site = "https://example.com",          -- links in the answers
--     remake_minutes = 5,                    -- !remake works this long after the match starts
--     pauses = 3,                            -- !pause: how many a player may take in a match
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

-- A player that is not there: it sits in every client's online list, the
-- answers come from it (the game shows them as its messages), and a private
-- message to it is a command even without "!". commands.bot = false turns it
-- off; commands.bot = { id = ..., nick = "..." } changes it.
local bot = nil
if config and config.bot ~= false then
	local b = type(config.bot) == "table" and config.bot or {}
	bot = {id = b.id or 999999999, nickname = b.nick or "QLadder", states = 0, country = "", info = "",
		score = 0, games_played = 0, games_win = 0, last_game = 0, pingtime = 0}
end
local MIN_INTERVAL = 1.0 -- seconds between two commands of a client
local REMAKE_MINUTES = config and config.remake_minutes or 5
local PAUSES = config and config.pauses or 3

-- The pause: a record of the GUI machine (menu.aix), section 66 = ReadPause, its Boolean, 01 end.
-- A player's game sends it to the host when the pause key is pressed; the host toggles its pause,
-- whatever the Boolean says, and broadcasts the record with its new state (see xapi.lua).
local PAUSE_ON, PAUSE_OFF = "\0\4\66\0\1\1", "\0\4\66\0\0\1"
local PAUSE_WAIT = 3 -- seconds a pause request waits for the host's answer before another may go

-- The save: the GUI machine's section 70, ReadSave: the save's name, the replay's name, the map's
-- name (str16: u16 length + bytes), 01 end. The game switched the online saves off, but a machine
-- that reads the record still saves the match to its profile under that name (menu.inc/readsave.inc).
local SAVE_INTERVAL = 30 -- seconds between two saves of a match

local function str16(text)
	return string.char(#text % 256, math.floor(#text / 256)) .. text
end

local function save_record(name, map)
	return "\0\4\70\0" .. str16(name) .. str16("replay.autosave") .. str16(map or "") .. "\1"
end

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
		help = "!rating [nick] - rating, !top - the best, !online - who is on, !rooms - rooms, !last - last match, !odds - chances in a room, !balance - even teams, !remake - replay the match (all agree), !pause / !unpause, !save",
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
		in_room = "This command works in a room.",
		need_two = "At least two players are needed.",
		odds = "Chances: %s", odds_side = "%s %d%% (%d)", team = "team %d",
		no_bots = "(computers are not counted)",
		balance = "Balanced: %s (%d) vs %s (%d), difference %d.",
		balance_max = "Balance works for 2 to 8 players.",
		remake_match = "!remake works in a running match.",
		remake_player = "Only players vote for a remake.",
		remake_late = "Too late for a remake: it works in the first %d minutes.",
		remake_over = "The match has a result already: no remake.",
		remake_vote = "%s wants a remake (%d/%d). Agree? Type !remake",
		remake_done = "Remake: everyone agreed. The match does not count for the ladder, you can leave.",
		pause_match = "!pause works in a running match.",
		pause_player = "Only players pause the match.",
		paused_already = "The match is paused already. !unpause resumes it.",
		not_paused = "The match is not paused.",
		pause_wait = "A moment: the host has not answered yet.",
		pause_limit = "No pauses left: %d a match.",
		pause = "%s pauses the match (pause %d of %d). !unpause resumes it.",
		unpause = "%s resumes the match.",
		save_match = "!save works in a running match.",
		save_wait = "The match was saved a moment ago.",
		save = "%s saves the match: \"%s\" (in the saved games of every player).",
	},
	ru = {
		help = "!rating [ник] — рейтинг, !top — лучшие, !online — кто в лобби, !rooms — комнаты, !last — последний матч, !odds — шансы в комнате, !balance — ровные команды, !remake — переиграть матч (если согласны все), !pause / !unpause, !save",
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
		in_room = "Эта команда работает в комнате.",
		need_two = "Нужно хотя бы двое игроков.",
		odds = "Шансы: %s", odds_side = "%s %d%% (%d)", team = "команда %d",
		no_bots = "(компьютеры не учитываются)",
		balance = "Ровнее всего: %s (%d) против %s (%d), разница %d.",
		balance_max = "Баланс считается для 2–8 игроков.",
		remake_match = "!remake работает в идущем матче.",
		remake_player = "За ремейк голосуют только игроки.",
		remake_late = "Для ремейка поздно: он возможен в первые %d мин.",
		remake_over = "У матча уже есть результат: ремейка не будет.",
		remake_vote = "%s за ремейк (%d/%d). Согласны? Пишите !remake",
		remake_done = "Ремейк: согласны все. Матч не идёт в ладдер, можно выходить.",
		pause_match = "!pause работает в идущем матче.",
		pause_player = "Паузу ставят только игроки.",
		paused_already = "Матч уже на паузе. Снять: !unpause",
		not_paused = "Матч не на паузе.",
		pause_wait = "Секунду: хост ещё не ответил.",
		pause_limit = "Лимит пауз исчерпан: %d за матч.",
		pause = "%s ставит паузу (%d из %d). Снять: !unpause",
		unpause = "%s снимает паузу.",
		save_match = "!save работает в идущем матче.",
		save_wait = "Матч только что сохранён.",
		save = "%s сохраняет матч: «%s» (в сохранениях у каждого игрока).",
	},
}
for key, text in pairs(TEXTS.ru) do
	TEXTS.ru[key] = cp1251(text)
end
-- a tag before an answer; empty since the answers come from the bot, whose name the game shows
local TAG = bot and "" or "%color(E0B050)%[QLadder]%color(default)% "

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

-- a message to everyone in the room, each in their own language: TEXTS[key] formatted with args
-- (nicks and numbers, the same in every language)
local function announce(session, key, ...)
	table.insert(answer, {xcmd.USER_SESSION_MSG, key = key, args = {...}, session = session})
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

-- the players of a room with their ladder rating (1500 unknown) and team (0: none); spectators left out
local function room_players(session)
	local rows = read_ladder() or {}
	local list = {}
	for _, client in pairs(session.clients) do
		if client.cid ~= xconst.spectator_countryid then
			local row = find_player(rows, client.nickname or "")
			table.insert(list, {nick = client.nickname or "?", rating = row and tonumber(row.rating) or 1500,
				team = client.room_team or 0})
		end
	end
	table.sort(list, function (a, b) return a.nick < b.nick end)
	return list
end

-- computers in the room's datasync: slots of four fields ("-difficulty,cid,team,color")
local function room_computers(session)
	local count = 0
	for slot in (session.last_datasync or ""):gmatch("[^|]+") do
		local fields = {}
		for f in slot:gmatch("[^,]+") do
			table.insert(fields, f)
		end
		if #fields == 4 then
			count = count + 1
		end
	end
	return count
end

local function average(players)
	local sum = 0
	for _, p in ipairs(players) do
		sum = sum + p.rating
	end
	return #players > 0 and sum / #players or 0
end

local function nicks(players)
	local out = {}
	for _, p in ipairs(players) do
		table.insert(out, p.nick)
	end
	return table.concat(out, ", ")
end

-- each side's chance: 10^(R/400) over the sum (Elo's expectation for two sides), R the side's average
commands.odds = function (remote, arg, in_room)
	if not remote.session then
		return reply(remote, TAG .. T.in_room, in_room)
	end
	local players = room_players(remote.session)
	if #players < 2 then
		return reply(remote, TAG .. T.need_two, in_room)
	end
	local sides, by_team = {}, {}
	for _, p in ipairs(players) do
		if p.team ~= 0 then
			if not by_team[p.team] then
				by_team[p.team] = {team = p.team, players = {}}
				table.insert(sides, by_team[p.team])
			end
			table.insert(by_team[p.team].players, p)
		else
			table.insert(sides, {players = {p}})
		end
	end
	table.sort(sides, function (a, b) return (a.team or 99) < (b.team or 99) end)
	local total, parts = 0, {}
	for _, side in ipairs(sides) do
		side.rating = average(side.players)
		side.weight = 10 ^ (side.rating / 400)
		total = total + side.weight
	end
	for _, side in ipairs(sides) do
		local name = side.team and (T.team:format(side.team) .. ": " .. nicks(side.players)) or side.players[1].nick
		table.insert(parts, T.odds_side:format(name, math.floor(100 * side.weight / total + 0.5), math.floor(side.rating + 0.5)))
	end
	reply(remote, TAG .. T.odds:format(table.concat(parts, "; ")) ..
		(room_computers(remote.session) > 0 and (" " .. T.no_bots) or ""), in_room)
end

-- the split of the room's players into two teams with the closest average ratings
commands.balance = function (remote, arg, in_room)
	if not remote.session then
		return reply(remote, TAG .. T.in_room, in_room)
	end
	local players = room_players(remote.session)
	if #players < 2 then
		return reply(remote, TAG .. T.need_two, in_room)
	end
	if #players > 8 then
		return reply(remote, TAG .. T.balance_max, in_room)
	end
	local n, half = #players, math.floor(#players / 2)
	local best, best_mask = nil, nil
	for mask = 0, 2 ^ n - 1 do
		local a, b, count = {}, {}, 0
		for i = 1, n do
			if math.floor(mask / 2 ^ (i - 1)) % 2 == 1 then
				table.insert(a, players[i])
				count = count + 1
			else
				table.insert(b, players[i])
			end
		end
		if count == half then -- every split comes twice (a/b and b/a): the same difference
			local diff = math.abs(average(a) - average(b))
			if not best or diff < best then
				best, best_mask = diff, {a, b}
			end
		end
	end
	local a, b = best_mask[1], best_mask[2]
	reply(remote, TAG .. T.balance:format(nicks(a), math.floor(average(a) + 0.5), nicks(b), math.floor(average(b) + 0.5),
		math.floor(best + 0.5)) .. (room_computers(remote.session) > 0 and (" " .. T.no_bots) or ""), in_room)
end

-- a remake: every player still in the match agrees in its first minutes, and the ladder
-- does not count it (the event goes to the match log and the recording)
commands.remake = function (remote, arg, in_room)
	local session = remote.session
	if not session or not session.locked then
		return reply(remote, TAG .. T.remake_match, in_room)
	elseif remote.cid == xconst.spectator_countryid then
		return reply(remote, TAG .. T.remake_player, in_room)
	elseif session.remade then
		return reply(remote, TAG .. T.remake_done, in_room)
	elseif session.has_result then
		return reply(remote, TAG .. T.remake_over, in_room)
	elseif xsocket.gettime() - (session.lock_time or 0) > REMAKE_MINUTES * 60 then
		return reply(remote, TAG .. T.remake_late:format(REMAKE_MINUTES), in_room)
	end
	session.remake_votes = session.remake_votes or {}
	session.remake_votes[remote.id] = true
	local agreed, total, ids = 0, 0, {}
	for id, client in pairs(session.clients) do
		if client.cid ~= xconst.spectator_countryid then
			total = total + 1
			if session.remake_votes[id] then
				agreed = agreed + 1
				table.insert(ids, id)
			end
		end
	end
	if total < 2 then
		return reply(remote, TAG .. T.need_two, in_room)
	elseif agreed < total then
		return announce(session, "remake_vote", remote.nickname or "?", agreed, total)
	end
	session.remade = true
	xmatchlog.emit({ev = "remake", sid = session.session_id, ids = ids})
	xrecord.marker(session, {ev = "remake", ids = ids})
	log("info", "remake agreed: %s", session.real_name or "?")
	announce(session, "remake_done")
end

-- the pause: the command sends the host the record a player's pause key sends; the state comes
-- from the host's broadcasts (xcommands.host_record), so a toggle never goes the wrong way
local function toggle_pause(remote, in_room, want)
	local session = remote.session
	if not session or not session.locked then
		return reply(remote, TAG .. T.pause_match, in_room)
	elseif remote.cid == xconst.spectator_countryid then
		return reply(remote, TAG .. T.pause_player, in_room)
	elseif (session.paused or false) == want then
		return reply(remote, TAG .. (want and T.paused_already or T.not_paused), in_room)
	elseif session.pause_sent and xsocket.gettime() - session.pause_sent < PAUSE_WAIT then
		return reply(remote, TAG .. T.pause_wait, in_room)
	end
	local host = session.clients[session.master_id]
	if not host then
		return reply(remote, TAG .. T.pause_match, in_room)
	end
	session.pauses = session.pauses or {}
	local used = session.pauses[remote.id] or 0
	if want and used >= PAUSES then
		return reply(remote, TAG .. T.pause_limit:format(PAUSES), in_room)
	end
	-- the host takes the record from a player of its room; for the host's own command, from another one
	local from = remote.id
	if from == session.master_id then
		for id in pairs(session.clients) do
			if id ~= session.master_id then
				from = id
				break
			end
		end
	end
	session.pause_sent = xsocket.gettime()
	xrecord.marker(session, {ev = want and "chat_pause" or "chat_unpause", id = remote.id})
	table.insert(answer, {send = xpackage(xcmd.LAN_RECORD, from, session.master_id)
		:write_buffer(want and PAUSE_ON or PAUSE_OFF), to = host})
	if want then
		session.pauses[remote.id] = used + 1
		announce(session, "pause", remote.nickname or "?", used + 1, PAUSES)
	else
		announce(session, "unpause", remote.nickname or "?")
	end
end

commands.pause = function (remote, arg, in_room)
	return toggle_pause(remote, in_room, true)
end

commands.unpause = function (remote, arg, in_room)
	return toggle_pause(remote, in_room, false)
end

-- a save of the match on every machine: the host gets the record from a player, like one its
-- own WriteSave would read; the others get it from the host, as the game broadcasts it
commands.save = function (remote, arg, in_room)
	local session = remote.session
	local host = session and session.clients[session.master_id]
	if not session or not session.locked or not host then
		return reply(remote, TAG .. T.save_match, in_room)
	elseif session.save_time and xsocket.gettime() - session.save_time < SAVE_INTERVAL then
		return reply(remote, TAG .. T.save_wait, in_room)
	end
	session.save_time = xsocket.gettime()
	local minute = math.floor((session.save_time - (session.lock_time or session.save_time)) / 60)
	local name = ("qladder_%s_%dmin"):format(os.date("%Y%m%d_%H%M"), minute)
	local record = save_record(name, session.mapname)
	local from = remote.id
	if from == session.master_id then
		for id in pairs(session.clients) do
			if id ~= session.master_id then
				from = id
				break
			end
		end
	end
	for id, client in pairs(session.clients) do
		table.insert(answer, {send = xpackage(xcmd.LAN_RECORD, id == session.master_id and from or session.master_id, id)
			:write_buffer(record), to = client})
	end
	xrecord.marker(session, {ev = "chat_save", id = remote.id, name = name})
	log("info", "save %s: %s", name, session.real_name or "?")
	announce(session, "save", remote.nickname or "?", name)
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
	bot = bot,

	-- a game packet (LAN_RECORD) from a room's host: follow its pause broadcasts
	host_record = function (session, payload)
		local on, off = payload:find(PAUSE_ON, 1, true), payload:find(PAUSE_OFF, 1, true)
		if not on and not off then
			return
		end
		-- the last one in the packet wins
		local last_on, last_off = on, off
		while on do
			last_on, on = on, payload:find(PAUSE_ON, on + 1, true)
		end
		while off do
			last_off, off = off, payload:find(PAUSE_OFF, off + 1, true)
		end
		session.paused = (last_on or 0) > (last_off or 0)
		session.pause_sent = nil
	end,

	-- a private message to the bot: whatever it says goes to handle()
	for_bot = function (id)
		return bot ~= nil and id == bot.id
	end,

	handle = function (remote, message, in_room, to_bot)
		if not config or type(message) ~= "string" then
			return false
		end
		-- the game sends "<lang>\7<text>" ("ru\7!top"), in a match's console "<mode>|<lang>\7<text>";
		-- it shows an incoming message by the same format (transliterating ru/uk for other languages)
		local prefix, text = message:match("^(.-\7)(.*)$")
		if not prefix then
			prefix, text = "", message
		end
		-- the player's game language: Russian answers for ru and uk, English for the rest
		local lang = prefix:match("(%a%a)\7$") or "en"
		remote.chat_lang = lang -- for messages to the whole room
		if text:sub(1, 1) ~= "!" and not to_bot then
			return false
		end
		local name, arg = text:match("^!(%a+)%s*(.-)%s*$")
		if to_bot and not name then
			name, arg = text:match("^!?(%a+)%s*(.-)%s*$") -- to the bot, "top" is "!top"
		end
		local command = name and commands[name:lower()]
		if not command then
			if to_bot then
				name, command, arg = "help", commands.help, "" -- the bot answers anything it does not know with the list
			else
				return false -- "!!!" and the like are just chat
			end
		end
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
			if line.send then
				line.send:transmit(line.to)
			elseif line.session then
				for _, client in pairs(line.session.clients) do
					local their = client.chat_lang or lang
					local texts = (their == "ru" or their == "uk") and TEXTS.ru or TEXTS.en
					xpackage(line[1], bot and bot.id or 0, client.id)
						:write("s", prefix:gsub("%a%a\7$", their .. "\7") .. TAG .. texts[line.key]:format(unpack(line.args)))
						:transmit(client)
				end
			else
				xpackage(line[1], bot and bot.id or 0, remote.id)
					:write("s", prefix .. line[2])
					:transmit(remote)
			end
		end
		return true
	end,
}

if config then
	log("info", "chat commands on, ladder %s", tostring(config.ladder))
else
	log("info", "disabled")
end

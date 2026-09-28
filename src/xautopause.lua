require "xlog"
require "xconfig"
require "xsocket"
require "xconst"
require "xrecord"
require "xcommands"

-- The automatic pause: a player whose game stops taking the match (a network
-- that stalls, a game that freezes) gets the match paused until they are back.
--
-- The host streams the match to every player all the time (several packets a
-- second), so a player's system acknowledges data all the time too. When a
-- player has data waiting for an acknowledgement and none has come for
-- `stall` seconds, the player is stalled: the server asks the host for a pause
-- as that player (the host takes a pause record only from a player of its
-- room), and tells the room. When the acknowledgements flow again for
-- `resume` seconds, or after `max` seconds, it asks for the match to go on.
-- The pause is a toggle and players press it too: the server follows the
-- host's state (xcommands.host_record) and leaves a pause the players ended.
--
-- config.store:
--   autopause = {
--     stall = 4,        -- seconds without an acknowledgement
--     resume = 2,       -- seconds a player must be back
--     max = 120,        -- the longest automatic pause
--     per_player = 3,   -- automatic pauses a player may get in a match
--   },
--
-- The acknowledgements come from the system: `ss -tin` (iproute2) for the
-- lobby port, once a second while a match of two players or more runs.

local log = xlog("xautopause")

local config = xconfig.autopause
local STALL = config and config.stall or 4
local RESUME = config and config.resume or 2
local MAX = config and config.max or 120
local PER_PLAYER = config and config.per_player or 3
local PORT = xconfig.port or 31523

-- "1.2.3.4:5678" / "[::ffff:1.2.3.4]:5678" -> "1.2.3.4:5678"
local function address(text)
	local host, port = text:match("^%[(.*)%]:(%d+)$")
	if not host then
		host, port = text:match("^(.*):(%d+)$")
	end
	if not host then
		return nil
	end
	return host:gsub("^::ffff:", "") .. ":" .. port
end

-- {peer address: {lastack = ms, unacked = packets}} for the lobby port's connections
local function tcp_state()
	local out = {}
	local pipe = io.popen(("ss -tinH state established '( sport = :%d )' 2>/dev/null"):format(PORT))
	if not pipe then
		return out
	end
	local peer
	for line in pipe:lines() do
		if line:match("^%s") then
			if peer then
				out[peer] = {
					lastack = tonumber(line:match("lastack:(%d+)")),
					unacked = tonumber(line:match("unacked:(%d+)")) or 0,
				}
			end
		else
			-- Recv-Q Send-Q Local Peer
			local fields = {}
			for word in line:gmatch("%S+") do
				table.insert(fields, word)
			end
			peer = fields[4] and address(fields[4])
		end
	end
	pipe:close()
	return out
end

local function peer_of(client)
	return client.host and client.port and (client.host .. ":" .. client.port)
end

local function players(session)
	local n = 0
	for _, client in pairs(session.clients) do
		if client.cid ~= xconst.spectator_countryid then
			n = n + 1
		end
	end
	return n
end

-- started matches with two players or more (the only ones a server pause can reach), and any
-- with an automatic pause on (the stalled player may have left since)
local function matches()
	local out = {}
	for _, server in pairs(servers or {}) do
		for _, session in pairs(server.sessions) do
			if session.locked and not session.closed and (players(session) >= 2 or session.autopause) then
				table.insert(out, session)
			end
		end
	end
	return out
end

-- a stall: data waits for an acknowledgement, and none came for `stall` seconds (lastack is
-- missing on a connection that has never been acknowledged)
local function stalled(state)
	return state ~= nil and state.unacked > 0 and (state.lastack or math.huge) >= STALL * 1000
end

local function flowing(state)
	return state ~= nil and (state.unacked == 0 or (state.lastack or math.huge) < 1000)
end

local function start(session, client, now)
	session.autopauses = session.autopauses or {}
	session.autopauses[client.id] = (session.autopauses[client.id] or 0) + 1
	client.stall_seen = true -- one pause for one stall
	local nick = client.nickname or "?"
	if not xcommands.send_pause(session, true, client.id) then
		return
	end
	session.autopause = {id = client.id, nick = nick, since = now}
	xrecord.marker(session, {ev = "autopause", id = client.id})
	log("info", "%s stalled: pause asked in %s", nick, session.real_name or "?")
	xcommands.say(session, "autopause", nick, MAX)
end

-- the pause ends: resume it if the host says it is on and the server may still send to it
local function finish(session, key, ...)
	local ap = session.autopause
	session.autopause = nil
	local resumed, was_paused = true, session.paused
	if session.paused then
		local client = session.clients[ap.id]
		local from = client and client.id or xcommands.record_sender(session, session.clients[session.master_id] or {})
		resumed = xcommands.send_pause(session, false, from)
	end
	xrecord.marker(session, {ev = "autoresume", id = ap.id, why = key})
	log("info", "%s: %s in %s (the host's pause %s, resume %s)", ap.nick, key, session.real_name or "?",
		was_paused and "on" or "off", was_paused and (resumed and "asked" or "cannot be asked") or "not needed")
	if key == "autogone" and not resumed then
		key = "autogone_key" -- the host is alone now: only its pause key resumes
	end
	xcommands.say(session, key, ...)
end

local check_session

local function check(session, tcp, now)
	-- one check of a room at a time: a check that sends may wait on a socket past the next tick
	if session.autopause_busy and now - session.autopause_busy < 10 then
		return
	end
	session.autopause_busy = now
	check_session(session, tcp, now)
	session.autopause_busy = nil
end

check_session = function (session, tcp, now)
	local ap = session.autopause
	if ap then
		local client = session.clients[ap.id]
		if not client then
			return finish(session, "autogone", ap.nick)
		end
		if session.paused then
			ap.confirmed = true
		elseif ap.confirmed then
			session.autopause = nil -- the players resumed it themselves: leave it
			return
		end
		if flowing(tcp[peer_of(client)]) then
			ap.back = ap.back or now
		else
			ap.back = nil
		end
		if ap.back and now - ap.back >= RESUME then
			return finish(session, "autoresume", ap.nick)
		elseif now - ap.since >= MAX then
			return finish(session, "autotimeout", ap.nick, MAX)
		end
		return
	end
	for id, client in pairs(session.clients) do
		if id ~= session.master_id and client.cid ~= xconst.spectator_countryid then
			local state = tcp[peer_of(client)]
			if not stalled(state) then
				client.stall_seen = nil
			elseif not client.stall_seen and not session.paused
				and ((session.autopauses or {})[id] or 0) < PER_PLAYER then
				return start(session, client, now)
			end
		end
	end
end

xautopause =
{
	enabled = (config ~= nil),
	-- for tests
	address = address,
	stalled = stalled,
	flowing = flowing,
}

if config then
	log("info", "on: stall %d s, resume %d s, max %d s, %d a player", STALL, RESUME, MAX, PER_PLAYER)
	xsocket.spawn(
		function ()
			while true do
				xsocket.sleep(1.0)
				local sessions = matches()
				if #sessions > 0 then
					local ok, tcp = pcall(tcp_state)
					if ok then
						local now = xsocket.gettime()
						for _, session in ipairs(sessions) do
							-- a thread each: a check sends (sending yields), and an error stays in it
							xsocket.spawn(check, session, tcp, now)
						end
					else
						log("error", "ss: %s", tostring(tcp))
					end
				end
			end
		end)
else
	log("info", "disabled")
end

require "xlog"
require "xconfig"
require "xsocket"

-- QLadder: append match events as JSON lines for the ladder web app.
-- Bytes >= 0x80 are written as \u00XX (latin-1), the reader restores
-- the original bytes and decodes them (utf-8 or cp1251).

local log = xlog("xmatchlog")

local path = xconfig.matchlog
local boot = os.time()

local escapes =
{
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encode_string(str)
	return '"' .. str:gsub('[%z\1-\31"\\\128-\255]',
		function (c)
			return escapes[c] or ("\\u%04x"):format(c:byte())
		end) .. '"'
end

local encode

local function encode_table(tbl)
	if tbl[1] ~= nil or next(tbl) == nil then
		local items = {}
		for _, value in ipairs(tbl) do
			table.insert(items, encode(value))
		end
		return "[" .. table.concat(items, ",") .. "]"
	end
	local items = {}
	for key, value in pairs(tbl) do
		table.insert(items, encode_string(tostring(key)) .. ":" .. encode(value))
	end
	return "{" .. table.concat(items, ",") .. "}"
end

encode = function (value)
	local kind = type(value)
	if kind == "string" then
		return encode_string(value)
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end
		return ("%.14g"):format(value)
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "table" then
		return encode_table(value)
	end
	return "null"
end

local function parser_tree(parser)
	local children = {}
	for _, node in parser:pairs() do
		table.insert(children, parser_tree(node))
	end
	return {k = parser.key, v = parser.value, c = children}
end

local function player_info(client)
	return
	{
		id = client.id,
		nick = client.nickname or "",
		cid = client.cid,
		team = client.team,
		color = client.color,
	}
end

xmatchlog =
{
	enabled = (path ~= nil),

	emit = function (event)
		if not path then
			return
		end
		event.boot = boot
		event.t = xsocket.gettime()
		local file, err = io.open(path, "ab")
		if not file then
			return log("error", "can not open %s: %s", path, tostring(err))
		end
		file:write(encode(event), "\n")
		file:close()
	end,

	start = function (session)
		local players = {}
		for _, client in pairs(session.clients) do
			table.insert(players, player_info(client))
		end
		return xmatchlog.emit({
			ev = "start",
			sid = session.session_id,
			room = session.real_name,
			gamename = session.gamename,
			map = session.mapname,
			money = session.money,
			fog = session.fog_of_war,
			bf = session.battlefield,
			max_players = session.max_players,
			master = session.master_id,
			sync = session.last_datasync,
			vcore = session.server.vcore,
			vdata = session.server.vdata,
			players = players,
		})
	end,

	result = function (session, remote, request)
		return xmatchlog.emit({
			ev = "result",
			sid = session.session_id,
			from = remote.id,
			parser_id = request.parser_id,
			parser = parser_tree(request.parser),
		})
	end,

	leave = function (session, remote, is_master)
		return xmatchlog.emit({
			ev = "leave",
			sid = session.session_id,
			id = remote.id,
			nick = remote.nickname or "",
			master = is_master,
		})
	end,

	close = function (session)
		return xmatchlog.emit({
			ev = "close",
			sid = session.session_id,
		})
	end,
}

local function write_status(status_path)
	local online = {}
	local rooms = {}
	for _, server in pairs(servers or {}) do
		for _, client in pairs(server.clients) do
			table.insert(online, {
				id = client.id,
				nick = client.nickname or "",
				room = client.session and client.session.real_name or nil,
			})
		end
		for _, session in pairs(server.sessions) do
			local players = {}
			for _, client in pairs(session.clients) do
				table.insert(players, client.nickname or "")
			end
			table.insert(rooms, {
				name = session.real_name,
				map = session.mapname,
				max_players = session.max_players,
				has_password = (session.real_pass ~= ""),
				playing = session.locked,
				players = players,
			})
		end
	end
	local tmp = status_path .. ".tmp"
	local file = io.open(tmp, "wb")
	if not file then
		return
	end
	file:write(encode({t = xsocket.gettime(), boot = boot, online = online, rooms = rooms}), "\n")
	file:close()
	os.rename(tmp, status_path)
end

if path then
	log("info", "writing match events to %s", path)
	xmatchlog.emit({ev = "boot", version = SICH_VERSION})
end

if xconfig.status then
	log("info", "writing lobby status to %s", xconfig.status)
	xsocket.spawn(
		function ()
			while true do
				local ok, err = pcall(write_status, xconfig.status)
				if not ok then
					log("error", "status: %s", tostring(err))
				end
				xsocket.sleep(5.0)
			end
		end)
end

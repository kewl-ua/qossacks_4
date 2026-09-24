require "xlog"
require "xconfig"
require "xsocket"
require "xconst"
require "xmatchlog"

-- QLadder: server-side match recording.
-- Every packet a room member sends while in the room (settings, room chat,
-- the in-game command stream) is appended to <recordings>/<boot>_<sid>.rec.
-- Rooms that never start a match are discarded.
--
-- File: "QLREC1\n", then records of
--   uint32 ms since the room was created (little endian) + raw Sich packet
--   (uint32 payload length, uint16 code, uint32 from, uint32 to, payload).
-- Markers use code 0xFFFF with a JSON payload (join, leave, lock, master...).

local log = xlog("xrecord")

local dir = xconfig.recordings
local MARKER = 0xFFFF
-- private messages between players are not part of a match
local SKIP = { [xcmd.SERVER_MESSAGE] = true }

local function u32(n)
	n = math.floor(n)
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function u16(n)
	return string.char(n % 256, math.floor(n / 256) % 256)
end

local function stamp(session)
	return u32(math.max(0, (xsocket.gettime() - session.rec_t0) * 1000))
end

xrecord =
{
	open = function (session)
		if not dir then
			return
		end
		session.rec_name = ("%d_%d.rec"):format(xmatchlog.boot, session.session_id)
		local file, err = io.open(dir .. "/" .. session.rec_name .. ".part", "wb")
		if not file then
			return log("error", "can not open recording: %s", tostring(err))
		end
		file:setvbuf("full", 64 * 1024)
		file:write("QLREC1\n")
		session.rec_file = file
		session.rec_t0 = xsocket.gettime()
	end,

	packet = function (session, packet)
		local file = session and session.rec_file
		if not file or SKIP[packet.code] then
			return
		end
		file:write(stamp(session), packet:get())
	end,

	marker = function (session, data)
		local file = session and session.rec_file
		if not file then
			return
		end
		local payload = xmatchlog.encode(data)
		file:write(stamp(session), u32(#payload), u16(MARKER), u32(data.id or 0), u32(0), payload)
	end,

	finish = function (session)
		local file = session.rec_file
		if not file then
			return
		end
		session.rec_file = nil
		file:close()
		local part = dir .. "/" .. session.rec_name .. ".part"
		if not session.locked then
			os.remove(part)
			return
		end
		os.rename(part, dir .. "/" .. session.rec_name)
		log("info", "recorded %s", session.rec_name)
		xmatchlog.emit({ev = "recording", sid = session.session_id, file = session.rec_name})
	end,
}

if dir then
	log("info", "recording matches to %s", dir)
else
	log("info", "disabled")
end

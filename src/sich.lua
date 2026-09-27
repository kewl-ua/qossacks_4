require "xversion"
require "xlog"
require "xconfig"
require "xserver"
require "xsocket"
require "xadmin"
require "xapi"
require "xecho"

local log = xlog("sich")

local host = xconfig.host or "*"
local port = xconfig.port or 31523

local server_socket = assert(xsocket.tcp())
assert(server_socket:bind(host, port))
assert(server_socket:listen(32))
log("info", "listening at %s", tostring(server_socket))

-- QLadder: a game that goes away without closing its connection (a crash, a lost network)
-- stayed in the lobby and its room for hours. TCP keepalive finds it: after 60 s without
-- traffic the system probes the peer every 15 s and drops the connection after 4 unanswered
-- probes, about 2 minutes. The probes are TCP's own: a live game answers without knowing.
local KEEPALIVE = {idle = 60, interval = 15, count = 4}

local function keepalive(client)
	pcall(function ()
		client:setoption("keepalive", true)
		client:setoption("tcp-keepidle", KEEPALIVE.idle)
		client:setoption("tcp-keepintvl", KEEPALIVE.interval)
		client:setoption("tcp-keepcnt", KEEPALIVE.count)
	end)
	return client
end

xsocket.spawn(
	function ()
		while true do
			xsocket.spawn(xserver, keepalive(assert(server_socket:accept())))
		end
	end)

xsocket.loop()

# qossacks_4

A lobby server for **Cossacks 3**: a fork of [Sich](https://github.com/3skcassoc/sich)
v0.2.9 by 3skcassoc, extended for a ladder site. It runs
[QLadder](https://qladder.com).

Everything Sich does works as before, and the players need nothing but the
stock game. Each addition is off until its option is set in `config.store`.

| Option | What it does |
|---|---|
| `matchlog = "/path/matches.jsonl"` | Lobby and match events as JSON lines: matches with players, nations, teams and room settings; results; leavers; accounts (no passwords or cd keys). |
| `status = "/path/status.json"` | Who is online and which rooms exist, rewritten every 5 s. |
| `recordings = "/path/dir"` | Every packet of every started room, in the QLREC1 format; packets Sich cannot handle go to `unhandled_<boot>.rec`. Private messages are never recorded. |
| `api = { port = 31524, token = "<32+ characters>" }` | A local line protocol to create accounts and reset passwords from a website. Listens on 127.0.0.1 unless `api.host` says otherwise. |

Other changes:

- Teams come from the room datasync: the lock packet only has a lobby
  placeholder (13 for the room's creator).
- Reports of a statistics mod (LAN parser 7700) are recorded and never
  relayed to the players.
- `PING` from clients is kept as their ping time.

The protocol, the room data and the match stream these features read are
documented in [cossacks_3_net_spec](https://github.com/kewl-ua/cossacks_3_net_spec),
with a Python parser for the recordings.

The upstream instructions follow; they apply unchanged.

## Server

To run Sich you need to install Lua 5.1 and LuaSocket library:

* **Debian**: `apt-get install lua5.1 lua-socket`

* **Windows**: download and install [LuaForWindows](https://github.com/rjpcomputing/luaforwindows/releases/latest)

Next, download [sich.lua](../../raw/main/release/sich.lua).
If you want to change default options (host, port, etc.) download and edit [config.store](../../raw/main/release/config.store).

To start:

* **Debian**: `lua sich.lua`

* **Windows**: double click on file `sich.lua`

## Client

* Open `<Cossacks 3>/data/resources/servers.dat` in text editor.

* Remove or comment out official servers, add new one.

* Restart game.

## Tools

* [C3 Servers](../../raw/main/tools/c3servers.wlua)

* [Protocol Dissector for Wireshark](../../raw/main/tools/cossacks3dissector.lua)

## License

* [WTFPL](../../raw/main/LICENSE), as upstream.

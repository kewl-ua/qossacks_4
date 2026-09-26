# qossacks_4 architecture

How the server is put together, what happens to a packet, and what a match
leaves behind. The protocol itself (frames, messages, the match stream) is in
[cossacks_3_net_spec](https://github.com/kewl-ua/cossacks_3_net_spec).

- [1. Overview](#1-overview)
- [2. Modules](#2-modules)
- [3. The path of a packet](#3-the-path-of-a-packet)
- [4. A match, and what it leaves behind](#4-a-match-and-what-it-leaves-behind)
- [5. Accounts](#5-accounts)
- [6. Saving the account store](#6-saving-the-account-store)
- [7. Files and events](#7-files-and-events)

## 1. Overview

```mermaid
flowchart LR
    P1["Cossacks 3<br/>(a player)"] <-->|"TCP 31523"| CORE
    P2["Cossacks 3<br/>(the host)"] <-->|"TCP 31523"| CORE
    subgraph Q["qossacks_4"]
        CORE["lobby core<br/>(Sich)"]
        LOG["xmatchlog"]
        REC["xrecord"]
        API["xapi"]
        CORE --> LOG
        CORE --> REC
        API --> CORE
    end
    LOG --> J[("matches.jsonl")]
    LOG --> S[("status.json")]
    REC --> R[("recordings/*.rec")]
    W["a website"] -->|"127.0.0.1:31524"| API
    J -.-> W
    S -.-> W
    R -.-> W
```

- The players' games connect to the lobby core, as to any Sich server. There
  is no traffic between the players: the server relays everything in a room.
- The additions only watch and write files, except `xapi`, which a website
  on the same machine uses to create accounts and set passwords.
- Every addition is off until its option is set in `config.store`.

## 2. Modules

```mermaid
flowchart LR
    subgraph up["from Sich v0.2.9"]
        direction TB
        MAIN["sich.lua<br/>start-up"] --> SERVER["xserver<br/>connections, login, lobby"]
        SERVER --> SESSION["xsession<br/>rooms"]
        SERVER --> PACKET["xpacket, xpack, xparser<br/>frames, values, parser trees"]
        SERVER --> REGISTER["xregister<br/>accounts"]
        REGISTER --> STORE["xstore<br/>*.store files"]
    end
    subgraph ours["added in qossacks_4"]
        direction TB
        MATCHLOG["xmatchlog<br/>events, status"]
        RECORD["xrecord<br/>recordings"]
        APIM["xapi<br/>local account API"]
    end
    SERVER --> MATCHLOG
    SERVER --> RECORD
    SESSION --> MATCHLOG
    SESSION --> RECORD
    MAIN --> APIM
    APIM --> REGISTER
    APIM --> MATCHLOG
    classDef add fill:#3b2f16,stroke:#d9a441,color:#f2e6c9
    class MATCHLOG,RECORD,APIM add
```

Not drawn: `xclient` and `xclients` (players, broadcast), `xconfig`
(`config.store`), `xsocket` (coroutines, sockets), `xlog`, and the upstream
extras `xadmin`, `xecho`, `xhard`.

Changed upstream modules:

| Module | Change |
|---|---|
| `xserver` | hooks for the log and the recorder; `PING` kept; mod reports dropped; `accounts.managed`; no password in the reminder log |
| `xsession` | hooks; the team from the room datasync |
| `xstore` | atomic save (6) |
| `sich.lua` | starts `xapi` |

## 3. The path of a packet

```mermaid
flowchart TD
    IN(["a frame from a player"]) --> REC{"in a room<br/>with a recording?"}
    REC -->|yes| APPEND["xrecord: append it<br/>(not private messages)"]
    REC -->|no| CODE
    APPEND --> CODE{"code"}
    CODE -->|"0x0190–0x01F4<br/>lobby messages"| PROC["the server handles it:<br/>login, rooms, chat, results"]
    PROC --> KNOWN{"handled?"}
    KNOWN -->|no| UNH["xrecord: unhandled_*.rec"]
    KNOWN -->|yes| DONE(["done"])
    CODE -->|"other codes<br/>(LAN_*: game traffic)"| ROOM{"in a room?"}
    ROOM -->|no| DROP(["dropped"])
    ROOM -->|yes| MOD{"LAN_PARSER 7700<br/>(a mod report)?"}
    MOD -->|yes| DROP2(["kept in the recording,<br/>never relayed"])
    MOD -->|no| RES{"LAN_PARSER 13 / 11<br/>(results)?"}
    RES -->|yes| LOGR["xmatchlog: result"] --> RELAY
    RES -->|no| RELAY["relay: to id_to,<br/>or to everyone else in the room"]
```

The match stream (`0x04B0 LAN_RECORD`) takes the relay path: the host sends
it, the server passes it to the other players and keeps a copy in the
recording.

## 4. A match, and what it leaves behind

```mermaid
sequenceDiagram
    autonumber
    participant M as master (host)
    participant P as another player
    participant Q as qossacks_4
    participant F as files
    M->>Q: SERVER_SESSION_CREATE
    Q->>F: recordings/‹boot›_‹room›.rec.part (marker "create")
    P->>Q: SERVER_SESSION_JOIN
    Q->>F: marker "join"
    M->>Q: SERVER_SESSION_PARSER 100 (room datasync)
    Note over Q: keeps nations, colours, teams
    M->>Q: SERVER_SESSION_LOCK
    Q->>F: matches.jsonl: "start" (players, settings), marker "lock"
    loop the match
        M->>Q: LAN_RECORD (the host's stream)
        Q->>P: relayed
        Q->>F: appended to the recording
    end
    M->>Q: LAN_PARSER 13 (results)
    Q->>F: matches.jsonl: "result"
    M->>Q: SERVER_SESSION_CLSCORE (per player)
    Q->>F: matches.jsonl: "score"
    M->>Q: SERVER_SESSION_CLOSE
    Q->>F: matches.jsonl: "close"
    P->>Q: SERVER_SESSION_LEAVE
    M->>Q: SERVER_SESSION_LEAVE (the last one)
    Q->>F: rename .rec.part → .rec, matches.jsonl: "recording"
```

- A player who leaves a started match is logged as `leave`. If it is the
  master, the server picks a new one and sends it `USER_SESSION_RECREATE`
  (upstream Sich): the match goes on with a new host.
- The recording of a room that never started is deleted:

```mermaid
stateDiagram-v2
    [*] --> Part: the room is created
    Part: ‹boot›_‹room›.rec.part
    note right of Part: the room members' frames are appended
    Part --> Rec: the last member left, after the start
    Part --> Deleted: the last member left, never started
    Rec: ‹boot›_‹room›.rec
    Rec --> [*]
    Deleted --> [*]
```

## 5. Accounts

With `accounts.managed`, accounts and passwords come only from the website,
through `xapi`:

```mermaid
sequenceDiagram
    participant W as website
    participant A as xapi (127.0.0.1)
    participant Q as qossacks_4
    participant G as the game
    W->>A: TOKEN, create, e-mail, nickname, password, Steam id
    A->>Q: new account → register.store
    A-->>W: ok, id
    Note over W: shows the generated password to its owner
    G->>Q: SERVER_AUTHENTICATE (e-mail, password)
    Q-->>G: USER_AUTHENTICATE, error 0: logged in
    G->>Q: SERVER_REGISTER (a new account from the game)
    Q-->>G: USER_REGISTER, error 6 ("Incorrect registration data")
    G->>Q: SERVER_UPDATE_INFO with another password
    Note over Q: keeps its password
    Q-->>G: USER_MESSAGE accounts.message
    W->>A: TOKEN, passwd, id, new password
    A->>Q: store it, and in the online client too
```

Without `accounts.managed` the game registers and changes passwords as in
Sich.

## 6. Saving the account store

```mermaid
flowchart LR
    A["serialize the accounts"] --> B["write register.store.tmp"]
    B --> C{"written and closed?"}
    C -->|no| E["log the error,<br/>remove the .tmp,<br/>the old store stays"]
    C -->|yes| D{"rename over<br/>register.store"}
    D -->|ok| OK(["saved"])
    D -->|"fails (Windows)"| F["remove the old store,<br/>rename again"] --> OK
```

A crash or a full disk in the middle of a save leaves either the old store or
the new one, never half of it. Upstream Sich rewrote the file in place.

## 7. Files and events

| Option | File | Content |
|---|---|---|
| `matchlog` | one JSON object per line | the events below |
| `status` | JSON, rewritten every 5 s | online players (with their address, not published), rooms, clients per game version |
| `recordings` | `<boot>_<room>.rec` | QLREC1: timestamped raw frames of a started room, plus JSON markers (`create`, `join`, `leave`, `lock`, `master`, `close`) |
| `recordings` | `unhandled_<boot>.rec` | frames the server could not parse or handle, same format |

`matchlog` events (`ev`):

| Event | When |
|---|---|
| `boot` | the server starts (with its version) |
| `account` | at boot for every account, on register, login and profile update (never a password or cd key) |
| `start` | a room is locked: players (nation, colour, team), the room's lobby entry and datasync, the game version |
| `result` | the host reports results (parser 13) or a surrender is confirmed (11) |
| `score` | `SERVER_SESSION_CLSCORE`: a result code per player |
| `leave` | a player leaves a started match |
| `close` | the host closes the match |
| `recording` | a recording is complete |

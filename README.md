# lsbridge

An [Ashita v4](https://www.ashitaxi.com/) addon that bridges **two FFXI linkshells ↔ Discord**, two ways, using simple file-based IPC.

Built for HorizonXI. Pairs with the [ffxi-jarvis](https://github.com/TreeFidyDad/ffxi-jarvis) Discord bot, which polls/writes the same files and relays each linkshell to its own Discord channel.

## How it works

```
FFXI (Ashita)  --append-->  ffxi_to_discord.txt  --poll-->  Discord bot  -->  #ls1 / #ls2
   ^                                                                              |
   |  <--/l or /l2 [Discord]--  discord_to_ffxi.txt  <--append--  Discord bot  <--
```

- The addon listens to `text_in`, tags each linkshell message with its source
  (`LS1` or `LS2`) and writes it to `ffxi_to_discord.txt` as `LS1|name|message`.
- It polls `discord_to_ffxi.txt` (lines `LS1|user|message`) and re-broadcasts new
  Discord messages into the matching linkshell via `/l` (LS1) or `/l2` (LS2),
  prefixed with `[Discord]`.
- Messages containing `[Discord]` are skipped on the FFXI side to prevent loops.

## Install

1. Copy the `lsbridge` folder into your Ashita `addons` directory, e.g.
   `...\HorizonXI\Game\addons\lsbridge\lsbridge.lua`
2. Edit `DATA_DIR` near the top of `lsbridge.lua` to point at the shared IPC folder used by the
   [ffxi-jarvis](https://github.com/TreeFidyDad/ffxi-jarvis) bot (`<bot>\data`).
3. In the bot, set `BRIDGE_CHANNEL_ID` (LS1) and optionally `BRIDGE_CHANNEL_ID_2` (LS2) in `.env`.
4. In game: `/addon load lsbridge`

## Commands

`/lsbridge [subcommand]`

| Subcommand | Description |
|------------|-------------|
| `status`   | Show enabled state, per-LS on/off, modes, poll interval |
| `on` / `off` | Enable / disable the whole bridge |
| `ls1`      | Toggle LS1 bridging on/off (chat modes 6 = self, 14 = others) |
| `ls2`      | Toggle LS2 bridging on/off (chat modes 27 = self, 15 = others, assumed) |
| `test [ls2]` | Write a test line to the Discord file (LS1, or LS2 if `ls2` given) |
| `say`      | Toggle how Discord messages appear in game: local native-looking lines (only you) vs broadcast to the whole LS via `/l` |
| `window`   | Toggle the ImGui Discord chat window |
| `clear`    | Clear both IPC files |
| `clearchat`| Clear the Discord chat window history |
| `debug`    | Toggle printing every `text_in` mode to the console |
| `logmode`  | Toggle logging every `text_in` mode to `modes_debug.txt` |
| `pktscan`  | Toggle a summary scan of incoming packet ids (find the online-members packet — see below) |
| `pktdump <0xID\|all\|names\|group\|off>` | Hex+ASCII dump packets to `packets_debug.txt`: a single id, `all` (everything except position/entity noise), `names` (only name-bearing packets, skipping known noise), `group` (only the party/group/linkshell-structure packets — best for finding the roster), or `off` |

## Detecting online linkshell members

The rich in-game **Linkshell** window (every online member with their main job and
current zone) is a **HorizonXI custom feature** — retail FFXI has no packet that lists
the whole online roster, and there's no published packet id for Horizon's version. So
the addon can't read it out of the box; the packet has to be identified live, then
parsed.

The addon ships read-only diagnostics to do that (they never block or modify
packets, and are off by default).

**What we've ruled out so far:**

- Opening the Linkshell window sends **no packet** (the client already has the data cached).
- **Zoning** doesn't deliver a roster.
- The **Ashita v4 SDK exposes no linkshell roster in memory** — its memory manager only
  offers party/alliance (up to 18 members), entities, player, target and inventory. (An
  entity-table scan matching your own `LinkshellColor` can find LS members *in your current
  zone*, but not those elsewhere.)
- No installed HorizonXI addon (HXUI, xiui, etc.) implements the window — it's compiled into
  the custom client, fed by a packet no addon handles.
- Earlier "name" leads were red herrings: `0x070` is a **crafting result** (a nearby player's
  synthesis), and `0x041` is the **blacklist** packet — neither is linkshell data.

**Leading theory (from packet reverse-engineering docs):** retail's group-list packets
**`0x0DD` (GP_SERV_GROUP_LIST)** and **`0x0E2` (GROUP_LIST2)** carry, per member, a name
(offset `0x28`), zone (`0x20`), main job/level (`0x22`/`0x23`) **and a "Kind" byte at `0x1C`**.
`Kind == 0` is your party/alliance; a **non-zero Kind** is the strongest suspect for how
HorizonXI pushes the online linkshell roster (reusing the existing client handler). Those
packets arrive **at login**.

**Recommended workflow — `group` mode across a relog:**

1. `/lsbridge pktdump group` — dumps only the party/group/linkshell family
   (`0x0C8/0x0DD/0x0DF/0x0E0/0x0E1/0x0E2`).
2. **Log out to character select and back in** with your LS pearl equipped (do this while LS
   members who are **not** in your party are online), then play briefly.
3. `/lsbridge pktdump off` — stop.
4. In `packets_debug.txt`, look at each `0x0DD`/`0x0E2` entry's byte `0x1C` (**Kind**): any
   entry with a non-zero Kind is an online member that isn't your party — i.e. the roster.
   Its name (`0x28`), zone (`0x20`) and job (`0x22`) decode the rest.

Other tools:

- `/lsbridge pktdump names` — dump only packets with player-name-like text (skips the party
  family, so it will *not* catch a `0x0DD`-based roster; use `group` for that).
- `/lsbridge pktdump all` — dump every packet except high-volume noise (full login/zone burst).
- `/lsbridge pktscan` (start → relog → stop) — lists which packet ids appear; watch for any id
  **above `0x11E`**, which would be a genuinely custom HorizonXI packet.
- `/lsbridge pktdump 0xNNN` — dump a single suspected id.

Once the id and field offsets are known, that packet can be parsed into a table and
shown in an on-screen list (and optionally pushed to Discord). Note HorizonXI's
[addon policy](https://www.horizonxi.com/addons/) requires custom addons to be
published/approved for general use.

## Chat modes (HorizonXI)

Your own and other players' linkshell messages arrive on **different** `text_in` mode numbers:

- **LS1:** `6` = your own messages, `14` = everyone else.

If messages from others don't relay on your server, run `/lsbridge logmode`, have someone talk in
LS, and check `modes_debug.txt` to find the correct mode numbers.

## License

MIT

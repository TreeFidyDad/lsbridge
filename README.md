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
| `clear`    | Clear both IPC files |
| `debug`    | Toggle printing every `text_in` mode to the console |
| `logmode`  | Toggle logging every `text_in` mode to `modes_debug.txt` |

## Chat modes (HorizonXI)

Your own and other players' linkshell messages arrive on **different** `text_in` mode numbers:

- **LS1:** `6` = your own messages, `14` = everyone else.

If messages from others don't relay on your server, run `/lsbridge logmode`, have someone talk in
LS, and check `modes_debug.txt` to find the correct mode numbers.

## License

MIT

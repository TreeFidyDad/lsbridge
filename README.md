# lsbridge

An [Ashita v4](https://www.ashitaxi.com/) addon that bridges **FFXI linkshell chat ↔ Discord**, two ways, using simple file-based IPC.

Built for HorizonXI. Pairs with the [ffxi-jarvis](https://github.com/TreeFidyDad/ffxi-jarvis) Discord bot, which polls/writes the same files and relays to a Discord channel.

## How it works

```
FFXI (Ashita)  --append-->  ffxi_to_discord.txt  --poll-->  Discord bot  -->  #channel
   ^                                                                              |
   |  <--/l [Discord] ...--  discord_to_ffxi.txt  <--append--  Discord bot  <-----
```

- The addon listens to `text_in` and writes linkshell messages to `ffxi_to_discord.txt`.
- It polls `discord_to_ffxi.txt` and re-sends new Discord messages into the linkshell via `/l [Discord] <name>: <msg>`.
- Messages containing `[Discord]` are skipped on the FFXI side to prevent loops.

## Install

1. Copy the `lsbridge` folder into your Ashita `addons` directory, e.g.
   `...\HorizonXI\Game\addons\lsbridge\lsbridge.lua`
2. Edit `DATA_DIR` near the top of `lsbridge.lua` to point at the shared IPC folder used by the
   [ffxi-jarvis](https://github.com/TreeFidyDad/ffxi-jarvis) bot (`<bot>\data`).
3. In game: `/addon load lsbridge`

## Commands

`/lsbridge [subcommand]`

| Subcommand | Description |
|------------|-------------|
| `status`   | Show enabled state, active LS modes, poll interval |
| `on` / `off` | Enable / disable relaying |
| `ls1`      | Bridge LS1 (chat modes 6 = self, 14 = others) |
| `ls2`      | Bridge LS2 (chat modes 27 = self, 15 = others, assumed) |
| `test`     | Write a test line to the Discord file |
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

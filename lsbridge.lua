addon.name    = 'lsbridge'
addon.author  = 'TreeFidyDad'
addon.version = '1.1'
addon.desc    = 'Two linkshell <-> Discord bridge via file IPC with Jarvis bot.'
addon.link    = 'https://github.com/TreeFidyDad/lsbridge'

require('common')

------------------------------------------------------------
-- Config
------------------------------------------------------------
local DATA_DIR = 'C:\\Users\\Blake\\ffxi-jarvis\\data'
local FFXI_TO_DISCORD = DATA_DIR .. '\\ffxi_to_discord.txt'
local DISCORD_TO_FFXI = DATA_DIR .. '\\discord_to_ffxi.txt'
local DEBUG_LOG = DATA_DIR .. '\\modes_debug.txt'

-- Map each text_in chat mode to which linkshell it belongs to.
-- Your own messages and other players' messages use different mode numbers.
--   LS1 on HorizonXI: 6 = self, 14 = others (confirmed via mode logging).
--   LS2 on HorizonXI: 27 = self, 15 = others (BEST GUESS - verify with /lsbridge logmode).
local MODE_TO_LS = {
    [6]  = 'LS1',
    [14] = 'LS1',
    [27] = 'LS2',
    [15] = 'LS2',
}
-- The slash command used to broadcast back into each linkshell.
local LS_SEND_CMD = {
    LS1 = '/l',
    LS2 = '/l2',
}
local POLL_INTERVAL = 1.0  -- seconds between file checks

------------------------------------------------------------
-- State
------------------------------------------------------------
local lastPoll = 0
local enabled = true
-- Per-linkshell enable toggle (both on by default).
local enabledLS = { LS1 = true, LS2 = true }
local lastFileSize = 0

------------------------------------------------------------
-- Write FFXI linkshell message to file for Discord bot.
-- Line format is "LS1|sender|message" so the bot can route per linkshell.
------------------------------------------------------------
local function sendToDiscord(ls, sender, message)
    local f = io.open(FFXI_TO_DISCORD, 'a')
    if f then
        f:write(ls .. '|' .. sender .. '|' .. message .. '\n')
        f:close()
    end
end

------------------------------------------------------------
-- Read Discord messages from file and broadcast into the right linkshell.
-- Line format from the bot is "LS1|username|message".
------------------------------------------------------------
local function pollDiscordMessages()
    local f = io.open(DISCORD_TO_FFXI, 'r')
    if not f then return end
    
    local content = f:read('*a')
    f:close()
    
    if not content or #content == 0 then return end
    if #content == lastFileSize then return end
    
    -- Only read new content
    local newContent = content:sub(lastFileSize + 1)
    lastFileSize = #content
    
    if not newContent or #newContent == 0 then return end
    
    local lines = {}
    for line in newContent:gmatch('[^\n]+') do
        table.insert(lines, line)
    end
    
    for _, line in ipairs(lines) do
        if #line > 0 then
            -- Parse routing tag: "LSx|user|message"
            local ls, rest = line:match('^(LS%d)|(.+)$')
            if not ls then
                ls = 'LS1'      -- backward compatible: untagged -> LS1
                rest = line
            end
            local cmd = LS_SEND_CMD[ls] or '/l'
            -- Send as actual linkshell message so everyone in that LS sees it
            AshitaCore:GetChatManager():QueueCommand(-1, string.format('%s [Discord] %s', cmd, rest))
        end
    end
end

------------------------------------------------------------
-- Clear the discord_to_ffxi file periodically (prevent unbounded growth)
------------------------------------------------------------
local lastClear = os.time()
local function maybeClearFile()
    if os.time() - lastClear > 3600 then  -- every hour
        local f = io.open(DISCORD_TO_FFXI, 'w')
        if f then f:close() end
        lastFileSize = 0
        lastClear = os.time()
    end
end

------------------------------------------------------------
-- Capture linkshell chat from text_in
------------------------------------------------------------
local debugModes = false  -- set true to log all text_in modes to console
local logToFile = false   -- set true (or /lsbridge logmode) to log all text_in modes to modes_debug.txt

local function logMode(mode, text)
    local f = io.open(DEBUG_LOG, 'a')
    if f then
        f:write(string.format('mode=%d | %s\n', mode, text))
        f:close()
    end
end

ashita.events.register('text_in', 'lsbridge_text_cb', function(e)
    if e.injected then return end
    
    local msg = e.message or ''
    -- Strip ALL FFXI color/control codes (more aggressive)
    local clean = msg:gsub('\x1E.', ''):gsub('\x1F.', ''):gsub('\x7F.', ''):gsub('%z', '')
    -- Also strip any remaining non-printable chars
    clean = clean:gsub('[%c]', '')
    if #clean < 2 then return end
    
    -- Diagnostic logging of every mode (helps identify LS modes)
    if logToFile then logMode(e.mode, clean) end
    if debugModes then
        print(string.format('[LSBridge-DBG] mode=%d msg=%.50s', e.mode, clean))
        return
    end
    
    if not enabled then return end
    
    -- Which linkshell did this message come from? (nil = not a bridged LS)
    local ls = MODE_TO_LS[e.mode]
    if not ls then return end
    if not enabledLS[ls] then return end
    
    -- Don't relay messages containing [Discord] (prevents loop)
    if clean:match('%[Discord%]') then return end
    
    -- Parse FFXI LS format: "[1]<CharName> message" or "<CharName> message"
    local sender, text = clean:match('^%[%d+%]<(.-)>%s*(.+)$')
    if not sender then
        sender, text = clean:match('^<(.-)>%s*(.+)$')
    end
    if not sender then
        -- Fallback: try "CharName : message" or just take everything
        sender, text = clean:match('^(.-)%s*:%s*(.+)$')
    end
    if not sender or not text then
        -- Last resort: send the whole line
        sendToDiscord(ls, 'LS', clean)
        return
    end
    
    sendToDiscord(ls, sender, text)
end)

------------------------------------------------------------
-- Poll for Discord messages every frame (throttled)
------------------------------------------------------------
ashita.events.register('d3d_present', 'lsbridge_poll_cb', function()
    if not enabled then return end
    
    local now = os.clock()
    if now - lastPoll < POLL_INTERVAL then return end
    lastPoll = now
    
    pollDiscordMessages()
    maybeClearFile()
end)

------------------------------------------------------------
-- Commands
------------------------------------------------------------
ashita.events.register('command', 'lsbridge_cmd_cb', function(e)
    local args = e.command:args()
    if not args[1] or args[1]:lower() ~= '/lsbridge' then return end
    e.blocked = true
    
    local sub = (args[2] or ''):lower()
    if sub == '' or sub == 'status' then
        local status = enabled and 'ENABLED' or 'DISABLED'
        print(string.format('[LSBridge] Status: %s | Poll: %.1fs', status, POLL_INTERVAL))
        print(string.format('[LSBridge] LS1: %s (modes 6,14)  |  LS2: %s (modes 27,15)',
            enabledLS.LS1 and 'on' or 'off', enabledLS.LS2 and 'on' or 'off'))
        print(string.format('[LSBridge] Files: %s', DATA_DIR))
    elseif sub == 'on' or sub == 'enable' then
        enabled = true
        print('[LSBridge] Bridge enabled.')
    elseif sub == 'off' or sub == 'disable' then
        enabled = false
        print('[LSBridge] Bridge disabled.')
    elseif sub == 'ls1' then
        enabledLS.LS1 = not enabledLS.LS1
        print(string.format('[LSBridge] LS1 bridging: %s', enabledLS.LS1 and 'ON' or 'OFF'))
    elseif sub == 'ls2' then
        enabledLS.LS2 = not enabledLS.LS2
        print(string.format('[LSBridge] LS2 bridging: %s', enabledLS.LS2 and 'ON' or 'OFF'))
    elseif sub == 'test' then
        -- Send a test message to Discord (LS1 by default, or LS2 via "/lsbridge test ls2")
        local ls = ((args[3] or ''):lower() == 'ls2') and 'LS2' or 'LS1'
        sendToDiscord(ls, 'LSBridge', 'Test message from FFXI!')
        print(string.format('[LSBridge] Test message sent to Discord file (%s).', ls))
    elseif sub == 'clear' then
        -- Clear both files
        local f1 = io.open(FFXI_TO_DISCORD, 'w')
        if f1 then f1:close() end
        local f2 = io.open(DISCORD_TO_FFXI, 'w')
        if f2 then f2:close() end
        lastFileSize = 0
        print('[LSBridge] Cleared bridge files.')
    elseif sub == 'debug' then
        debugModes = not debugModes
        print(string.format('[LSBridge] Debug mode (console): %s (say something in LS now)', debugModes and 'ON' or 'OFF'))
    elseif sub == 'logmode' then
        logToFile = not logToFile
        print(string.format('[LSBridge] Mode logging to file: %s -> %s', logToFile and 'ON' or 'OFF', DEBUG_LOG))
    else
        print('[LSBridge] Commands: /lsbridge [status|on|off|ls1|ls2|test [ls2]|clear|debug|logmode]')
    end
end)

------------------------------------------------------------
-- Load / Unload
------------------------------------------------------------
ashita.events.register('load', 'lsbridge_load_cb', function()
    -- Initialize file size tracker
    local f = io.open(DISCORD_TO_FFXI, 'r')
    if f then
        local content = f:read('*a')
        lastFileSize = content and #content or 0
        f:close()
    end
    
    print('[LSBridge] Loaded! Bridging LS1 (6,14) + LS2 (27,15) <-> Discord.')
    print('[LSBridge] Commands: /lsbridge [status|on|off|ls1|ls2|test [ls2]|clear|debug|logmode]')
end)

ashita.events.register('unload', 'lsbridge_unload_cb', function()
    print('[LSBridge] Unloaded.')
end)

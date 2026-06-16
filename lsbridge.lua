addon.name    = 'lsbridge'
addon.author  = 'TreeFidyDad'
addon.version = '1.0'
addon.desc    = 'Linkshell <-> Discord bridge via file IPC with Jarvis bot.'
addon.link    = 'https://github.com/TreeFidyDad/huntpartner'

require('common')

------------------------------------------------------------
-- Config
------------------------------------------------------------
local DATA_DIR = 'C:\\Users\\Blake\\ffxi-jarvis\\data'
local FFXI_TO_DISCORD = DATA_DIR .. '\\ffxi_to_discord.txt'
local DISCORD_TO_FFXI = DATA_DIR .. '\\discord_to_ffxi.txt'
local DEBUG_LOG = DATA_DIR .. '\\modes_debug.txt'

-- Which linkshell modes to bridge. Your own LS messages and other players'
-- incoming LS messages can arrive on different mode numbers, so we capture a set.
-- LS1 on HorizonXI: 6 = self, 14 = others (confirmed via mode logging).
local LS_MODES = { [6] = true, [14] = true }   -- LS1 (self + others)
local LS_MODES_2 = { [27] = true, [15] = true }  -- LS2 (assumed: self 27, others 15)
local POLL_INTERVAL = 1.0  -- seconds between file checks

------------------------------------------------------------
-- State
------------------------------------------------------------
local lastPoll = 0
local enabled = true
local lastFileSize = 0

------------------------------------------------------------
-- Write FFXI linkshell message to file for Discord bot
------------------------------------------------------------
local function sendToDiscord(sender, message)
    local f = io.open(FFXI_TO_DISCORD, 'a')
    if f then
        f:write(sender .. ': ' .. message .. '\n')
        f:close()
    end
end

------------------------------------------------------------
-- Read Discord messages from file and display in FFXI
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
            -- Send as actual linkshell message so everyone in LS sees it
            local cmd = string.format('/l [Discord] %s', line)
            AshitaCore:GetChatManager():QueueCommand(-1, cmd)
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
    
    -- Check if this is a linkshell message (self or others)
    if not LS_MODES[e.mode] then return end
    
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
        sendToDiscord('LS', clean)
        return
    end
    
    sendToDiscord(sender, text)
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
        local modes = {}
        for m in pairs(LS_MODES) do modes[#modes+1] = tostring(m) end
        print(string.format('[LSBridge] Status: %s | LS Modes: %s | Poll: %.1fs', status, table.concat(modes, ','), POLL_INTERVAL))
        print(string.format('[LSBridge] Files: %s', DATA_DIR))
    elseif sub == 'on' or sub == 'enable' then
        enabled = true
        print('[LSBridge] Bridge enabled.')
    elseif sub == 'off' or sub == 'disable' then
        enabled = false
        print('[LSBridge] Bridge disabled.')
    elseif sub == 'ls1' then
        LS_MODES = { [6] = true, [14] = true }
        print('[LSBridge] Now bridging LS1 (modes 6,14).')
    elseif sub == 'ls2' then
        LS_MODES = { [27] = true, [15] = true }
        print('[LSBridge] Now bridging LS2 (modes 27,15).')
    elseif sub == 'test' then
        -- Send a test message to Discord
        sendToDiscord('LSBridge', 'Test message from FFXI!')
        print('[LSBridge] Test message sent to Discord file.')
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
        print('[LSBridge] Commands: /lsbridge [status|on|off|ls1|ls2|test|clear|debug|logmode]')
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
    
    print('[LSBridge] Loaded! Bridging LS1 <-> Discord (modes 6,14).')
    print('[LSBridge] Commands: /lsbridge [status|on|off|ls1|ls2|test|clear|debug|logmode]')
end)

ashita.events.register('unload', 'lsbridge_unload_cb', function()
    print('[LSBridge] Unloaded.')
end)

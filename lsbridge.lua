addon.name    = 'lsbridge'
addon.author  = 'TreeFidyDad'
addon.version = '1.2'
addon.desc    = 'Two linkshell <-> Discord bridge via file IPC with Jarvis bot.'
addon.link    = 'https://github.com/TreeFidyDad/lsbridge'

require('common')
local imgui = require('imgui')

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
-- NOTE: FFXI sometimes ORs high-order bitflags onto the base mode (e.g. 33554446 = 14 + flags).
-- We mask to the lower 8 bits to extract the base chat type.
local BASE_MODE_TO_LS = {
    [6]  = 'LS1',
    [14] = 'LS1',
    [27] = 'LS2',
    [15] = 'LS2',
}
local function modeToLS(mode)
    local base = mode % 256  -- mask to lower 8 bits
    return BASE_MODE_TO_LS[base]
end
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
-- Discord chat window visibility
local showDiscordWindow = { true }
-- Discord message history (ring buffer, max 100 messages)
local discordHistory = {}
local MAX_HISTORY = 100
local scrollToBottom = false

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
-- Read Discord messages from file and show in custom window.
-- Line format from the bot is "LS1|username|message".
------------------------------------------------------------
local function pollDiscordMessages()
    local f = io.open(DISCORD_TO_FFXI, 'r')
    if not f then return end
    
    local content = f:read('*a')
    f:close()
    
    if not content or #content == 0 then return end
    -- File was truncated/cleared (it shrank since our last read) -- e.g. the
    -- hourly clear or a bot restart. Reset the offset so we re-read from the
    -- start instead of slicing past the end (which silently drops messages).
    if #content < lastFileSize then
        lastFileSize = 0
    end
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
                ls = 'LS1'
                rest = line
            end
            -- Add to history (ring buffer)
            table.insert(discordHistory, {
                time = os.date('%H:%M'),
                ls = ls,
                text = rest
            })
            if #discordHistory > MAX_HISTORY then
                table.remove(discordHistory, 1)
            end
            scrollToBottom = true
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
local logToFile = true    -- TEMP: capturing all modes to diagnose missing messages

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
    -- Decode auto-translate tokens into readable text (e.g. "All right!") using
    -- Ashita's chat manager, then strip color/translate control codes. This is
    -- the same approach chatfeed uses. Without this, auto-translate phrases are
    -- opaque tokens that the Discord bot would post as garbage ("??").
    local clean = msg
    local ok = pcall(function()
        clean = AshitaCore:GetChatManager():ParseAutoTranslate(msg, true)
        clean = clean:strip_colors()
        clean = clean:strip_translate(true)
    end)
    if not ok then clean = msg end
    -- Belt-and-suspenders: strip any leftover FFXI control codes / stray bytes.
    clean = clean:gsub('\x1E.', ''):gsub('\x1F.', ''):gsub('\x7F.', ''):gsub('%z', '')
    clean = clean:gsub(string.char(0x07), ' ')
    clean = clean:gsub('[%c]', '')
    -- Drop any remaining non-ASCII bytes that can't survive the trip to Discord.
    clean = clean:gsub('[\128-\255]', '')
    -- Collapse the whitespace any stripped tokens left behind.
    clean = clean:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #clean < 2 then return end
    
    -- Diagnostic logging of every mode (helps identify LS modes)
    if logToFile then logMode(e.mode, clean) end
    if debugModes then
        print(string.format('[LSBridge-DBG] mode=%d msg=%.50s', e.mode, clean))
        return
    end
    
    if not enabled then return end
    
    -- Which linkshell did this message come from? (nil = not a bridged LS)
    -- Use modeToLS() which masks off high-order bitflags.
    local ls = modeToLS(e.mode)
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

    -- Drop messages whose body was entirely auto-translate / non-ASCII and is
    -- now empty after stripping, so we never post a blank/garbled line.
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    if #text == 0 then return end

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
-- ImGui Discord Chat Window
------------------------------------------------------------
ashita.events.register('d3d_present', 'lsbridge_ui_cb', function()
    if not showDiscordWindow[1] then return end
    
    imgui.SetNextWindowSize({ 350, 200 }, ImGuiCond_FirstUseEver)
    if imgui.Begin('Discord Chat', showDiscordWindow, ImGuiWindowFlags_None) then
        -- Chat history area (scrollable)
        local footerHeight = 0
        imgui.BeginChild('ChatHistory', { 0, -footerHeight }, true, ImGuiWindowFlags_None)
        
        for _, msg in ipairs(discordHistory) do
            -- Color by linkshell
            local color = msg.ls == 'LS2' and { 0.6, 0.8, 1.0, 1.0 } or { 0.4, 1.0, 0.6, 1.0 }
            imgui.TextColored(color, string.format('[%s] [%s] %s', msg.time, msg.ls, msg.text))
        end
        
        -- Auto-scroll to bottom on new messages
        if scrollToBottom then
            imgui.SetScrollHereY(1.0)
            scrollToBottom = false
        end
        
        imgui.EndChild()
    end
    imgui.End()
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
    elseif sub == 'window' or sub == 'discord' then
        showDiscordWindow[1] = not showDiscordWindow[1]
        print(string.format('[LSBridge] Discord window: %s', showDiscordWindow[1] and 'SHOWN' or 'HIDDEN'))
    elseif sub == 'clearchat' then
        discordHistory = {}
        print('[LSBridge] Discord chat history cleared.')
    else
        print('[LSBridge] Commands: /lsbridge [status|on|off|ls1|ls2|test [ls2]|clear|debug|logmode|window|clearchat]')
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
    print('[LSBridge] Commands: /lsbridge [status|on|off|ls1|ls2|window|clearchat|test|clear|debug|logmode]')
end)

ashita.events.register('unload', 'lsbridge_unload_cb', function()
    print('[LSBridge] Unloaded.')
end)

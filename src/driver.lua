-- =========================================================
-- NAIM UNITI SERIES — Universal IP Production Driver 
-- Version: v1.29 (CONTENT Restored + Omni-Payload)
-- =========================================================

driver_label = "Naim Uniti Series v1.29"
driver_help = "Universal IP driver for Naim Uniti integrated amplifiers and streamers."

driver_channels = {
    TCP(15081, "192.168.1.100", "Naim API", "Enter the Naim Uniti IP address.", {
        numericArgument("timeBetweenMessages", 5000, 0, 1000000)
    })
}

resource_types = {
    ["Digital Receiver"] = {
        standardResourceType = "RENDERER",
        address = stringArgument("address", "main"),
        events = {},
        queries = {
            LIST_INPUTS = { context_help = "Returns discovered Naim inputs." },
            GET_PLAYQUEUE = { context_help = "Playqueue query." },
            BROWSE_PLAYQUEUE = { context_help = "Playqueue query." },
            LIST_PLAYQUEUE_ITEMS = { context_help = "Playqueue query." },
            BROWSE = { arguments = { stringArgument("id", "") }, context_help = "Browse native content." }
        },
        -- CONTENT CAPABILITY RESTORED
        capabilities = {"POWER", "INPUT", "VOLUME", "PLAYER", "PLAYQUEUE", "CONTENT"},
        commands = {
            TURN_ON = { context_help = "Wake Naim Uniti" },
            STANDBY = { context_help = "System standby" },
            SELECT_INPUT = { arguments = { stringArgument("INPUT", "") } },
            VOLUME_UP = { context_help = "Volume up" },
            VOLUME_DOWN = { context_help = "Volume down" },
            SET_VOLUME = { arguments = { numericArgument("VOLUME", 0, 0, 100) } },
            SET_MUTE = { arguments = { boolArgument("MUTE", false) } },
            PLAY = { context_help = "Play / Resume" },
            PAUSE = { context_help = "Pause" },
            STOP = { context_help = "Stop" },
            NEXT = { context_help = "Next track" },
            PREV = { context_help = "Previous track" },
            _SET_SHUFFLE = { arguments = { boolArgument("_SHUFFLE", false) }, context_help = "Set Shuffle" },
            _SET_REPEAT = { arguments = { stringArgument("_REPEAT", "") }, context_help = "Set Repeat" },
            SET_CONTENT_ID = { arguments = { stringArgument("ID", ""), stringArgument("PROVIDER_TYPE", "dlna") }, context_help = "Play a DLNA stream URL" }
        },
        states = {
            boolArgument("ONLINE", false),
            stringArgument("INPUT", ""),
            numericArgument("VOLUME", 0, 0, 100),
            boolArgument("MUTE", false),
            stringArgument("NOW_PLAYING", ""),
            stringArgument("NOW_PLAYING_DETAILS", ""),
            stringArgument("NOW_PLAYING_ART", ""),
            enumArgument("STATE", {"Play", "Pause", "Stop", "None"}, "Stop"),
            stringArgument("CONTENT_ID", ""),
            numericArgument("PLAYQUEUE_INDEX", -1, -1, 999999),
            stringArgument("PLAYQUEUE_VERSION", "0"),
            boolArgument("_SHUFFLE", false),
            stringArgument("_REPEAT", "")
        }
    }
}

-- =========================================================
-- SECTION 2: GLOBAL MEMORY CACHES & QUERIES
-- =========================================================

local NAIM_PLAYBACK_STATE = "Stop"
local CURRENT_INPUT = ""

local CACHED_PLAYQUEUE = {}
local CACHED_PLAYQUEUE_INDEX = 0

local CACHED_INPUTS = {
    { address = "playqueue", name = "Playqueue / UPnP", type = "internal", capabilities = {"PLAYER", "PLAYQUEUE", "CONTENT"}, providerTypes = {"dlna"} },
    { address = "analog1", name = "Analog 1", type = "internal", capabilities = {"PLAYER"} },
    { address = "spotify", name = "Spotify", type = "internal", capabilities = {"PLAYER", "PLAYQUEUE", "CONTENT"} },
    { address = "tidal", name = "Tidal", type = "internal", capabilities = {"PLAYER", "PLAYQUEUE", "CONTENT"} }
}
local HAS_DISCOVERED_INPUTS = false

local function makeNaim(addr)
    if not addr then return "" end
    if addr == "playqueue" then return "inputs/playqueue" end
    return string.gsub(addr, "_", "/")
end

function query(queryName, resource, queryArgs)
    Trace(">>> INCOMING BLI QUERY: " .. tostring(queryName))
    
    if queryName == "LIST_INPUTS" then
        return { inputs = CACHED_INPUTS }
        
    elseif queryName == "BROWSE" then
        return { items = {} }
        
    elseif queryName == "GET_PLAYQUEUE" or queryName == "LIST_PLAYQUEUE_ITEMS" or queryName == "BROWSE_PLAYQUEUE" then
        Trace(">>> SERVING CACHE: " .. tostring(#CACHED_PLAYQUEUE) .. " items. ACTIVE IDX: " .. tostring(CACHED_PLAYQUEUE_INDEX))
        
        return {
            version = "1",
            total = #CACHED_PLAYQUEUE,
            offset = 0,
            items = CACHED_PLAYQUEUE
        }
    end
end

-- =========================================================
-- SECTION 3: BACKGROUND STATE POLLING
-- =========================================================

function process()
    local naim_ip = channel.attributes("host")
    if not naim_ip or naim_ip == "" then return CONST.HW_ERROR end
    local base_url = "http://" .. naim_ip .. ":15081"
    
    if channel.status() then driver.setOnline() end
    
    while channel.status() do
        channel.read(1)
        
        if not HAS_DISCOVERED_INPUTS then
            local success, msg = urlGet(base_url .. "/inputs")
            if success and msg and msg ~= "" then
                local parsed = jsonToTable(msg)
                if type(parsed) == "table" and type(parsed.children) == "table" then
                    local new_inputs = {}
                    
                    table.insert(new_inputs, { address = "playqueue", name = "Playqueue / UPnP", type = "internal", capabilities = {"PLAYER", "PLAYQUEUE", "CONTENT"}, providerTypes = {"dlna"} })
                    
                    for _, inp in ipairs(parsed.children) do
                        local raw_address = inp.name or "unknown"
                        if raw_address ~= "inputs/playqueue" then
                            local safe_address = string.gsub(raw_address, "/", "_")
                            table.insert(new_inputs, {
                                address = safe_address,
                                name = inp.title or inp.name or "Unknown Input",
                                type = "internal",
                                capabilities = {"PLAYER", "PLAYQUEUE", "CONTENT"}
                            })
                        end
                    end
                    CACHED_INPUTS = new_inputs
                    HAS_DISCOVERED_INPUTS = true
                end
            end
        end
        
        local current_state = NAIM_PLAYBACK_STATE or "Stop"
        local now_playing, now_playing_details, now_playing_art, quality_str = "", "", "", ""
        local active_input_raw, active_input_safe, content_id = "", "", ""
        local current_vol, current_mute, is_shuffle, repeat_str = 0, false, false, "Off"

        local success_vol, msg_vol = urlGet(base_url .. "/levels/room")
        if success_vol and msg_vol ~= "" then
            local vol_parsed = jsonToTable(msg_vol)
            if type(vol_parsed) == "table" then
                current_vol = tonumber(vol_parsed.volume) or 0
                current_mute = (tostring(vol_parsed.mute) == "1")
            end
        end

        local success_np, msg_np = urlGet(base_url .. "/nowplaying")
        if success_np and msg_np ~= "" then
            local np_parsed = jsonToTable(msg_np)
            if type(np_parsed) == "table" then
                active_input_raw = np_parsed.source or np_parsed.input or ""
                active_input_safe = (active_input_raw == "inputs/playqueue") and "playqueue" or string.gsub(active_input_raw, "/", "_") 
                
                local ts = tostring(np_parsed.transportState)
                if ts == "2" then current_state = "Play" elseif ts == "3" then current_state = "Pause" else current_state = "Stop" end
                is_shuffle = (tostring(np_parsed.shuffle) == "1")
                local repeat_raw = tostring(np_parsed["repeat"])
                if repeat_raw == "1" then repeat_str = "One" elseif repeat_raw == "2" then repeat_str = "All" end
                
                local bit_depth = np_parsed.bitDepth or ""
                local sample_rate = np_parsed.sampleRate or ""
                if bit_depth ~= "" and sample_rate ~= "" then
                    local sr_khz = tonumber(sample_rate)
                    if sr_khz then quality_str = bit_depth .. "bit / " .. tostring(sr_khz / 1000) .. "kHz" end
                end
            end
        end
        
        local success_pq, msg_pq = urlGet(base_url .. "/inputs/playqueue")
        if success_pq and msg_pq ~= "" then
            local pq_parsed = jsonToTable(msg_pq)
            if type(pq_parsed) == "table" then
                content_id = pq_parsed.current or ""
                local new_queue = {}
                local new_idx = 0
                
                if type(pq_parsed.children) == "table" then
                    for i, track in ipairs(pq_parsed.children) do
                        local t_name = track.name or "Unknown Track"
                        local t_artist = track.artistName or ""
                        local t_album = track.albumName or ""
                        local t_art = track.artwork or ""
                        
                        -- Replaced em-dash to ensure parsing safety
                        local safe_artist = t_artist
                        if t_artist ~= "" and t_album ~= "" then safe_artist = t_artist .. " - " .. t_album
                        elseif t_album ~= "" then safe_artist = t_album end
                        
                        if track.ussi == content_id then
                            new_idx = i - 1 
                            if quality_str ~= "" then now_playing = t_name .. " [" .. quality_str .. "]" else now_playing = t_name end
                            local details_str = ""
                            if safe_artist ~= "" then details_str = details_str .. "artist:" .. safe_artist end
                            if t_album ~= "" then 
                                if details_str ~= "" then details_str = details_str .. ";" end
                                details_str = details_str .. "album:" .. t_album 
                            end
                            now_playing_details = details_str
                            now_playing_art = t_art
                        end
                        
                        table.insert(new_queue, {
                            id = track.ussi or tostring(i),
                            name = t_name,
                            artist = safe_artist,
                            album = t_album,
                            art = t_art,
                            type = "track",
                            providerType = "uri"
                        })
                    end
                end
                CACHED_PLAYQUEUE = new_queue
                CACHED_PLAYQUEUE_INDEX = new_idx
            end
        end

        NAIM_PLAYBACK_STATE = current_state
        CURRENT_INPUT = active_input_safe
        
        for res in readAllResources("Digital Receiver") do
            setResourceState("Digital Receiver", res.address, {
                ONLINE = true,
                STATE = current_state,
                INPUT = active_input_safe,
                VOLUME = current_vol,
                MUTE = current_mute,
                NOW_PLAYING = now_playing,
                NOW_PLAYING_DETAILS = now_playing_details,
                NOW_PLAYING_ART = now_playing_art,
                CONTENT_ID = content_id,
                PLAYQUEUE_INDEX = CACHED_PLAYQUEUE_INDEX,
                PLAYQUEUE_VERSION = tostring(#CACHED_PLAYQUEUE) .. ":" .. tostring(content_id),
                _SHUFFLE = is_shuffle,
                _REPEAT = repeat_str
            })
        end
        channel.read(2)
    end
    channel.retry("Connection failed", 10)
    driver.setError()
    return CONST.HW_ERROR
end

function executeCommand(command, resource, commandArgs)
    local rtype = resource.type or resource.typeId
    local naim_ip = channel.attributes("host")
    if not naim_ip or naim_ip == "" then return end
    local base_url = "http://" .. naim_ip .. ":15081"
    
    Trace(">>> EXECUTING COMMAND: " .. tostring(command))
    
    if rtype == "Digital Receiver" then
        if command == "TURN_ON" then 
            urlPut(base_url .. "/power?system=on", "", {})
            setResourceState(rtype, resource.address, { ONLINE = true })
        elseif command == "STANDBY" then 
            urlPut(base_url .. "/power?system=lona", "", {})
            setResourceState(rtype, resource.address, { ONLINE = false, STATE = "None", INPUT = "" })
        elseif command == "SELECT_INPUT" then
            local safe_input = commandArgs.INPUT
            local target = makeNaim(safe_input)
            urlPut(base_url .. "/system/input?id=" .. target, "", {})
            CURRENT_INPUT = safe_input
            setResourceState(rtype, resource.address, { INPUT = safe_input, ONLINE = true })
        elseif command == "SET_VOLUME" then
            urlPut(base_url .. "/levels/room?volume=" .. commandArgs.VOLUME, "", {})
            setResourceState(rtype, resource.address, { VOLUME = commandArgs.VOLUME })
        elseif command == "VOLUME_UP" then urlGet(base_url .. "/levels/room?cmd=volup")
        elseif command == "VOLUME_DOWN" then urlGet(base_url .. "/levels/room?cmd=voldown")
        elseif command == "SET_MUTE" then
            urlPut(base_url .. "/levels/room?mute=" .. (commandArgs.MUTE and "1" or "0"), "", {})
            setResourceState(rtype, resource.address, { MUTE = commandArgs.MUTE })
        elseif command == "PLAY" then 
            if NAIM_PLAYBACK_STATE == "Pause" then urlGet(base_url .. "/nowplaying?cmd=resume") else urlGet(base_url .. "/nowplaying?cmd=play") end
            setResourceState(rtype, resource.address, { STATE = "Play" })
        elseif command == "PAUSE" then 
            urlGet(base_url .. "/nowplaying?cmd=pause")
            setResourceState(rtype, resource.address, { STATE = "Pause" })
        elseif command == "STOP" then 
            urlGet(base_url .. "/nowplaying?cmd=stop")
            setResourceState(rtype, resource.address, { STATE = "Stop" })
        elseif command == "NEXT" then urlGet(base_url .. "/nowplaying?cmd=next")
        elseif command == "PREV" then urlGet(base_url .. "/nowplaying?cmd=prev")
        elseif command == "_SET_SHUFFLE" then
            urlPut(base_url .. "/nowplaying?shuffle=" .. (commandArgs._SHUFFLE and "1" or "0"), "", {})
            setResourceState(rtype, resource.address, { _SHUFFLE = commandArgs._SHUFFLE })
        elseif command == "_SET_REPEAT" then
            local rep = "0"; if commandArgs._REPEAT == "One" then rep = "1" elseif commandArgs._REPEAT == "All" then rep = "2" end
            urlPut(base_url .. "/nowplaying?repeat=" .. rep, "", {})
            setResourceState(rtype, resource.address, { _REPEAT = commandArgs._REPEAT })
        elseif command == "SET_CONTENT_ID" then
            if commandArgs.ID and commandArgs.ID ~= "" then
                Trace(">>> BLI REQUESTED TO INJECT CONTENT ID: " .. tostring(commandArgs.ID))
                urlPut(base_url .. "/nowplaying?cmd=playurl&url=" .. commandArgs.ID, "", {})
                urlGet(base_url .. "/inputs/playqueue?cmd=playid&id=" .. commandArgs.ID)
            end
        end
    end
end

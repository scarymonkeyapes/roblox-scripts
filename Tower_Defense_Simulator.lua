-- Cookies Hub (Tower Defense Simulator)  [KEYLESS]
-- RightShift: show/hide | X button or _G.CookiesHubTDS.Unload(): unload
-- Console: _G.CookiesHubTDS.Set("AutoFarm", true)
--
-- Live-verified against TDS (roblox-ts build). TDS is server-authoritative: no cash/kill hacks.
-- This is a COST-AWARE AUTO-PLAYER. It reads every tower's real price, upgrade costs, damage,
-- cooldown, range and income from the game's own config, then each tick spends on the best thing
-- per dollar: damage first whenever the defense is short or leaking, farms only when it's safe and
-- they pay themselves back, and it saves up for a much better buy instead of wasting cash.
--
-- Confirmed API:
--  * Network.Channel("Troops"):InvokeServer("Place", {Position, Rotation}, name) -> Model | "error"
--                              InvokeServer("Upgrade", "Set", {Troop=Model, Path=1|2})   (2 = branch, e.g. Pursuit 4-5)
--                              InvokeServer("Sell", {Troop=Model})
--                              InvokeServer("Target", "Set", {Troop=Model, Target="First"|"Strongest"|...})
--  * NewNetwork.Channel("Elevators"):invokeServer("Enter", elevator) / ("SetSize", 1) / ("SetReady", true)
--  * NewNetwork.Channel("Quests"):invokeServer("RequestState") / ("ClaimQuest", id)
--  * NewNetwork.Channel("Achievements"):invokeServer("Claim", name)   (claimable = Cache("Achievements") {completed=true})
--  * Shared.UI.Network.Channel("Inventory"):InvokeServer("Equip"|"Unequip", "tower", name)   (lobby; NOT Modules.Network)
--  * Network.Channel("LobbyVoting"): map-vote room -> FireServer("Vote", mapName, charPos) / FireServer("Ready")
--        InvokeServer("Override", mapName) (VIP+ pass 10518590) only swaps it onto a board - you still vote it.
--        Real result: workspace attrs Map (chosen), Map1..4 (boards). ReplicatedStorage.State.Map is NOT the map.
--  * Network.Channel("Voting"):InvokeServer("Skip")
--  * NewNetwork.Channel("GameManager"):fireServer("Rematch")   (the old Network channel has no fireServer)
--  * Shared.Modules.Asset("Troops", name).Stats.Default
--        .Defaults {Price, Limit, Damage, Cooldown, Range, Income}   .Upgrades[i] {Cost, Stats{...}}
--  * Shared.Modules.GameState.Replicator:Get("Wave"|"TotalWaves"|"Health"|"MaxHealth")
--  * Client.Modules.Replicators.TowerReplicator.getTowerByModel(m) -> {TowerName, Upgrade, Position, OwnerName}
--  * Client.Modules.Cache("Inventory.Troops")._data() -> towers you own
-- Gotchas: TowerReplicator / GameState can YIELD FOREVER when required in the lobby, so every game
-- module is loaded lazily with a timeout. Save this file as UTF-8 WITHOUT a BOM or it won't load.

if _G.CookiesHubTDS and _G.CookiesHubTDS.Unload then pcall(_G.CookiesHubTDS.Unload) end

local Players          = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local lp               = Players.LocalPlayer

-- ---------- guard ----------
-- autoexec runs before the game loads; give ReplicatedStorage time to fill in before deciding this isn't TDS
if not game:IsLoaded() then game.Loaded:Wait() end
RS:WaitForChild("Shared", 15) RS:WaitForChild("Client", 15)
local okNet, Net = pcall(require, RS:FindFirstChild("Shared") and RS.Shared.Modules and RS.Shared.Modules.Network)
local PRmod = RS:FindFirstChild("Client") and RS.Client.Modules and RS.Client.Modules:FindFirstChild("Replicators")
PRmod = PRmod and PRmod:FindFirstChild("PlayerReplicator")
local okPR, PR = pcall(require, PRmod)
if not (okNet and type(Net) == "table" and Net.Channel and okPR and type(PR) == "table") then
    warn("[CookiesHub TDS] Not Tower Defense Simulator (missing Network / PlayerReplicator). Aborting.")
    return
end
local NetFolder = RS:FindFirstChild("Network")
local alive = true   -- cleared on Unload so every loop exits (keeps reloads clean)

-- ---------- settings ----------
local S = {
    AutoFarm     = false,   -- master
    AutoPlace    = true,
    AutoUpgrade  = true,
    UseFarms     = true,    -- buy/upgrade Farms when it's safe and they pay back
    AutoSkip     = true,    -- only skips while the defense is clearly ahead
    AutoVote     = true,
    AutoRematch  = true,
    SellFarmsEnd = true,    -- final wave: farms can't pay anymore, sell them for boss damage
    ReplaceWeak  = true,    -- at the tower cap, sell the weakest damage tower for a much stronger one
    SmartTarget  = true,    -- slow heavy hitters target Strongest
    AutoAbility  = true,    -- fire tower abilities that need no aiming (e.g. DJ Booth "Drop The Beat")
    AutoMode     = true,    -- pick the mode that earns the most per hour while still winning
    Watchdog     = true,    -- rejoin if nothing progresses for minutes (stuck lobby/vote room/match)
    AutoLoadout  = true,    -- lobby: equip the best loadout for the mode about to be played
    UseTimescale = true,    -- solo: spend 1 Timescale Ticket per match (only while ahead) to play at 2x
    AutoCrates   = true,    -- lobby: open crates you own
    Coop         = false,   -- co-op: play as a party with other Cookies Hub users (see the Co-op tab)
    CoopAccept   = true,    -- co-op: auto-accept party invites from Roblox friends
    CoopRole     = 1,       -- co-op: this player's slot in the party (1 = leader); saved so match servers know it
    CoopSize     = 1,       -- co-op: party size when it was last seen in the lobby
    AutoJoin     = false,   -- lobby: walk into a solo elevator for VoteMode and start
    AntiAFK      = true,
    AutoPlaytime = false,
    AutoDaily    = false,
    AutoQuests   = false,
    MaxTowers    = 20,
    VoteMode     = "Easy",
    VIPMap       = "",      -- VIP+ pass: force this map every round ("" = vote normally)
    ToggleKey    = Enum.KeyCode.RightShift,
}
-- settings survive teleports/reloads (lobby -> match -> lobby), so an autoexec'd hub picks up where it left off
local HttpService = game:GetService("HttpService")
-- save files are per Roblox account: several accounts on one PC share the executor's workspace (and its
-- autoexec), and must not overwrite each other's settings, co-op slot, session or records.
-- readAcct(base, true) falls back to the old shared file once, so existing data carries over.
local function acctFile(base) return ("CookiesHubTDS_%d_%s"):format(lp.UserId, base) end
local function readAcct(base, legacy)
    local ok, s = pcall(readfile, acctFile(base))
    if ok and type(s) == "string" and s ~= "" then return s end
    if legacy then
        local ok2, s2 = pcall(readfile, "CookiesHubTDS_" .. base)
        if ok2 and type(s2) == "string" and s2 ~= "" then return s2 end
    end
    return nil
end
local SETTINGS_FILE = acctFile("settings.json")
pcall(function()
    for k, v in pairs(HttpService:JSONDecode(readAcct("settings.json", true))) do
        if S[k] ~= nil and type(S[k]) == type(v) then S[k] = v end
    end
end)
-- co-op party member (not the leader): follows the leader's queue, map and mode instead of choosing its own
local function coopFollower() return S.Coop and S.CoopSize > 1 and S.CoopRole > 1 end
local function saveSettings()
    local out = {}
    for k, v in pairs(S) do if type(v) ~= "userdata" then out[k] = v end end
    pcall(function() writefile(SETTINGS_FILE, HttpService:JSONEncode(out)) end)
end

-- fallback strength for towers whose damage isn't readable (unit spawners etc.)
local TIER = {
    Accelerator=10, Ranger=10, Engineer=9, Turret=9, ["Gatling Gun"]=9, Minigunner=8,
    ["Ace Pilot"]=8, Pyromancer=8, Electroshocker=8, ["Toxic Gunner"]=8, Executioner=7,
    Sniper=7, Rocketeer=6, Demoman=6, ["Crook Boss"]=6, Warden=6, Pursuit=6,
    Paintballer=5, Cowboy=5, Soldier=4, Hunter=4, Shotgunner=4, Scout=2,
    Commander=9, ["DJ Booth"]=8, Farm=7, Freezer=6, ["Military Base"]=6, Medic=5, ["Mercenary Base"]=6,
}
local BUFF = { ["DJ Booth"]=true, Commander=true }

-- ---------- lazy, time-boxed requires ----------
local function safeRequire(inst, timeout)
    if not inst then return nil end
    local done, mod = false, nil
    task.spawn(function()
        local ok, m = pcall(require, inst)
        if ok then mod = m end
        done = true
    end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < (timeout or 3) do task.wait() end
    return mod
end
local lazyMods = {}
local function lazy(key, path, timeout)
    local e = lazyMods[key]
    if e and e.mod then return e.mod end
    if e and os.clock() - e.t < 10 then return nil end   -- failed recently; don't pile up hung threads
    local inst = RS
    for part in string.gmatch(path, "[^%.]+") do inst = inst and inst:FindFirstChild(part) end
    local mod = safeRequire(inst, timeout)
    lazyMods[key] = { mod = mod, t = os.clock() }
    return mod
end
local function getTR()    return lazy("TR", "Client.Modules.Replicators.TowerReplicator", 2) end
local function getGS()    return lazy("GS", "Shared.Modules.GameState", 2) end
local function getAsset() return lazy("Asset", "Shared.Modules.Asset", 3) end
local function getCache() return lazy("Cache", "Client.Modules.Cache", 3) end
local function getNPC()   return lazy("NPC", "Client.Modules.Replicators.NPCReplicator", 2) end
local function getEnum()  return lazy("Enum", "Shared.Modules.Enum", 3) end

-- ---------- channels ----------
local Troops     = Net.Channel("Troops")
local Difficulty = Net.Channel("Difficulty")
local Voting     = Net.Channel("Voting")
local NewNet     = safeRequire(RS.Shared.Modules:FindFirstChild("NewNetwork"), 3)
local GameMgr    = NewNet and NewNet.Channel and NewNet.Channel("GameManager")

-- the farm session (wins, losses, coins since start...) is saved to a file: the hub reloads on every teleport,
-- which used to wipe the counters each new game. It carries on unless the hub has been off for 15+ minutes.
local SESSION_FILE, SESSION_KEYS = acctFile("session.json"), { "wins", "losses", "placements", "upgrades", "crates" }
local session = { wins = 0, losses = 0, placements = 0, upgrades = 0, crates = 0, startTime = os.time(),
                  startCoins = (lp:FindFirstChild("Coins") and lp.Coins.Value) or 0,
                  startXP = (lp:FindFirstChild("Experience") and lp.Experience.Value) or 0,
                  loadClock = os.clock(), log = {} }
pcall(function()
    local saved = HttpService:JSONDecode(readAcct("session.json"))
    if type(saved) == "table" and tonumber(saved.last) and os.time() - saved.last < 15 * 60 then
        for _, k in ipairs(SESSION_KEYS) do session[k] = tonumber(saved[k]) or 0 end
        session.startTime = tonumber(saved.startTime) or session.startTime
        session.startCoins = tonumber(saved.startCoins) or session.startCoins
        session.startXP = tonumber(saved.startXP) or session.startXP
    end
end)
local function saveSession()
    -- autoexec can load before the Coins value exists; take the baseline once it does
    if session.startCoins == 0 and lp:FindFirstChild("Coins") then session.startCoins = lp.Coins.Value end
    local out = { last = os.time(), startTime = session.startTime, startCoins = session.startCoins, startXP = session.startXP }
    for _, k in ipairs(SESSION_KEYS) do out[k] = session[k] end
    pcall(function() writefile(SESSION_FILE, HttpService:JSONEncode(out)) end)
end
-- the in-window log dies with each teleport, so every line is also appended to a file (trimmed past ~200KB)
local LOG_FILE = acctFile("log.txt")
local function logLine(t)
    local line = ("[%s] %s"):format(os.date("%m-%d %H:%M:%S"), t)
    table.insert(session.log, 1, line)
    if #session.log > 30 then session.log[#session.log] = nil end
    pcall(function()
        local ok, all = pcall(readfile, LOG_FILE)   -- appendfile won't create a missing file on every executor
        all = (ok and type(all) == "string" and all or "") .. line .. "\n"
        writefile(LOG_FILE, #all > 200000 and all:sub(-100000) or all)
    end)
end

-- ---------- state helpers ----------
local function me()
    local ok, p = pcall(PR.GetLocalPlayer)
    if ok and p and p._values then return p._values[1] end
    return nil
end
local function cash() local m = me() return (m and m.Cash) or 0 end
local function inMatch()
    local t = Workspace:FindFirstChild("Type")
    return t and t.Value == "Game" and Workspace:FindFirstChild("Map") ~= nil
end
-- live enemies only: NPCs also holds placeholder models (e.g. "Red"/"Blue") with no RootPointer
local function liveEnemies()
    local npcs, n = Workspace:FindFirstChild("NPCs"), 0
    for _, m in ipairs(npcs and npcs:GetChildren() or {}) do
        if m:FindFirstChild("RootPointer") then n = n + 1 end
    end
    return n
end
local function statValue(name) local v = lp:FindFirstChild(name) return v and v.Value or 0 end
local function equippedLoadout()
    local m = me()
    local out = {}
    if m and type(m.EquippedTowers) == "table" then
        for _, v in pairs(m.EquippedTowers) do
            local name = type(v) == "table" and (v.Name or v.name) or v
            if type(name) == "string" then out[#out + 1] = name end
        end
    end
    return out
end

-- VIP+ gamepass: lets you override the map in the match server's vote room (cached; it can't change mid-session)
local VIP_PASS, vipOwned = 10518590, nil
local function ownsVIP()
    if vipOwned == nil then
        local ok, owns = pcall(function()
            return game:GetService("MarketplaceService"):UserOwnsGamePassAsync(lp.UserId, VIP_PASS)
        end)
        if not ok then return false end   -- retry next time
        vipOwned = owns == true
    end
    return vipOwned
end
-- maps the override menu offers, same filter as the game's Intermission view; sorted easiest first
local DIFF_ORDER = { Easy = 1, Normal = 2, Hard = 3, Insane = 4 }
local function mapList()
    local maps = RS:FindFirstChild("Content") and RS.Content:FindFirstChild("Maps")
    local E, ID = getEnum(), lazy("ID", "Shared.Modules.IntermissionData", 3)
    if not (maps and E and ID) then return {} end
    local gm = E.Gamemode and E.Gamemode[Workspace:GetAttribute("GameMode") or "Survival"]
    local out = {}
    for _, child in ipairs(maps:GetChildren()) do
        local data = child:IsA("Folder") and child:FindFirstChild("Data") or child
        local ok, v = pcall(require, data)
        if ok and type(v) == "table" and (v.MapType == E.MapType.Community
            or (type(v.Gamemodes) == "table" and v.Gamemodes[gm] and ID.MAPS and ID.MAPS[child.Name])) then
            local diff = "?"
            for k, val in pairs(E.Difficulty) do if val == v.Difficulty then diff = k end end
            out[#out + 1] = { name = child.Name, diff = diff }
        end
    end
    table.sort(out, function(a, b)
        local da, db = DIFF_ORDER[a.diff] or 9, DIFF_ORDER[b.diff] or 9
        if da ~= db then return da < db end
        return a.name < b.name
    end)
    return out
end

-- real results per loadout and mode: paper stats miss splash, burn, slows and summons, so a loadout that's
-- actually winning beats any recommendation
local RECORD_FILE = acctFile("loadouts.json")
local records = {}
pcall(function()
    local t = HttpService:JSONDecode(readAcct("loadouts.json"))
    if type(t) == "table" then records = t end
end)
local function loadoutKey(names)
    local t = table.clone(names)
    table.sort(t)
    return table.concat(t, ",")
end
local function loadoutRecord(names, mode)
    local r = (records[mode] or {})[loadoutKey(names)]
    return r and r.w or 0, r and r.l or 0
end

-- per-mode results and earnings, driving Auto mode: farm whichever mode pays the most coins per hour while
-- still winning; try the next mode up once the one below is reliable; bench a mode for an hour after 2
-- losses in a row
local MODES = { "Easy", "Casual", "Intermediate", "Molten", "Fallen" }
local STAT_KEYS = {}   -- display order: each mode solo, then as a party
for _, m in ipairs(MODES) do STAT_KEYS[#STAT_KEYS + 1] = m STAT_KEYS[#STAT_KEYS + 1] = m .. "+coop" end
local MODE_FILE = acctFile("modes.json")
local modeStats = {}
pcall(function()
    local t = HttpService:JSONDecode(readAcct("modes.json"))
    if type(t) == "table" then modeStats = t end
end)
local function modeStat(m)
    modeStats[m] = modeStats[m] or { w = 0, l = 0, coins = 0, secs = 0, streak = 0, bench = 0 }
    return modeStats[m]
end
-- solo and co-op results are kept apart ("Casual" vs "Casual+coop"): solo Casual went 0W/8L while the first
-- co-op Casual run won at full HP, so one record would steer both wrong
local function inCoop() return S.Coop and S.CoopSize > 1 end
local function statKey(mode, coop)
    if coop == nil then coop = inCoop() end
    return coop and (mode .. "+coop") or mode
end
local function recordResult(won, mode)
    local names = equippedLoadout()
    if #names > 0 then
        local byMode = records[mode] or {}
        records[mode] = byMode
        local r = byMode[loadoutKey(names)] or { w = 0, l = 0 }
        byMode[loadoutKey(names)] = r
        if won then r.w = r.w + 1 else r.l = r.l + 1 end
        pcall(function() writefile(RECORD_FILE, HttpService:JSONEncode(records)) end)
    end
    local st = modeStat(mode)
    if won then st.w, st.streak = st.w + 1, 0 else st.l, st.streak = st.l + 1, st.streak + 1 end
    if st.streak >= 2 then
        st.bench, st.streak = os.time() + 3600, 0
        logLine(mode .. " lost twice in a row - benched for an hour")
    end
    pcall(function() writefile(MODE_FILE, HttpService:JSONEncode(modeStats)) end)
end
-- match coins are only paid out after we've left (they show up on the next server), so a finished match
-- leaves a pending {mode, coins at its start, os.time at its start} in the file, settled when the next
-- match starts: earned = coins now - coins then, over the whole cycle incl. vote room and loading
local function settleEarnings()
    local p = modeStats._pending
    if type(p) ~= "table" then return end
    modeStats._pending = nil
    local dc, secs = statValue("Coins") - p.coins, os.time() - p.t
    if dc >= 0 and secs > 0 and secs < 3 * 3600 then
        local st = modeStat(p.mode)
        st.coins, st.secs = st.coins + dc, st.secs + secs
        logLine(("Last %s match: +%d coins in %dm"):format(p.mode, dc, math.floor(secs / 60)))
    end
    pcall(function() writefile(MODE_FILE, HttpService:JSONEncode(modeStats)) end)
end
local function leavePending(mode, start)
    modeStats._pending = { mode = mode, coins = start.coins, t = start.t }
    pcall(function() writefile(MODE_FILE, HttpService:JSONEncode(modeStats)) end)
end
local bestLoadoutFor   -- defined with the loadout code further down; chooseMode only calls it at runtime
local function chooseMode()
    if not S.AutoMode then return S.VoteMode end
    local now, best, bestRate, coop = os.time(), nil, -1, inCoop()
    local function reliable(st) return st.w + st.l >= 3 and st.w >= (st.w + st.l) * 0.75 end
    for i, m in ipairs(MODES) do
        local key = statKey(m, coop)
        local st, games = modeStat(key), modeStat(key).w + modeStat(key).l
        -- the mode below must be reliable here; in co-op a solid solo record below counts too
        local unlocked = i == 1 or reliable(modeStat(statKey(MODES[i - 1], coop)))
            or (coop and reliable(modeStat(MODES[i - 1])))
        -- no point trying out an easier mode when a harder one already wins (co-op went straight to Casual)
        local harderProven = false
        for j = i + 1, #MODES do
            local hs = modeStat(statKey(MODES[j], coop))
            if hs.secs > 0 and reliable(hs) then harderProven = true end
        end
        if unlocked and st.bench <= now then
            if (games < 2 or st.secs == 0) and not harderProven then return m end   -- not enough data yet: play it to find out
            local rate = st.secs > 0 and st.coins / st.secs * 3600 or 0
            if st.w >= games * 0.7 and rate > bestRate then best, bestRate = m, rate end
            -- losing here, but the loadout it would bring next hasn't been tried here yet: give it a go
            -- (bounded: once that loadout has 2 games here this stops)
            if st.w < games * 0.7 and bestLoadoutFor then
                local ok, want = pcall(bestLoadoutFor, m)
                if ok and type(want) == "table" and #want > 0 then
                    local w, l = loadoutRecord(want, key)
                    if w + l < 2 then return m end
                end
            end
        end
    end
    return best or "Easy"
end

local function gsGet(key)
    local GS = getGS()
    if not GS then return nil end
    local rep = GS.Replicator
    if rep and rep.Get then
        local ok, v = pcall(function() return rep:Get(key) end)
        if ok and v ~= nil then return v end
    end
    return GS[key]
end
-- the mode this match is actually on (the elevator decides it), falling back to the setting
local function matchMode() return tostring(gsGet("Difficulty") or S.VoteMode) end
local LOBBY_PLACE = 3260590327
-- the mode's final boss, from the game's own data: GameModeData[mode].Boss -> Content.NewEnemies[boss].Stats
-- (Easy Brute 17.5k HP, Casual Grave Digger 40k HP + summons + tower-stunning stomp, Intermediate Patient Zero 100k)
local bossCache = {}
local function bossInfo(mode)
    if bossCache[mode] ~= nil then return bossCache[mode] or nil end
    local GM = lazy("GMD", "Shared.Data.GameModeData", 3)
    local name = type(GM) == "table" and type(GM[mode]) == "table" and GM[mode].Boss
    local ne = RS:FindFirstChild("Content") and RS.Content:FindFirstChild("NewEnemies")
    local f = name and ne and ne:FindFirstChild(name)
    local ok, st = pcall(function() return require(f.Stats) end)
    local hp = ok and type(st) == "table" and tonumber(st.MaxHealth)
    bossCache[mode] = hp and { name = name, hp = hp, speed = tonumber(st.Speed) or 1 } or false
    return bossCache[mode] or nil
end
local function gameInfo()
    return {
        wave  = tonumber(gsGet("Wave")) or 0,
        total = tonumber(gsGet("TotalWaves")) or 25,
        hp    = tonumber(gsGet("Health")) or 0,
        maxHp = tonumber(gsGet("MaxHealth")) or 1,
    }
end

-- ---------- tower data (from the game's own config) ----------
local infoCache = {}
local function towerInfo(name)
    local cached = infoCache[name]
    if cached ~= nil then return cached or nil end
    local Asset = getAsset()
    if not Asset then return nil end
    local ok, a = pcall(Asset, "Troops", name)
    local st = ok and type(a) == "table" and type(a.Stats) == "table" and (a.Stats.Default or select(2, next(a.Stats)))
    if type(st) ~= "table" or type(st.Defaults) ~= "table" then infoCache[name] = false return nil end
    local d = st.Defaults
    -- detections carry forward level to level; upgrades only list what changes
    local det = { hidden = false, lead = false, flying = false }
    local function readDet(t, into)
        if type(t) ~= "table" then return end
        if t.HiddenDetection ~= nil then into.hidden = t.HiddenDetection == true end
        if t.LeadDetection ~= nil then into.lead = t.LeadDetection == true end
        if t.FlyingDetection ~= nil then into.flying = t.FlyingDetection == true end
    end
    readDet(d.Detections, det)
    local hasDmg = type(d.Damage) == "number" and d.Damage > 0
    -- Attributes hold the damage that isn't the main hit (Pyromancer MaxHits/Burn*, Ace Pilot Bomb*/Explosion*);
    -- like detections, upgrades only list what changes
    local attr0 = type(d.Attributes) == "table" and table.clone(d.Attributes) or {}
    local cur = { dmg = d.Damage, cd = d.Cooldown, range = d.Range, income = d.Income, attr = attr0 }
    local levels = { [0] = { cost = d.Price, dmg = cur.dmg, cd = cur.cd, range = cur.range, income = cur.income, attr = attr0,
                             hidden = det.hidden, lead = det.lead, flying = det.flying } }
    local maxLevel = 0
    -- walk one upgrade path; trunk levels are {Cost, Stats}, branched levels (e.g. Pursuit 4-5) are {[1]={...}, [2]={...}}
    local function walk(branch)
        local c, dt = table.clone(cur), table.clone(det)
        local lv, top = {}, 0
        for i, u in ipairs(st.Upgrades) do
            local path = 1
            if type(u) == "table" and type(u.Cost) ~= "number" and type(u[branch]) == "table" then u, path = u[branch], branch end
            if type(u) ~= "table" or type(u.Cost) ~= "number" then break end
            local s = type(u.Stats) == "table" and u.Stats or {}
            readDet(s.Detections, dt)
            local attr = table.clone(c.attr)
            for k, v in pairs(type(s.Attributes) == "table" and s.Attributes or {}) do attr[k] = v end
            c = { dmg = s.Damage or c.dmg, cd = s.Cooldown or c.cd, range = s.Range or c.range, income = s.Income or c.income, attr = attr }
            lv[i] = { cost = u.Cost, path = path, dmg = c.dmg, cd = c.cd, range = c.range, income = c.income, attr = attr,
                      hidden = dt.hidden, lead = dt.lead, flying = dt.flying }
            top = i
        end
        return lv, top
    end
    if type(st.Upgrades) == "table" then
        -- two-path towers: keep the branch that ends strongest (damage, or income for economy towers)
        local best, bestScore
        for branch = 1, math.max(1, tonumber(st.Paths) or 1) do
            local lv, top = walk(branch)
            local L = lv[top]
            local score = L and (hasDmg and (L.dmg or 0) / math.max(L.cd or 1, 0.05) or (L.income or 0)) or -1
            if not bestScore or score > bestScore then best, bestScore, maxLevel = lv, score, top end
        end
        for i, L in pairs(best) do levels[i] = L end
    end
    -- active abilities: {Name, Level (unlock), Debounce (cooldown), InitialCooldown}, on Defaults or an upgrade
    local abilities = {}
    local function readAbilities(t)
        for _, a in pairs(type(t) == "table" and t or {}) do
            if type(a) == "table" and type(a.Name) == "string" then abilities[#abilities + 1] = a end
        end
    end
    readAbilities(d.Abilities)
    for _, u in ipairs(type(st.Upgrades) == "table" and st.Upgrades or {}) do
        readAbilities(type(u) == "table" and type(u.Stats) == "table" and u.Stats.Abilities)
    end
    local info = {
        name = name, price = d.Price or math.huge, limit = d.Limit or 99, levels = levels, maxLevel = maxLevel,
        abilities = abilities,
        econ = (not hasDmg) and (d.Income or 0) > 0,
        buff = BUFF[name] == true,
    }
    infoCache[name] = info
    return info
end

-- effective damage per second at a level (short range covers less path, so it counts for less).
-- Counts the damage that isn't the main hit, assuming enemies come in groups (~2 in reach):
--   MaxHits - one shot hits several enemies (Pyromancer flames hit 3)
--   Burn    - BurnDamage every BurnTick on each enemy hit (Pyromancer 2/s)
--   Bombs   - ExplosionDamage splash every BombTime once BombDropping (Ace Pilot upgrades)
-- Before this a Pyromancer read ~2 dmg/s, so one looked like enough hidden cover and every dollar went
-- into Ace Pilots.
local function dpsAt(info, lvl, single)
    local L = info.levels[lvl]
    if not L or info.econ or info.buff then return 0 end
    if type(L.dmg) == "number" and type(L.cd) == "number" and L.cd > 0 then
        local a, group = L.attr or {}, single and 1 or 2   -- single: against one target (a boss)
        local hits = math.min(tonumber(a.MaxHits) or 1, group)
        local dps = L.dmg / L.cd * hits
        if tonumber(a.BurnDamage) and tonumber(a.BurnTick) and a.BurnTick > 0 then
            dps = dps + a.BurnDamage / a.BurnTick * hits
        end
        if a.BombDropping == true and tonumber(a.ExplosionDamage) and tonumber(a.BombTime) and a.BombTime > 0 then
            dps = dps + a.ExplosionDamage / a.BombTime * group
        end
        return dps * math.clamp((L.range or 12) / 14, 0.45, 1.25)
    end
    return (TIER[info.name] or 3)
end
local function incomeAt(info, lvl) local L = info.levels[lvl] return (L and L.income) or 0 end
-- damage that can actually hit hidden / lead enemies (towers without the detection can't target them)
local function catDps(info, lvl, cat)
    local L = info.levels[lvl]
    return (L and L[cat]) and dpsAt(info, lvl) or 0
end

-- ---------- map: path samples, placement spots, coverage ----------
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
local function refreshGroundFilter()
    local list = {}
    local g = Workspace:FindFirstChild("Ground") if g then list[#list + 1] = g end
    local map = Workspace:FindFirstChild("Map")
    if map and map:FindFirstChild("Ground") then list[#list + 1] = map.Ground end
    groundParams.FilterDescendantsInstances = list
end
local function groundAt(pos)
    local h = Workspace:Raycast(pos + Vector3.new(0, 35, 0), Vector3.new(0, -70, 0), groundParams)
    return h and h.Position
end
-- every enemy path on the map (multi-path maps send enemies down all of them)
local function allWaypoints()
    local map = Workspace:FindFirstChild("Map")
    local paths = map and map:FindFirstChild("Paths")
    local out = {}
    for _, path in ipairs(paths and paths:GetChildren() or {}) do
        local pts = path:GetChildren()
        table.sort(pts, function(a, b) return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0) end)
        local wp = {}
        for _, p in ipairs(pts) do
            local pos = p:IsA("BasePart") and p.Position or p:GetAttribute("Position")
            if typeof(pos) == "Vector3" then wp[#wp + 1] = pos end
        end
        if #wp > 0 then out[#out + 1] = wp end
    end
    return out
end

local pathPts, spots, badSpot, covCache = {}, {}, {}, {}
local shortestPath = 0   -- studs; how long the boss is on the map decides the damage it needs
local function rebuildMap()
    refreshGroundFilter()
    pathPts, shortestPath = {}, 0
    local runs = {}   -- per-path sample ranges, so path direction never jumps across paths
    for _, wp in ipairs(allWaypoints()) do
        local first, len = #pathPts + 1, 0
        for i = 1, #wp - 1 do
            local a, b = wp[i], wp[i + 1]
            local seg = b - a
            len = len + seg.Magnitude
            local n = math.max(1, math.floor(seg.Magnitude / 2))
            for k = 0, n - 1 do pathPts[#pathPts + 1] = a + seg * (k / n) end
        end
        if len > 0 and (shortestPath == 0 or len < shortestPath) then shortestPath = len end
        pathPts[#pathPts + 1] = wp[#wp]
        runs[#runs + 1] = { first, #pathPts }
    end
    spots, badSpot, covCache = {}, {}, {}
    local seen = {}
    for _, run in ipairs(runs) do
        for i = run[1], run[2], 2 do
            local here = pathPts[i]
            local nxt, prv = pathPts[math.min(i + 1, run[2])], pathPts[math.max(i - 1, run[1])]
            local dir = Vector3.new(nxt.X - prv.X, 0, nxt.Z - prv.Z)
            dir = dir.Magnitude > 0 and dir.Unit or Vector3.new(1, 0, 0)
            local perp = Vector3.new(-dir.Z, 0, dir.X)
            for _, d in ipairs({ 3.5, -3.5, 5.5, -5.5, 8, -8, 11, -11, 15, -15 }) do
                local g = groundAt(here + perp * d)
                if g then
                    local key = math.floor(g.X / 2) .. "," .. math.floor(g.Z / 2)
                    if not seen[key] then seen[key] = true spots[#spots + 1] = g end
                end
            end
        end
    end
end
local function spotKey(p) return math.floor(p.X / 2) .. "," .. math.floor(p.Z / 2) end
local function coverage(p, range)
    local key = spotKey(p) .. "," .. math.floor(range)
    local c = covCache[key]
    if c then return c end
    c = 0
    local r2 = range * range
    for _, q in ipairs(pathPts) do
        local dx, dz = q.X - p.X, q.Z - p.Z
        if dx * dx + dz * dz <= r2 then c = c + 1 end
    end
    covCache[key] = c
    return c
end
-- teammates' towers (filled by myTowers): their spots are taken, and their detection covers the team
local otherTowers = {}   -- { pos = Vector3, info = towerInfo, level = n }
local function spotFree(p, towers)
    if (badSpot[spotKey(p)] or 0) > os.clock() then return false end
    for _, t in ipairs(towers) do
        if t.pos then
            local dx, dz = t.pos.X - p.X, t.pos.Z - p.Z
            if dx * dx + dz * dz < 2.6 * 2.6 then return false end
        end
    end
    for _, o in ipairs(otherTowers) do
        local dx, dz = o.pos.X - p.X, o.pos.Z - p.Z
        if dx * dx + dz * dz < 2.6 * 2.6 then return false end
    end
    return true
end
-- best spots for a tower: damage covers the most path, farms stay off the good spots, buffs sit by damage
local function rankSpots(info, towers)
    local range = (info.levels[0] and info.levels[0].range) or 10
    local list = {}
    for _, p in ipairs(spots) do
        if spotFree(p, towers) then
            local score
            if info.econ then
                score = -coverage(p, 14)
            elseif info.buff then
                score = 0
                for _, t in ipairs(towers) do
                    if t.dps > 0 and t.pos then
                        local dx, dz = t.pos.X - p.X, t.pos.Z - p.Z
                        if dx * dx + dz * dz <= range * range then score = score + 1 end
                    end
                end
                score = score * 1000 + coverage(p, range)
            else
                score = coverage(p, range)
            end
            list[#list + 1] = { p = p, s = score }
        end
    end
    table.sort(list, function(a, b) return a.s > b.s end)
    return list
end

-- ---------- my towers on the field ----------
local placedCount = 0
local function towerLevel(model)
    local tr = getTR()
    if not tr then return 0 end
    local ok, ent = pcall(function() return tr.getTowerByModel(model) end)
    if ok and type(ent) == "table" then return tonumber(ent.Upgrade) or 0 end
    return 0
end
local function myTowers()
    local tr = getTR()
    local list = {}
    local tf = Workspace:FindFirstChild("Towers")
    if not (tr and tf) then return list end
    local myName = me() and me().Name
    local others = {}
    for _, model in ipairs(tf:GetChildren()) do
        local ok, ent = pcall(function() return tr.getTowerByModel(model) end)
        if ok and type(ent) == "table" and myName and ent.OwnerName ~= myName and typeof(ent.Position) == "Vector3" then
            others[#others + 1] = { pos = ent.Position, info = towerInfo(ent.TowerName or model.Name), level = tonumber(ent.Upgrade) or 0 }
        end
        if ok and type(ent) == "table" and ((not myName) or ent.OwnerName == myName) then
            local name = ent.TowerName or model.Name
            local info = towerInfo(name)
            local lvl = tonumber(ent.Upgrade) or 0
            list[#list + 1] = {
                model = model, name = name, level = lvl, info = info,
                uid = model:GetAttribute("TowerUID") or tostring(model),
                pos = typeof(ent.Position) == "Vector3" and ent.Position or nil,
                worth = tonumber(ent.Worth) or 0,
                dps = info and dpsAt(info, lvl) or 0,
            }
        end
    end
    otherTowers = others
    return list
end

-- ---------- actions ----------
local function placeTower(name, pos)
    local ok, res = pcall(function()
        return Troops:InvokeServer("Place", { Position = pos, Rotation = CFrame.Angles(0, 0, 0) }, name)
    end)
    if ok and typeof(res) == "Instance" then return res end
    return nil
end
local function upgradeTower(model, path)
    pcall(function() return Troops:InvokeServer("Upgrade", "Set", { Troop = model, Path = path or 1 }) end)
end
local function sellTower(model)
    pcall(function() return Troops:InvokeServer("Sell", { Troop = model }) end)
    task.wait(0.15)
    return model.Parent == nil
end
-- slow, heavy hitters waste shots on weak enemies at the front; aim them at the strongest one instead.
-- On the boss wave everything aims at Strongest: the boss summons enemies that walk ahead of it, and on
-- "First" the whole defense shoots those while the boss walks in (live: Casual lost twice on the last wave)
local targeted = {}
local function setTargeting(t, bossWave)
    local key = t.uid .. ":" .. t.level .. (bossWave and ":boss" or "")   -- re-checked per level and for the boss
    if targeted[key] or not t.info or t.dps <= 0 then return end
    targeted[key] = true
    local L = t.info.levels[t.level]
    if bossWave or (L and type(L.dmg) == "number" and type(L.cd) == "number" and L.cd >= 1.5 and L.dmg >= 8) then
        pcall(function() Troops:InvokeServer("Target", "Set", { Troop = t.model, Target = "Strongest" }) end)
    end
end
-- abilities, fired the way the game's ability button does ("Abilities", "Activate", {Name, Troop, Data}).
-- Skips toggles (e.g. Ace Pilot "Toggle Reverse") and aimed ones (the game builds their Data in a client
-- callback, e.g. Military Base "Airstrike"); only fires while enemies are on the field.
local abilityReady = {}   -- [uid..name] = os.clock() when it may fire next
local function useAbilities(t, enemiesOut)
    if not (t.info and #t.info.abilities > 0) then return end
    local ent
    for _, a in ipairs(t.info.abilities) do
        local key = t.uid .. ":" .. a.Name
        if t.level >= (tonumber(a.Level) or 0) and not a.Name:lower():find("toggle") then
            if not abilityReady[key] then
                abilityReady[key] = os.clock() + (tonumber(a.InitialCooldown) or 0)
            elseif enemiesOut and os.clock() >= abilityReady[key] then
                ent = ent or select(2, pcall(function() return getTR().getTowerByModel(t.model) end))
                local aimed = type(ent) == "table" and type(ent.AbilityCallbacks) == "table" and ent.AbilityCallbacks[a.Name]
                if aimed then
                    abilityReady[key] = math.huge
                else
                    local ok, res = pcall(function()
                        return Troops:InvokeServer("Abilities", "Activate", { Name = a.Name, Troop = t.model, Data = {} })
                    end)
                    abilityReady[key] = os.clock() + (ok and res and (tonumber(a.Debounce) or 30) or 5)
                    if ok and res then logLine(("%s: %s"):format(t.name, a.Name)) end
                end
            end
        end
    end
end


-- ---------- enemy types (hidden / lead / flying) ----------
-- read the same way the game's own hover tooltip does: NPC model -> RootPointer -> NPCReplicator entity
local CATS = { hidden = "Hidden", lead = "Lead", flying = "Flying" }
-- [VoteMode][cat] = earliest wave that category showed up; saved to a file because the hub re-runs on every teleport
local SEEN_FILE = "CookiesHubTDS_enemytypes.json"
local firstSeen = {}
pcall(function()
    local t = HttpService:JSONDecode(readfile(SEEN_FILE))
    if type(t) == "table" then firstSeen = t end
end)
local function saveSeen() pcall(function() writefile(SEEN_FILE, HttpService:JSONEncode(firstSeen)) end) end
local function scanEnemyTypes(wave)
    local npcs = Workspace:FindFirstChild("NPCs")
    local NR, E = getNPC(), getEnum()
    if not (npcs and NR and E and E.StatusEffect and NR.GetNPCFromFolder) then return end
    local mode = matchMode()
    local seen = firstSeen[mode] or {}
    firstSeen[mode] = seen
    for _, model in ipairs(npcs:GetChildren()) do
        local ptr = model:FindFirstChild("RootPointer")
        local ok, npc = pcall(NR.GetNPCFromFolder, ptr and ptr.Value)
        local ser = ok and type(npc) == "table" and npc.StatusEffectRenderer
        if ser then
            for cat, effect in pairs(CATS) do
                if (not seen[cat] or wave < seen[cat]) and E.StatusEffect[effect] ~= nil then
                    local okH, has = pcall(function() return ser:has(E.StatusEffect[effect]) end)
                    if okH and has then seen[cat] = wave saveSeen() logLine(("%s enemies from wave %d"):format(effect, wave)) end
                end
            end
        end
    end
end
-- categories the defense must cover now: already seen this match, or due within 2 waves (from earlier matches)
local function neededCats(wave)
    local out, seen = {}, firstSeen[matchMode()] or {}
    for cat in pairs(CATS) do
        if seen[cat] and wave >= seen[cat] - 2 then out[#out + 1] = cat end
    end
    return out
end

-- ---------- the brain ----------
local brain = { status = "idle", dps = 0, target = 0 }
local lastHp, lastLeak, stuck = nil, -1e9, {}

local function chooseAction(towers, loadout, money, g)
    local counts, totalDps, dpsCount, econWorth, dpsWorth = {}, 0, 0, 0, 0
    for _, t in ipairs(towers) do
        counts[t.name] = (counts[t.name] or 0) + 1
        totalDps = totalDps + t.dps
        if t.dps > 0 then dpsCount = dpsCount + 1 dpsWorth = dpsWorth + t.worth end
        if t.info and t.info.econ then econWorth = econWorth + t.worth end
    end
    local wavesLeft = math.max(0, g.total - g.wave)
    -- rough damage the current wave needs; deliberately modest - real leaks (base health drops)
    -- are the strong signal and switch the brain to all-damage for 30s
    local target = 8 + g.wave * 5
    -- boss prep: the last waves (boss on the final one) get a higher bar so every dollar goes into damage
    local lastStretch = g.wave > 0 and wavesLeft <= 2
    if lastStretch then target = target * (wavesLeft == 0 and 2 or 1.5) end
    local leaking = os.clock() - lastLeak < 30
    local hpLow = g.wave > 0 and g.hp < g.maxHp * 0.6   -- base health reads 0 until wave 1 starts
    local needDefense = dpsCount == 0 or leaking or totalDps < target or hpLow
    brain.dps, brain.target = totalDps, target
    -- the whole team's damage (just ours when solo): what wave skips should judge, since in co-op each hub
    -- only sees its share and they'd rarely all agree to skip
    local teamDps = totalDps
    for _, o in ipairs(otherTowers) do if o.info then teamDps = teamDps + dpsAt(o.info, o.level) end end
    brain.teamDps = teamDps

    -- boss prep: over the last 6 waves build single-target damage up to the boss's HP over the time it
    -- spends walking the (shortest) path, x3 for stomp stuns, summons and gaps in coverage. Group damage
    -- (burn spread, multi-hit) doesn't count against one big target. Live: a Casual run went into the
    -- Grave Digger (40k HP) with lots of group damage and lost the base on the last wave.
    local boss, bossNeed, bossHave = bossInfo(matchMode()), 0, 0
    if boss and shortestPath > 0 and g.total > 0 and wavesLeft <= 6 then
        local ramp = 0.5 + 0.5 * (6 - wavesLeft) / 6
        bossNeed = boss.hp / (shortestPath / boss.speed) * 3 * ramp
        for _, t in ipairs(towers) do if t.info then bossHave = bossHave + dpsAt(t.info, t.level, true) end end
        brain.boss = ("%s %.0f/%.0f single-target dmg/s"):format(boss.name, bossHave, bossNeed)
    else
        brain.boss = nil
    end
    local bossShort = bossHave < bossNeed
    brain.bossShort = bossShort and wavesLeft <= 3

    -- enemy types the defense can't (or barely can) hit yet: towers without the detection ignore them
    local short, blind, seenAt = {}, false, firstSeen[matchMode()] or {}
    brain.cover = {}
    for _, cat in ipairs(neededCats(g.wave)) do
        local have, count = 0, 0
        for _, t in ipairs(towers) do
            local v = t.info and catDps(t.info, t.level, cat) or 0
            if v > 0 then have, count = have + v, count + 1 end
        end
        -- teammates' detection covers the whole team (co-op: hidden is slot 2's job). Live: a co-op leader with
        -- $225 sat saving $3000 for its own hidden upgrade while slot 2 already covered hidden
        for _, o in ipairs(otherTowers) do
            local v = o.info and catDps(o.info, o.level, cat) or 0
            if v > 0 then have, count = have + v, count + 1 end
        end
        -- damage alone isn't enough: one tower can't be everywhere on the path, so hidden cover also needs
        -- numbers - 2 towers when they show up, +1 every 3 waves after (max 8). Live: 4 level-1 Pyromancers vs
        -- 8 Ace Pilots that couldn't see hidden by wave 19.
        local needCount = cat == "hidden" and math.min(8, 2 + math.floor(math.max(0, g.wave - (seenAt[cat] or g.wave)) / 3)) or 1
        -- 70% of the wave's need: hidden zombies make up much of the later waves (a Casual run that met only
        -- 40% looked fine on total damage and still died to them)
        if have < math.max(8, target * 0.7) or count < needCount then short[#short + 1] = cat end
        if have == 0 then blind = true end
        brain.cover[#brain.cover + 1] = ("%s %d/%d towers, %.0f dmg/s"):format(cat, count, needCount, have)
    end
    brain.short = table.concat(short, "+")
    -- detection a buy leads to: the first level ahead that adds damage against a short category, and the
    -- total cost to get there (e.g. Pyromancer only sees hidden from level 1: $900 place + $325 upgrade).
    -- Returns value = detection dps per dollar to unlock, and that unlock cost.
    local function shortGain(info, lvl)
        local value, unlock = 0, math.huge
        for _, cat in ipairs(short) do
            local sum = lvl < 0 and info.price or 0
            for k = math.max(lvl + 1, 0), info.maxLevel do
                if k > 0 and k > lvl then sum = sum + info.levels[k].cost end
                local v = catDps(info, k, cat) - (lvl >= 0 and catDps(info, lvl, cat) or 0)
                if v > 0 then value, unlock = value + v / sum, math.min(unlock, sum) break end
            end
        end
        return value, unlock
    end

    local bestD, bestDAll, bestE, buffA, buffU, bestC, bestCAll, bestB, bestBAll, bestReach
    local function consider(a)
        if a.dmg and a.bvalue and a.bvalue > 0 then
            if not bestBAll or a.bvalue > bestBAll.bvalue then bestBAll = a end
            if a.cost <= money and (not bestB or a.bvalue > bestB.bvalue) then bestB = a end
        end
        if a.dmg then
            if not bestDAll or a.value > bestDAll.value then bestDAll = a end
            if a.cost <= money and (not bestD or a.value > bestD.value) then bestD = a end
            if a.cvalue and a.cvalue > 0 then
                -- totally blind to a category: the fastest (cheapest) route to any detection wins;
                -- otherwise the best detection damage per dollar
                local function better(x, y) if blind then return x.unlock < y.unlock end return x.cvalue > y.cvalue end
                if not bestCAll or better(a, bestCAll) then bestCAll = a end
                if a.cost <= money and (not bestC or better(a, bestC)) then bestC = a end
                if a.cost <= money + 1500 and (not bestReach or better(a, bestReach)) then bestReach = a end
            end
        elseif a.cost <= money and (not bestE or a.value > bestE.value) then
            bestE = a
        end
    end

    -- at the tower cap the only way to add damage is to swap out the weakest damage tower
    local atCap, weakest = #towers >= S.MaxTowers, nil
    if atCap and S.ReplaceWeak then
        for _, t in ipairs(towers) do
            if t.dps > 0 and (not weakest or t.dps < weakest.dps) then weakest = t end
        end
    end
    if S.AutoPlace and (not atCap or weakest) then
        for _, name in ipairs(loadout) do
            local info = towerInfo(name)
            if info and (counts[name] or 0) < info.limit then
                if atCap then
                    local gain = dpsAt(info, 0)
                    -- only when the swap at least doubles that slot's damage, so it never churns
                    if not info.econ and not info.buff and gain > weakest.dps * 2 then
                        local cvalue, unlock = shortGain(info, -1)
                        consider({ kind = "place", name = name, info = info, cost = info.price, dmg = true, replace = weakest,
                                   value = (gain - weakest.dps) / info.price, cvalue = cvalue, unlock = unlock })
                    end
                elseif info.econ then
                    if S.UseFarms then
                        consider({ kind = "place", name = name, info = info, cost = info.price,
                                   value = incomeAt(info, 0) * wavesLeft / info.price })
                    end
                elseif info.buff then
                    if (counts[name] or 0) == 0 and dpsCount >= 3 then
                        buffA = { kind = "place", name = name, info = info, cost = info.price }
                    end
                else
                    local gain = dpsAt(info, 0)
                    if gain > 0 then
                        -- each extra copy of the same tower is worth a bit less: spreads the defense over
                        -- different towers (and detections) instead of stacking one cheap tower
                        local spread = 0.8 ^ (counts[name] or 0)
                        local cvalue, unlock = shortGain(info, -1)
                        consider({ kind = "place", name = name, info = info, cost = info.price, dmg = true,
                                   value = gain / info.price * spread, cvalue = cvalue * spread, unlock = unlock,
                                   bvalue = dpsAt(info, 0, true) / info.price * spread })
                    end
                end
            end
        end
    end

    if S.AutoUpgrade then
        for _, t in ipairs(towers) do
            local info = t.info
            if info and t.level < info.maxLevel and (stuck[t.uid] or 0) < os.clock() then
                local cost = info.levels[t.level + 1].cost
                if info.econ then
                    if S.UseFarms then
                        consider({ kind = "upgrade", tower = t, name = t.name, cost = cost,
                                   value = (incomeAt(info, t.level + 1) - incomeAt(info, t.level)) * wavesLeft / cost })
                    end
                elseif info.buff then
                    -- support levels (bigger buff, and abilities like DJ Booth's from level 3): cheapest first
                    if cost <= money and (not buffU or cost < buffU.cost) then
                        buffU = { kind = "upgrade", tower = t, name = t.name, cost = cost }
                    end
                else
                    local gain = dpsAt(info, t.level + 1) - dpsAt(info, t.level)
                    local cvalue, unlock = shortGain(info, t.level)
                    if gain > 0 or cvalue > 0 then
                        consider({ kind = "upgrade", tower = t, name = t.name, cost = cost, dmg = true, value = gain / cost,
                                   bvalue = (dpsAt(info, t.level + 1, true) - dpsAt(info, t.level, true)) / cost,
                                   cvalue = cvalue, unlock = unlock })
                    end
                end
            end
        end
    end

    -- missing detection beats everything except having no defense at all: plain damage can't touch those
    -- enemies, so while a category is short every dollar goes toward detection - never farms or support.
    -- (Live: a Casual run with plenty of total damage but one Pyromancer bought 4 farms at wave 15 and died to
    -- hidden zombies.) Blind: cheapest route to any detection. Partly covered: best detection per dollar.
    if #short > 0 and bestCAll and dpsCount > 0 then
        if bestC then brain.status = "buying " .. brain.short .. " detection" return bestC end
        -- save for the best step that's reachable soon (~$1500 away), not the best overall: in co-op the kill
        -- money is split three ways and a $3000 Ace Pilot upgrade took minutes while a $900 Pyromancer would do
        local save = bestReach or bestCAll
        brain.status = ("saving for %s (%s detection, $%d)"):format(save.name or "?", brain.short, save.cost)
        return nil
    end
    -- boss prep comes right after detection: no farms or support while single-target damage is short
    if bossShort and bestBAll and dpsCount > 0 then
        if bestB then brain.status = "boss prep: buying single-target damage" return bestB end
        brain.status = ("boss prep: saving for %s ($%d)"):format(bestBAll.name or "?", bestBAll.cost)
        return nil
    end
    if needDefense then
        brain.status = dpsCount == 0 and "opening defense" or (leaking and "LEAKING - buying damage") or "building damage"
        return bestD
    end
    -- economy only while safe, only if it pays back ~1.6x before the game ends, and kept in balance with damage
    if bestE and bestE.value >= 1.6 and wavesLeft >= 4 and econWorth <= dpsWorth * 1.2 + 600 then
        brain.status = "economy"
        return bestE
    end
    -- support (e.g. DJ Booth): the brain otherwise spends every dollar as it arrives, so while the defense is
    -- ahead it saves up for the booth, then levels it when comfortably ahead (its ability unlocks at level 3)
    if buffA then
        if buffA.cost <= money then brain.status = "support" return buffA end
        brain.status = ("saving for %s ($%d)"):format(buffA.name, buffA.cost)
        return nil
    end
    if buffU and totalDps >= target * 1.3 then brain.status = "support upgrade" return buffU end
    -- a far better damage buy is within reach: save for it instead of frittering cash away (not when the boss is near)
    if not lastStretch and bestDAll and bestDAll ~= bestD and bestDAll.cost > money and bestDAll.cost <= money * 3
       and (not bestD or bestD.value < bestDAll.value * 0.5) then
        brain.status = ("saving for %s ($%d)"):format(bestDAll.name or "?", bestDAll.cost)
        return nil
    end
    brain.status = "scaling damage"
    return bestD
end

local function doAction(a, towers)
    if a.kind == "place" then
        if a.replace then
            if not sellTower(a.replace.model) then return false end
            logLine(("Sold %s to make room for %s"):format(a.replace.name, a.name))
            towers = myTowers()
        end
        local ranked = rankSpots(a.info, towers)
        for i = 1, math.min(6, #ranked) do
            local p = ranked[i].p
            if placeTower(a.name, p) then
                session.placements = session.placements + 1
                logLine(("Placed %s ($%d)"):format(a.name, a.cost))
                return true
            end
            badSpot[spotKey(p)] = os.clock() + 60
            if cash() < a.cost then return false end
        end
        return false
    end
    local t = a.tower
    upgradeTower(t.model, t.info.levels[t.level + 1].path)
    task.wait(0.15)
    if towerLevel(t.model) > t.level then
        session.upgrades = session.upgrades + 1
        logLine(("Upgraded %s to %d ($%d)"):format(t.name, t.level + 1, a.cost))
        return true
    end
    stuck[t.uid] = os.clock() + 15
    return false
end

-- ---------- votes ----------
-- TDS runs every vote ("Ready?", "Restart?", wave skips, cutscene skips) through one VoteManager;
-- Voting:InvokeServer("Skip") casts YES on whichever vote is open.
local CollectionService = game:GetService("CollectionService")
local function activeVote()
    local vm = CollectionService:GetTagged("VoteManager")[1]
        or (RS:FindFirstChild("StateReplicators") and RS.StateReplicators:FindFirstChild("VoteReplicator"))
    if not vm then return nil end
    if vm:GetAttribute("Enabled") ~= true then return nil end
    return tostring(vm:GetAttribute("Title") or "")
end
local lastVote = {}
local function castVote(title)
    if os.clock() - (lastVote[title] or 0) < 3 then return end
    lastVote[title] = os.clock()
    pcall(function() Voting:InvokeServer("Skip") end)
end

local function farmTick()
    if not inMatch() then return end
    if #spots == 0 then rebuildMap() end
    local g = gameInfo()
    if lastHp and g.wave > 0 and g.hp < lastHp then lastLeak = os.clock() end
    lastHp = g.hp
    if g.hp <= 0 and g.wave > 0 then brain.status = "game over" return end
    if g.wave > 0 then scanEnemyTypes(g.wave) end
    local loadout = equippedLoadout()
    if #loadout == 0 then return end
    local towers = myTowers()
    local enemiesOut = liveEnemies() > 0
    for _, t in ipairs(towers) do
        -- final wave: farms pay out per wave, so they're dead money now - turn them into boss damage. If boss
        -- prep is short in the last 3 waves, sell them then: cash from a final-wave sale lands while the boss
        -- is already walking in (live: $11.5k of upgrades bought the second the base fell)
        local sellNow = g.total > 0 and (g.wave >= g.total or brain.bossShort)
        if S.SellFarmsEnd and sellNow and t.info and t.info.econ and sellTower(t.model) then
            logLine(("Sold %s for the boss"):format(t.name))
        else
            if S.SmartTarget then setTargeting(t, g.total > 0 and g.wave >= g.total) end
            if S.AutoAbility then useAbilities(t, enemiesOut) end
        end
    end
    for _ = 1, 3 do   -- several buys per tick so cash never piles up
        towers = myTowers()
        placedCount = #towers
        local a = chooseAction(towers, loadout, cash(), g)
        if not a or not doAction(a, towers) then break end
    end
    -- the defense is clearly ahead: full health, no leaks for a minute, the team's damage well over the wave's
    -- need, no detection gap and no boss shortfall
    local ahead = g.wave >= 2 and g.hp >= g.maxHp and os.clock() - lastLeak > 60
        and (brain.teamDps or brain.dps) >= brain.target * 1.3 and (brain.short or "") == "" and not brain.bossShort
    -- wave-skip votes: only while ahead
    local vt = activeVote()
    if vt and S.AutoSkip and vt:lower():find("skip") and not vt:lower():find("cutscene") and ahead then
        castVote(vt)
    end
    -- Timescale Tickets (solo only - the game disables time scale with 2+ players): while ahead from wave 3,
    -- spend 1 ticket to unlock it for this match, then step 1 -> 1.5 -> 2x. The cycle wraps 2x -> 0 = PAUSED,
    -- so it only steps while below 2.
    if S.UseTimescale and ahead and g.wave >= 3 then
        local GS = getGS()
        local rep = GS and GS.Replicator
        local function get(k) local ok, v = pcall(function() return rep:Get(k) end) return ok and v end
        if rep and get("PlayerCount") == 1 and get("TimeScaleDisabled") ~= true and get("NewGameModes") == true then
            local TM = Net.Channel("TicketsManager")
            local scale = tonumber(get("TimeScale")) or 1
            if get("TimeScaleLocked") == true then
                if os.clock() - (session.lastTimescaleTry or 0) > 30 then
                    session.lastTimescaleTry = os.clock()
                    local ok, res, err = pcall(function() return TM:InvokeServer("UnlockTimeScale") end)
                    logLine(ok and res and "Used a Timescale Ticket (speed-up unlocked for this match)"
                        or ("Timescale unlock failed: " .. tostring(ok and err or res)))
                end
            elseif scale >= 1 and scale < 2 and os.clock() - (session.lastTimescaleStep or 0) > 2 then
                session.lastTimescaleStep = os.clock()
                pcall(function() TM:FireServer("CycleTimeScale") end)
            end
        end
    end
end

-- main farm loop
task.spawn(function()
    while alive do
        task.wait(0.3)
        if S.AutoFarm then
            local ok, err = pcall(farmTick)
            if not ok then brain.status = "error: " .. tostring(err) end
        end
    end
end)

-- vote room: the chosen map has to win the board vote. If it's already on a board, stand on it and vote
-- (works without VIP). Otherwise VIP+ "Override" swaps it onto a board - it doesn't pick the map by itself,
-- so we still vote for it after. (Override rejects maps already in the rotation.)
local function pickMap(room)
    local LV = Net.Channel("LobbyVoting")
    local boards = room:WaitForChild("Boards", 10)
    local display = S.VIPMap   -- boards show the map's DisplayName
    pcall(function() display = getAsset()("NewMaps", S.VIPMap).DisplayName or S.VIPMap end)
    local function voteIfShown()
        for _, b in ipairs(boards and boards:GetChildren() or {}) do
            local title = b:FindFirstChild("Hitboxes") and b.Hitboxes:FindFirstChild("Bottom")
            title = title and title:FindFirstChild("MapDisplay") and title.MapDisplay:FindFirstChild("Title")
            if title and (title.Text == S.VIPMap or title.Text == display) then
                -- same as the board's ProximityPrompt: ("Vote", mapName, characterPosition), standing on the board
                local char, pad = lp.Character, b.Hitboxes:FindFirstChild("VotePlatform")
                if char and pad then pcall(function() char:PivotTo(pad.CFrame + Vector3.new(0, 3, 0)) end) task.wait(0.3) end
                pcall(function() LV:FireServer("Vote", S.VIPMap, char and char:GetPivot().Position) end)
                return true
            end
        end
        return false
    end
    if voteIfShown() then logLine("Voted map: " .. S.VIPMap) return end
    if not ownsVIP() then logLine(S.VIPMap .. " isn't on a board and you don't have VIP+ to override") return end
    -- loaded by autoexec the hub gets here seconds after joining, before the server has applied VIP+
    -- ("You are not authorized..."), so retry for a while; the room's timer only starts on the first vote
    local ok, res, msg
    local onBoard = false
    for attempt = 1, 7 do
        ok, res, msg = pcall(function() return LV:InvokeServer("Override", S.VIPMap) end)
        if ok and res then break end
        -- already on a board (its title just hadn't shown yet): nothing to override, vote for it below
        if ok and tostring(msg):find("rotation") then onBoard = true break end
        if attempt < 7 then task.wait(4) end
    end
    if not (ok and res) and not onBoard then logLine("VIP map failed: " .. tostring(ok and msg or res)) return end
    for _ = 1, 20 do   -- the board updates a moment after the override
        task.wait(0.25)
        if voteIfShown() then logLine("VIP map: " .. S.VIPMap .. " (overridden + voted)") return end
    end
    -- loaded this early, the game's board UI can miss the override event and never show the map; the server
    -- still knows it, so vote by name from its board: the workspace Map1..4 attributes say which one (an
    -- override lands on Board1)
    local slot = 1
    for n = 1, 4 do if Workspace:GetAttribute("Map" .. n) == S.VIPMap then slot = n end end
    local b = boards and (boards:FindFirstChild("Board" .. slot) or boards:GetChildren()[1])
    local char, pad = lp.Character, b and b:FindFirstChild("Hitboxes") and b.Hitboxes:FindFirstChild("VotePlatform")
    if char and pad then pcall(function() char:PivotTo(pad.CFrame + Vector3.new(0, 3, 0)) end) task.wait(0.3) end
    pcall(function() LV:FireServer("Vote", S.VIPMap, char and char:GetPivot().Position) end)
    logLine("VIP map: " .. S.VIPMap .. (onBoard and " (on board " .. slot .. ", voted by name)" or " (overridden + voted by name)"))
end

-- difficulty vote, game-over detection, rematch
task.spawn(function()
    local overSince, matchStart
    local lastReady, overriddenRoom = 0, nil
    while alive do
        task.wait(1)
        -- match server's map-vote room ("Vote For A Map" + Ready/Veto): VIP+ forces the chosen map, then ready up
        local room = Workspace:FindFirstChild("IntermissionLobby")
        if S.AutoFarm and room and S.VIPMap ~= "" and overriddenRoom ~= room and not coopFollower() then
            overriddenRoom = room
            pickMap(room)
            task.wait(1)
        end
        if S.AutoFarm and S.AutoVote and room and os.clock() - lastReady > 5 then
            lastReady = os.clock()
            pcall(function() Net.Channel("LobbyVoting"):FireServer("Ready") end)
        end
        if S.AutoFarm and inMatch() then
            local g = gameInfo()
            if S.AutoVote and g.wave == 0 then pcall(function() Difficulty:InvokeServer("Vote", S.VoteMode) end) end
            local vt = activeVote()
            if vt then
                local low = vt:lower()
                if low:find("ready") or low:find("cutscene") then
                    castVote(vt)                                   -- start the match / skip cutscenes
                elseif low:find("restart") and S.AutoRematch and (coopFollower() or not (S.AutoJoin and chooseMode() ~= matchMode())) then
                    castVote(vt)                                   -- replay after a loss (unless switching mode)
                end
            end
            -- earnings baseline; only trusted if we saw the match from wave 1 (a mid-match reload would
            -- understate the time and inflate coins/hour)
            -- not while a game-over screen is up (a hub (re)loaded onto one would record that result twice)
            local over = g.hp <= 0 or (g.total > 0 and g.wave >= g.total and liveEnemies() == 0)
            if g.wave >= 1 and not matchStart and not overSince and not over then
                settleEarnings()   -- the previous match's payout has landed by now
                matchStart = { t = os.time(), coins = statValue("Coins"), fromStart = g.wave <= 1 }
            end
            local won = g.total > 0 and g.wave >= g.total and Workspace:FindFirstChild("NPCs") ~= nil
                and liveEnemies() == 0 and g.hp > 0
            local lost = g.wave > 0 and g.maxHp > 0 and g.hp <= 0
            if won or lost then
                if not overSince then
                    overSince = os.clock()
                    session.lastWon = won
                    if won then session.wins = session.wins + 1 else session.losses = session.losses + 1 end
                    saveSession()
                    logLine(won and "WON the match" or "Lost the match")
                    -- record now: after a loss the restart vote can start the next run within seconds,
                    -- which would wipe this match's state before the rematch step below runs
                    -- a match played with building switched off says nothing about the mode or loadout
                    if matchStart and S.AutoPlace and S.AutoUpgrade then
                        local m = statKey(matchMode())   -- "+coop" when played as a party
                        recordResult(won, m)
                        if matchStart.fromStart then leavePending(m, matchStart) end
                        matchStart = nil
                    end
                end
                if S.AutoRematch and os.clock() - overSince > 6 and os.clock() - (session.lastRematch or 0) > 8 then
                    session.lastRematch = os.clock()
                    local nextMode = coopFollower() and matchMode() or chooseMode()   -- members follow the leader
                    -- Play Again can hang (seen live: fired every 8s for minutes, no teleport) and a missed
                    -- Restart vote expires; after ~45s on the game-over screen take the lobby route instead
                    local playAgainStuck = os.clock() - overSince > 45
                    if S.AutoJoin and (nextMode ~= matchMode() or playAgainStuck) then
                        -- a different mode means a different elevator: back to the lobby, Auto join takes it from there
                        logLine(playAgainStuck and "Stuck on the game-over screen - back to lobby"
                            or ("Switching to %s - back to lobby"):format(nextMode))
                        pcall(function() game:GetService("TeleportService"):Teleport(LOBBY_PLACE) end)
                    elseif session.lastWon then
                        -- after a win "Play Again" matchmakes a fresh game
                        if GameMgr then pcall(function() GameMgr:fireServer("Rematch") end) end
                        logLine("Play again (matchmaking)")
                    else
                        -- after a loss it's the "Restart?" vote (also handled by the vote reader above)
                        castVote("Restart?")
                        logLine("Voted restart")
                    end
                end
            elseif overSince then
                overSince = nil                    -- a new match started on this server
                matchStart = nil
                rebuildMap() lastHp = nil lastLeak = -1e9 stuck = {}
            end
        end
    end
end)

-- ---------- meta claims (lobby) ----------
local function rf(folder, name)
    local f = NetFolder and NetFolder:FindFirstChild(folder)
    return f and f:FindFirstChild("RF:" .. name)
end
task.spawn(function()
    while alive do
        task.wait(8)
        if S.AutoPlaytime then
            local r = rf("PlaytimeRewards", "ClaimReward")
            if r then pcall(function() r:InvokeServer() end) end
        end
        if S.AutoDaily then
            local g = rf("DailySpin", "GetDailyReward")
            if g then pcall(function() g:InvokeServer() end) end
            local s = rf("DailySpin", "RedeemSpin")
            if s then pcall(function() s:InvokeServer() end) end
        end
    end
end)

-- quests + achievements: same calls the lobby's Quest window and LogBook make
local function claimQuests()
    if not (NewNet and NewNet.Channel) then return end
    local Q = NewNet.Channel("Quests")
    local ok, st = pcall(function() return Q:invokeServer("RequestState") end)
    if ok and type(st) == "table" and type(st.groups) == "table" then
        for _, group in pairs(st.groups) do
            for _, q in pairs(type(group) == "table" and group or {}) do
                if type(q) == "table" and q.started and type(q.id) == "string" then
                    local okC, res = pcall(function() return Q:invokeServer("ClaimQuest", q.id) end)
                    if okC and res == true then logLine("Claimed quest " .. (q.source or q.id)) end
                end
            end
        end
    end
    local Cache = getCache()
    local okA, ach = pcall(function() local c = Cache("Achievements") return type(c._data) == "function" and c._data() or c._data end)
    if okA and type(ach) == "table" then
        local A = NewNet.Channel("Achievements")
        for name, v in pairs(ach) do
            -- true = already claimed; {completed=true} = done but unclaimed
            if type(v) == "table" and v.completed and type(name) == "string" then
                local okC, res = pcall(function() return A:invokeServer("Claim", name) end)
                if okC and res then logLine("Claimed achievement " .. name) end
            end
        end
    end
end
-- crates you own (Cache "Inventory.Crates" = {name = count}), opened like the inventory's Open button
local function openCrates()
    local Cache, UINet = getCache(), lazy("UINet", "Shared.UI.Network", 3)
    local Inv = UINet and UINet.Channel and UINet.Channel("Inventory")
    local ok, crates = pcall(function() local c = Cache("Inventory.Crates") return type(c._data) == "function" and c._data() or c._data end)
    if not (Inv and ok and type(crates) == "table") then return end
    for name, count in pairs(crates) do
        for _ = 1, math.min(tonumber(count) or 0, 25) do
            local okO, res, err = pcall(function() return Inv:InvokeServer("Open", "Crate", name) end)
            if not (okO and res) then logLine(("Crate %s: %s"):format(name, tostring(okO and err or res))) break end
            session.crates = (session.crates or 0) + 1
            logLine("Opened " .. name .. " crate")
            task.wait(1.5)
        end
    end
end
task.spawn(function()
    while alive do
        -- lobby or a match server's vote room: the inventory locks once the game starts
        -- ("Cannot change inventory after the game has started!"), and Play Again rarely visits the lobby
        if not inMatch() then
            if S.AutoQuests then pcall(claimQuests) end
            if S.AutoCrates then pcall(openCrates) end
        end
        task.wait(60)
    end
end)

-- anti-AFK: Roblox kicks after 20 idle minutes; a fake input on Idled resets the timer
local VirtualUser = game:GetService("VirtualUser")
local idleConn = lp.Idled:Connect(function()
    if S.AntiAFK then pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end) end
end)

-- ---------- loadout recommendation (TDS won't let scripts equip, so we recommend) ----------
local function ownedTowers()
    local Cache = getCache()
    if type(Cache) ~= "function" then return {} end
    local ok, inv = pcall(function() local c = Cache("Inventory.Troops") return type(c._data) == "function" and c._data() or c._data end)
    local list = {}
    if ok and type(inv) == "table" then for name in pairs(inv) do if type(name) == "string" then list[#list + 1] = name end end end
    return list
end
-- co-op roles (slot in the party): each player brings a different kind of defense so the party covers more
local ROLE_NAMES = { "Economy + damage", "Hidden detection", "Boss damage", "Support" }
local function recommend(owned, mode, role)
    role = role or 1
    mode = mode or S.VoteMode
    -- enemy types to cover: hidden and flying always (hidden kills most runs), plus anything seen on this mode
    local cats, catSet = { "hidden", "flying" }, { hidden = true, flying = true }
    for cat in pairs(firstSeen[mode] or {}) do
        if not catSet[cat] then catSet[cat] = true cats[#cats + 1] = cat end
    end
    local infos = {}
    for _, n in ipairs(owned) do local i = towerInfo(n) if i then infos[#infos + 1] = i end end
    local pick, used = {}, {}
    local function take(i) if i and not used[i.name] and #pick < 5 then pick[#pick + 1] = i.name used[i.name] = true end end
    for _, i in ipairs(infos) do if i.econ then take(i) break end end          -- economy
    if role == 4 then                                                          -- support: bring a buff tower
        for _, i in ipairs(infos) do if i.buff then take(i) break end end
    end
    local opener                                                               -- cheap wave-1 damage
    for _, i in ipairs(infos) do
        if not i.econ and not i.buff and i.price <= 600 then
            local v = dpsAt(i, 0) / i.price
            if not opener or v > opener.v then opener = { i = i, v = v } end
        end
    end
    if opener then take(opener.i) end
    -- hidden enemies arrive by wave 8 on Easy, flying ones later/on harder modes: make sure something sees
    -- each cheaply (cost to its first level with that detection, e.g. Pyromancer hidden = $900 + $325)
    local function detectCost(i, cat)
        local sum = i.price
        for L = 0, i.maxLevel do
            if L > 0 then sum = sum + i.levels[L].cost end
            if i.levels[L][cat] then return sum end
        end
        return math.huge
    end
    for _, cat in ipairs(cats) do
        local covered = false
        for _, n in ipairs(pick) do
            local i = towerInfo(n)
            if i and detectCost(i, cat) <= 2500 then covered = true end
        end
        if not covered then
            local best
            for _, i in ipairs(infos) do
                if not i.econ and not i.buff and not used[i.name] and (not best or detectCost(i, cat) < detectCost(best, cat)) then best = i end
            end
            if best and detectCost(best, cat) < math.huge then take(best) end
        end
    end
    -- late-game carries, judged on what a match can actually afford: the best level reachable within
    -- MATCH_BUDGET (a maxed Turret costs $139k - you never get there on a 20-wave Easy run)
    local MATCH_BUDGET = 15000
    local scale = {}
    for _, i in ipairs(infos) do
        if not i.econ and not i.buff and not used[i.name] then
            local total, lvl = i.price, 0
            for L = 1, i.maxLevel do
                if total + i.levels[L].cost > MATCH_BUDGET then break end
                total, lvl = total + i.levels[L].cost, L
            end
            if total <= MATCH_BUDGET then
                -- a carry that can't see hidden enemies at that level only counts for part of its damage
                -- half group damage, half single-target: the final boss is one big target
                local sees = i.levels[lvl].hidden
                local top = (dpsAt(i, lvl) + dpsAt(i, lvl, true)) / 2 * (sees and 1 or 0.4)
                if role == 2 then top = dpsAt(i, lvl) * (sees and 1 or 0.1)          -- detection: hidden-capable only
                elseif role == 3 then top = dpsAt(i, lvl, true) * (sees and 1 or 0.6) end -- boss: single-target
                scale[#scale + 1] = { i = i, top = top, eff = top / total }
            end
        end
    end
    table.sort(scale, function(a, b) return a.top > b.top end)
    for k = 1, math.min(2, #scale) do take(scale[k].i) end
    table.sort(scale, function(a, b) return a.eff > b.eff end)
    for _, s in ipairs(scale) do take(s.i) end
    return pick
end
-- equip a loadout the way the lobby inventory does: Shared.UI.Network (not Shared.Modules.Network)
-- Inventory channel, ("Unequip"|"Equip", "tower", name). Unequip first so the 5 slots have room.
local function equipLoadout(names)
    local UINet = lazy("UINet", "Shared.UI.Network", 3)
    local Inv = UINet and UINet.Channel and UINet.Channel("Inventory")
    if not Inv then return false, "inventory channel not found" end
    local want, have = {}, {}
    for _, n in ipairs(names) do want[n] = true end
    for _, n in ipairs(equippedLoadout()) do
        have[n] = true
        if not want[n] then pcall(function() Inv:InvokeServer("Unequip", "tower", n) end) end
    end
    local errs = {}
    for _, n in ipairs(names) do
        if not have[n] then
            local ok, res, msg = pcall(function() return Inv:InvokeServer("Equip", "tower", n) end)
            if not (ok and res) then errs[#errs + 1] = n .. ": " .. tostring(ok and msg or res) end
        end
    end
    task.wait(1)
    local now = {}
    for _, n in ipairs(equippedLoadout()) do now[n] = true end
    for _, n in ipairs(names) do if not now[n] then return false, #errs > 0 and table.concat(errs, "; ") or (n .. " didn't equip") end end
    return true
end

-- towers worth buying: not owned, sold for coins (Properties.Price Type 2; 3 = gems, 1 = event/crate only),
-- affordable now, ranked like recommend() ranks carries for this player's role. Suggestions only - never buys.
local function buySuggestions(role)
    local folder = RS:FindFirstChild("Content") and RS.Content:FindFirstChild("Tower")
    local Asset = getAsset()
    if not (folder and Asset) then return {} end
    local owned = {}
    for _, n in ipairs(ownedTowers()) do owned[n] = true end
    local coins, list = statValue("Coins"), {}
    for _, child in ipairs(folder:GetChildren()) do
        local n = child.Name
        local ok, a = pcall(Asset, "Troops", n)
        local price = ok and type(a) == "table" and type(a.Properties) == "table" and a.Properties.Price
        local info = not owned[n] and type(price) == "table" and price.Type == 2 and tonumber(price.Value)
            and price.Value <= coins and towerInfo(n)
        if info then
            local total, lvl = info.price, 0
            for L = 1, info.maxLevel do
                if total + info.levels[L].cost > 15000 then break end
                total, lvl = total + info.levels[L].cost, L
            end
            local sees = info.levels[lvl].hidden
            local score = (dpsAt(info, lvl) + dpsAt(info, lvl, true)) / 2 * (sees and 1 or 0.4)
            if role == 2 then score = dpsAt(info, lvl) * (sees and 1 or 0.1)
            elseif role == 3 then score = dpsAt(info, lvl, true) * (sees and 1 or 0.6)
            elseif info.buff then score = role == 4 and 1e6 or 0 end
            if score > 0 then
                list[#list + 1] = { name = n, cost = price.Value, score = score, hidden = sees, buff = info.buff, econ = info.econ }
            end
        end
    end
    table.sort(list, function(x, y) return x.score > y.score end)
    return list
end

-- ---------- co-op (party) ----------
-- Uses TDS's own lobby party system: Network.Channel("Party") CreateParty / InvitePlayer / AcceptInvite /
-- LeaveParty, and the client PartyStore ({party = {players, invited, partyParams}, invites = {inviters}}).
-- The hubs never message each other: every member sees the same party list, so each one works out its slot
-- (1 = leader) and role from it. The party store only exists in the lobby, so slot and size are saved to
-- settings for match servers.
local PartyChan = Net.Channel("Party")
local coopLeaderId   -- party leader's UserId while in the lobby
local coopEnteredAt = 0
local function partyState()
    local PS = lazy("PartyStore", "Client.Interfaces.Stores.Lobby.PartyStore", 3)
    local ok, st = pcall(function() return PS.getState() end)
    return ok and type(st) == "table" and st or nil
end
local function isMe(v) return v == lp or v == lp.UserId or (typeof(v) == "Instance" and v == lp) end
local function playerName(v)
    if typeof(v) == "Instance" then return v.DisplayName end
    local p = tonumber(v) and Players:GetPlayerByUserId(v)
    return p and p.DisplayName or tostring(v)
end
local function coopResult(what, ok, res)
    local good = ok and type(res) == "table" and res.success
    logLine(good and what or (what .. " failed: " .. tostring(ok and type(res) == "table" and res.error or res)))
    return good
end
local function coopInvite(plr)
    local st = partyState()
    if st and st.party then
        return coopResult("Invited " .. plr.DisplayName, pcall(function() return PartyChan:InvokeServer("InvitePlayer", plr) end))
    end
    return coopResult("Made a party and invited " .. plr.DisplayName, pcall(function() return PartyChan:InvokeServer("CreateParty", plr) end))
end
local function coopLeave()
    return coopResult("Left the party", pcall(function() return PartyChan:InvokeServer("LeaveParty") end))
end
local function isFriend(plr)
    local ok, yes = pcall(function() return lp:IsFriendsWith(plr.UserId) end)
    return ok and yes
end
-- lobby: keep slot/size current and accept friends' invites
task.spawn(function()
    while alive do
        task.wait(3)
        local t = Workspace:FindFirstChild("Type")
        local st = t and t.Value == "Lobby" and partyState()
        if st then
            local role, size = 1, 1
            if type(st.party) == "table" and type(st.party.players) == "table" then
                size = #st.party.players
                for i, v in ipairs(st.party.players) do if isMe(v) then role = i end end
                local lead = st.party.players[1]
                coopLeaderId = typeof(lead) == "Instance" and lead.UserId or tonumber(lead)
            else
                coopLeaderId = nil
            end
            if role ~= S.CoopRole or size ~= S.CoopSize then
                S.CoopRole, S.CoopSize = role, size
                saveSettings()
                logLine(size > 1 and ("Co-op: party of %d, you are slot %d (%s)"):format(size, role, ROLE_NAMES[math.min(role, #ROLE_NAMES)]) or "Co-op: no party")
            end
            if S.Coop and S.CoopAccept and not st.party then
                for _, inviter in ipairs(type(st.invites) == "table" and st.invites or {}) do
                    if typeof(inviter) == "Instance" and isFriend(inviter) then
                        coopResult("Joined " .. inviter.DisplayName .. "'s party",
                            pcall(function() return PartyChan:InvokeServer("AcceptInvite", inviter) end))
                        break
                    end
                end
            end
        end
    end
end)

-- best loadout for a mode, from real results first:
--   1) a loadout that's winning on this mode (2+ wins, more than twice its losses)
--   2) else the best winner on any mode, unless it has already lost twice here
--   3) else a fresh recommendation covering that mode's enemy types (hidden always)
function bestLoadoutFor(mode)
    local owned, ownedSet = ownedTowers(), {}
    for _, n in ipairs(owned) do ownedSet[n] = true end
    -- co-op: the leader keeps the proven/solo logic; everyone else brings their role's loadout
    if S.Coop and S.CoopSize > 1 and S.CoopRole > 1 and #owned > 0 then
        local role = math.clamp(S.CoopRole, 1, #ROLE_NAMES)
        return recommend(owned, mode, role), "co-op role: " .. ROLE_NAMES[role]
    end
    local function names(key) local t = {} for n in key:gmatch("[^,]+") do t[#t + 1] = n end return t end
    local function usable(key)
        for _, n in ipairs(names(key)) do if not ownedSet[n] then return false end end
        return true
    end
    local function winning(r) return r.w >= 2 and r.w > r.l * 2 end
    local best, bestScore
    local mkey = statKey(mode)   -- results for this mode, played this way (solo or co-op)
    for key, r in pairs(records[mkey] or {}) do
        if winning(r) and usable(key) and (not bestScore or r.w - 2 * r.l > bestScore) then best, bestScore = key, r.w - 2 * r.l end
    end
    if best then return names(best), "winning on " .. mkey end
    local here = records[mkey] or {}
    for rkey in pairs(records) do
        for key, r in pairs(type(records[rkey]) == "table" and records[rkey] or {}) do
            local lostHere = here[key] and here[key].l >= 2 and here[key].w < here[key].l
            if winning(r) and usable(key) and not lostHere and (not bestScore or r.w - 2 * r.l > bestScore) then
                best, bestScore = key, r.w - 2 * r.l
            end
        end
    end
    if best then return names(best), "proven on other modes" end
    if #owned == 0 then return equippedLoadout(), "inventory unreadable - keeping current" end
    return recommend(owned, mode), "recommended for " .. mode
end

-- lobby -> match: step into an empty Survival elevator for VoteMode, make it solo, ready up
local function myElevator()
    for _, e in ipairs(CollectionService:GetTagged("Elevator")) do
        if e:GetAttribute("LeaderUserId") == lp.UserId then return e end
    end
end
-- equip the best loadout for a mode (and co-op role) before queueing; false = not ready yet, try again later.
-- Autoexec gets here seconds after joining, often before the inventory cache has loaded; without it the pick
-- falls back to "keep current" (live: 4 Casual runs on the Easy loadout), so wait for it.
local function equipForMode(mode)
    if not S.AutoLoadout then return true end
    if #ownedTowers() == 0 and os.clock() - session.loadClock < 40 then
        brain.status = "waiting for inventory before queueing"
        return false
    end
    local want, why = bestLoadoutFor(mode)
    if #want > 0 and loadoutKey(want) ~= loadoutKey(equippedLoadout()) then
        local ok, err = equipLoadout(want)
        logLine(ok and ("Equipped for %s (%s): %s"):format(mode, why, table.concat(want, ", "))
            or ("Loadout equip failed: " .. tostring(err)))
    end
    return true
end
local function joinMatch()
    local t = Workspace:FindFirstChild("Type")
    if not (t and t.Value == "Lobby") or lp:GetAttribute("Teleporting") or not (NewNet and NewNet.Channel) then return end
    -- co-op: only the party leader queues; the party carries everyone else into the match
    local coop = S.Coop and S.CoopSize > 1
    if S.Coop and not coop then
        brain.status = "co-op: waiting for a party - invite players in the Co-op tab (or turn Co-op off to play solo)"
        return
    end
    local El = NewNet.Channel("Elevators")
    if coop and S.CoopRole > 1 then
        -- follower: get the role loadout on first (the leader's elevator countdown is short, and the party
        -- can pull us in before we'd otherwise get to it), then step into the leader's elevator - harmless if
        -- the party already pulled us in
        if not equipForMode(S.VoteMode) then return end
        if os.clock() - coopEnteredAt < 60 then brain.status = "co-op: in the leader's elevator" return end
        for _, e in ipairs(CollectionService:GetTagged("Elevator")) do
            if coopLeaderId and e:GetAttribute("LeaderUserId") == coopLeaderId and e:FindFirstChild("Touch") then
                local char = lp.Character
                if char then pcall(function() char:PivotTo(e.Touch.CFrame + Vector3.new(0, 3, 0)) end) end
                local ok, entered = pcall(function() return El:invokeServer("Enter", e) end)
                if ok and entered then coopEnteredAt = os.clock() logLine("Co-op: joined the leader's elevator") end
                return
            end
        end
        brain.status = "co-op: waiting for the party leader to queue"
        return
    end
    if myElevator() then return end   -- already in one; its countdown teleports us
    local mode = chooseMode()
    local pick
    for _, e in ipairs(CollectionService:GetTagged("Elevator")) do
        if e:GetAttribute("Type") == "Survival" and e:GetAttribute("Difficulty") == mode
           and (e:GetAttribute("Players") or 1) == 0 and e:FindFirstChild("Touch")
           and (e:GetAttribute("Capacity") or 4) >= (coop and S.CoopSize or 1) then
            pick = e break
        end
    end
    if not pick then brain.status = "waiting for a free " .. mode .. " elevator" return end
    if not equipForMode(mode) then return end
    local char = lp.Character
    if char then pcall(function() char:PivotTo(pick.Touch.CFrame + Vector3.new(0, 3, 0)) end) end
    local ok, entered = pcall(function() return El:invokeServer("Enter", pick) end)
    if not (ok and entered) then return end
    task.wait(1)
    pcall(function() El:invokeServer("SetSize", coop and S.CoopSize or 1) end)   -- solo, or room for the party
    task.wait(0.5)
    pcall(function() El:invokeServer("SetReady", true) end)
    logLine(("Joined %s elevator (%s)%s"):format(mode, tostring(pick:GetAttribute("Map")), coop and (" with a party of " .. S.CoopSize) or ""))
end
task.spawn(function()
    while alive do
        task.wait(5)
        if S.AutoJoin and S.AutoFarm then pcall(joinMatch) end
    end
end)

-- watchdog: if the farm's state hasn't moved for minutes (lobby that never queues, vote room that never
-- starts, a match whose wave/health/towers/cash stop changing, a failed Play Again), go back to the lobby;
-- autoexec + Auto join restart the loop from there
task.spawn(function()
    local sig, since = nil, os.clock()
    while alive do
        task.wait(5)
        if S.AutoFarm and S.Watchdog then
            local cur, limit
            local t = Workspace:FindFirstChild("Type")
            if inMatch() then
                local g = gameInfo()
                cur, limit = ("match %d %d %d %d"):format(g.wave, g.hp, placedCount, math.floor(cash() / 250)), 300
            elseif Workspace:FindFirstChild("IntermissionLobby") then
                cur, limit = "vote room", 150
            elseif t and t.Value == "Lobby" then
                cur, limit = myElevator() and "lobby, in elevator" or "lobby", S.AutoJoin and 240 or nil
            else
                cur, limit = "other", 300
            end
            if cur ~= sig then
                sig, since = cur, os.clock()
            elseif limit and os.clock() - since > limit then
                logLine(("Watchdog: stuck (%s) for %ds - rejoining"):format(cur, math.floor(os.clock() - since)))
                since = os.clock()
                pcall(function() game:GetService("TeleportService"):Teleport(LOBBY_PLACE) end)
            end
        end
    end
end)

-- ======================================================================
-- UI  (purple Cookies Hub theme)
-- ======================================================================
local C = {
    bg=Color3.fromRGB(20,16,30), panel=Color3.fromRGB(30,24,44), row=Color3.fromRGB(42,34,60),
    accent=Color3.fromRGB(171,113,235), accent2=Color3.fromRGB(139,92,214), danger=Color3.fromRGB(226,90,90),
    text=Color3.fromRGB(236,232,245), text2=Color3.fromRGB(165,158,185),
}
local function corner(p, r) local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, r or 8) c.Parent = p return c end

local gui = Instance.new("ScreenGui")
gui.Name = "CookiesHubTDS" gui.ResetOnSpawn = false gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true gui.DisplayOrder = 9999
pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = lp:WaitForChild("PlayerGui") end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(430, 480) main.Position = UDim2.new(0.5, -215, 0.5, -240)
main.BackgroundColor3 = C.bg main.BorderSizePixel = 0 main.Active = true main.Parent = gui corner(main, 12)

local bar = Instance.new("Frame") bar.Size = UDim2.new(1, 0, 0, 40) bar.BackgroundColor3 = C.panel
bar.BorderSizePixel = 0 bar.Parent = main corner(bar, 12)
local title = Instance.new("TextLabel") title.BackgroundTransparency = 1 title.Position = UDim2.fromOffset(14, 0)
title.Size = UDim2.new(1, -90, 1, 0) title.Font = Enum.Font.GothamBold title.TextSize = 15 title.TextColor3 = C.text
title.TextXAlignment = Enum.TextXAlignment.Left title.Text = "Cookies Hub  -  Tower Defense" title.Parent = bar
-- wins/losses at a glance: in the title bar (every tab, even minimised) and as a card on top of the Farm tab.
-- All in one table: the hub's top level is close to Luau's 200-local cap.
local score = {}
score.title = Instance.new("TextLabel")
do
    local s = score.title
    s.BackgroundTransparency = 1 s.AnchorPoint = Vector2.new(1, 0.5) s.Position = UDim2.new(1, -72, 0.5, 0)
    s.Size = UDim2.fromOffset(120, 24) s.Font = Enum.Font.GothamBold s.TextSize = 15 s.RichText = true
    s.TextXAlignment = Enum.TextXAlignment.Right s.TextColor3 = C.text s.Text = "" s.Parent = bar
end
local function topBtn(t, x, col)
    local b = Instance.new("TextButton") b.Size = UDim2.fromOffset(24, 24) b.Position = UDim2.new(1, x, 0.5, -12)
    b.BackgroundColor3 = col b.Text = t b.Font = Enum.Font.GothamBold b.TextSize = 14 b.TextColor3 = C.text
    b.BorderSizePixel = 0 b.Parent = bar corner(b, 6) return b
end
local minBtn = topBtn("-", -62, C.row)
local closeBtn = topBtn("X", -32, C.danger)

local tabRow = Instance.new("Frame") tabRow.Size = UDim2.new(1, -20, 0, 30) tabRow.Position = UDim2.fromOffset(10, 48)
tabRow.BackgroundTransparency = 1 tabRow.Parent = main
local tl = Instance.new("UIListLayout") tl.FillDirection = Enum.FillDirection.Horizontal tl.Padding = UDim.new(0, 6) tl.Parent = tabRow
local body = Instance.new("Frame") body.Size = UDim2.new(1, -20, 1, -90) body.Position = UDim2.fromOffset(10, 84)
body.BackgroundTransparency = 1 body.Parent = main

local tabs, tabBtns = {}, {}
local function selectTab(n)
    for k, p in pairs(tabs) do p.Visible = k == n end
    for k, b in pairs(tabBtns) do b.BackgroundColor3 = k == n and C.accent or C.row b.TextColor3 = k == n and C.bg or C.text2 end
end
local function addTab(n)
    local b = Instance.new("TextButton") b.Size = UDim2.new(1 / 7, -5, 1, 0) b.BackgroundColor3 = C.row b.Text = n
    b.Font = Enum.Font.GothamMedium b.TextSize = 12 b.TextColor3 = C.text2 b.BorderSizePixel = 0 b.Parent = tabRow corner(b, 6)
    local p = Instance.new("ScrollingFrame") p.Size = UDim2.fromScale(1, 1) p.BackgroundTransparency = 1 p.BorderSizePixel = 0
    p.ScrollBarThickness = 3 p.CanvasSize = UDim2.new() p.AutomaticCanvasSize = Enum.AutomaticSize.Y p.Visible = false p.Parent = body
    local l = Instance.new("UIListLayout") l.Padding = UDim.new(0, 8) l.SortOrder = Enum.SortOrder.LayoutOrder l.Parent = p
    tabs[n] = p tabBtns[n] = b b.MouseButton1Click:Connect(function() selectTab(n) end)
    return p
end
local function sec(parent, t)
    local l = Instance.new("TextLabel") l.Size = UDim2.new(1, 0, 0, 18) l.BackgroundTransparency = 1
    l.Font = Enum.Font.GothamBold l.TextSize = 12 l.TextColor3 = C.accent l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = string.upper(t) l.Parent = parent return l
end
local function note(parent, t)
    local l = Instance.new("TextLabel") l.Size = UDim2.new(1, 0, 0, 16) l.AutomaticSize = Enum.AutomaticSize.Y
    l.BackgroundTransparency = 1 l.Font = Enum.Font.Gotham l.TextSize = 12 l.TextColor3 = C.text2 l.TextWrapped = true
    l.TextXAlignment = Enum.TextXAlignment.Left l.Text = t l.Parent = parent return l
end
local toggleRender = {}   -- key -> redraw, so console Set() keeps the switches in sync
local function Toggle(parent, label, key, onChange)
    local row = Instance.new("Frame") row.Size = UDim2.new(1, 0, 0, 34) row.BackgroundColor3 = C.row row.BorderSizePixel = 0 row.Parent = parent corner(row, 6)
    local t = Instance.new("TextLabel") t.BackgroundTransparency = 1 t.Position = UDim2.fromOffset(12, 0) t.Size = UDim2.new(1, -70, 1, 0)
    t.Font = Enum.Font.GothamMedium t.TextSize = 13 t.TextColor3 = C.text t.TextXAlignment = Enum.TextXAlignment.Left t.Text = label t.Parent = row
    local knob = Instance.new("TextButton") knob.Size = UDim2.fromOffset(44, 22) knob.Position = UDim2.new(1, -56, 0.5, -11)
    knob.BackgroundColor3 = S[key] and C.accent or C.bg knob.Text = "" knob.BorderSizePixel = 0 knob.Parent = row corner(knob, 11)
    local dot = Instance.new("Frame") dot.Size = UDim2.fromOffset(18, 18) dot.Position = S[key] and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9)
    dot.BackgroundColor3 = C.text dot.BorderSizePixel = 0 dot.Parent = knob corner(dot, 9)
    local function render()
        knob.BackgroundColor3 = S[key] and C.accent or C.bg
        dot:TweenPosition(S[key] and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.12, true)
    end
    knob.MouseButton1Click:Connect(function() S[key] = not S[key] render() saveSettings() if onChange then pcall(onChange, S[key]) end end)
    toggleRender[key] = render
    return { set = function(v) S[key] = v render() end }
end
local function Button(parent, label, col, fn)
    local b = Instance.new("TextButton") b.Size = UDim2.new(1, 0, 0, 32)
    b.BackgroundColor3 = col or C.accent2 b.Text = label b.Font = Enum.Font.GothamMedium b.TextSize = 13 b.TextColor3 = C.text
    -- own thread: actions call the server and wait for it (party invites, equips), which can't yield inside the
    -- click handler's call chain ("attempt to yield across metamethod/C-call boundary")
    b.BorderSizePixel = 0 b.Parent = parent corner(b, 6) b.MouseButton1Click:Connect(function() task.spawn(pcall, fn) end) return b
end

-- Farm tab
local farmTab = addTab("Farm")
do   -- scoreboard card: three big numbers + coins line
    local card = Instance.new("Frame") card.Size = UDim2.new(1, 0, 0, 86) card.BackgroundColor3 = C.panel
    card.BorderSizePixel = 0 card.Parent = farmTab corner(card, 10)
    local function stat(xScale, label, color)
        local num = Instance.new("TextLabel") num.BackgroundTransparency = 1
        num.Position = UDim2.new(xScale, 0, 0, 6) num.Size = UDim2.new(1 / 3, 0, 0, 34)
        num.Font = Enum.Font.GothamBlack num.TextSize = 30 num.TextColor3 = color num.Text = "0" num.Parent = card
        local cap = Instance.new("TextLabel") cap.BackgroundTransparency = 1
        cap.Position = UDim2.new(xScale, 0, 0, 40) cap.Size = UDim2.new(1 / 3, 0, 0, 14)
        cap.Font = Enum.Font.GothamBold cap.TextSize = 11 cap.TextColor3 = C.text2 cap.Text = label cap.Parent = card
        return num
    end
    score.wins = stat(0, "WINS", Color3.fromRGB(80, 220, 120))
    score.losses = stat(1 / 3, "LOSSES", C.danger)
    score.rate = stat(2 / 3, "WIN RATE", C.accent)
    score.coins = Instance.new("TextLabel") score.coins.BackgroundTransparency = 1
    score.coins.Position = UDim2.new(0, 0, 0, 60) score.coins.Size = UDim2.new(1, 0, 0, 20)
    score.coins.Font = Enum.Font.GothamMedium score.coins.TextSize = 13 score.coins.TextColor3 = C.text
    score.coins.Text = "" score.coins.Parent = card
end
sec(farmTab, "Auto farm")
Toggle(farmTab, "Auto farm (master)", "AutoFarm", function(v) logLine(v and "Auto farm ON" or "Auto farm OFF") end)
Toggle(farmTab, "Auto place towers", "AutoPlace")
Toggle(farmTab, "Auto upgrade", "AutoUpgrade")
Toggle(farmTab, "Use farms (economy)", "UseFarms")
Toggle(farmTab, "Auto skip waves (only when safe)", "AutoSkip")
Toggle(farmTab, "Auto vote difficulty", "AutoVote")
Toggle(farmTab, "Auto rematch", "AutoRematch")
Toggle(farmTab, "Auto join match from lobby (solo)", "AutoJoin")
Toggle(farmTab, "Sell farms on the final wave", "SellFarmsEnd")
Toggle(farmTab, "Replace weak towers at the cap", "ReplaceWeak")
Toggle(farmTab, "Smart targeting (Strongest for heavy hitters)", "SmartTarget")
Toggle(farmTab, "Anti-AFK", "AntiAFK")
Toggle(farmTab, "Use tower abilities", "AutoAbility")
Toggle(farmTab, "Watchdog (rejoin if stuck)", "Watchdog")
Toggle(farmTab, "Use Timescale Tickets for 2x speed (solo, 1 per match)", "UseTimescale")
Toggle(farmTab, "Auto pick mode (most coins/hr that still wins)", "AutoMode")

sec(farmTab, "Farm this mode")
do
    local modeRow = Instance.new("Frame") modeRow.Size = UDim2.new(1, 0, 0, 30) modeRow.BackgroundTransparency = 1 modeRow.Parent = farmTab
    local ml = Instance.new("UIListLayout") ml.FillDirection = Enum.FillDirection.Horizontal ml.Padding = UDim.new(0, 5) ml.Parent = modeRow
    local modeBtns = {}
    local function renderModes()
        for n, b in pairs(modeBtns) do
            b.BackgroundColor3 = (S.VoteMode == n) and C.accent or C.row
            b.TextColor3 = (S.VoteMode == n) and C.bg or C.text2
        end
    end
    for _, n in ipairs({ "Easy", "Casual", "Molten", "Fallen" }) do
        local b = Instance.new("TextButton") b.Size = UDim2.new(0.25, -4, 1, 0) b.BackgroundColor3 = C.row b.Text = n
        b.Font = Enum.Font.GothamMedium b.TextSize = 12 b.TextColor3 = C.text2 b.BorderSizePixel = 0 b.Parent = modeRow corner(b, 6)
        modeBtns[n] = b
        b.MouseButton1Click:Connect(function() S.VoteMode = n renderModes() saveSettings() logLine("Farm mode: " .. n) end)
    end
    renderModes()
end
note(farmTab, "Easy/Casual = safe auto-win. Molten/Fallen pay more but need a strong loadout. With Auto pick mode ON these buttons are ignored: it tries the next mode up once the one below wins 75%+, keeps the best coins/hr, and benches a mode for an hour after 2 losses in a row.")
local stModes = note(farmTab, "Modes: -")

sec(farmTab, "Status")
local stBrain = note(farmTab, "Brain: idle")
local stWave  = note(farmTab, "Wave: -")
local stDps   = note(farmTab, "Damage: -")
local stCash  = note(farmTab, "Cash: -")
local stTow   = note(farmTab, "Towers: 0")
local stSess  = note(farmTab, "Session: -")
local stRate  = note(farmTab, "Earning: -")
local stLog   = note(farmTab, "")
Button(farmTab, "Rescan map (if placement looks stuck)", C.accent2, function() rebuildMap() logLine("Map rescanned") end)

-- Loadout tab  (each tab lives in its own do-block: Luau caps a function at 200 locals and the hub's
-- top level hit that - ':2142: Out of local registers')
do
local loadoutTab = addTab("Loadout")
sec(loadoutTab, "Recommended farm loadout")
local recNote = note(loadoutTab, "Press scan to read your inventory.")
local ownedNote = note(loadoutTab, "")
Button(loadoutTab, "Scan, recommend & equip", C.accent, function()
    local owned = ownedTowers()
    if #owned == 0 then recNote.Text = "Couldn't read your inventory yet - open the lobby once and retry." return end
    table.sort(owned)
    ownedNote.Text = ("You own %d: %s"):format(#owned, table.concat(owned, ", "))
    local mode = chooseMode()
    local rec, why = bestLoadoutFor(mode)
    local w, l = loadoutRecord(rec, statKey(mode))
    local lines = {}
    for _, n in ipairs(rec) do
        local i = towerInfo(n)
        local hid = i and i.levels and (function() for L = 0, i.maxLevel do if i.levels[L].hidden then return L end end end)()
        lines[#lines + 1] = i and ("%s  ($%d, %s%s)"):format(n, i.price, i.econ and "economy" or ("%.0f dmg/s"):format(dpsAt(i, 0)),
            hid and (", sees hidden from L" .. hid) or "") or n
    end
    local head = ("Best for %s (%s, %dW/%dL there):\n"):format(mode, why, w, l)
    if inMatch() or Workspace:FindFirstChild("IntermissionLobby") then
        recNote.Text = head .. table.concat(lines, "\n") .. "\n\nYou're in a match - it equips in the lobby."
        return
    end
    if loadoutKey(rec) == loadoutKey(equippedLoadout()) then
        recNote.Text = head .. table.concat(lines, "\n") .. "\n\nAlready equipped."
        return
    end
    recNote.Text = "Equipping...\n" .. table.concat(lines, "\n")
    local ok, err = equipLoadout(rec)
    recNote.Text = (ok and head or ("Couldn't equip all (" .. tostring(err) .. "):\n")) .. table.concat(lines, "\n")
    logLine(ok and ("Equipped for " .. mode) or ("Equip failed: " .. tostring(err)))
end)
Toggle(loadoutTab, "Auto equip the best loadout for each mode", "AutoLoadout")
note(loadoutTab, "Picks from real results first: a loadout that's winning on that mode, else the best winner from other modes (unless it already lost twice there), else a fresh pick from the game's prices and damage that always covers hidden enemies plus every enemy type seen on that mode. Equipped in the lobby right before queueing.")
sec(loadoutTab, "Towers worth buying")
local buyNote = note(loadoutTab, "Press to check the shop against your coins.")
Button(loadoutTab, "Suggest towers I can afford", C.accent2, function()
    local role = (S.Coop and S.CoopSize > 1) and S.CoopRole or 1
    local list = buySuggestions(role)
    if #list == 0 then
        buyNote.Text = ("Nothing useful in the coin shop for %d coins right now (or the inventory isn't loaded - try in the lobby)."):format(statValue("Coins"))
        return
    end
    local lines = {}
    for k = 1, math.min(5, #list) do
        local x = list[k]
        lines[#lines + 1] = ("%d. %s - %d coins%s"):format(k, x.name, x.cost,
            x.buff and " (support)" or x.hidden and " (sees hidden)" or "")
    end
    buyNote.Text = ("You have %d coins. Best buys%s:\n%s\nBuy them yourself in the shop - the hub never spends your coins.")
        :format(statValue("Coins"), role > 1 and (" for your co-op role (" .. ROLE_NAMES[math.min(role, #ROLE_NAMES)] .. ")") or "",
            table.concat(lines, "\n"))
end)

end
-- Maps tab (VIP+ map override)
do
local mapsTab = addTab("Maps")
sec(mapsTab, "VIP map pick")
local vipNote = note(mapsTab, "Checking VIP+ pass...")
local mapSel = note(mapsTab, "")
local mapBtns = {}
local function renderMaps()
    mapSel.Text = S.VIPMap == "" and "Map: vote normally" or ("Map every round: " .. S.VIPMap)
    for n, b in pairs(mapBtns) do
        b.BackgroundColor3 = (S.VIPMap == n) and C.accent or C.row
        b.TextColor3 = (S.VIPMap == n) and C.bg or C.text
    end
end
Button(mapsTab, "Vote normally (no override)", C.row, function() S.VIPMap = "" saveSettings() renderMaps() end)
task.spawn(function()
    vipNote.Text = ownsVIP() and "VIP+ owned - pick a map and every round starts on it (Auto farm must be ON)."
        or "No VIP+ gamepass: your map is only voted for when it shows up on a vote board. With VIP+ it's forced every round."
    local lastDiff
    for _, m in ipairs(mapList()) do
        if m.diff ~= lastDiff then lastDiff = m.diff sec(mapsTab, m.diff .. " maps") end
        local b = Button(mapsTab, m.name, C.row, function() S.VIPMap = m.name saveSettings() renderMaps() logLine("VIP map set: " .. m.name) end)
        b.Size = UDim2.new(1, 0, 0, 26)
        mapBtns[m.name] = b
    end
    renderMaps()
end)

end
-- Meta tab
do
local metaTab = addTab("Meta")
sec(metaTab, "Passive claims (lobby)")
Toggle(metaTab, "Auto playtime rewards", "AutoPlaytime")
Toggle(metaTab, "Auto daily spin", "AutoDaily")
Toggle(metaTab, "Auto claim quests & achievements", "AutoQuests")
Toggle(metaTab, "Auto open crates", "AutoCrates")
note(metaTab, "Free rewards claimed while you're in the lobby (quests checked once a minute).")

end
-- Co-op tab
local coopTab = addTab("Co-op")
sec(coopTab, "How to use co-op")
note(coopTab, table.concat({
    "Play as a party of 2-4 players who all run Cookies Hub. Each player gets a role so the party covers more:",
    "  Slot 1 (leader): economy + damage.  Slot 2: hidden detection.  Slot 3: boss damage.  Slot 4: support.",
    "",
    "0. Every account must have finished the TDS tutorial - new accounts get pulled into it from the lobby.",
    "1. Everyone joins the SAME lobby server (join a friend through Roblox, or use the same private server).",
    "2. Everyone runs Cookies Hub and turns on Co-op mode below and Auto farm in the Farm tab.",
    "3. Party members should be Roblox friends with the leader - friends' invites are accepted automatically.",
    "4. The leader presses a player's name below to invite them. The leader is slot 1; others get their slot in join order.",
    "5. The leader's hub queues the elevator for the whole party, picks the mode (and VIP map). Everyone else follows.",
    "6. In the match every hub builds its own towers for its role and steers clear of teammates' spots.",
    "",
    "Tips: only the leader needs Auto join / Auto pick mode / VIP map. Each player still needs their own loadout -",
    "the hub equips the best one for their role from towers they own; 'Towers worth buying' in the Loadout tab",
    "shows what to buy next for your role.",
}, "\n"))
sec(coopTab, "Co-op")
Toggle(coopTab, "Co-op mode", "Coop", function(v) logLine(v and "Co-op mode ON" or "Co-op mode OFF") end)
Toggle(coopTab, "Auto-accept party invites from friends", "CoopAccept")
local coopStatus = note(coopTab, "Party: -")
sec(coopTab, "Invite players in this lobby")
local inviteNote = note(coopTab, "Press Refresh in the lobby to list players.")
local inviteBtns = {}
local function refreshInvites()
    for _, b in ipairs(inviteBtns) do b:Destroy() end
    inviteBtns = {}
    local t = Workspace:FindFirstChild("Type")
    if not (t and t.Value == "Lobby") then inviteNote.Text = "Invites only work in the lobby." return end
    local others = {}
    for _, p in ipairs(Players:GetPlayers()) do if p ~= lp then others[#others + 1] = p end end
    table.sort(others, function(a, b) return isFriend(a) and not isFriend(b) end)
    inviteNote.Text = #others == 0 and "Nobody else is in this lobby server." or "Press a name to invite (friends listed first):"
    for k = 1, math.min(#others, 12) do
        local p = others[k]
        inviteBtns[#inviteBtns + 1] = Button(coopTab, ("Invite %s%s"):format(p.DisplayName, isFriend(p) and "  (friend)" or ""),
            C.row, function() coopInvite(p) end)
    end
end
Button(coopTab, "Refresh player list", C.accent2, refreshInvites)
Button(coopTab, "Leave party", C.danger, coopLeave)

-- Stats tab: everything the hub has recorded (saved files, so it survives teleports)
local statsTab = addTab("Stats")
sec(statsTab, "Modes (all recorded matches)")
local stModeTable = note(statsTab, "-")
sec(statsTab, "Loadouts by mode")
local stLoadouts = note(statsTab, "-")
sec(statsTab, "Enemy types (first wave seen)")
local stEnemies = note(statsTab, "-")
sec(statsTab, "This farm session (carries across games)")
local stServer = note(statsTab, "-")
local function renderStats()
    local rows, totalCoins, totalSecs = {}, 0, 0
    for _, m in ipairs(STAT_KEYS) do
        local st = modeStats[m]
        if st and (st.w + st.l > 0 or st.secs > 0) then
            totalCoins, totalSecs = totalCoins + st.coins, totalSecs + st.secs
            rows[#rows + 1] = ("%s: %dW / %dL (%d%%)  %s%s"):format(m, st.w, st.l, math.floor(st.w / math.max(1, st.w + st.l) * 100),
                st.secs > 0 and ("%d coins in %dm = %.0f/hr"):format(st.coins, math.floor(st.secs / 60), st.coins / st.secs * 3600) or "no earnings yet",
                st.bench > os.time() and ("  BENCHED %dm"):format(math.floor((st.bench - os.time()) / 60)) or "")
        end
    end
    rows[#rows + 1] = ("Next: %s%s"):format(chooseMode(), totalSecs > 0 and ("   |   overall %.0f coins/hr"):format(totalCoins / totalSecs * 3600) or "")
    stModeTable.Text = table.concat(rows, "\n")
    local lrows = {}
    for _, m in ipairs(STAT_KEYS) do
        local list = {}
        for key, r in pairs(records[m] or {}) do list[#list + 1] = { key = key, w = r.w, l = r.l } end
        table.sort(list, function(a, b) return a.w - 2 * a.l > b.w - 2 * b.l end)
        for k = 1, math.min(3, #list) do
            lrows[#lrows + 1] = ("%s: %dW/%dL  %s"):format(m, list[k].w, list[k].l, (list[k].key:gsub(",", ", ")))
        end
    end
    stLoadouts.Text = #lrows > 0 and table.concat(lrows, "\n") or "no results yet"
    local erows = {}
    for _, m in ipairs(MODES) do
        local seen, parts = firstSeen[m], {}
        for cat, w in pairs(seen or {}) do parts[#parts + 1] = ("%s from wave %d"):format(cat, w) end
        if #parts > 0 then erows[#erows + 1] = m .. ": " .. table.concat(parts, ", ") end
    end
    stEnemies.Text = #erows > 0 and table.concat(erows, "\n") or "none seen yet"
    local mins = (os.time() - session.startTime) / 60
    stServer.Text = ("Farming %dm: %d W / %d L, %d placed, %d upgrades, %d crates opened\nCoins %d (+%d this session)  |  Gems %d")
        :format(mins, session.wins, session.losses, session.placements, session.upgrades, session.crates or 0,
            statValue("Coins"), statValue("Coins") - session.startCoins, statValue("Gems"))
end

-- Info tab
do
local infoTab = addTab("Info")
sec(infoTab, "Cookies Hub Discord")
local DISCORD = "https://discord.com/invite/ymJusGPxkE"
local discordBtn
discordBtn = Button(infoTab, "Copy Discord invite (Cookies Hub)", C.accent, function()
    local copy = setclipboard or toclipboard or (syn and syn.write_clipboard)
    if copy then
        copy(DISCORD)
        discordBtn.Text = "Copied! Paste it in your browser"
    else
        discordBtn.Text = DISCORD   -- executor has no clipboard: show it to copy by hand
    end
    task.delay(3, function() if discordBtn.Parent then discordBtn.Text = "Copy Discord invite (Cookies Hub)" end end)
end)
sec(infoTab, "How it plays")
note(infoTab, "Reads every tower's real price, upgrade cost and damage from the game. Wave 1 it buys the best cheap damage tower. Whenever damage is short or enemies leak, every dollar goes into the best damage per dollar. When the defense is ahead it buys farms that pay back before the game ends, then saves for big upgrades. Damage towers go where they cover the most path; farms stay off the good spots. It watches for hidden, lead and flying enemies; when the defense can't hit them it buys the tower or upgrade that detects them first, and remembers the wave they arrived so the next match is ready 2 waves early.")
note(infoTab, "Covers every path on multi-path maps. In the last 2 waves it stops saving and farming and pours everything into damage for the boss; on the final wave it sells farms too.")
sec(infoTab, "Honest note")
note(infoTab, "TDS is server-authoritative - no cash/kill hacks exist. This is an auto-player. Easy/Casual solo is the sweet spot. Turn on Auto farm + Auto join and it queues itself from the lobby.")
end
selectTab("Farm")

-- live status
task.spawn(function()
    local tick = 0
    while alive do
        task.wait(1)
        tick = tick + 1
        if tick % 15 == 0 then saveSession() end   -- keeps placements/upgrades and the 15-minute gap clock current
        pcall(function()
            stBrain.Text = "Brain: " .. brain.status
                .. ((not S.AutoPlace or not S.AutoUpgrade) and S.AutoFarm and "   (Auto place/upgrade is OFF - it can't build!)" or "")
            if inMatch() and S.AutoFarm then
                local g = gameInfo()
                stWave.Text = ("Wave %d / %d   -   Base %d / %d"):format(g.wave, g.total, g.hp, g.maxHp)
                stDps.Text = ("Damage: %.0f dmg/s   (wave needs ~%.0f)%s%s"):format(brain.dps, brain.target,
                    (brain.short or "") ~= "" and ("   missing: " .. brain.short) or "",
                    (brain.cover and #brain.cover > 0 and ("\nCover: " .. table.concat(brain.cover, "  |  ")) or "")
                    .. (brain.boss and ("\nBoss: " .. brain.boss) or ""))
            else
                stWave.Text = inMatch() and "Wave: (turn on Auto farm)" or "Wave: in lobby"
                stDps.Text = "Damage: -"
            end
            stCash.Text = ("Cash: $%s"):format(tostring(cash()))
            stTow.Text = ("Towers: %d / %d"):format(placedCount, S.MaxTowers)
            stSess.Text = ("Session: %d placed - %d upgrades"):format(session.placements, session.upgrades)
            local hrs = math.max((os.time() - session.startTime) / 3600, 1 / 3600)
            local coinsNow = (lp:FindFirstChild("Coins") and lp.Coins.Value) or session.startCoins
            local xpNow = (lp:FindFirstChild("Experience") and lp.Experience.Value) or session.startXP
            stRate.Text = ("Earning: +%d coins, +%d XP  (%.0f coins/hr)")
                :format(coinsNow - session.startCoins, xpNow - session.startXP, (coinsNow - session.startCoins) / hrs)
            -- scoreboard (this farm session, carried across games)
            local games = session.wins + session.losses
            score.title.Text = ('<font color="#50DC78">W %d</font>   <font color="#E25A5A">L %d</font>'):format(session.wins, session.losses)
            score.wins.Text = tostring(session.wins)
            score.losses.Text = tostring(session.losses)
            score.rate.Text = games > 0 and ("%d%%"):format(math.floor(session.wins / games * 100 + 0.5)) or "-"
            score.coins.Text = ("+%d coins this session  |  %.0f coins/hr  |  farming %dm")
                :format(coinsNow - session.startCoins, (coinsNow - session.startCoins) / hrs, math.floor((os.time() - session.startTime) / 60))
            if statsTab.Visible then renderStats() end
            if coopTab.Visible then
                local st, names = partyState(), {}
                if st and type(st.party) == "table" then
                    for i, v in ipairs(st.party.players or {}) do names[#names + 1] = ("%d. %s"):format(i, playerName(v)) end
                end
                coopStatus.Text = (S.Coop and "Co-op ON" or "Co-op OFF") .. "   |   "
                    .. (S.CoopSize > 1 and ("party of %d, you are slot %d: %s"):format(S.CoopSize, S.CoopRole, ROLE_NAMES[math.min(S.CoopRole, #ROLE_NAMES)])
                        or "not in a party")
                    .. (#names > 0 and ("\n" .. table.concat(names, "   ")) or "")
            end
            local rows = {}
            for _, m in ipairs(STAT_KEYS) do
                local st = modeStats[m]
                if st and st.w + st.l > 0 then
                    rows[#rows + 1] = ("%s %dW/%dL %s%s"):format(m, st.w, st.l,
                        st.secs > 0 and ("%.0f coins/hr"):format(st.coins / st.secs * 3600) or "no earnings yet",
                        st.bench > os.time() and " (benched)" or "")
                end
            end
            stModes.Text = ("Next mode: %s\n%s"):format(chooseMode(), #rows > 0 and table.concat(rows, "\n") or "no results yet")
            stLog.Text = table.concat({ session.log[1] or "", session.log[2] or "", session.log[3] or "" }, "\n")
        end)
    end
end)

-- drag
do
    local dragging, startPos, startM
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true startPos = main.Position startM = i.Position
            i.Changed:Connect(function() if i.UserInputState == Enum.UserInputState.End then dragging = false end end)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startM
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized tabRow.Visible = not minimized
    main.Size = minimized and UDim2.fromOffset(430, 40) or UDim2.fromOffset(430, 480)
end)

local inputConn
local function Unload()
    alive = false S.AutoFarm = false
    if inputConn then inputConn:Disconnect() end
    idleConn:Disconnect()
    pcall(function() gui:Destroy() end)
    _G.CookiesHubTDS = nil
end
closeBtn.MouseButton1Click:Connect(Unload)
inputConn = UserInputService.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == S.ToggleKey then main.Visible = not main.Visible end
end)

_G.CookiesHubTDS = {
    Unload = Unload, State = S, Session = session, Brain = brain,
    Set = function(k, v) if S[k] ~= nil then S[k] = v saveSettings() if toggleRender[k] then toggleRender[k]() end end end,
    Get = function(k) return S[k] end,
    Recommend = function(mode) return recommend(ownedTowers(), mode) end,
    BestLoadout = function(mode) return bestLoadoutFor(mode or chooseMode()) end,}
logLine("Cookies Hub (TDS) loaded.")

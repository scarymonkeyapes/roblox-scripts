-- Cookies Hub (Turret Barrage Defense)  [KEYLESS]
-- RightShift: show/hide | B: auto aim on/off | X button or _G.CookiesHubTurret.Unload(): unload
-- Console: _G.CookiesHubTurret.Set("AutoAim", true)
--
-- Read from the live game (place 71993944365294):
--  * PlayerScripts.FlakClient.TurretController (module) runs the gun:
--      Stats() -> live stats table of the current gun {Id, Rate (shots/s), Heat (per shot), Speed, Range, Mag, Homing, Lob...}
--        The fire loop reads Stats().Rate every frame (max 4 shots per frame) and adds Stats().Heat per shot.
--      Heat() -> heat, overheatLocked | SetHeat(n) | ClearLock(n) clears the overheat lock
--      LookAt(worldPos) sets turret yaw/pitch | SetFiring(bool) = trigger held | AimPoint(enemy) = enemy body now
--      Mag() -> rounds, magSize | AddRound(gunId, n) refills a non-empty mag
--      CallSupport(id) / Net "CallSupport":FireServer(id, worldPos) = call-ins; HudController.SupportLeft(id) = uses left
--  * FlakClient.EnemyController.All() -> {id = {kind, hp, hpMax, path, t0, model}}; Config.Enemies[kind] {Neutral, Ground, Boss}
--    ReplicatedStorage.Flak.EnemyPath.Position(path, serverTime - t0) = path position (used for leading shots)
--  * Field upgrade cards: Net "PickCard":FireServer(index); cards UI = PlayerGui.FlakHud.Screen.Turret.HudBC.Cards
--  * Stash items (Nuke/Repair): Net "Shop":InvokeServer("use", item).  Playtime gifts: Net "Rewards":InvokeServer("gift", "<n>")
--    (lobby only), ready when attr GiftT0 + Config.Rewards.Gifts[n].Minutes*60 has passed and n is not in attr "Gifts".
-- Save this file as UTF-8 WITHOUT a BOM or it won't load.

if _G.CookiesHubTurret and _G.CookiesHubTurret.Unload then pcall(_G.CookiesHubTurret.Unload) end

local Players          = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting         = game:GetService("Lighting")
local HttpService      = game:GetService("HttpService")
local VirtualUser      = game:GetService("VirtualUser")
local lp               = Players.LocalPlayer

-- ---------- guard ----------
if not game:IsLoaded() then game.Loaded:Wait() end
local Flak = RS:WaitForChild("Flak", 15)
local FC = lp:WaitForChild("PlayerScripts"):WaitForChild("FlakClient", 15)
if not (Flak and FC and FC:FindFirstChild("TurretController")) then
    warn("[CookiesHub Turret] Not Turret Barrage Defense (missing ReplicatedStorage.Flak / FlakClient). Aborting.")
    return
end
local TC      = require(FC.TurretController)
local EC      = require(FC.EnemyController)
local CState  = require(FC.ClientState)
local Hud     = require(FC.HudController)
local Config  = require(Flak.Config)
local EPath   = require(Flak.EnemyPath)
local Net     = require(Flak.Net)
local alive = true

-- ---------- settings ----------
local S = {
    AutoAim       = false,
    AutoFire      = true,     -- shoot whenever auto aim has a target
    AimMode       = "Smart",  -- Smart | Nearest | Lowest HP | Bosses first
    TargetGround  = true,     -- infantry / vehicles too, not just aircraft
    Lead          = true,     -- aim where the target will be when the round arrives
    WeakSpot      = false,    -- aim at the glowing WeakSpot part when the target has one
    AutoSwitch    = false,    -- slot 1 for aircraft/bosses, slot 3 for infantry/vehicles
    BossRockets   = false,    -- ...and slot 2 (rockets) on bosses
    LeadMarker    = false,    -- on-screen dot where to aim (for manual play)
    AutoReplay    = false,    -- start the next run from the lobby by itself
    ReplayDelay   = 4,
    AutoRewards   = true,     -- daily login, all quests, all battle pass tiers, daily chest
    AutoCrates    = false,    -- open crates in your stash
    AutoSkills    = false,    -- spend gunner skill points
    AutoUpgrades  = false,    -- lead sight, factory armor, gun stat upgrades (spends cash)
    AutoBase      = false,    -- base upgrades (spends cash)
    AutoBuyGuns   = false,    -- buys the cheapest gun you can afford (spends cash)
    NoOverheat    = false,
    InfiniteAmmo  = false,    -- keeps the magazine topped up so it never reloads
    FireRateOn    = false,
    FireRateMult  = 2,
    AutoCallins   = false,
    RepairAt      = 60,       -- REPAIR CREW only below this factory HP %
    AutoNuke      = false,    -- uses Nukes from your stash (bought items!)
    NukeAt        = 12,       -- ...when this many enemies are up, or a boss
    AutoStashRepair = false,  -- uses Repair kits from your stash
    StashRepairAt = 35,
    AutoCards     = false,
    AutoGifts     = true,
    EnemyESP      = false,
    BossAlert     = true,
    FullBright    = false,
    AntiAFK       = true,
    ToggleKey     = Enum.KeyCode.RightShift,
}
local SETTINGS_FILE = ("CookiesHubTurret_%d_settings.json"):format(lp.UserId)
pcall(function()
    for k, v in pairs(HttpService:JSONDecode(readfile(SETTINGS_FILE))) do
        if S[k] ~= nil and type(S[k]) == type(v) then S[k] = v end
    end
end)
local function saveSettings()
    local out = {}
    for k, v in pairs(S) do if type(v) ~= "userdata" then out[k] = v end end
    pcall(function() writefile(SETTINGS_FILE, HttpService:JSONEncode(out)) end)
end

local stats = { cards = 0, callins = 0, nukes = 0, gifts = 0, buys = 0, claims = 0, crates = 0, runs = 0,
    kills = 0, bestWave = 0, earned = 0, start = os.clock(), status = "idle" }
local conns = {}
local function on(sig, fn) local c = sig:Connect(fn) conns[#conns + 1] = c return c end

-- ---------- helpers ----------
local function inRun()
    return TC.Active() and not CState.over
end
local function enemyCfg(e) return Config.Enemies[e.kind] end
local function valid(e)
    local c = enemyCfg(e)
    return c and not c.Neutral and e.path and e.model and e.model.Parent and (e.hp or 1) > 0
end
local function enemies()
    local list = {}
    for _, e in pairs(EC.All()) do if valid(e) then list[#list + 1] = e end end
    return list
end
local function camPos() return workspace.CurrentCamera.CFrame.Position end

-- the glowing WeakSpot part of an enemy model (searched again every second while none is found)
local weakCache = setmetatable({}, { __mode = "k" })
local function weakPart(e)
    local m = e.model
    local c = weakCache[m]
    if c and c.part and c.part.Parent then return c.part end
    if c and not c.part and os.clock() - c.t < 1 then return nil end
    c = { t = os.clock() }
    for _, d in ipairs(m:GetDescendants()) do
        if d:IsA("BasePart") and d.Name == "WeakSpot" then c.part = d break end
    end
    weakCache[m] = c
    return c.part
end

-- where to aim so the round meets the target
local function aimPoint(e, st, now)
    local ok, cur = pcall(TC.AimPoint, e)
    if not ok or typeof(cur) ~= "Vector3" then return nil end
    local wp = S.WeakSpot and not (st and st.Homing) and weakPart(e)
    if wp then cur = wp.Position end
    if not S.Lead or not st or st.Lob or st.Homing or (st.Speed or 0) <= 0 then return cur end
    local okB, base = pcall(EPath.Position, e.path, now - e.t0)
    if not okB or typeof(base) ~= "Vector3" then return cur end
    local off, o, p = cur - base, camPos(), cur
    for _ = 1, 3 do
        local t = (p - o).Magnitude / st.Speed
        local okP, q = pcall(EPath.Position, e.path, now + t - e.t0)
        if not okP then return cur end
        p = q + off
    end
    return p
end

-- ======================================================================
-- Gun: no overheat, fire rate, infinite ammo  (edits the live Stats() table, restored on change/unload)
-- ======================================================================
local orig, written = {}, {}   -- [statsTable] = {Rate, Heat} the game set / what we last wrote
local function restoreStats()
    for st, o in pairs(orig) do st.Rate = o.Rate st.Heat = o.Heat end
    table.clear(orig) table.clear(written)
end
local function stepGun()
    local st = TC.Stats()
    if type(st) ~= "table" or type(st.Rate) ~= "number" then return end
    local o, w = orig[st], written[st]
    if not o then o = { Rate = st.Rate, Heat = st.Heat or 0 } orig[st] = o written[st] = {} w = written[st] end
    -- the game rewrote a value (upgrade card etc.): take that as the new base
    if w.Rate and st.Rate ~= w.Rate then o.Rate = st.Rate end
    if w.Heat and st.Heat ~= w.Heat then o.Heat = st.Heat end
    w.Rate = S.FireRateOn and o.Rate * S.FireRateMult or o.Rate
    w.Heat = S.NoOverheat and 0 or o.Heat
    st.Rate, st.Heat = w.Rate, w.Heat
    if S.NoOverheat then
        local heat, locked = TC.Heat()
        if locked then TC.ClearLock(0) elseif (heat or 0) > 0 then TC.SetHeat(0) end
    end
    if S.InfiniteAmmo and st.Mag and st.Id then
        local n, size = TC.Mag()
        if n and size and n > 0 and n < size then TC.AddRound(st.Id, size) end
    end
end

-- ======================================================================
-- Auto aim / auto fire
-- ======================================================================
local target, nextPick, weFire, nextSwitch = nil, 0, false, 0
local function score(e, d, c)
    local frac = (e.hpMax and e.hpMax > 0) and (e.hp or 0) / e.hpMax or 1
    if S.AimMode == "Nearest" then return d
    elseif S.AimMode == "Lowest HP" then return (e.hp or 0) + d * 0.001
    elseif S.AimMode == "Bosses first" then return (c.Boss and 0 or 1e6) + d
    end
    -- Smart: close, hurt targets first; bosses pulled forward, ground units pushed back a bit
    return d * (0.5 + 0.5 * frac) * (c.Boss and 0.4 or 1) * (c.Ground and 1.4 or 1)
end
local function pickTarget(st, now)
    local best, bs
    local o, range = camPos(), (st and st.Range or 1000)
    for _, e in ipairs(enemies()) do
        local c = enemyCfg(e)
        local groundOk = not c.Ground or S.TargetGround
        if st and st.Homing then groundOk = (st.LockGround and (c.Ground or c.Boat)) or (not st.LockGround and not c.Ground) end
        if groundOk then
            local p = aimPoint(e, st, now)
            local d = p and (p - o).Magnitude
            if d and d > 5 and d <= range then
                local s = score(e, d, c)
                if not bs or s < bs then best, bs = e, s end
            end
        end
    end
    return best
end
local function stopFiring()
    if weFire then weFire = false pcall(TC.SetFiring, false) end
end
local function stepAim()
    if not (S.AutoAim and inRun()) then target = nil stopFiring() return end
    if Hud.CardsOpen and Hud.CardsOpen() then stopFiring() return end
    local st, now = TC.Stats(), workspace:GetServerTimeNow()
    if target and (not valid(target) or EC.Get(target.id) ~= target) then target = nil end
    if not target or os.clock() >= nextPick then
        nextPick = os.clock() + 0.25
        target = pickTarget(st, now) or target
    end
    local p = target and aimPoint(target, st, now)
    if not p then target = nil stopFiring() return end
    -- gun choice: slot 1 main (aircraft, bosses), slot 3 small arms (infantry, vehicles), slot 2 rockets (bosses, optional)
    if S.AutoSwitch and os.clock() >= nextSwitch then
        local loadout, cur = TC.LoadoutState()
        local c, want = enemyCfg(target), 1
        if c.Boss and S.BossRockets and loadout[2] then want = 2
        elseif c.Ground and not c.Boss and loadout[3] then want = 3 end
        if cur == 2 then   -- rockets reloading: fall back to the main gun
            local _, _, reloading = TC.Mag()
            if reloading then want = 1 end
        end
        if loadout[want] and want ~= cur then
            nextSwitch = os.clock() + 8   -- every swap costs a short lock, so don't flap between air and ground targets
            TC.SwitchTo(want)
            stopFiring()
            return
        end
    end
    TC.LookAt(p)
    local fire = S.AutoFire
    if fire and st and st.Homing then   -- rockets only leave once the lock is complete
        local _, _, locked = TC.Lock()
        fire = locked == true
    end
    if fire then
        weFire = true
        TC.SetFiring(true)
    else
        stopFiring()
    end
end

-- ======================================================================
-- Call-ins, nuke, stash repair, cards, gifts
-- ======================================================================
local lastCall = 0
local function groundBelow(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ex = { workspace.CurrentCamera }
    if lp.Character then ex[#ex + 1] = lp.Character end
    params.FilterDescendantsInstances = ex
    local hit = workspace:Raycast(pos + Vector3.new(0, 300, 0), Vector3.new(0, -2000, 0), params)
    return hit and hit.Position or pos
end
local function bestCallPoint()
    -- densest group of enemies (ground units count double), clamped to call-in range
    local list, now = enemies(), workspace:GetServerTimeNow()
    local pts = {}
    for _, e in ipairs(list) do
        local ok, p = pcall(TC.AimPoint, e)
        if ok and typeof(p) == "Vector3" then pts[#pts + 1] = { p = p, w = enemyCfg(e).Ground and 2 or 1 } end
    end
    local best, bw
    for _, a in ipairs(pts) do
        local w = 0
        for _, b in ipairs(pts) do if (Vector3.new(a.p.X, 0, a.p.Z) - Vector3.new(b.p.X, 0, b.p.Z)).Magnitude < 80 then w += b.w end end
        if not bw or w > bw then best, bw = a.p, w end
    end
    local o = camPos()
    if not best then
        local lv = workspace.CurrentCamera.CFrame.LookVector
        local flat = Vector3.new(lv.X, 0, lv.Z)
        best = o + (flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, 1)) * 250
    end
    local maxR = (tonumber(Config.Support.MaxRange) or 700) - 50
    local flat = Vector3.new(best.X - o.X, 0, best.Z - o.Z)
    if flat.Magnitude > maxR then best = Vector3.new(o.X, best.Y, o.Z) + flat.Unit * maxR end
    return groundBelow(best)
end
local function factoryPct()
    local m = CState.factoryMax or 0
    return m > 0 and (CState.factoryHP or 0) / m * 100 or 100
end
local function slots()
    local ok, cf = pcall(require, FC:FindFirstChild("CallinFX"))
    local s = ok and cf and cf.Slots and cf.Slots() or Config.Callins.DefaultSlots
    return s or {}
end
local function stepCallins()
    if not (S.AutoCallins and inRun()) or os.clock() - lastCall < 2.5 then return end
    if #enemies() == 0 then return end
    for _, id in pairs(slots()) do
        if type(id) == "string" and id ~= "" and Hud.SupportLeft(id) > 0 then
            if id ~= "Repair" or factoryPct() < S.RepairAt then
                Net.Get("CallSupport"):FireServer(id, bestCallPoint())
                lastCall = os.clock() stats.callins += 1
                return
            end
        end
    end
end
local function stashCount(item)
    local p = CState.profile
    return p and p.Stash and (p.Stash[item] or 0) or 0
end
local lastStash = 0
local function stepStash()
    if not inRun() or os.clock() - lastStash < 5 then return end
    if S.AutoNuke and stashCount("Nuke") > 0 then
        local list, boss = enemies(), false
        for _, e in ipairs(list) do if enemyCfg(e).Boss then boss = true end end
        if boss or #list >= S.NukeAt then
            lastStash = os.clock()
            local ok, _, _, prof = pcall(function() return Net.Get("Shop"):InvokeServer("use", "Nuke") end)
            if ok and type(prof) == "table" then CState.profile = prof end
            stats.nukes += 1
            return
        end
    end
    if S.AutoStashRepair and stashCount("Repair") > 0 and factoryPct() < S.StashRepairAt then
        lastStash = os.clock()
        local ok, _, _, prof = pcall(function() return Net.Get("Shop"):InvokeServer("use", "Repair") end)
        if ok and type(prof) == "table" then CState.profile = prof end
    end
end

-- card priority (Config.Cards ids). With no-overheat on, cooling cards are worthless so they go last.
local CARD_ORDER = { "Damage", "Crit", "APRounds", "Bounty", "Payday", "BaseSentry", "Reinforce", "BaseDome", "Fortify",
    "DoubleTime", "Velocity", "Burst", "RushGun", "Strike", "GunShield", "HeavyDrop", "Quartermaster", "FireRate", "Repair", "Cooling" }
local cardRank = {}
for id, c in pairs(Config.Cards) do
    local name = type(c) == "table" and (c.Name or c.name)
    if name then cardRank[string.upper(name)] = id end
end
local lastCard = 0
local function stepCards()
    if not S.AutoCards or os.clock() - lastCard < 1.5 then return end
    if not (Hud.CardsOpen and Hud.CardsOpen()) then return end
    local root = Hud.Ref and Hud.Ref("cards")
    if not root then return end
    -- each card shows its name; map name -> left-to-right slot index
    local found = {}
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("TextLabel") and d.Visible and d.AbsoluteSize.X > 0 then
            local id = cardRank[string.upper(d.Text)]
            if id then found[#found + 1] = { id = id, x = d.AbsolutePosition.X } end
        end
    end
    if #found == 0 then return end
    table.sort(found, function(a, b) return a.x < b.x end)
    local pickIdx, bestR = 1, math.huge
    for i, f in ipairs(found) do
        local r = table.find(CARD_ORDER, f.id) or 99
        if f.id == "Repair" and factoryPct() < 50 then r = 0 end
        if r < bestR then pickIdx, bestR = i, r end
    end
    lastCard = os.clock()
    Net.Get("PickCard"):FireServer(pickIdx)
    stats.cards += 1
end

local function readyGifts()
    local t0 = lp:GetAttribute("GiftT0")
    if type(t0) ~= "number" then return {} end
    local got = {}
    for i in tostring(lp:GetAttribute("Gifts") or ""):gmatch("%d+") do got[tonumber(i)] = true end
    local played, out = workspace:GetServerTimeNow() - t0, {}
    for i, g in ipairs(Config.Rewards.Gifts) do
        if not got[i] and played >= (g.Minutes or 0) * 60 then out[#out + 1] = i end
    end
    return out
end
local function claimGifts()
    if CState.mission ~= nil or TC.Active() then return "only in the lobby" end
    local n = 0
    for _, i in ipairs(readyGifts()) do
        local ok, res = pcall(function() return Net.Get("Rewards"):InvokeServer("gift", tostring(i)) end)
        if ok and res then n += 1 stats.gifts += 1 end
        task.wait(1)
    end
    return n > 0 and ("claimed " .. n) or "none ready"
end

-- ======================================================================
-- Server calls: rewards, crates, armory, skills, replay
-- Shop / Rewards / BattlePass answer (ok, message, newProfile); Crates answers (ok, data).
-- ======================================================================
local Remotes = Flak:WaitForChild("Remotes", 15)
local function invoke(name, ...)
    local rf = Remotes and Remotes:FindFirstChild(name)
    if not (rf and rf:IsA("RemoteFunction")) then return false, "no remote " .. name end
    local args = table.pack(...)
    local ok, a, b, c = pcall(function() return rf:InvokeServer(table.unpack(args, 1, args.n)) end)
    if not ok then return false, tostring(a) end
    if type(c) == "table" then
        CState.profile = c
        pcall(CState.Emit, "profile", c)
    end
    return a, b
end

local backoff = {}   -- [key] = os.clock() before which we don't retry a failed purchase
local function try(key, ...)
    if (backoff[key] or 0) > os.clock() then return false end
    local ok = invoke("Shop", ...)
    if ok == true then backoff[key] = nil stats.buys += 1 return true end
    backoff[key] = os.clock() + 45
    return false
end

local lastRewards = 0
local function stepRewards()
    if not S.AutoRewards or os.clock() - lastRewards < 120 then return end
    lastRewards = os.clock()
    local n = 0
    for _, call in ipairs({ { "Rewards", "login" }, { "Rewards", "questsAll" }, { "BattlePass", "all" }, { "Rewards", "bonus" } }) do
        if invoke(call[1], call[2]) == true then n += 1 end
        task.wait(0.5)
    end
    stats.claims += n
end

local lastCrate = 0
local function stepCrates()
    if not S.AutoCrates or inRun() or os.clock() - lastCrate < 30 then return end
    lastCrate = os.clock()
    local cr = CState.profile and CState.profile.Crates
    local n = cr and ((cr.Free or 0) + (cr.Paid or 0)) or 0
    if n <= 0 then return end
    local ok, data = invoke("Crates", "open", math.min(n, tonumber(Config.Crates.MaxOpen) or 1))
    if ok == true and type(data) == "table" and type(data.results) == "table" then stats.crates += #data.results end
end

local SKILL_ORDER = { "Acquire", "Spotter", "Profit", "Lucky", "Eagle", "Assist", "Steady", "Scavenger", "Traverse", "Cool" }
local STAT_ORDER = { "Damage", "Critical", "Velocity", "FireRate", "Penetration", "Range", "Zoom", "Cooling" }
local lastSpend = 0
local function stepSpend()
    local P = CState.profile
    if not P or os.clock() - lastSpend < 2 then return end
    lastSpend = os.clock()
    local budget = 4   -- failed attempts per tick, so a long shopping list can't flood the server
    local function attempt(key, ...)
        if (backoff[key] or 0) > os.clock() or budget <= 0 then return false end
        budget -= 1
        return try(key, ...)
    end
    if S.AutoSkills and (P.SkillPoints or 0) > 0 then
        for _, k in ipairs(SKILL_ORDER) do
            if P.Skills and P.Skills[k] ~= nil and attempt("skill" .. k, "skill", k) then return end
        end
    end
    if S.AutoUpgrades then
        if not P.LeadSight and attempt("lead", "lead") then return end
        if attempt("armor", "armor") then return end
        local gunIds, seen = {}, {}
        for _, v in pairs(P.Loadout or {}) do if type(v) == "string" and not seen[v] then seen[v] = true gunIds[#gunIds + 1] = v end end
        for _, v in pairs(P.Equipped or {}) do if type(v) == "string" and not seen[v] then seen[v] = true gunIds[#gunIds + 1] = v end end
        for _, gid in ipairs(gunIds) do
            for _, stat in ipairs(STAT_ORDER) do
                if attempt("up" .. gid .. stat, "upgrade", gid, stat) then return end
            end
        end
    end
    if S.AutoBase and P.Base then
        for k in pairs(P.Base) do if attempt("base" .. k, "base", k) then return end end
    end
    if S.AutoBuyGuns then
        local list = {}
        for id, g in pairs(Config.Guns) do
            if type(g) == "table" and (g.Cost or 0) > 0 and not (P.Guns and P.Guns[id]) and g.Cost <= (P.Cash or 0) then list[#list + 1] = id end
        end
        table.sort(list, function(a, b) return Config.Guns[a].Cost < Config.Guns[b].Cost end)
        for _, id in ipairs(list) do if attempt("gun" .. id, "buyGun", id) then return end end
    end
end

local function redeemCode(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return "type a code first" end
    local ok, msg = invoke("Rewards", "code", text)
    return (ok == true and "redeemed: " or "not accepted: ") .. tostring(msg or "")
end

-- auto replay: after a run the game drops you in the lobby; start the same mode again
local lastMode, lobbySince, lastPlay = "flak", nil, 0
local function stepReplay()
    if inRun() then
        lobbySince = nil
        local m = CState.mission
        if m and m.mode then lastMode = m.mode end
        return
    end
    if not S.AutoReplay or CState.mission ~= nil then lobbySince = nil return end
    lobbySince = lobbySince or os.clock()
    if os.clock() - lobbySince < S.ReplayDelay or os.clock() - lastPlay < 15 then return end
    local sq = FC:FindFirstChild("SquadUI")
    sq = sq and require(sq)
    if sq and sq.ResultsOpen and sq.ResultsOpen() then   -- still on the results card: let the game's own "back to lobby" run
        if os.clock() - lobbySince > S.ReplayDelay + 4 and sq.Lobby then pcall(sq.Lobby) end
        return
    end
    lastPlay = os.clock()
    Net.Get("PartyAction"):FireServer("play", lastMode, nil, 1, true)
    stats.runs += 1
end

-- ======================================================================
-- Visuals: enemy ESP, boss alert, fullbright
-- ======================================================================
local espGui = Instance.new("ScreenGui")
espGui.Name = "CookiesHubTurretESP" espGui.ResetOnSpawn = false espGui.IgnoreGuiInset = true
pcall(function() espGui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not espGui.Parent then espGui.Parent = lp:WaitForChild("PlayerGui") end
local espFolder = Instance.new("Folder") espFolder.Name = "CookiesHubTurretHL" espFolder.Parent = espGui
local esp = {}   -- [model] = {bb, label, hl}
local function clearEsp()
    for _, v in pairs(esp) do pcall(function() v.bb:Destroy() if v.hl then v.hl:Destroy() end end) end
    table.clear(esp)
end
local function stepEsp()
    if not S.EnemyESP then if next(esp) then clearEsp() end return end
    local seen, hlCount = {}, 0
    for _, e in ipairs(enemies()) do
        local m, c = e.model, enemyCfg(e)
        seen[m] = true
        local v = esp[m]
        if not v then
            local bb = Instance.new("BillboardGui")
            bb.Size = UDim2.fromOffset(160, 34) bb.AlwaysOnTop = true bb.StudsOffset = Vector3.new(0, 6, 0) bb.MaxDistance = 5000
            local l = Instance.new("TextLabel") l.Size = UDim2.fromScale(1, 1) l.BackgroundTransparency = 1
            l.Font = Enum.Font.GothamBold l.TextSize = 13 l.TextStrokeTransparency = 0.4 l.Parent = bb
            bb.Adornee = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true) bb.Parent = espGui
            v = { bb = bb, label = l } esp[m] = v
        end
        local col = c.Boss and Color3.fromRGB(255, 70, 70) or (c.Ground and Color3.fromRGB(255, 200, 80) or Color3.fromRGB(120, 220, 255))
        v.label.TextColor3 = col
        local d = (camPos() - (v.bb.Adornee and v.bb.Adornee.Position or camPos())).Magnitude
        v.label.Text = ("%s%s\n%d/%d hp  %dm"):format(c.Boss and "BOSS " or "", e.kind, math.floor(e.hp or 0), math.floor(e.hpMax or 0), d)
        hlCount += 1
        if hlCount <= 30 and not v.hl then   -- Roblox draws at most 31 Highlights
            local hl = Instance.new("Highlight") hl.FillTransparency = 0.75 hl.OutlineColor = col hl.FillColor = col
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop hl.Adornee = m hl.Parent = espFolder v.hl = hl
        end
    end
    for m, v in pairs(esp) do
        if not seen[m] then pcall(function() v.bb:Destroy() if v.hl then v.hl:Destroy() end end) esp[m] = nil end
    end
end

local bossSeen = {}
local function stepBossAlert()
    if not (S.BossAlert and inRun()) then return end
    for _, e in ipairs(enemies()) do
        if enemyCfg(e).Boss and not bossSeen[e.id] then
            bossSeen[e.id] = true
            pcall(Hud.Toast, ("BOSS INBOUND: %s (%d hp)"):format(e.kind, math.floor(e.hpMax or 0)))
        end
    end
end

local savedLighting
local function applyFullBright(onNow)
    if onNow then
        savedLighting = savedLighting or { Lighting.Brightness, Lighting.ClockTime, Lighting.FogEnd, Lighting.GlobalShadows, Lighting.Ambient }
        Lighting.Brightness = 2 Lighting.ClockTime = 14 Lighting.FogEnd = 1e6 Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
    elseif savedLighting then
        Lighting.Brightness, Lighting.ClockTime, Lighting.FogEnd, Lighting.GlobalShadows, Lighting.Ambient = table.unpack(savedLighting)
        savedLighting = nil
    end
end

-- ---------- main loops ----------
on(RunService.Heartbeat, function()
    if not alive then return end
    if TC.Active() then pcall(stepGun) end
    pcall(stepAim)
end)
on(lp.Idled, function()
    if S.AntiAFK then pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end) end
end)
-- session numbers (kills, cash earned, best wave)
local lastKills, lastCash, wasRun = 0, nil, false
local function stepSession()
    local k = CState.kills or 0
    if inRun() then
        if not wasRun then lastKills = 0 end
        if k > lastKills then stats.kills += k - lastKills end
        lastKills = k
        stats.bestWave = math.max(stats.bestWave, tonumber(CState.wave) or 0)
    end
    wasRun = inRun()
    local cash = CState.profile and CState.profile.Cash
    if cash then
        if lastCash and cash > lastCash then stats.earned += cash - lastCash end
        lastCash = cash
    end
end

-- on-screen dot where to aim (manual play)
local marker = Instance.new("Frame")
marker.Size = UDim2.fromOffset(16, 16) marker.AnchorPoint = Vector2.new(0.5, 0.5) marker.BackgroundTransparency = 1
marker.Visible = false marker.Parent = espGui
do
    local s = Instance.new("UIStroke") s.Thickness = 2 s.Color = Color3.fromRGB(80, 255, 140) s.Parent = marker
    local c = Instance.new("UICorner") c.CornerRadius = UDim.new(1, 0) c.Parent = marker
end
local markerTarget, markerPick = nil, 0
on(RunService.RenderStepped, function()
    if not (S.LeadMarker and inRun()) then marker.Visible = false return end
    local st, now = TC.Stats(), workspace:GetServerTimeNow()
    if not markerTarget or not valid(markerTarget) or os.clock() >= markerPick then
        markerPick = os.clock() + 0.25
        markerTarget = (S.AutoAim and target) or pickTarget(st, now)
    end
    local p = markerTarget and aimPoint(markerTarget, st, now)
    if not p then marker.Visible = false return end
    local v, onScreen = workspace.CurrentCamera:WorldToViewportPoint(p)
    marker.Visible = onScreen and v.Z > 0
    if marker.Visible then marker.Position = UDim2.fromOffset(v.X, v.Y) end
end)

task.spawn(function()
    local tick = 0
    while alive do
        tick += 1
        pcall(stepCallins)
        pcall(stepStash)
        pcall(stepCards)
        pcall(stepBossAlert)
        pcall(stepEsp)
        pcall(stepSession)
        pcall(stepReplay)
        pcall(stepSpend)
        if tick % 4 == 0 then
            pcall(stepRewards)
            pcall(stepCrates)
        end
        if S.FullBright then pcall(applyFullBright, true) end
        if S.AutoGifts and tick % 30 == 0 and #readyGifts() > 0 then pcall(claimGifts) end
        if not inRun() then table.clear(bossSeen) end
        stats.status = inRun() and ("wave " .. tostring(CState.wave) .. ", " .. #enemies() .. " enemies") or "lobby"
        task.wait(0.5)
    end
end)

-- ======================================================================
-- UI  (purple Cookies Hub theme, tabs like the other hubs)
-- ======================================================================
local C = {
    bg=Color3.fromRGB(20,16,30), panel=Color3.fromRGB(30,24,44), row=Color3.fromRGB(42,34,60),
    accent=Color3.fromRGB(171,113,235), accent2=Color3.fromRGB(139,92,214), danger=Color3.fromRGB(226,90,90),
    good=Color3.fromRGB(80,220,120), text=Color3.fromRGB(236,232,245), text2=Color3.fromRGB(165,158,185),
}
local W, H = 450, 470
local function corner(p, r) local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, r or 8) c.Parent = p return c end

local gui = Instance.new("ScreenGui")
gui.Name = "CookiesHubTurret" gui.ResetOnSpawn = false gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true gui.DisplayOrder = 9999
pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = lp:WaitForChild("PlayerGui") end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(W, H) main.Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2)
main.BackgroundColor3 = C.bg main.BorderSizePixel = 0 main.Active = true main.Parent = gui corner(main, 12)
local bar = Instance.new("Frame") bar.Size = UDim2.new(1, 0, 0, 40) bar.BackgroundColor3 = C.panel
bar.BorderSizePixel = 0 bar.Parent = main corner(bar, 12)
do
    local title = Instance.new("TextLabel") title.BackgroundTransparency = 1 title.Position = UDim2.fromOffset(14, 0)
    title.Size = UDim2.new(1, -90, 1, 0) title.Font = Enum.Font.GothamBold title.TextSize = 15 title.TextColor3 = C.text
    title.TextXAlignment = Enum.TextXAlignment.Left title.Text = "Cookies Hub  -  Turret Barrage" title.Parent = bar
end
local function topBtn(t, x, col)
    local b = Instance.new("TextButton") b.Size = UDim2.fromOffset(24, 24) b.Position = UDim2.new(1, x, 0.5, -12)
    b.BackgroundColor3 = col b.Text = t b.Font = Enum.Font.GothamBold b.TextSize = 14 b.TextColor3 = C.text
    b.BorderSizePixel = 0 b.Parent = bar corner(b, 6) return b
end
local minBtn = topBtn("-", -62, C.row)
local closeBtn = topBtn("X", -32, C.danger)

local tabRow = Instance.new("Frame") tabRow.Size = UDim2.new(1, -20, 0, 28) tabRow.Position = UDim2.fromOffset(10, 48)
tabRow.BackgroundTransparency = 1 tabRow.Parent = main
do
    local tl = Instance.new("UIListLayout") tl.FillDirection = Enum.FillDirection.Horizontal tl.Padding = UDim.new(0, 5) tl.Parent = tabRow
end
local body = Instance.new("Frame") body.Size = UDim2.new(1, -20, 1, -92) body.Position = UDim2.fromOffset(10, 84)
body.BackgroundTransparency = 1 body.Parent = main

local ui = { tabs = {}, tabBtns = {}, renders = {} }
local TAB_NAMES = { "Combat", "Gun", "Support", "Auto", "Stats", "Visual", "Info" }
function ui.select(n)
    for k, p in pairs(ui.tabs) do p.Visible = k == n end
    for k, b in pairs(ui.tabBtns) do b.BackgroundColor3 = k == n and C.accent or C.row b.TextColor3 = k == n and C.bg or C.text2 end
end
function ui.tab(n)
    local b = Instance.new("TextButton") b.Size = UDim2.new(1 / #TAB_NAMES, -5, 1, 0) b.BackgroundColor3 = C.row b.Text = n
    b.Font = Enum.Font.GothamMedium b.TextSize = 11 b.TextColor3 = C.text2 b.BorderSizePixel = 0 b.Parent = tabRow corner(b, 6)
    local p = Instance.new("ScrollingFrame") p.Size = UDim2.fromScale(1, 1) p.BackgroundTransparency = 1 p.BorderSizePixel = 0
    p.ScrollBarThickness = 3 p.CanvasSize = UDim2.new() p.AutomaticCanvasSize = Enum.AutomaticSize.Y p.Visible = false p.Parent = body
    local l = Instance.new("UIListLayout") l.Padding = UDim.new(0, 7) l.SortOrder = Enum.SortOrder.LayoutOrder l.Parent = p
    ui.tabs[n] = p ui.tabBtns[n] = b b.MouseButton1Click:Connect(function() ui.select(n) end)
    return p
end
function ui.sec(parent, t)
    local l = Instance.new("TextLabel") l.Size = UDim2.new(1, 0, 0, 18) l.BackgroundTransparency = 1
    l.Font = Enum.Font.GothamBold l.TextSize = 12 l.TextColor3 = C.accent l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = string.upper(t) l.Parent = parent return l
end
function ui.note(parent, t)
    local l = Instance.new("TextLabel") l.Size = UDim2.new(1, 0, 0, 16) l.AutomaticSize = Enum.AutomaticSize.Y
    l.BackgroundTransparency = 1 l.Font = Enum.Font.Gotham l.TextSize = 12 l.TextColor3 = C.text2 l.TextWrapped = true
    l.TextXAlignment = Enum.TextXAlignment.Left l.Text = t l.Parent = parent return l
end
function ui.toggle(parent, label, key, onChange)
    local row = Instance.new("Frame") row.Size = UDim2.new(1, 0, 0, 34) row.BackgroundColor3 = C.row row.BorderSizePixel = 0 row.Parent = parent corner(row, 6)
    local t = Instance.new("TextLabel") t.BackgroundTransparency = 1 t.Position = UDim2.fromOffset(12, 0) t.Size = UDim2.new(1, -70, 1, 0)
    t.Font = Enum.Font.GothamMedium t.TextSize = 13 t.TextColor3 = C.text t.TextXAlignment = Enum.TextXAlignment.Left t.Text = label t.Parent = row
    local knob = Instance.new("TextButton") knob.Size = UDim2.fromOffset(44, 22) knob.Position = UDim2.new(1, -56, 0.5, -11)
    knob.Text = "" knob.BorderSizePixel = 0 knob.Parent = row corner(knob, 11)
    local dot = Instance.new("Frame") dot.Size = UDim2.fromOffset(18, 18) dot.BackgroundColor3 = C.text dot.BorderSizePixel = 0 dot.Parent = knob corner(dot, 9)
    local function render()
        knob.BackgroundColor3 = S[key] and C.accent or C.bg
        dot.Position = S[key] and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9)
    end
    render()
    knob.MouseButton1Click:Connect(function()
        S[key] = not S[key] render() saveSettings()
        if onChange then task.spawn(pcall, onChange, S[key]) end
    end)
    ui.renders[key] = render
end
function ui.button(parent, label, col, fn)
    local b = Instance.new("TextButton") b.Size = UDim2.new(1, 0, 0, 30)
    b.BackgroundColor3 = col or C.accent2 b.Text = label b.Font = Enum.Font.GothamMedium b.TextSize = 13 b.TextColor3 = C.text
    b.BorderSizePixel = 0 b.Parent = parent corner(b, 6)
    b.MouseButton1Click:Connect(function() task.spawn(pcall, fn) end)
    return b
end
function ui.input(parent, placeholder, buttonText, fn)
    local row = Instance.new("Frame") row.Size = UDim2.new(1, 0, 0, 34) row.BackgroundTransparency = 1 row.Parent = parent
    local box = Instance.new("TextBox") box.Size = UDim2.new(1, -96, 1, 0) box.BackgroundColor3 = C.row box.BorderSizePixel = 0
    box.PlaceholderText = placeholder box.Text = "" box.ClearTextOnFocus = false box.Font = Enum.Font.Gotham box.TextSize = 13
    box.TextColor3 = C.text box.PlaceholderColor3 = C.text2 box.Parent = row corner(box, 6)
    local b = Instance.new("TextButton") b.Size = UDim2.fromOffset(88, 34) b.Position = UDim2.new(1, -88, 0, 0)
    b.BackgroundColor3 = C.accent2 b.Text = buttonText b.Font = Enum.Font.GothamMedium b.TextSize = 13 b.TextColor3 = C.text
    b.BorderSizePixel = 0 b.Parent = row corner(b, 6)
    b.MouseButton1Click:Connect(function() task.spawn(pcall, fn, box.Text) end)
    return box
end
function ui.cycle(parent, label, key, options)
    local b = ui.button(parent, "", C.row, function() end)
    local function render() b.Text = label .. ":  " .. tostring(S[key]) end
    b.MouseButton1Click:Connect(function()
        local i = table.find(options, S[key]) or 0
        S[key] = options[i % #options + 1] render() saveSettings()
    end)
    render() ui.renders[key] = render
end
function ui.slider(parent, label, key, min, max, step, fmt)
    local row = Instance.new("Frame") row.Size = UDim2.new(1, 0, 0, 46) row.BackgroundColor3 = C.row row.BorderSizePixel = 0 row.Parent = parent corner(row, 6)
    local t = Instance.new("TextLabel") t.BackgroundTransparency = 1 t.Position = UDim2.fromOffset(12, 4) t.Size = UDim2.new(1, -24, 0, 18)
    t.Font = Enum.Font.GothamMedium t.TextSize = 13 t.TextColor3 = C.text t.TextXAlignment = Enum.TextXAlignment.Left t.Parent = row
    local track = Instance.new("TextButton") track.Text = "" track.AutoButtonColor = false track.Size = UDim2.new(1, -24, 0, 8)
    track.Position = UDim2.fromOffset(12, 30) track.BackgroundColor3 = C.bg track.BorderSizePixel = 0 track.Parent = row corner(track, 4)
    local fill = Instance.new("Frame") fill.BackgroundColor3 = C.accent fill.BorderSizePixel = 0 fill.Parent = track corner(fill, 4)
    local function render()
        local v = S[key]
        fill.Size = UDim2.new(math.clamp((v - min) / (max - min), 0, 1), 0, 1, 0)
        t.Text = label .. ":  " .. (fmt or "%s"):format(v)
    end
    local dragging = false
    local function setFrom(x)
        local a = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        local v = math.floor((min + (max - min) * a) / step + 0.5) * step
        S[key] = math.clamp(v, min, max) render()
    end
    track.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true setFrom(i.Position.X)
        end
    end)
    on(UserInputService.InputChanged, function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then setFrom(i.Position.X) end
    end)
    on(UserInputService.InputEnded, function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
            dragging = false saveSettings()
        end
    end)
    render() ui.renders[key] = render
end

for _, n in ipairs(TAB_NAMES) do ui.tab(n) end

do -- Combat
    local p = ui.tabs.Combat
    ui.sec(p, "Auto aim   (B)")
    ui.toggle(p, "Auto aim (locks the turret onto enemies)", "AutoAim", function(v) if not v then stopFiring() end end)
    ui.toggle(p, "Auto fire while locked on", "AutoFire", function(v) if not v then stopFiring() end end)
    ui.toggle(p, "Lead moving targets", "Lead")
    ui.toggle(p, "Target ground units too (infantry, vehicles)", "TargetGround")
    ui.cycle(p, "Target priority", "AimMode", { "Smart", "Nearest", "Lowest HP", "Bosses first" })
    ui.toggle(p, "Aim at weak spots (glowing parts)", "WeakSpot")
    ui.toggle(p, "Auto switch gun (air / ground)", "AutoSwitch")
    ui.toggle(p, "Rockets on bosses (needs auto switch)", "BossRockets")
    ui.toggle(p, "Lead marker (green ring where to aim)", "LeadMarker")
    ui.note(p, "Smart: close and damaged targets first, bosses pulled forward, ground units a little later. Rocket guns only pick what they can lock (air or ground). Auto aim turns the turret for you, so you can't aim by hand while it's on - press B to hand control back.")
    ui.sec(p, "Status")
    ui.stats = ui.note(p, "-")
end
do -- Gun
    local p = ui.tabs.Gun
    ui.sec(p, "No cooldown")
    ui.toggle(p, "No overheat", "NoOverheat")
    ui.toggle(p, "Infinite ammo (never reload)", "InfiniteAmmo")
    ui.note(p, "No overheat sets the gun's heat per shot to 0 and clears any overheat lock. Infinite ammo keeps magazine guns topped up so they never hit a reload.")
    ui.sec(p, "Fire rate")
    ui.toggle(p, "Fire rate changer", "FireRateOn")
    ui.slider(p, "Fire rate multiplier", "FireRateMult", 1, 10, 0.5, "%.1fx")
    ui.gun = ui.note(p, "-")
    ui.note(p, "The game fires at most 4 rounds per frame, so very high multipliers top out at your FPS x 4. Pair it with No overheat or the gun locks up almost instantly. Turning these off puts the gun's real numbers back.")
end
do -- Support
    local p = ui.tabs.Support
    ui.sec(p, "Call-ins")
    ui.toggle(p, "Auto call-ins (your equipped slots)", "AutoCallins")
    ui.slider(p, "Repair crew below factory HP", "RepairAt", 10, 100, 5, "%d%%")
    ui.note(p, "Uses each call-in as soon as it has uses left, aimed at the biggest group of enemies.")
    ui.sec(p, "Field upgrades")
    ui.toggle(p, "Auto pick field upgrade cards", "AutoCards")
    ui.note(p, "Order: Heavier Rounds, Marksman, AP Rounds, War Bonds, Payday, Sentry Gun, Reinforcements, Iron Dome, Sandbags... cooling cards last. Field Repairs jumps to the front when the factory is under 50%.")
    ui.sec(p, "Stash items (paid items - off by default)")
    ui.toggle(p, "Auto nuke", "AutoNuke")
    ui.slider(p, "Nuke when enemies up (or a boss)", "NukeAt", 4, 40, 1, "%d")
    ui.toggle(p, "Auto repair kit", "AutoStashRepair")
    ui.slider(p, "Repair kit below factory HP", "StashRepairAt", 10, 90, 5, "%d%%")
    ui.sec(p, "Rewards")
    ui.toggle(p, "Auto claim playtime gifts (in the lobby)", "AutoGifts")
    ui.msg = ui.note(p, " ")
    ui.button(p, "Claim ready gifts now", C.accent2, function() ui.msg.Text = "Gifts: " .. tostring(claimGifts()) end)
end
do -- Auto
    local p = ui.tabs.Auto
    ui.sec(p, "Replay")
    ui.toggle(p, "Auto replay (start the next run from the lobby)", "AutoReplay")
    ui.slider(p, "Wait in lobby before replaying", "ReplayDelay", 2, 20, 1, "%d s")
    ui.note(p, "Starts the same mode again, solo. Combine with auto aim, call-ins and field upgrade cards for a full AFK farm.")
    ui.sec(p, "Rewards")
    ui.toggle(p, "Auto claim login, quests, battle pass, daily chest", "AutoRewards")
    ui.toggle(p, "Auto open crates in your stash", "AutoCrates")
    ui.msg2 = ui.note(p, " ")
    ui.button(p, "Claim rewards now", C.accent2, function()
        ui.msg2.Text = "Working..."
        local n = 0
        for _, call in ipairs({ { "Rewards", "login" }, { "Rewards", "questsAll" }, { "BattlePass", "all" }, { "Rewards", "bonus" } }) do
            if invoke(call[1], call[2]) == true then n += 1 end
        end
        ui.msg2.Text = n > 0 and ("Claimed " .. n .. " reward group(s)") or "Nothing to claim right now"
    end)
    ui.sec(p, "Redeem a code")
    ui.msg3 = ui.note(p, "Codes aren't listed anywhere in the game files, so paste one from the game's Discord or social pages.")
    ui.input(p, "code", "Redeem", function(text) ui.msg3.Text = redeemCode(text) end)
    ui.sec(p, "Spending  (uses your cash, scrap and points - off by default)")
    ui.toggle(p, "Auto spend skill points", "AutoSkills")
    ui.toggle(p, "Auto upgrades: lead sight, armor, gun stats", "AutoUpgrades")
    ui.toggle(p, "Auto base upgrades", "AutoBase")
    ui.toggle(p, "Auto buy the cheapest affordable gun", "AutoBuyGuns")
    ui.note(p, "Each purchase is the same request the armory sends; the server decides whether it goes through, and anything refused is retried after 45 seconds. Skill order: Target Acquisition first (unlocks the game's own auto-aim), then Spotter, Profit, Lucky, Eagle...")
    ui.note(p, "Not automated: PRESTIGE (resets your upgrade levels 1-5) and the Lab (super-turret pieces) - do those yourself.")
end
do -- Stats
    local p = ui.tabs.Stats
    ui.sec(p, "This session")
    ui.sess = ui.note(p, "-")
    ui.button(p, "Reset session numbers", C.accent2, function()
        stats.kills, stats.bestWave, stats.earned, stats.runs, stats.start = 0, 0, 0, 0, os.clock()
    end)
end
do -- Visual
    local p = ui.tabs.Visual
    ui.sec(p, "ESP")
    ui.toggle(p, "Enemy ESP (name, hp, distance)", "EnemyESP")
    ui.toggle(p, "Boss incoming alert", "BossAlert")
    ui.toggle(p, "Fullbright (see through night and rain)", "FullBright", function(v) applyFullBright(v) end)
    ui.note(p, "Colors: blue aircraft, yellow ground units, red bosses.")
    ui.sec(p, "Misc")
    ui.toggle(p, "Anti AFK", "AntiAFK")
end
do -- Info
    local p = ui.tabs.Info
    ui.sec(p, "Cookies Hub Discord")
    local DISCORD = "https://discord.com/invite/ymJusGPxkE"
    local btn
    btn = ui.button(p, "Copy Discord invite (Cookies Hub)", C.accent, function()
        local copy = setclipboard or toclipboard or (syn and syn.write_clipboard)
        if copy then copy(DISCORD) btn.Text = "Copied! Paste it in your browser" else btn.Text = DISCORD end
        task.delay(3, function() if btn.Parent then btn.Text = "Copy Discord invite (Cookies Hub)" end end)
    end)
    ui.note(p, DISCORD)
    ui.sec(p, "Warning")
    ui.note(p, "Automating a game breaks its rules and can get your account banned. Use at your own risk, ideally on an alt account.")
    ui.sec(p, "Hotkeys")
    ui.note(p, "RightShift: show / hide this window\nB: auto aim on / off")
    ui.sec(p, "Console")
    ui.note(p, '_G.CookiesHubTurret.Set("FireRateMult", 4)\n_G.CookiesHubTurret.Unload()')
    ui.sec(p, "Not included")
    ui.note(p, "Prestige and the Lab (they reset or need hand choices). Downed pilots and kill cash are paid automatically by the game, so there is nothing to collect.")
end
ui.select("Combat")

-- drag / minimize / hotkeys
do
    local dragging, startPos, startMouse
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, startPos, startMouse = true, main.Position, i.Position
        end
    end)
    on(UserInputService.InputChanged, function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startMouse
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    on(UserInputService.InputEnded, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
end
local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    tabRow.Visible, body.Visible = not minimized, not minimized
    main.Size = minimized and UDim2.fromOffset(W, 40) or UDim2.fromOffset(W, H)
end)
on(UserInputService.InputBegan, function(i, gp)
    if gp then return end
    if i.KeyCode == S.ToggleKey then main.Visible = not main.Visible
    elseif i.KeyCode == Enum.KeyCode.B then
        S.AutoAim = not S.AutoAim if ui.renders.AutoAim then ui.renders.AutoAim() end saveSettings()
        if not S.AutoAim then stopFiring() end
        pcall(Hud.Toast, "COOKIES HUB AUTO AIM " .. (S.AutoAim and "ON" or "OFF"))
    end
end)

task.spawn(function()
    while alive do
        local st = TC.Stats()
        ui.stats.Text = ("%s\nTarget: %s\nCards picked %d  -  call-ins %d  -  nukes %d  -  gifts %d"):format(
            stats.status, target and (target.kind .. " (" .. math.floor(target.hp or 0) .. " hp)") or "none",
            stats.cards, stats.callins, stats.nukes, stats.gifts)
        local hrs = math.max((os.clock() - stats.start) / 3600, 1 / 3600)
        ui.sess.Text = ("Time %dm  -  runs started %d\nKills %d (%.0f / min)  -  best wave %d\nCash earned $%d ($%d / hour)\nCards %d  -  call-ins %d  -  nukes %d  -  gifts %d\nShop purchases %d  -  reward claims %d  -  crate items %d"):format(
            math.floor(hrs * 60), stats.runs, stats.kills, stats.kills / (hrs * 60), stats.bestWave,
            stats.earned, stats.earned / hrs, stats.cards, stats.callins, stats.nukes, stats.gifts,
            stats.buys, stats.claims, stats.crates)
        if type(st) == "table" and orig[st] then
            local heat = TC.Heat()
            ui.gun.Text = ("%s: %.1f shots/s (base %.1f)  -  heat %.0f%%"):format(tostring(st.Id), st.Rate, orig[st].Rate, (heat or 0) * 100)
        else
            ui.gun.Text = "Not on a gun right now."
        end
        task.wait(0.5)
    end
end)

-- ---------- API / unload ----------
local function unload()
    alive = false
    stopFiring()
    pcall(restoreStats)
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    clearEsp()
    pcall(applyFullBright, false)
    pcall(function() espGui:Destroy() end)
    pcall(function() gui:Destroy() end)
    _G.CookiesHubTurret = nil
end
closeBtn.MouseButton1Click:Connect(unload)
_G.CookiesHubTurret = {
    Unload = unload,
    Set = function(k, v)
        if S[k] == nil then return false end
        S[k] = v saveSettings()
        if ui.renders[k] then ui.renders[k]() end
        if k == "FullBright" then applyFullBright(v) end
        return true
    end,
    S = S,
    Stats = stats,
}
print("[CookiesHub Turret] loaded")

-- Cookies Hub (TIMBER!)  [KEYLESS]
-- RightShift: show/hide | X button or _G.CookiesHubTimber.Unload(): unload
-- Console: _G.CookiesHubTimber.Set("AutoFarm", true)
--
-- Live-verified against TIMBER! (place 104154897094697):
--  * Trees: workspace.Trees.<Model> attrs Health, MaxHealth, IsFalling, GroveLocked, Species, TreeTier,
--    TreeSpawnPosition (trunk base). Standing next to a tree, the game's own axe/chainsaw auto-chops it.
--  * Manual swing (fallback): Remotes.ChopSwing:FireServer("axe", nil), then shortly after
--    Remotes.RequestChop:FireServer(trunkPart, ChopPredict.swing(trunkPart, "axe")) - same as AxeController.
--  * Logs: workspace.DroppedLogs.FallenLog (attrs PlotIndex, PickedBy). The game auto-picks any log whose
--    Bark is within 5.5 studs while CarriedLogs < MaxCarriedLogs; only PlotIndex 0 or your own plot.
--  * Deposit: stand in workspace.Plots.Plot<PlotIndex>.LogDropZone* (they fill up: rotate between them).
--  * Islands: workspace.WorldSites.<Bridge> attrs Cost/Progress/Built/Locked/PadAt - stand on PadAt with logs.
--  * Tycoon: Remotes.TycoonState pushes {Money, Catalog[{Id,Price,Available,Owned}], Objective, Contract{Ready}};
--    Remotes.TycoonRequest:InvokeServer("Purchase", id) / ("ClaimContract", nil).
--  * Picks: Remotes.RequestUpgradeChoice:InvokeServer(key, "Upgrade"|"Ability"), key = AxeDamage|CarryCapacity|Speed,
--    pending counts in attrs PendingUpgradeChoices / PendingAbilityChoices.
--  * Rebirth (= ending the day): RequestEndDaySummary -> RequestDayUpgradeChoice(key) -> RequestStartNextDay;
--    tree: RequestRebirthTreeState / RequestRebirthNodeUnlock(id). Helpers: RequestHelperState / RequestHelperRoll(rarity, false).
--  * Rewards: RequestDailyLoginClaim(), RequestLikeGiftClaim().
-- Save this file as UTF-8 WITHOUT a BOM or it won't load.

if _G.CookiesHubTimber and _G.CookiesHubTimber.Unload then pcall(_G.CookiesHubTimber.Unload) end

local Players          = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Lighting         = game:GetService("Lighting")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")
local lp               = Players.LocalPlayer

-- ---------- guard ----------
if not game:IsLoaded() then game.Loaded:Wait() end
local Remotes = RS:WaitForChild("Remotes", 15)
if not (Remotes and Remotes:FindFirstChild("RequestChop") and Workspace:FindFirstChild("Trees")) then
    warn("[CookiesHub Timber] Not TIMBER! (missing Remotes.RequestChop / workspace.Trees). Aborting.")
    return
end
local alive = true   -- cleared on Unload so every loop exits

-- ---------- settings (per account: several accounts on one PC share the executor workspace) ----------
local S = {
    AutoFarm     = false,
    ChopAssist   = true,     -- swing ourselves if a tree stops losing health (accounts without auto-chop)
    AutoIslands  = false,    -- full loads go to the next unbuilt bridge until it's done
    AutoBuy      = false,    -- buy affordable factory/tycoon items, the game's next objective first
    AutoOrders   = true,     -- claim finished orders (contracts)
    AutoStats    = false,    -- spend stat picks ("Truck loaded. Pick one stat upgrade")
    AutoAbility  = false,    -- choose abilities ("Truck milestone reached. Pick one ability category")
    StatFocus    = "Balanced",
    AbilityFocus = "Balanced",
    AutoRebirth  = false,    -- resets progress: off unless switched on
    AutoNodes    = true,     -- spend rebirth points on the rebirth tree
    AutoHelpers  = false,    -- spend Sap on helper hires
    AutoRewards  = true,     -- daily login + like gift
    LogESP       = false,
    TreeESP      = false,
    PlayerESP    = false,
    FullBright   = false,
    AntiAFK      = true,
    ToggleKey    = Enum.KeyCode.RightShift,
}
local SETTINGS_FILE = ("CookiesHubTimber_%d_settings.json"):format(lp.UserId)
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

-- ---------- session stats (saved, so a reload/rejoin within 15 minutes carries on) ----------
local STAT_KEYS = { "trees", "logs", "deposits", "islandLogs", "orders", "buys", "picks", "rebirths", "hires", "rewards" }
local stats = { start = os.time(), startMoney = lp:GetAttribute("Money") or 0, status = "idle", log = {} }
for _, k in ipairs(STAT_KEYS) do stats[k] = 0 end
local STATS_FILE = ("CookiesHubTimber_%d_session.json"):format(lp.UserId)
pcall(function()
    local t = HttpService:JSONDecode(readfile(STATS_FILE))
    if type(t) == "table" and tonumber(t.last) and os.time() - t.last < 15 * 60 then
        for _, k in ipairs(STAT_KEYS) do stats[k] = tonumber(t[k]) or 0 end
        stats.start, stats.startMoney = tonumber(t.start) or stats.start, tonumber(t.startMoney) or stats.startMoney
    end
end)
local function saveStats()
    local out = { last = os.time(), start = stats.start, startMoney = stats.startMoney }
    for _, k in ipairs(STAT_KEYS) do out[k] = stats[k] end
    pcall(function() writefile(STATS_FILE, HttpService:JSONEncode(out)) end)
end
local function logLine(t)
    table.insert(stats.log, 1, ("[%s] %s"):format(os.date("%H:%M:%S"), t))
    if #stats.log > 20 then stats.log[#stats.log] = nil end
end

-- ---------- helpers ----------
local function hrp()
    local c = lp.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    local r = c and c:FindFirstChild("HumanoidRootPart")
    if r and h and h.Health > 0 then return r end
end
local function moveTo(cf)
    local r = hrp()
    if not r then return false end
    r.AssemblyLinearVelocity = Vector3.zero
    r.CFrame = cf
    return true
end
local function attr(name) return lp:GetAttribute(name) end
local function myPlot() return Workspace:FindFirstChild("Plots") and Workspace.Plots:FindFirstChild("Plot" .. tostring(attr("PlotIndex"))) end
local function invoke(name, ...)
    local r = Remotes:FindFirstChild(name)
    if not r then return false, "no remote " .. name end
    local args = table.pack(...)
    return pcall(function() return r:InvokeServer(table.unpack(args, 1, args.n)) end)
end
-- the game answers either true/false or a table like {Ok = false, Error = "..."} (live: the like gift said
-- "Earn rewards by completing timber orders.") - only a clear yes counts
local function succeeded(ok, res)
    if not ok or res == false or res == nil then return false end
    if type(res) == "table" then return res.Ok ~= false and res.Success ~= false and res.Error == nil end
    return true
end

local function choppable(t)
    local hp = t:GetAttribute("Health")
    return t:IsA("Model") and t:GetAttribute("GroveLocked") ~= true and t:GetAttribute("IsFalling") ~= true
        and typeof(t:GetAttribute("TreeSpawnPosition")) == "Vector3" and (hp == nil or hp > 0)
end
local skipTree, skipLog, zoneBusy = {}, {}, {}
local function nearestTree(from)
    local best, bd
    for _, t in ipairs(Workspace.Trees:GetChildren()) do
        if choppable(t) and (skipTree[t] or 0) < os.clock() then
            local d = (t:GetAttribute("TreeSpawnPosition") - from).Magnitude
            if not bd or d < bd then best, bd = t, d end
        end
    end
    return best
end
-- logs we may take: unowned (PlotIndex 0) or our plot's (same rule the game's LogFlow uses)
local function takeable(log)
    local pi = log:GetAttribute("PlotIndex")
    local bark = log:FindFirstChild("Bark") or (log:IsA("Model") and log.PrimaryPart)
    return bark and bark:IsA("BasePart") and not log:GetAttribute("PickedBy")
        and (pi == 0 or pi == attr("PlotIndex") or (pi ~= nil and pi == attr("CoopPlotIndex"))) and bark
end
local function nearestLog(from)
    local best, bd, bestBark
    local dl = Workspace:FindFirstChild("DroppedLogs")
    for _, log in ipairs(dl and dl:GetChildren() or {}) do
        local bark = takeable(log)
        if bark and (skipLog[log] or 0) < os.clock() then
            local d = (bark.Position - from).Magnitude
            if not bd or d < bd then best, bd, bestBark = log, d, bark end
        end
    end
    return best, bestBark
end
-- drop zones nearest first. They fill up: a lane's truck drives off when it's loaded, and the yard zone feeds
-- the factory, which can back up (live: the yard zone refused 12 logs for 45s while lane 04 took 11 at once)
local function dropZones(from)
    local plot = myPlot()
    local list = {}
    for _, z in ipairs(plot and plot:GetChildren() or {}) do
        if z:IsA("BasePart") and z.Name:find("^LogDropZone") then list[#list + 1] = z end
    end
    table.sort(list, function(a, b)
        local ba, bb = (zoneBusy[a] or 0) > os.clock(), (zoneBusy[b] or 0) > os.clock()
        if ba ~= bb then return bb end   -- zones that just refused go last
        return (a.Position - from).Magnitude < (b.Position - from).Magnitude
    end)
    return list
end
local function trunkOf(tree)
    for _, d in ipairs(tree:GetDescendants()) do if d:IsA("BasePart") then return d end end
end
-- the next island structure to build: unlocked, not built, not full (bridges open new islands)
local function nextSite()
    local ws = Workspace:FindFirstChild("WorldSites")
    local best
    for _, m in ipairs(ws and ws:GetChildren() or {}) do
        local cost, prog = tonumber(m:GetAttribute("Cost")), tonumber(m:GetAttribute("Progress")) or 0
        if cost and cost > 0 and m:GetAttribute("Built") ~= true and m:GetAttribute("Locked") ~= true and prog < cost
           and typeof(m:GetAttribute("PadAt")) == "Vector3" and (zoneBusy[m] or 0) < os.clock() then
            if not best or cost < best:GetAttribute("Cost") then best = m end
        end
    end
    return best
end

-- fallback swing, exactly like AxeController: ChopSwing first, RequestChop with the client prediction shortly after
local ChopPredict
pcall(function() ChopPredict = require(lp:WaitForChild("PlayerScripts"):WaitForChild("ChopPredict", 5)) end)
local function swing(tree)
    local trunk = trunkOf(tree)
    if not trunk then return end
    pcall(function() Remotes.ChopSwing:FireServer("axe", nil) end)
    task.wait(0.2)
    local ok, pred = false, nil
    if ChopPredict then ok, pred = pcall(ChopPredict.swing, trunk, "axe", nil) end
    pcall(function() Remotes.RequestChop:FireServer(trunk, ok and pred or nil) end)
end

-- ---------- auto farm ----------
-- full -> the next island bridge (if on) or our plot's drop zones; logs on the ground -> stand on them;
-- else stand by the nearest tree and let the game's auto-chop fell it (swinging ourselves if it stalls)
local function waitDrain(seconds)
    local last, lastChange = attr("CarriedLogs") or 0, os.clock()
    while alive and (attr("CarriedLogs") or 0) > 0 and os.clock() - lastChange < seconds do
        task.wait(0.1)
        local now = attr("CarriedLogs") or 0
        if now ~= last then last, lastChange = now, os.clock() end
    end
end
local function deliverToIsland()
    local site = nextSite()
    if not site then return false end
    local before, prog0 = attr("CarriedLogs") or 0, tonumber(site:GetAttribute("Progress")) or 0
    stats.status = "building " .. tostring(site:GetAttribute("Name") or site.Name)
    moveTo(CFrame.new(site:GetAttribute("PadAt") + Vector3.new(0, 2.5, 0)))
    waitDrain(3)
    local given = before - (attr("CarriedLogs") or 0)
    if given > 0 then
        stats.islandLogs = stats.islandLogs + given
        logLine(("%s: %s/%s"):format(tostring(site:GetAttribute("Name") or site.Name), tostring(site:GetAttribute("Progress")), tostring(site:GetAttribute("Cost"))))
        if site:GetAttribute("Built") == true then logLine("Finished " .. tostring(site:GetAttribute("Name") or site.Name) .. "!") end
        return true
    end
    if (tonumber(site:GetAttribute("Progress")) or 0) <= prog0 then zoneBusy[site] = os.clock() + 60 end
    return false
end
local function depositAll()
    if S.AutoIslands and deliverToIsland() then return end
    local r = hrp()
    local zones = r and dropZones(r.Position) or {}
    if #zones == 0 then stats.status = "no drop zone found on your plot" return end
    local before = attr("CarriedLogs") or 0
    for _, zone in ipairs(zones) do
        if not (alive and S.AutoFarm) or (attr("CarriedLogs") or 0) == 0 then break end
        stats.status = "depositing at " .. zone.Name
        moveTo(zone.CFrame + Vector3.new(0, 3, 0))
        waitDrain(2.5)   -- stay while it keeps taking logs; move on once it stalls
        if (attr("CarriedLogs") or 0) > 0 then zoneBusy[zone] = os.clock() + 20 end
    end
    local dropped = before - (attr("CarriedLogs") or 0)
    if dropped > 0 then
        stats.deposits = stats.deposits + 1
        logLine(("Deposited %d logs"):format(dropped))
    else
        stats.status = "all drop zones full - waiting for a truck"
        task.wait(4)
    end
end
local function collect(log, bark)
    stats.status = "collecting logs"
    local before = attr("CarriedLogs") or 0
    moveTo(CFrame.new(bark.Position + Vector3.new(0, 3, 0)))
    local t0 = os.clock()
    while alive and log.Parent and not log:GetAttribute("PickedBy") and os.clock() - t0 < 1.2 do task.wait(0.1) end
    local got = (attr("CarriedLogs") or 0) - before
    if got > 0 then stats.logs = stats.logs + got else skipLog[log] = os.clock() + 15 end
end
local function chop(tree)
    stats.status = "chopping " .. tostring(tree:GetAttribute("Species") or tree.Name)
    local base = tree:GetAttribute("TreeSpawnPosition")
    moveTo(CFrame.lookAt(base + Vector3.new(3.5, 3, 0), base + Vector3.new(0, 3, 0)))
    local t0, lastHp, lastChange = os.clock(), tree:GetAttribute("Health"), os.clock()
    while alive and S.AutoFarm and tree.Parent and os.clock() - t0 < 12 do
        if tree:GetAttribute("IsFalling") == true or (tree:GetAttribute("Health") or 1) <= 0 then
            stats.trees = stats.trees + 1
            task.wait(0.8)   -- let the logs land
            return
        end
        local hp = tree:GetAttribute("Health")
        if hp ~= lastHp then lastHp, lastChange = hp, os.clock() end
        if S.ChopAssist and os.clock() - lastChange > 1.2 then swing(tree) task.wait(0.45) else task.wait(0.1) end
    end
    skipTree[tree] = os.clock() + 30   -- wouldn't fall (out of reach, contested...): leave it for a while
end
task.spawn(function()
    while alive do
        task.wait(0.15)
        local r = hrp()
        if S.AutoFarm and r and attr("IsDowned") ~= true then
            local ok, err = pcall(function()
                local carried, max = attr("CarriedLogs") or 0, attr("MaxCarriedLogs") or 12
                if carried >= max then depositAll() return end
                local log, bark = nearestLog(r.Position)
                if log then collect(log, bark) return end
                if carried > 0 and carried >= max * 0.75 then depositAll() return end
                local tree = nearestTree(r.Position)
                if tree then chop(tree) elseif carried > 0 then depositAll() else stats.status = "no trees available" end
            end)
            if not ok then stats.status = "error: " .. tostring(err) end
        elseif not S.AutoFarm then
            stats.status = "idle"
        end
    end
end)

-- ---------- tycoon / progression manager ----------
-- the server pushes the tycoon state (money, catalog, objective, current order); we act on the latest one
local tycoon
local tycoonConn = Remotes.TycoonState.OnClientEvent:Connect(function(s) if type(s) == "table" then tycoon = s end end)
local TRACKS = { AxeDamage = true, CarryCapacity = true, Speed = true }
-- stat/ability to pick: the chosen focus, or "Balanced" = the track with the lowest level/tier
local function pickKey(focus, levelAttrs)
    if TRACKS[focus] then return focus end
    local best, bl
    for key, a in pairs(levelAttrs) do
        local lvl = tonumber(attr(a)) or 0
        if not bl or lvl < bl then best, bl = key, lvl end
    end
    return best
end
local STAT_LEVELS = { AxeDamage = "AxeDamageUpgradeLevel", CarryCapacity = "CarryCapacityUpgradeLevel", Speed = "SpeedUpgradeLevel" }
local ABILITY_TIERS = { AxeDamage = "AxeAbilityTier", CarryCapacity = "CarryAbilityTier", Speed = "MovementAbilityTier" }
-- rebirth tree, cheapest/earliest first (Requires respected by the order)
local NODE_ORDER = { "forest_legacy", "convoy_command", "mythic_growth" }
local HELPER_RARITIES = { "Legendary", "Rare", "Uncommon", "Common" }
local HELPER_BASE = { Common = 5, Uncommon = 40, Rare = 350, Legendary = 2000 }
-- finds the offered day-upgrade keys anywhere in the rebirth summary reply
local function findChoiceKeys(t, out, depth)
    out = out or {}
    if type(t) ~= "table" or (depth or 0) > 4 then return out end
    if type(t.Key) == "string" then out[#out + 1] = t.Key end
    for _, v in pairs(t) do findChoiceKeys(v, out, (depth or 0) + 1) end
    return out
end
local function doRebirth()
    local ok, good, _, data = invoke("RequestEndDaySummary")
    if not (ok and good) then return end
    local keys = findChoiceKeys(data)
    local key = keys[1]
    for _, k in ipairs(keys) do if k:find("Money") then key = k break end end
    if key then invoke("RequestDayUpgradeChoice", key) end
    local ok2, started = invoke("RequestStartNextDay")
    if ok2 and started then
        stats.rebirths = stats.rebirths + 1
        logLine("Rebirth" .. (key and (" (" .. key .. ")") or ""))
    end
end
local lastSlow = 0
task.spawn(function()
    while alive do
        task.wait(1.5)
        pcall(function()
            local s = tycoon
            -- finished orders
            if S.AutoOrders and s and type(s.Contract) == "table" and s.Contract.Ready == true then
                local ok, res = invoke("TycoonRequest", "ClaimContract", nil)
                if succeeded(ok, res) then
                    stats.orders = stats.orders + 1
                    logLine(("Claimed %s (+$%s)"):format(tostring(s.Contract.Title or "order"), tostring(s.Contract.Reward or "?")))
                    tycoon = nil   -- wait for a fresh state before acting again
                end
            end
            -- factory/tycoon purchases: the game's next objective first, then the cheapest available item
            if S.AutoBuy and tycoon and type(tycoon.Catalog) == "table" then
                local money, pick = tonumber(tycoon.Money) or 0, nil
                local want = type(tycoon.Objective) == "table" and tycoon.Objective.ActionId
                for _, item in ipairs(tycoon.Catalog) do
                    if type(item) == "table" and item.Available == true and item.Owned ~= true and item.Locked ~= true
                       and (tonumber(item.Price) or math.huge) <= money then
                        if item.Id == want then pick = item break end
                        if not pick or item.Price < pick.Price then pick = item end
                    end
                end
                if pick then
                    local ok, res = invoke("TycoonRequest", "Purchase", pick.Id)
                    if succeeded(ok, res) then
                        stats.buys = stats.buys + 1
                        logLine(("Bought %s ($%s)"):format(tostring(pick.Name or pick.Id), tostring(pick.Price)))
                        tycoon = nil
                    end
                end
            end
            -- stat and ability picks
            if S.AutoStats and (tonumber(attr("PendingUpgradeChoices")) or 0) > 0 then
                local key = pickKey(S.StatFocus, STAT_LEVELS)
                local ok, res = invoke("RequestUpgradeChoice", key, "Upgrade")
                if succeeded(ok, res) then stats.picks = stats.picks + 1 logLine("Stat pick: " .. key) end
            end
            if S.AutoAbility and (tonumber(attr("PendingAbilityChoices")) or 0) > 0 then
                local key = pickKey(S.AbilityFocus, ABILITY_TIERS)
                local ok, res = invoke("RequestUpgradeChoice", key, "Ability")
                if succeeded(ok, res) then stats.picks = stats.picks + 1 logLine("Ability pick: " .. key) end
            end
            -- rebirth (= ending the day) once the game says it's ready
            if S.AutoRebirth and attr("RebirthReady") == true then doRebirth() end
            -- slower checks: rebirth tree, helpers, rewards
            if os.clock() - lastSlow > 20 then
                lastSlow = os.clock()
                if S.AutoNodes then
                    local ok, tree = invoke("RequestRebirthTreeState")
                    if ok and type(tree) == "table" then
                        local pts, have = tonumber(tree.RebirthPoints) or 0, {}
                        for _, id in pairs(tree.UnlockedNodeIds or {}) do have[id] = true end
                        for _, id in ipairs(NODE_ORDER) do
                            if not have[id] and pts > 0 then
                                local ok2, res = invoke("RequestRebirthNodeUnlock", id)
                                if succeeded(ok2, res) then logLine("Rebirth tree: " .. id) end
                                break
                            end
                        end
                    end
                end
                local okH, hs = invoke("RequestHelperState")
                if okH and type(hs) == "table" then
                    if S.AutoRewards and type(hs.DailyLogin) == "table" and hs.DailyLogin.CanClaim == true then
                        local ok, res = invoke("RequestDailyLoginClaim")
                        if succeeded(ok, res) then stats.rewards = stats.rewards + 1 logLine("Claimed daily login reward") end
                    end
                    -- best helper the Sap can buy (each hire of a rarity raises its price 50%)
                    if S.AutoHelpers and hs.HasOpenSlot ~= false then
                        local sap = type(hs.Sap) == "table" and tonumber(hs.Sap.Sap) or tonumber(hs.Sap) or 0
                        for _, rarity in ipairs(HELPER_RARITIES) do
                            local n = type(hs.RarityRollCounts) == "table" and tonumber(hs.RarityRollCounts[rarity]) or 0
                            local cost = math.floor(HELPER_BASE[rarity] * (1 + n * 0.5) + 0.5)
                            if sap >= cost then
                                local ok, res = invoke("RequestHelperRoll", rarity, false)
                                if succeeded(ok, res) then stats.hires = stats.hires + 1 logLine(("Hired a %s helper (%d Sap)"):format(rarity, cost)) end
                                break
                            end
                        end
                    end
                end
                -- the like gift unlocks through play ("Earn rewards by completing timber orders."): retry every 10 min
                if S.AutoRewards and attr("LikeGiftClaimed") ~= true and os.clock() >= (stats.likeRetryAt or 0) then
                    local ok, res = invoke("RequestLikeGiftClaim")
                    if succeeded(ok, res) then stats.rewards = stats.rewards + 1 logLine("Claimed like gift")
                    else stats.likeRetryAt = os.clock() + 600 end
                end
                saveStats()
            end
        end)
    end
end)

-- ---------- ESP ----------
local espFolder = Instance.new("Folder")
espFolder.Name = "CookiesHubTimberESP"
pcall(function() espFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not espFolder.Parent then espFolder.Parent = lp:WaitForChild("PlayerGui") end
local esp = {}   -- [instance] = { hl = outline, bb = BillboardGui, label = TextLabel, kind = "log"|"tree"|"player" }
local function makeEsp(target, adornee, color, kind)
    -- Roblox draws only ~31 Highlights at once and a forest has far more logs/trees: those get a box outline
    local hl
    if kind == "player" then
        hl = Instance.new("Highlight")
        hl.Adornee = target hl.FillColor = color hl.OutlineColor = color
        hl.FillTransparency = 0.6 hl.OutlineTransparency = 0 hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    else
        hl = Instance.new("SelectionBox")
        hl.Adornee = adornee hl.Color3 = color hl.LineThickness = 0.06
        hl.SurfaceColor3 = color hl.SurfaceTransparency = 0.8
    end
    hl.Parent = espFolder
    local bb = Instance.new("BillboardGui")
    bb.Adornee = adornee bb.Size = UDim2.fromOffset(160, 32) bb.StudsOffset = Vector3.new(0, kind == "tree" and 8 or 3, 0)
    bb.AlwaysOnTop = true bb.MaxDistance = kind == "player" and 2000 or 600 bb.Parent = espFolder
    local t = Instance.new("TextLabel")
    t.BackgroundTransparency = 1 t.Size = UDim2.fromScale(1, 1) t.Font = Enum.Font.GothamBold t.TextSize = 13
    t.TextColor3 = color t.TextStrokeTransparency = 0.4 t.Text = "" t.Parent = bb
    esp[target] = { hl = hl, bb = bb, label = t, kind = kind }
end
local function dropEsp(target)
    local e = esp[target]
    if e then e.hl:Destroy() e.bb:Destroy() esp[target] = nil end
end
local COLORS = {
    mine = Color3.fromRGB(255, 205, 60), others = Color3.fromRGB(150, 150, 150), player = Color3.fromRGB(171, 113, 235),
    tree = Color3.fromRGB(90, 220, 120), locked = Color3.fromRGB(226, 90, 90),
}
local TREE_ESP_RANGE = 250
local function refreshEsp()
    local r = hrp()
    local me = r and r.Position
    if S.LogESP then   -- yellow = yours to take, grey = someone else's
        local dl = Workspace:FindFirstChild("DroppedLogs")
        for _, log in ipairs(dl and dl:GetChildren() or {}) do
            local bark = log:FindFirstChild("Bark") or (log:IsA("Model") and log.PrimaryPart)
            if bark and not esp[log] then makeEsp(log, bark, takeable(log) and COLORS.mine or COLORS.others, "log") end
        end
    end
    if S.TreeESP and me then   -- trees within range: green = choppable, red = locked grove
        for _, t in ipairs(Workspace.Trees:GetChildren()) do
            local base = t:GetAttribute("TreeSpawnPosition")
            if typeof(base) == "Vector3" and (base - me).Magnitude <= TREE_ESP_RANGE and not esp[t] then
                local trunk = trunkOf(t)
                if trunk then makeEsp(t, trunk, t:GetAttribute("GroveLocked") == true and COLORS.locked or COLORS.tree, "tree") end
            end
        end
    end
    if S.PlayerESP then
        for _, p in ipairs(Players:GetPlayers()) do
            local c = p ~= lp and p.Character
            local head = c and (c:FindFirstChild("Head") or c:FindFirstChild("HumanoidRootPart"))
            if head and not esp[c] then makeEsp(c, head, COLORS.player, "player") end
        end
    end
    for target, e in pairs(esp) do
        local on = (e.kind == "log" and S.LogESP) or (e.kind == "tree" and S.TreeESP) or (e.kind == "player" and S.PlayerESP)
        local pos = e.bb.Adornee and e.bb.Adornee:IsA("BasePart") and e.bb.Adornee.Position
        local dist = (pos and me) and math.floor((pos - me).Magnitude) or 0
        if not target.Parent or not on or (e.kind == "tree" and (dist > TREE_ESP_RANGE + 20 or (target:GetAttribute("Health") or 1) <= 0)) then
            dropEsp(target)
        elseif e.kind == "log" then
            e.label.Text = ("Log  %dm"):format(dist)
        elseif e.kind == "tree" then
            local hp, mx = tonumber(target:GetAttribute("Health")) or 0, tonumber(target:GetAttribute("MaxHealth")) or 1
            e.label.Text = ("%s T%s  %d%%  %dm%s"):format(tostring(target:GetAttribute("Species") or "tree"), tostring(target:GetAttribute("TreeTier") or "?"),
                math.floor(hp / mx * 100), dist, target:GetAttribute("GroveLocked") == true and "  LOCKED" or "")
        else
            local p = Players:GetPlayerFromCharacter(target)
            e.label.Text = ("%s  %dm"):format(p and p.DisplayName or target.Name, dist)
        end
    end
end
task.spawn(function()
    while alive do
        pcall(refreshEsp)
        task.wait(0.5)
    end
end)

-- ---------- full bright ----------
-- the game drives its own day/night lighting, so it's re-applied every second; originals come back when it's off
local LIGHT_PROPS = { "Brightness", "ClockTime", "FogEnd", "GlobalShadows", "Ambient", "OutdoorAmbient" }
local savedLight, savedAtmo
local function applyFullBright(on)
    if on then
        if not savedLight then
            savedLight = {}
            for _, p in ipairs(LIGHT_PROPS) do savedLight[p] = Lighting[p] end
            local a = Lighting:FindFirstChildOfClass("Atmosphere")
            savedAtmo = a and { inst = a, density = a.Density, haze = a.Haze }
        end
        Lighting.Brightness = 3 Lighting.ClockTime = 14 Lighting.FogEnd = 1e5 Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(180, 180, 180) Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
        local a = Lighting:FindFirstChildOfClass("Atmosphere")
        if a then a.Density = 0 a.Haze = 0 end
    elseif savedLight then
        for p, v in pairs(savedLight) do pcall(function() Lighting[p] = v end) end
        if savedAtmo and savedAtmo.inst.Parent then savedAtmo.inst.Density = savedAtmo.density savedAtmo.inst.Haze = savedAtmo.haze end
        savedLight, savedAtmo = nil, nil
    end
end
task.spawn(function()
    while alive do
        if S.FullBright then pcall(applyFullBright, true) end
        task.wait(1)
    end
end)

-- ---------- anti-AFK ----------
local VirtualUser = game:GetService("VirtualUser")
local idleConn = lp.Idled:Connect(function()
    if S.AntiAFK then pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end) end
end)

-- ======================================================================
-- UI  (purple Cookies Hub theme, tabs like the TDS hub)
-- ======================================================================
local C = {
    bg=Color3.fromRGB(20,16,30), panel=Color3.fromRGB(30,24,44), row=Color3.fromRGB(42,34,60),
    accent=Color3.fromRGB(171,113,235), accent2=Color3.fromRGB(139,92,214), danger=Color3.fromRGB(226,90,90),
    good=Color3.fromRGB(80,220,120), text=Color3.fromRGB(236,232,245), text2=Color3.fromRGB(165,158,185),
}
local W, H = 470, 480
local function corner(p, r) local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, r or 8) c.Parent = p return c end

local gui = Instance.new("ScreenGui")
gui.Name = "CookiesHubTimber" gui.ResetOnSpawn = false gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
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
    title.TextXAlignment = Enum.TextXAlignment.Left title.Text = "Cookies Hub  -  TIMBER!" title.Parent = bar
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
local TAB_NAMES = { "Farm", "Upgrades", "Islands", "Visuals", "Teleport", "Stats", "Info" }
function ui.select(n)
    for k, p in pairs(ui.tabs) do p.Visible = k == n end
    for k, b in pairs(ui.tabBtns) do b.BackgroundColor3 = k == n and C.accent or C.row b.TextColor3 = k == n and C.bg or C.text2 end
end
function ui.tab(n)
    local b = Instance.new("TextButton") b.Size = UDim2.new(1 / #TAB_NAMES, -5, 1, 0) b.BackgroundColor3 = C.row b.Text = n
    b.Font = Enum.Font.GothamMedium b.TextSize = 12 b.TextColor3 = C.text2 b.BorderSizePixel = 0 b.Parent = tabRow corner(b, 6)
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
    b.MouseButton1Click:Connect(function() task.spawn(pcall, fn) end)   -- own thread: actions may wait on the server
    return b
end
-- a row of choice buttons bound to a string setting
function ui.choice(parent, key, options)
    local row = Instance.new("Frame") row.Size = UDim2.new(1, 0, 0, 28) row.BackgroundTransparency = 1 row.Parent = parent
    local l = Instance.new("UIListLayout") l.FillDirection = Enum.FillDirection.Horizontal l.Padding = UDim.new(0, 5) l.Parent = row
    local btns = {}
    local function render()
        for v, b in pairs(btns) do b.BackgroundColor3 = S[key] == v and C.accent or C.row b.TextColor3 = S[key] == v and C.bg or C.text2 end
    end
    for _, v in ipairs(options) do
        local b = Instance.new("TextButton") b.Size = UDim2.new(1 / #options, -4, 1, 0) b.Text = v
        b.Font = Enum.Font.GothamMedium b.TextSize = 12 b.BorderSizePixel = 0 b.Parent = row corner(b, 6)
        btns[v] = b
        b.MouseButton1Click:Connect(function() S[key] = v saveSettings() render() end)
    end
    render()
    ui.renders[key] = render
end

for _, n in ipairs(TAB_NAMES) do ui.tab(n) end

do -- Farm
    local p = ui.tabs.Farm
    ui.sec(p, "Auto farm")
    ui.toggle(p, "Auto farm (chop, collect, deposit)", "AutoFarm", function(v) logLine(v and "Auto farm ON" or "Auto farm OFF") end)
    ui.toggle(p, "Swing if a tree stops taking damage", "ChopAssist")
    ui.note(p, "Stands by the nearest unlocked tree (the game's axe/chainsaw chops it), picks up your logs and drops them at your plot when full - trying each drop zone in turn as they fill. Never takes other players' logs.")
    ui.sec(p, "Free rewards")
    ui.toggle(p, "Auto claim daily login + like gift", "AutoRewards")
    ui.sec(p, "Misc")
    ui.toggle(p, "Anti-AFK", "AntiAFK")
    ui.sec(p, "Status")
    ui.status = ui.note(p, "Status: idle")
    ui.carry = ui.note(p, "Carrying: -")
    ui.log = ui.note(p, "")
end
do -- Upgrades
    local p = ui.tabs.Upgrades
    ui.sec(p, "Factory")
    ui.toggle(p, "Auto buy upgrades (next objective first)", "AutoBuy")
    ui.toggle(p, "Auto claim finished orders", "AutoOrders")
    ui.objective = ui.note(p, "Next objective: -")
    ui.order = ui.note(p, "Order: -")
    ui.sec(p, "Stat picks (every truck load)")
    ui.toggle(p, "Auto pick stat upgrades", "AutoStats")
    ui.choice(p, "StatFocus", { "Balanced", "AxeDamage", "CarryCapacity", "Speed" })
    ui.sec(p, "Abilities (truck milestones)")
    ui.toggle(p, "Auto choose abilities", "AutoAbility")
    ui.choice(p, "AbilityFocus", { "Balanced", "AxeDamage", "CarryCapacity", "Speed" })
    ui.note(p, "Balanced picks whichever track is lowest, so all three grow evenly.")
    ui.sec(p, "Helpers")
    ui.toggle(p, "Auto hire helpers with Sap (best rarity affordable)", "AutoHelpers")
    ui.sec(p, "Rebirth")
    ui.toggle(p, "Auto rebirth when ready (RESETS PROGRESS)", "AutoRebirth")
    ui.toggle(p, "Auto unlock rebirth tree nodes", "AutoNodes")
    ui.note(p, "Rebirth = ending the day once you reach the truckload target. It takes the money-multiplier day upgrade when offered. Off by default because it resets your run.")
end
do -- Islands
    local p = ui.tabs.Islands
    ui.sec(p, "Islands")
    ui.toggle(p, "Auto build islands (send full loads to the next bridge)", "AutoIslands")
    ui.note(p, "While on, every full load goes to the next unlocked bridge until it's built, then back to selling. Needs Auto farm on.")
    ui.sites = ui.note(p, "-")
end
do -- Visuals
    local p = ui.tabs.Visuals
    ui.sec(p, "ESP")
    ui.toggle(p, "Log ESP (yellow = yours, grey = others')", "LogESP")
    ui.toggle(p, "Tree ESP (type, tier, health; red = locked)", "TreeESP")
    ui.toggle(p, "Player ESP (name + distance)", "PlayerESP")
    ui.sec(p, "World")
    ui.toggle(p, "Full bright", "FullBright", function(v) applyFullBright(v) end)
end
do -- Teleport
    local p = ui.tabs.Teleport
    ui.sec(p, "Your plot")
    ui.button(p, "Plot drop zone", C.accent2, function()
        local r = hrp() local z = r and dropZones(r.Position)[1]
        if z then moveTo(z.CFrame + Vector3.new(0, 3, 0)) end
    end)
    ui.button(p, "Spawn", C.row, function()
        local sp = Workspace:FindFirstChildOfClass("SpawnLocation") or Workspace:FindFirstChild("SpawnLocation")
        if sp then moveTo(sp.CFrame + Vector3.new(0, 4, 0)) end
    end)
    ui.sec(p, "Island sites")
    local ws = Workspace:FindFirstChild("WorldSites")
    for _, m in ipairs(ws and ws:GetChildren() or {}) do
        if typeof(m:GetAttribute("PadAt")) == "Vector3" then
            ui.button(p, tostring(m:GetAttribute("Name") or m.Name), C.row, function()
                moveTo(CFrame.new(m:GetAttribute("PadAt") + Vector3.new(0, 3, 0)))
            end)
        end
    end
    ui.sec(p, "Groves")
    local groves = {}
    for _, t in ipairs(Workspace.Trees:GetChildren()) do
        local g, pos = t:GetAttribute("Grove"), t:GetAttribute("TreeSpawnPosition")
        if typeof(g) == "string" and typeof(pos) == "Vector3" then
            groves[g] = groves[g] or { sum = Vector3.zero, n = 0 }
            groves[g].sum, groves[g].n = groves[g].sum + pos, groves[g].n + 1
        end
    end
    for g, d in pairs(groves) do
        local centre = d.sum / d.n
        ui.button(p, ("%s grove (%d trees)"):format(g, d.n), C.row, function() moveTo(CFrame.new(centre + Vector3.new(0, 5, 0))) end)
    end
end
do -- Stats
    local p = ui.tabs.Stats
    ui.sec(p, "This session (carries across rejoins)")
    ui.stats = ui.note(p, "-")
    ui.button(p, "Reset session stats", C.danger, function()
        for _, k in ipairs(STAT_KEYS) do stats[k] = 0 end
        stats.start, stats.startMoney = os.time(), attr("Money") or 0
        saveStats()
    end)
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
    ui.sec(p, "How it works")
    ui.note(p, "Auto farm stands next to trees (the game chops them for you), collects your logs and drops them at your plot. Islands sends full loads to the next bridge. Upgrades buys the factory's next step, claims finished orders and spends stat/ability picks for you. Everything is read from the game's own state.")
    ui.sec(p, "Keys")
    ui.note(p, "RightShift shows/hides the hub. X unloads it and restores your lighting.")
end
ui.select("Farm")

-- live status
task.spawn(function()
    while alive do
        task.wait(1)
        pcall(function()
            ui.status.Text = "Status: " .. stats.status
            ui.carry.Text = ("Carrying: %d / %d logs   |   deposited today: %s"):format(attr("CarriedLogs") or 0, attr("MaxCarriedLogs") or 0, tostring(attr("DayLogsDeposited") or 0))
            ui.log.Text = table.concat({ stats.log[1] or "", stats.log[2] or "", stats.log[3] or "" }, "\n")
            local s = tycoon
            if s and type(s.Objective) == "table" then ui.objective.Text = ("Next objective: %s - %s"):format(tostring(s.Objective.Title), tostring(s.Objective.Body)) end
            if s and type(s.Contract) == "table" then
                ui.order.Text = ("Order: %s  %s/%s%s"):format(tostring(s.Contract.Title), tostring(s.Contract.Current), tostring(s.Contract.Target), s.Contract.Ready and "  READY" or "")
            end
            local rows = {}
            local ws = Workspace:FindFirstChild("WorldSites")
            for _, m in ipairs(ws and ws:GetChildren() or {}) do
                local cost = tonumber(m:GetAttribute("Cost"))
                if cost and cost > 0 then
                    rows[#rows + 1] = ("%s: %s/%d%s"):format(tostring(m:GetAttribute("Name") or m.Name), tostring(m:GetAttribute("Progress") or 0), cost,
                        m:GetAttribute("Built") == true and "  BUILT" or (m:GetAttribute("Locked") == true and ("  locked - " .. tostring(m:GetAttribute("LockText") or "")) or ""))
                end
            end
            ui.sites.Text = #rows > 0 and table.concat(rows, "\n") or "No island sites found."
            local mins = math.max((os.time() - stats.start) / 60, 1 / 60)
            local money = (attr("Money") or stats.startMoney) - stats.startMoney
            ui.stats.Text = ("Farming %dm\nMoney: +$%d  (%.0f/min)\nTrees felled: %d   Logs collected: %d   Deposits: %d\nIsland logs: %d   Orders claimed: %d   Purchases: %d\nPicks: %d   Rebirths: %d   Helpers hired: %d   Rewards: %d")
                :format(math.floor(mins), money, money / mins, stats.trees, stats.logs, stats.deposits, stats.islandLogs, stats.orders, stats.buys, stats.picks, stats.rebirths, stats.hires, stats.rewards)
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
    main.Size = minimized and UDim2.fromOffset(W, 40) or UDim2.fromOffset(W, H)
end)

local inputConn
local function Unload()
    alive = false S.AutoFarm = false
    saveStats()
    if inputConn then inputConn:Disconnect() end
    idleConn:Disconnect()
    tycoonConn:Disconnect()
    pcall(applyFullBright, false)
    pcall(function() espFolder:Destroy() end)
    pcall(function() gui:Destroy() end)
    _G.CookiesHubTimber = nil
end
closeBtn.MouseButton1Click:Connect(Unload)
inputConn = UserInputService.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == S.ToggleKey then main.Visible = not main.Visible end
end)
if S.FullBright then applyFullBright(true) end

_G.CookiesHubTimber = {
    Unload = Unload, State = S, Stats = stats,
    Set = function(k, v)
        if S[k] == nil then return end
        S[k] = v saveSettings()
        if ui.renders[k] then ui.renders[k]() end
        if k == "FullBright" then applyFullBright(v) end
    end,
    Get = function(k) return S[k] end,
    Tycoon = function() return tycoon end,
}
logLine("Cookies Hub (TIMBER!) loaded.")

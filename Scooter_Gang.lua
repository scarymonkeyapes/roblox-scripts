-- Cookies Hub (Scooter Gang [ALPHA])  [KEYLESS]
-- RightShift: show/hide | X button or _G.CookiesHubScooterGang.Unload(): unload
-- Console: _G.CookiesHubScooterGang.Set("AutoDeliver", true)
--
-- WARNING: auto-farming breaks the game's rules and can get an account banned. Use at your own risk, ideally on an
-- alt account. Defaults are conservative (75% speed, SafeStop + BlockPolice on, fly/noclip/boost off).
--
-- Read from Scooter Gang (place 105693218931258, leifstout Networker services):
--  * Client service modules are plain tables in ReplicatedStorage.Shared.Services.<X>.<X>Client and the game's
--    require cache is shared, so the hub calls them directly (DeliveryClient:startJob(), VehicleClient:requestSpawn()...).
--  * Deliveries: DeliveryClient:getState() -> { active, stage = "toRestaurant" | "toCustomer" | nil, target }.
--    The server completes pickup / drop-off from your ride's position (pickup = stop on the PickupSpot for 0.5 s,
--    drop = inside the customer's ring). Pay scales with speed and streak.
--  * Movement checks (Config.Delivery.antiCheat / Config.Economy): speed is compared against your ride's top speed
--    (x1.15 tolerance) and teleports above 400 km/h are flagged, so the ride is glided at up to its own top speed
--    (controller:getState().topSpeedKmh), collisions + crashing off so buildings don't knock you off.
--  * Map teleport ("Map","teleport", id) dismounts you; VehicleClient:requestSpawn() puts the ride back under you.
--  * Police offences / witness reports are sent by the client (PoliceClient.reportOffence / reportWitness).
--  * Rewards: RewardsClient:getDaily().claimedToday / claimDaily() / claimFreeRide(). Quests auto-claim server side.
--  * Next ride: player attrs NextRide / NextRidePrice -> DealershipClient:buy(id) + equip(id).
-- Save this file as UTF-8 WITHOUT a BOM or it won't load.

if _G.CookiesHubScooterGang and _G.CookiesHubScooterGang.Unload then pcall(_G.CookiesHubScooterGang.Unload) end

local Players          = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local Workspace        = game:GetService("Workspace")
local lp               = Players.LocalPlayer

-- ---------- guard ----------
if not game:IsLoaded() then game.Loaded:Wait() end
local Shared = RS:WaitForChild("Shared", 15)
local SvcFolder = Shared and Shared:WaitForChild("Services", 15)
if not (SvcFolder and SvcFolder:FindFirstChild("Delivery") and SvcFolder:FindFirstChild("Vehicle")) then
    warn("[CookiesHub ScooterGang] Not Scooter Gang (missing Delivery / Vehicle services). Aborting.")
    return
end
local alive = true   -- cleared on Unload so every loop exits

-- ---------- settings (per account) ----------
local S = {
    -- farm
    AutoDeliver   = false,
    SpeedPct      = 75,      -- % of your ride's top speed (the server allows up to ~115%)
    AutoRemount   = true,    -- respawn the ride under you when you fall off / get dismounted
    BlockPolice   = true,    -- don't report your own offences to the police
    SafeStop      = true,    -- pause while police chase you; switch the farm off if you keep falling off
    -- progress
    AutoBuyRide   = false,
    -- rewards
    AutoDaily     = true,
    AutoFreeRide  = true,
    -- visual
    PlayerESP     = false,
    Tracers       = false,
    ScooterESP    = false,
    Fullbright    = false,
    -- scooter
    ScooterFly    = false,
    ScooterNoclip = false,
    ScooterFlySpeed = 120,
    SpeedBoost    = false,
    BoostMult     = 1.3,
    WheelieLimit  = false,
    WheelieAngle  = 30,
    NoCrash       = false,
    -- player
    InfJump       = false,
    WalkSpeedOn   = false,
    WalkSpeed     = 40,
    JumpOn        = false,
    JumpMult      = 2,
    Noclip        = false,
    Fly           = false,
    FlySpeed      = 80,
    -- misc
    AntiAFK       = true,
    ToggleKey     = Enum.KeyCode.RightShift,
}
local SETTINGS_FILE = ("CookiesHubScooterGang_%d_settings.json"):format(lp.UserId)
pcall(function()
    for k, v in pairs(HttpService:JSONDecode(readfile(SETTINGS_FILE))) do
        if S[k] ~= nil and type(S[k]) == type(v) then S[k] = v end
    end
end)
S.SpeedPct = math.clamp(S.SpeedPct, 30, 110)
local function saveSettings()
    local out = {}
    for k, v in pairs(S) do if type(v) ~= "userdata" then out[k] = v end end
    pcall(function() writefile(SETTINGS_FILE, HttpService:JSONEncode(out)) end)
end

-- ---------- game access ----------
local function client(name)
    local f = SvcFolder:FindFirstChild(name)
    local m = f and f:FindFirstChild(name .. "Client")
    local ok, mod = pcall(require, m)
    return ok and type(mod) == "table" and mod or nil
end
local Delivery   = client("Delivery")
local Vehicle    = client("Vehicle")
local Police     = client("Police")
local Rewards    = client("Rewards")
local Dealership = client("Dealership")
local Codes      = client("CodeService")
local Map        = client("Map")
local Units, DeliveryCfg
pcall(function() Units = require(Shared.Modules.Units) end)
pcall(function() DeliveryCfg = require(Shared.Modules.Config.Delivery) end)
local function kmhToStuds(k) return Units and Units.kmhToStuds(k) or k * 1.7778 end

local function deliveryState()
    local ok, st = pcall(Delivery.getState, Delivery)
    return ok and type(st) == "table" and st or nil
end
-- the mounted ride table (VehicleClient's private u2): { controller, rig = { root }, model, ... }
local function ride()
    local ok, r = pcall(debug.getupvalue, Vehicle.isMounted, 1)
    return ok and type(r) == "table" and r.rig and r.controller and r or nil
end
local function cash()
    local ls = lp:FindFirstChild("leaderstats")
    local c = ls and ls:FindFirstChild("Cash")
    return c and tonumber(c.Value) or 0
end
local function short(n)
    n = tonumber(n)
    if not n then return "-" end
    local units = { "", "K", "M", "B", "T" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do n = n / 1000 i = i + 1 end
    return (i == 1 and "%d%s" or "%.2f%s"):format(n, units[i])
end

-- where to start a job: the Restaurant-tagged model's StartAt (streams out when far), else the Map point
local PIZZA = Vector3.new(-32.5, 10.5, -234.5)
pcall(function()
    for _, p in ipairs(Map:getPoints()) do
        if p.kind == "restaurant" and typeof(p.position) == "Vector3" then PIZZA = p.position break end
    end
end)
local function restaurantSpot()
    local tag = DeliveryCfg and DeliveryCfg.tags.restaurant or "Restaurant"
    for _, v in ipairs(CollectionService:GetTagged(tag)) do
        local at = v:GetAttribute("StartAt")
        if typeof(at) == "Vector3" then return at, v:GetAttribute("StartRadius") or 9 end
    end
    return PIZZA, 9
end

-- ---------- police: keep your own offences unreported ----------
local policeOrig = {}
local function applyPolice()
    if not Police then return end
    for _, fn in ipairs({ "reportOffence", "reportWitness" }) do
        if S.BlockPolice then
            if not policeOrig[fn] and type(Police[fn]) == "function" then
                policeOrig[fn] = Police[fn]
                Police[fn] = function() end
            end
        elseif policeOrig[fn] then
            Police[fn] = policeOrig[fn] policeOrig[fn] = nil
        end
    end
end
applyPolice()

-- ---------- auto delivery ----------
-- The ride is glided straight at the GPS target. Ride parts we turn non-colliding are remembered and restored.
-- Crashing is switched off on the ride's controller (instance fields over its class methods) while any feature
-- needs it: the farm, scooter fly, or the No crash toggle.
local crashOff = { farm = false, fly = false, noclip = false }
local patched     -- controller whose crash checks are switched off
local function syncCrash()
    local r = ride()
    local c = r and (S.NoCrash or crashOff.farm or crashOff.fly or crashOff.noclip) and r.controller or nil
    if patched and patched ~= c then patched._crash = nil patched._checkCrash = nil patched = nil end
    if c and patched ~= c then
        c._crash = function() return false end
        c._checkCrash = function() return false end
        patched = c
    end
end
local noCollide = {}
local function restoreRideCollide()
    for part, was in pairs(noCollide) do if part.Parent then part.CanCollide = was end end
    table.clear(noCollide)
end
local function rideNoCollide(r)
    for _, d in ipairs(r.model:GetDescendants()) do
        if d:IsA("BasePart") and d.CanCollide then noCollide[d] = true d.CanCollide = false end
    end
end
local function releaseRide()
    restoreRideCollide()
    crashOff.farm = false
    syncCrash()
end
local function prepRide(r)
    crashOff.farm = true
    syncCrash()
    rideNoCollide(r)
end
local function topSpeedStuds(r)
    local ok, st = pcall(r.controller.getState, r.controller)
    local kmh = ok and st and tonumber(st.topSpeedKmh) or 60
    return kmhToStuds(kmh) * S.SpeedPct / 100
end
-- Moving the ride: each frame we place the root and give it the matching velocity (so speed reads right).
-- Physics also integrates that velocity between frames, so steps start from where we last put it, not from where
-- physics carried it, or the ride travels at double the set speed.
local commanded = setmetatable({}, { __mode = "k" })   -- [root] = last position we set
local function basePos(root)
    local c = commanded[root]
    if c and (root.Position - c).Magnitude < 25 then return c end
    return root.Position
end
local function placeRoot(root, pos, face, vel)
    root.CFrame = CFrame.lookAt(pos, pos + face)
    root.AssemblyLinearVelocity = vel
    root.AssemblyAngularVelocity = Vector3.zero
    commanded[root] = pos
end
-- one frame of travel towards `tgt`; returns true once parked on it
local function glide(r, tgt, dt)
    local root = r.rig.root
    local p = basePos(root)
    local flat = Vector3.new(tgt.X - p.X, 0, tgt.Z - p.Z)
    if flat.Magnitude < 2.5 then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        commanded[root] = nil
        return true
    end
    local speed = topSpeedStuds(r)
    local dir = flat.Unit
    local step = math.min(flat.Magnitude, speed * dt)
    placeRoot(root, Vector3.new(p.X, tgt.Y + 3, p.Z) + dir * step, dir, dir * (step / dt))
    return false
end

local stats = { delivered = 0, earned = 0, startCash = cash(), startedAt = os.clock(), msg = "idle", hist = {} }
local deliveredConn = Delivery.Delivered:Connect(function() stats.delivered = stats.delivered + 1 end)
local messageConn = Delivery.Message:Connect(function(m) if type(m) == "string" then stats.msg = m end end)

local lastSpawn, lastStart = 0, 0
local pausedUntil = 0   -- SafeStop: police are after you
local respawns = {}     -- times the farm had to put you back on the ride
-- police check once a second while the farm runs
task.spawn(function()
    while alive do
        if S.AutoDeliver and S.SafeStop and Police then
            local ok, heat = pcall(Police.getHeat, Police)
            if ok and type(heat) == "table" and ((tonumber(heat.stars) or 0) > 0 or heat.chasing == true) then
                pausedUntil = os.clock() + 5
                stats.msg = "paused: police"
            end
        end
        task.wait(1)
    end
end)
local farmConn = RunService.Heartbeat:Connect(function(dt)
    if not S.AutoDeliver then
        if crashOff.farm then releaseRide() end
        return
    end
    if os.clock() < pausedUntil then
        if crashOff.farm then releaseRide() end
        return
    end
    local r = ride()
    if not r then
        releaseRide()
        if S.AutoRemount and os.clock() - lastSpawn > 4 then
            lastSpawn = os.clock()
            respawns[#respawns + 1] = lastSpawn
            while respawns[1] and lastSpawn - respawns[1] > 60 do table.remove(respawns, 1) end
            if S.SafeStop and #respawns >= 4 then
                table.clear(respawns)
                stats.msg = "farm off: kept falling off the ride"
                task.defer(function() if _G.CookiesHubScooterGang then _G.CookiesHubScooterGang.Set("AutoDeliver", false) end end)
                return
            end
            task.spawn(pcall, Vehicle.requestSpawn, Vehicle)
            stats.msg = "respawning ride"
        end
        return
    end
    local st = deliveryState()
    if not st then return end
    prepRide(r)
    if st.active then
        if typeof(st.target) == "Vector3" then glide(r, st.target, dt) end   -- nil between orders: hold still
        return
    end
    -- no job: ride to the restaurant, then start one
    local spot, radius = restaurantSpot()
    local p = r.rig.root.Position
    if Vector3.new(spot.X - p.X, 0, spot.Z - p.Z).Magnitude > radius - 2 then
        glide(r, spot, dt)
        stats.msg = "riding to the restaurant"
    elseif os.clock() - lastStart > 3 then
        lastStart = os.clock()
        glide(r, spot, dt)
        task.spawn(function()
            local ok, good, why = pcall(Delivery.startJob, Delivery)
            stats.msg = ok and tostring(why or good) or "start failed"
        end)
    end
end)

-- ---------- teleports and rides ----------
local KitServices
pcall(function() KitServices = require(RS.UI.Kit.Services) end)
local function mapPoints()
    local ok, pts = pcall(Map.getPoints, Map)
    return ok and type(pts) == "table" and pts or {}
end
local function teleportTo(id)
    if not KitServices then return false, "no teleport service" end
    local ok, good, why = pcall(KitServices.call, "Map", "teleport", id)
    if not (ok and good) then return false, tostring(ok and why or good) end
    task.wait(1.5)
    if not ride() then pcall(Vehicle.requestSpawn, Vehicle) end   -- teleporting drops you off the ride
    return true, why
end
local function ownedRides()
    local out = {}
    pcall(function()
        for id in pairs(require(Shared.Modules.Data).client.owned() or {}) do out[#out + 1] = id end
    end)
    table.sort(out)
    return out
end
local function switchRide(id)
    if not Dealership then return end
    pcall(Dealership.equip, Dealership, id)
    task.wait(0.5)
    pcall(Vehicle.requestSpawn, Vehicle, id)
end

-- ---------- scooter: fly, speed boost, wheelie limiter, no crash ----------
-- Inputs go through VehicleClient:setInput (the game's touch buttons), which merge with your keyboard.
-- The game ignores all ride input while the Dealership / Garage menu is open.
local boosted     -- { tuning, orig = { topSpeed, power, accel } }
local function unboost()
    if boosted then
        for k, v in pairs(boosted.orig) do boosted.tuning[k] = v end
        boosted = nil
    end
end
local function boost(r)
    if boosted and boosted.tuning ~= r.tuning then unboost() end
    if not boosted then
        boosted = { tuning = r.tuning, orig = { topSpeed = r.tuning.topSpeed, power = r.tuning.power, accel = r.tuning.accel } }
    end
    for k, v in pairs(boosted.orig) do r.tuning[k] = v * S.BoostMult end
end

local heldInputs = {}   -- inputs the hub is holding down, released when a feature stops
local function hold(name, on)
    if on then heldInputs[name] = true elseif not heldInputs[name] then return else heldInputs[name] = nil end
    pcall(Vehicle.setInput, Vehicle, name, on)
end
local function releaseInputs()
    for name in pairs(heldInputs) do pcall(Vehicle.setInput, Vehicle, name, false) end
    table.clear(heldInputs)
end

-- wheelie limiter: you keep the gas and the wheelie key; the nose just can't pass the angle. The controller simulates
-- the wheelie as an angle (wAngle, radians) and a rate (wRate); it has its own loop-out cap on them, so this adds a
-- lower one the same way. Inputs are never touched, so full throttle stays full throttle.
local function stepWheelie(r)
    local c = r.controller
    local limit = math.rad(S.WheelieAngle)
    if type(c.wAngle) == "number" and c.wAngle > limit then
        c.wAngle = limit
        c.wRate = math.min(tonumber(c.wRate) or 0, 0)
    end
end

-- scooter fly: WASD along the camera, Space up, Ctrl down; collisions and crashing off while flying
local function stepScooterFly(r, dt)
    local c = Workspace.CurrentCamera
    if not c then return end
    local look, right = c.CFrame.LookVector, c.CFrame.RightVector
    local dir = Vector3.zero
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += look end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= look end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += right end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= right end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
    local root = r.rig.root
    local vel = dir.Magnitude > 0 and dir.Unit * S.ScooterFlySpeed or Vector3.zero
    local flat = Vector3.new(look.X, 0, look.Z)
    local face = flat.Magnitude > 0.01 and flat.Unit or root.CFrame.LookVector
    placeRoot(root, basePos(root) + vel * dt, face, vel)
end

local wasNoCollide = false
local scooterConn = RunService.Heartbeat:Connect(function(dt)
    local r = ride()
    local farming = S.AutoDeliver   -- the farm drives the ride itself; these would fight it (and boost breaks its speed cap)
    if r and S.SpeedBoost and not farming then boost(r) else unboost() end

    local flyNow = r ~= nil and S.ScooterFly and not farming
    crashOff.fly = flyNow
    local ghostNow = r ~= nil and S.ScooterNoclip and not farming and not flyNow   -- drive normally, through solid things
    crashOff.noclip = ghostNow
    local noCollideNow = flyNow or ghostNow
    if noCollideNow then rideNoCollide(r) end
    if flyNow then stepScooterFly(r, dt)
    elseif wasNoCollide and not noCollideNow and not crashOff.farm then restoreRideCollide() end
    wasNoCollide = noCollideNow

    local wheelieNow = r ~= nil and S.WheelieLimit and not farming and not flyNow
    if wheelieNow then stepWheelie(r) end

    syncCrash()
end)

local function unstuck() pcall(Vehicle.requestUnstuck, Vehicle) end

-- ---------- auto buy the next ride ----------
task.spawn(function()
    while alive do
        if S.AutoBuyRide and Dealership then
            local id, price = lp:GetAttribute("NextRide"), tonumber(lp:GetAttribute("NextRidePrice"))
            if type(id) == "string" and id ~= "" and price and cash() >= price then
                local ok, good = pcall(Dealership.buy, Dealership, id)
                if ok and good then
                    pcall(Dealership.equip, Dealership, id)
                    stats.msg = "bought " .. id
                    task.wait(2)
                    if not ride() then pcall(Vehicle.requestSpawn, Vehicle, id) end
                end
            end
        end
        task.wait(10)
    end
end)

-- ---------- rewards ----------
task.spawn(function()
    while alive do
        if Rewards then
            if S.AutoDaily then
                local ok, d = pcall(Rewards.getDaily, Rewards)
                if ok and type(d) == "table" and d.claimedToday == false then pcall(Rewards.claimDaily, Rewards) end
            end
            if S.AutoFreeRide then pcall(Rewards.claimFreeRide, Rewards) end
        end
        task.wait(60)
    end
end)

-- codes are printed on the CodeSigns around the map
local function signCodes()
    local out, seen = {}, {}
    local signs = Workspace:FindFirstChild("CodeSigns")
    for _, d in ipairs(signs and signs:GetDescendants() or {}) do
        if d:IsA("TextLabel") then
            local t = d.Text:gsub("^%s+", ""):gsub("%s+$", "")
            if t ~= "" and #t <= 24 and not t:find(":") and not t:find("%s") and not seen[t] then
                seen[t] = true out[#out + 1] = t
            end
        end
    end
    return out
end
local function redeem(code)
    if not Codes then return false, "no code service" end
    local ok, good, why = pcall(Codes.redeem, Codes, code)
    return ok and good, ok and why or tostring(good)
end

-- ---------- visuals: player / scooter ESP, tracers, fullbright ----------
local Lighting = game:GetService("Lighting")
local cam = function() return Workspace.CurrentCamera end
local espGui = Instance.new("ScreenGui")   -- holds the Highlights / labels; parented with the hub window below
espGui.Name = "CookiesHubScooterGangESP" espGui.ResetOnSpawn = false
pcall(function() espGui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not espGui.Parent then espGui.Parent = lp:WaitForChild("PlayerGui") end

local PLAYER_COL, SCOOTER_COL = Color3.fromRGB(171, 113, 235), Color3.fromRGB(80, 220, 120)
local esp = {}   -- [model] = { hl, bb, label, kind }
local function dropEsp(model)
    local e = esp[model]
    if not e then return end
    esp[model] = nil
    e.hl:Destroy() e.bb:Destroy()
end
local function ensureEsp(model, kind, color, adornee)
    local e = esp[model]
    if e and e.hl.Parent and e.bb.Parent then return e end
    dropEsp(model)
    local hl = Instance.new("Highlight")
    hl.Adornee = model hl.FillColor = color hl.OutlineColor = color hl.FillTransparency = 0.6
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop hl.Parent = espGui
    local bb = Instance.new("BillboardGui")
    bb.Adornee = adornee bb.AlwaysOnTop = true bb.Size = UDim2.fromOffset(140, 20) bb.StudsOffset = Vector3.new(0, 3, 0)
    bb.Parent = espGui
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1) label.BackgroundTransparency = 1 label.Font = Enum.Font.GothamBold
    label.TextSize = 12 label.TextColor3 = color label.TextStrokeTransparency = 0.4 label.Parent = bb
    e = { hl = hl, bb = bb, label = label, kind = kind }
    esp[model] = e
    return e
end
local function dist(pos)
    local r = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    return r and (r.Position - pos).Magnitude or 0
end
local function refreshEsp()
    local want = {}
    if S.PlayerESP then
        for _, pl in ipairs(Players:GetPlayers()) do
            local ch = pl ~= lp and pl.Character
            local root = ch and ch:FindFirstChild("HumanoidRootPart")
            if root then
                want[ch] = true
                ensureEsp(ch, "player", PLAYER_COL, root).label.Text = ("%s [%dm]"):format(pl.DisplayName, dist(root.Position) / 3.2)
            end
        end
    end
    if S.ScooterESP then
        local mine = ride()
        mine = mine and mine.model
        local rides = Workspace:FindFirstChild("Rides")
        for _, m in ipairs(rides and rides:GetChildren() or {}) do
            local root = m:IsA("Model") and m ~= mine and (m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart"))
            if root then
                want[m] = true
                ensureEsp(m, "scooter", SCOOTER_COL, root).label.Text = ("%s [%dm]"):format(m.Name, dist(root.Position) / 3.2)
            end
        end
    end
    for model in pairs(esp) do
        if not want[model] or not model.Parent then dropEsp(model) end
    end
end

-- tracers: Drawing lines from the bottom of the screen to each player (needs the executor's Drawing library)
local hasDrawing = type(Drawing) == "table" and Drawing.new ~= nil
local lines = {}   -- [player] = Line
local function hideLines() for _, l in pairs(lines) do l.Visible = false end end
local function stepTracers()
    local c = cam()
    if not (S.Tracers and hasDrawing and c) then hideLines() return end
    local vp = c.ViewportSize
    local from = Vector2.new(vp.X / 2, vp.Y)
    for pl, l in pairs(lines) do
        if not pl.Parent then l:Remove() lines[pl] = nil end
    end
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= lp then
            local root = pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
            local l = lines[pl]
            if not l then l = Drawing.new("Line") l.Thickness = 1.5 l.Color = PLAYER_COL lines[pl] = l end
            local pos, onScreen = nil, false
            if root then pos, onScreen = c:WorldToViewportPoint(root.Position) end
            l.Visible = onScreen and pos.Z > 0
            if l.Visible then l.From = from l.To = Vector2.new(pos.X, pos.Y) end
        end
    end
end

-- fullbright: the game runs its own day/night, so hold the values every frame and put the originals back when off
local fbSaved
local function stepFullbright()
    if not S.Fullbright then
        if fbSaved then
            for k, v in pairs(fbSaved.light) do Lighting[k] = v end
            for atm, d in pairs(fbSaved.atmos) do if atm.Parent then atm.Density = d end end
            fbSaved = nil
        end
        return
    end
    if not fbSaved then
        fbSaved = { light = {}, atmos = {} }
        for _, k in ipairs({ "Brightness", "ClockTime", "FogEnd", "GlobalShadows", "Ambient", "OutdoorAmbient" }) do fbSaved.light[k] = Lighting[k] end
    end
    Lighting.Brightness = 2 Lighting.ClockTime = 14 Lighting.FogEnd = 1e9 Lighting.GlobalShadows = false
    Lighting.Ambient = Color3.new(1, 1, 1) Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
    for _, a in ipairs(Lighting:GetChildren()) do
        if a:IsA("Atmosphere") then
            if fbSaved.atmos[a] == nil then fbSaved.atmos[a] = a.Density end
            a.Density = 0
        end
    end
end

-- ---------- player: walk speed, jump, infinite jump, noclip, fly ----------
-- The ride drives you while mounted, so these only apply on foot (fly / noclip / speed are left alone on the ride).
local moveSaved       -- { hum, walk, usePower, jumpPower, jumpHeight }
local function restoreMove()
    local m = moveSaved
    moveSaved = nil
    if m and m.hum.Parent then
        m.hum.WalkSpeed = m.walk m.hum.JumpPower = m.jumpPower m.hum.JumpHeight = m.jumpHeight
    end
end
local function stepMove(hum)
    local want = S.WalkSpeedOn or S.JumpOn
    if want and (not moveSaved or moveSaved.hum ~= hum) then
        moveSaved = { hum = hum, walk = hum.WalkSpeed, jumpPower = hum.JumpPower, jumpHeight = hum.JumpHeight }
    end
    if not want then restoreMove() return end
    if S.WalkSpeedOn then hum.WalkSpeed = S.WalkSpeed else hum.WalkSpeed = moveSaved.walk end
    if S.JumpOn then
        if hum.UseJumpPower then hum.JumpPower = moveSaved.jumpPower * S.JumpMult
        else hum.JumpHeight = moveSaved.jumpHeight * S.JumpMult end
    end
end

local ncSaved = {}   -- [part] = original CanCollide
local function restoreNoclip()
    for part, was in pairs(ncSaved) do if part.Parent then part.CanCollide = was end end
    table.clear(ncSaved)
end
local function stepNoclip(char)
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") and d.CanCollide then ncSaved[d] = true d.CanCollide = false end
    end
end

local flying = false
local function stopFly(hum)
    if flying then
        flying = false
        if hum and hum.Parent then hum.PlatformStand = false end
    end
end
local function stepFly(hum, root)
    local c = cam()
    if not c then return end
    flying = true
    hum.PlatformStand = true
    local dir = Vector3.zero
    local look, right = c.CFrame.LookVector, c.CFrame.RightVector
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += look end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= look end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += right end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= right end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
    root.AssemblyLinearVelocity = dir.Magnitude > 0 and dir.Unit * S.FlySpeed or Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local lastEsp = 0
local visualConn = RunService.RenderStepped:Connect(function()
    stepFullbright()
    stepTracers()
    if os.clock() - lastEsp > 0.4 then
        lastEsp = os.clock()
        pcall(refreshEsp)
    end
end)
local moveConn = RunService.Stepped:Connect(function()
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and root and hum.Health > 0) then return end
    local onRide = ride() ~= nil
    stepMove(hum)
    if S.Noclip and not onRide then stepNoclip(char) elseif next(ncSaved) then restoreNoclip() end
    if S.Fly and not onRide then stepFly(hum, root) else stopFly(hum) end
end)
local jumpConn = UserInputService.JumpRequest:Connect(function()
    if not S.InfJump then return end
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

local VirtualUser = game:GetService("VirtualUser")
local idleConn = lp.Idled:Connect(function()
    if S.AntiAFK then pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end) end
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
gui.Name = "CookiesHubScooterGang" gui.ResetOnSpawn = false gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
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
    title.TextXAlignment = Enum.TextXAlignment.Left title.Text = "Cookies Hub  -  Scooter Gang" title.Parent = bar
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

local ui = { tabs = {}, tabBtns = {}, renders = {}, conns = {} }   -- conns: UserInputService hooks, cut on Unload
local TAB_NAMES = { "Farm", "Scooter", "Travel", "Visual", "Player", "Rewards", "Info" }
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
    b.MouseButton1Click:Connect(function() task.spawn(pcall, fn) end)
    return b
end
-- a draggable slider bound to a number setting
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
        local v = min + (max - min) * a
        v = math.floor(v / step + 0.5) * step
        S[key] = math.clamp(v, min, max) render()
    end
    track.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true setFrom(i.Position.X)
        end
    end)
    ui.conns[#ui.conns + 1] = UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then setFrom(i.Position.X) end
    end)
    ui.conns[#ui.conns + 1] = UserInputService.InputEnded:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
            dragging = false saveSettings()
        end
    end)
    render()
    ui.renders[key] = render
end
-- a text box + button
function ui.input(parent, placeholder, buttonText, fn)
    local row = Instance.new("Frame") row.Size = UDim2.new(1, 0, 0, 34) row.BackgroundColor3 = C.row row.BorderSizePixel = 0 row.Parent = parent corner(row, 6)
    local box = Instance.new("TextBox") box.Size = UDim2.new(1, -110, 0, 24) box.Position = UDim2.fromOffset(8, 5)
    box.BackgroundColor3 = C.bg box.PlaceholderText = placeholder box.Text = "" box.ClearTextOnFocus = false
    box.Font = Enum.Font.GothamMedium box.TextSize = 13 box.TextColor3 = C.text box.PlaceholderColor3 = C.text2
    box.BorderSizePixel = 0 box.Parent = row corner(box, 6)
    local b = Instance.new("TextButton") b.Size = UDim2.fromOffset(90, 24) b.Position = UDim2.new(1, -98, 0, 5)
    b.BackgroundColor3 = C.accent2 b.Text = buttonText b.Font = Enum.Font.GothamMedium b.TextSize = 12 b.TextColor3 = C.text
    b.BorderSizePixel = 0 b.Parent = row corner(b, 6)
    b.MouseButton1Click:Connect(function() task.spawn(pcall, fn, box.Text, b) end)
    return box, b
end

for _, n in ipairs(TAB_NAMES) do ui.tab(n) end

do -- Farm
    local p = ui.tabs.Farm
    ui.sec(p, "Pizza deliveries")
    ui.toggle(p, "Auto deliver (rides orders for you)", "AutoDeliver")
    ui.slider(p, "Speed (% of your ride's top speed)", "SpeedPct", 30, 110, 5, "%d%%")
    ui.toggle(p, "Respawn ride if you fall off", "AutoRemount")
    ui.toggle(p, "Don't report offences to the police", "BlockPolice", applyPolice)
    ui.toggle(p, "Safe stop (pause when chased, stop if you keep falling)", "SafeStop")
    ui.note(p, "Rides to the Pizza Place, starts a job, then glides your ride to each pickup / customer. Pay goes up with speed and your streak. The server allows up to about 115% of your ride's top speed; 95% is safe. A faster ride = faster deliveries.")
    ui.sec(p, "Progress")
    ui.toggle(p, "Auto buy the next ride when you can afford it", "AutoBuyRide")
    ui.ride = ui.note(p, "-")
    ui.sec(p, "Stats")
    ui.stats = ui.note(p, "-")
end
do -- Scooter
    local p = ui.tabs.Scooter
    ui.sec(p, "Riding")
    ui.toggle(p, "Speed boost", "SpeedBoost")
    ui.slider(p, "Boost", "BoostMult", 1, 3, 0.05, "%.2fx")
    ui.note(p, "Raises your ride's top speed, power and acceleration (1.5x took a 71 km/h G4 to 107 km/h). The server didn't pull it back in testing, but it checks speed on deliveries and riding pay, so high boosts are a risk.")
    ui.toggle(p, "Wheelie limiter (caps the wheelie angle)", "WheelieLimit")
    ui.slider(p, "Max wheelie angle", "WheelieAngle", 10, 70, 1, "%d deg")
    ui.note(p, "You keep full control: hold gas and Shift / Ctrl yourself. The limiter never touches your inputs, it just stops the nose from rising past the angle so you can't loop out. Wheelies pay cash in this game.")
    ui.toggle(p, "No crash (never fall off the scooter)", "NoCrash")
    ui.button(p, "Unstuck / flip upright (the game's reset)", C.accent2, unstuck)
    ui.sec(p, "Scooter fly")
    ui.toggle(p, "Fly with your scooter", "ScooterFly")
    ui.slider(p, "Scooter fly speed", "ScooterFlySpeed", 20, 400, 5, "%d")
    ui.note(p, "WASD along the camera, Space up, Ctrl down. Passes through buildings. Above ~700 the server treats it as a teleport.")
    ui.toggle(p, "Scooter noclip (drive through walls and buildings)", "ScooterNoclip")
    ui.note(p, "These pause while Auto deliver is on (the farm drives the ride), and none of them work while the game's Dealership or Garage menu is open.")
    ui.sec(p, "Your rides")
    local rideBtns = {}
    local function rebuildRides()
        for _, b in ipairs(rideBtns) do b:Destroy() end
        table.clear(rideBtns)
        for _, id in ipairs(ownedRides()) do
            rideBtns[#rideBtns + 1] = ui.button(p, id, C.row, function() switchRide(id) end)
        end
    end
    ui.button(p, "Refresh my rides", C.accent2, rebuildRides)
    ui.note(p, "Click a ride to equip it and put it under you.")
    rebuildRides()
end
do -- Travel
    local p = ui.tabs.Travel
    ui.sec(p, "Teleport")
    ui.note(p, "Uses the game's own map teleport. It refuses during a delivery or a police chase, and puts you back on your ride afterwards.")
    local tpBtns = {}
    local function rebuildTp()
        for _, b in ipairs(tpBtns) do b:Destroy() end
        table.clear(tpBtns)
        for _, pt in ipairs(mapPoints()) do
            local b
            b = ui.button(p, tostring(pt.name or pt.id), C.row, function()
                local ok, why = teleportTo(pt.id)
                if not ok then
                    b.Text = tostring(why)
                    task.delay(2.5, function() if b.Parent then b.Text = tostring(pt.name or pt.id) end end)
                end
            end)
            tpBtns[#tpBtns + 1] = b
        end
    end
    ui.button(p, "Refresh teleport list", C.accent2, rebuildTp)
    rebuildTp()
end
do -- Visual
    local p = ui.tabs.Visual
    ui.sec(p, "ESP")
    ui.toggle(p, "Player ESP (outline + name + distance)", "PlayerESP")
    ui.toggle(p, "Tracers (lines to every player)", "Tracers")
    ui.toggle(p, "Scooter ESP (other riders' scooters)", "ScooterESP")
    ui.note(p, hasDrawing and "Distances are in metres." or "Tracers need an executor with the Drawing library - yours doesn't have it, so they stay off. Distances are in metres.")
    ui.sec(p, "World")
    ui.toggle(p, "Fullbright (no night, fog or shadows)", "Fullbright")
end
do -- Player
    local p = ui.tabs.Player
    ui.sec(p, "Movement")
    ui.toggle(p, "Infinite jump", "InfJump")
    ui.toggle(p, "Walk speed", "WalkSpeedOn")
    ui.slider(p, "Walk speed", "WalkSpeed", 16, 200, 1, "%d")
    ui.toggle(p, "Jump multiplier", "JumpOn")
    ui.slider(p, "Jump multiplier", "JumpMult", 1, 10, 0.25, "%.2fx")
    ui.toggle(p, "Noclip", "Noclip")
    ui.toggle(p, "Fly", "Fly")
    ui.slider(p, "Fly speed", "FlySpeed", 10, 300, 5, "%d")
    ui.note(p, "Fly: WASD to move, Space up, Ctrl down. These apply on foot - while you're riding a scooter, the scooter drives you, so they pause until you get off.")
    ui.sec(p, "Hotkeys")
    ui.note(p, "G: auto deliver on/off   F: fly   V: noclip   (ignored while typing in chat)")
end
do -- Rewards
    local p = ui.tabs.Rewards
    ui.sec(p, "Auto claim")
    ui.toggle(p, "Daily reward", "AutoDaily")
    ui.toggle(p, "Free ride (group reward)", "AutoFreeRide")
    ui.note(p, "Checked every minute. Daily and weekly quests are claimed by the game automatically.")
    ui.sec(p, "Codes")
    local signBtn
    signBtn = ui.button(p, "Redeem the codes on the map's code signs", nil, function()
        local list = signCodes()
        if #list == 0 then signBtn.Text = "No codes found (get closer to a sign)" end
        local good = 0
        for _, code in ipairs(list) do
            if redeem(code) then good = good + 1 end
            task.wait(0.5)
        end
        if #list > 0 then signBtn.Text = ("Tried %d code(s), %d redeemed"):format(#list, good) end
        task.delay(3, function() if signBtn.Parent then signBtn.Text = "Redeem the codes on the map's code signs" end end)
    end)
    ui.input(p, "type a code", "Redeem", function(code, btn)
        code = (code or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if code == "" then return end
        local ok, why = redeem(code)
        btn.Text = ok and "Redeemed!" or "Failed"
        if not ok then warn("[CookiesHub ScooterGang] code " .. code .. ": " .. tostring(why)) end
        task.delay(2, function() if btn.Parent then btn.Text = "Redeem" end end)
    end)
    ui.sec(p, "Misc")
    ui.toggle(p, "Anti-AFK", "AntiAFK")
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
    ui.sec(p, "How it works")
    ui.note(p, "Turn on Auto deliver and leave it running: the pizza job is the best money in the game. Everything goes through the game's own client services, so the server pays you like a normal delivery.")
    ui.sec(p, "Keys")
    ui.note(p, "RightShift shows/hides the hub. X unloads it.")
    ui.sec(p, "Unload")
    ui.button(p, "Unload Cookies Hub (turns everything off)", C.danger, function()
        if _G.CookiesHubScooterGang then _G.CookiesHubScooterGang.Unload() end
    end)
end
ui.select("Farm")

-- live readouts
task.spawn(function()
    while alive do
        pcall(function()
            local st = deliveryState() or {}
            if not st.active then stats.streak = 0 elseif (st.streak or 0) > 0 then stats.streak = st.streak end   -- 0 between orders
            local earned = cash() - stats.startCash
            local hours = math.max((os.clock() - stats.startedAt) / 3600, 1 / 3600)
            ui.stats.Text = ("Cash: %s   (+%s this session, %s/h)\nDeliveries: %d   Streak: %s   Stage: %s\n%s"):format(
                short(cash()), short(earned), short(earned / hours), stats.delivered, tostring(stats.streak or 0),
                st.active and tostring(st.stage or "next order...") or "no job", stats.msg)
            -- income watch: compare the last 2 minutes with the session so far
            local now = os.clock()
            local hist = stats.hist
            hist[#hist + 1] = { now, cash() }
            while hist[1] and now - hist[1][1] > 125 do table.remove(hist, 1) end
            if S.AutoDeliver and now - stats.startedAt > 240 and #hist > 100 then
                local recent = (cash() - hist[1][2]) / (now - hist[1][1])
                local overall = earned / (now - stats.startedAt)
                if overall > 0 and recent < overall * 0.25 then stats.msg = "WARNING: income dropped - check the farm" end
            end
            local id, price = lp:GetAttribute("NextRide"), lp:GetAttribute("NextRidePrice")
            ui.ride.Text = id and ("Next ride: %s  -  $%s"):format(tostring(id), short(price)) or "Next ride: all bought"
        end)
        task.wait(1)
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
    ui.conns[#ui.conns + 1] = UserInputService.InputChanged:Connect(function(i)
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
    alive = false
    if inputConn then inputConn:Disconnect() end
    for _, c in ipairs(ui.conns) do c:Disconnect() end
    farmConn:Disconnect()
    scooterConn:Disconnect()
    unboost() releaseInputs()
    crashOff.fly = false crashOff.noclip = false
    S.NoCrash = false   -- not saved; just lets releaseRide below put the crash checks back
    idleConn:Disconnect()
    visualConn:Disconnect() moveConn:Disconnect() jumpConn:Disconnect()
    S.Fullbright = false stepFullbright()
    for model in pairs(esp) do dropEsp(model) end
    for _, l in pairs(lines) do pcall(function() l:Remove() end) end
    restoreMove() restoreNoclip()
    do
        local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
        stopFly(hum)
    end
    pcall(function() espGui:Destroy() end)
    pcall(function() deliveredConn:Disconnect() messageConn:Disconnect() end)
    releaseRide()
    S.BlockPolice = false applyPolice()   -- put the game's reporters back (not saved)
    pcall(function() gui:Destroy() end)
    _G.CookiesHubScooterGang = nil
end
closeBtn.MouseButton1Click:Connect(Unload)
inputConn = UserInputService.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == S.ToggleKey then main.Visible = not main.Visible end
    local hotkey = ({ [Enum.KeyCode.G] = "AutoDeliver", [Enum.KeyCode.F] = "Fly", [Enum.KeyCode.V] = "Noclip" })[i.KeyCode]
    if hotkey then _G.CookiesHubScooterGang.Set(hotkey, not S[hotkey]) end
end)

_G.CookiesHubScooterGang = {
    Unload = Unload, State = S,
    Set = function(k, v)
        if S[k] == nil then return end
        S[k] = v saveSettings()
        if k == "BlockPolice" then applyPolice() end
        if ui.renders[k] then ui.renders[k]() end
    end,
    Get = function(k) return S[k] end,
}
print("[CookiesHub] Scooter Gang loaded.")

-- Cookies Hub (Airsoft Battles)  [KEYLESS]
-- RightShift: show/hide | X button or _G.CookiesHubAirsoft.Unload(): unload
-- Console: _G.CookiesHubAirsoft.Set("Aimbot", true)
--
-- Read from [NEW GUNS] Airsoft Battles (place 16261605398):
--  * Teams: Player attr Team ("Red"/"Blue"); once deployed the character gets attrs Team, Deployed, Protected
--    (spawn protection). Lobby characters have no Team attr. The game's own auto-shoot compares character Team attrs.
--  * Bots: workspace.FPlayers.<Model> with attrs IsBot, Team, Deployed, Protected + a Humanoid.
--  * Guns are ACS: <char>.ACS_Client.ACS_Framework. getsenv(fw).Shoot upvalues: [1] = gun settings table
--    (require(tool.ACS_Settings): camRecoil, gunRecoil, MinSpread, MaxSpread, Ammo, ShootRate, ShootType, Jammed...),
--    [6] = rounds in the magazine (the game only counts them client-side; 0 -> Reload()).
--  * Hits are found on the client (Projectile.BulletHitDetector) and sent with Events.Damage:InvokeServer;
--    parts named Head / HitboxHead count as headshots, so a bigger head on your screen = easier headshots.
-- Save this file as UTF-8 WITHOUT a BOM or it won't load.

if _G.CookiesHubAirsoft and _G.CookiesHubAirsoft.Unload then pcall(_G.CookiesHubAirsoft.Unload) end

local Players          = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")
local lp               = Players.LocalPlayer

-- ---------- guard ----------
if not game:IsLoaded() then game.Loaded:Wait() end
if not (RS:WaitForChild("ACS_Engine", 15) and Workspace:FindFirstChild("FPlayers")) then
    warn("[CookiesHub Airsoft] Not Airsoft Battles (missing ReplicatedStorage.ACS_Engine / workspace.FPlayers). Aborting.")
    return
end
local alive = true   -- cleared on Unload so every loop exits

-- ---------- settings (per account) ----------
local S = {
    -- aim
    Aimbot        = false,
    AimKey        = "Right mouse",   -- Right mouse | Left mouse | Always
    AimPart       = "Head",          -- Head | Torso | Closest (body part nearest the crosshair)
    TargetPriority = "Crosshair",    -- Crosshair | Distance | Health (all inside the FOV circle)
    DropComp      = 0,               -- bullet drop lift, gravity in studs/s^2 (0 = off)
    TargetInfo    = true,            -- line + name/HP readout for the locked target
    AimbotToggleKey = "None",        -- keyboard key that flips Aimbot on/off
    SilentToggleKey = "None",        -- keyboard key that flips Silent aim on/off
    AutoShoot     = false,           -- fire whenever silent aim has a target
    AimMode       = "Camera",        -- Camera (feeds the turn into the game's own camera) | Mouse (moves your mouse)
    AimFOV        = 150,             -- pixels from the crosshair
    ShowFOV       = true,
    Smoothness    = 0.5,             -- 0 = snap, higher = slower
    Prediction    = true,            -- lead moving targets by bullet travel time
    WallCheck     = true,
    TeamCheck     = true,
    TargetBots    = true,
    TargetPlayers = true,
    IgnoreProtected = true,          -- skip spawn-protected targets
    TriggerBot    = false,
    TriggerDelay  = 0.05,
    SilentAim     = false,           -- bullets curve to the target, your camera doesn't move
    SilentHitChance = 100,
    -- visuals
    ESP           = false,
    ESPBoxes      = true,
    BoxStyle      = "Corners",       -- Corners | Full
    ESPNames      = true,
    ESPHealth     = true,
    ESPDistance   = true,
    ESPWeapon     = true,
    Skeleton      = false,
    Arrows        = true,            -- arrows at the screen edge for enemies you can't see on screen
    VisibleColors = true,            -- enemies in your line of sight turn green
    ESPMaxDistance = 1500,
    ESPTextSize   = 13,
    Tracers       = false,
    TracerFrom    = "Bottom",        -- Bottom | Center | Mouse
    Chams         = false,
    ChamsFill     = 0.5,
    ESPTeamCheck  = true,            -- only enemies
    ESPBots       = true,
    SpawnTag      = true,            -- "[SPAWN]" next to spawn-protected names
    Radar         = false,
    RadarRange    = 250,
    RadarSize     = 180,
    BulletTracers = false,           -- draw where your shots went
    FullBright    = false,
    NoFog         = false,
    -- player
    WalkSpeedOn   = false,
    WalkSpeed     = 24,
    JumpOn        = false,
    JumpPower     = 60,
    Noclip        = false,
    AntiAFK       = true,
    AutoRedeploy  = false,
    -- hitbox
    Hitbox        = false,
    HitboxPart    = "Head",          -- Head | Torso
    HitboxSize    = 6,
    HitboxVisible = true,
    -- gun
    NoRecoil      = false,
    NoSpread      = false,
    NoReload      = false,
    RapidFire     = false,
    FireRateMult  = 1.5,
    FullAuto      = false,
    -- camera
    FOVChanger    = false,
    FOV           = 90,
    KeepADSZoom   = true,
    ToggleKey     = Enum.KeyCode.RightShift,
}
local SETTINGS_FILE = ("CookiesHubAirsoft_%d_settings.json"):format(lp.UserId)
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

local COLORS = {
    enemy = Color3.fromRGB(255, 80, 80), team = Color3.fromRGB(80, 170, 255), bot = Color3.fromRGB(255, 165, 60),
    fov = Color3.fromRGB(171, 113, 235), white = Color3.new(1, 1, 1), hpBack = Color3.fromRGB(20, 20, 20),
    visible = Color3.fromRGB(90, 255, 120), outline = Color3.new(0, 0, 0), info = Color3.fromRGB(220, 220, 230),
}

-- ---------- targets ----------
local function camera() return Workspace.CurrentCamera end
local function myChar() return lp.Character end
local function myTeam()
    local c = myChar()
    return (c and c:GetAttribute("Team")) or lp:GetAttribute("Team")
end
local function humanoidOf(m)
    local h = m and m:FindFirstChildOfClass("Humanoid")
    if h and h.Health > 0 then return h end
end
-- everyone in the match (players + bots), deployed and alive
local function getTargets()
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        local c = p ~= lp and p.Character
        if c and c:GetAttribute("Team") ~= nil and c:GetAttribute("Deployed") ~= false then
            local h, root = humanoidOf(c), c:FindFirstChild("HumanoidRootPart")
            if h and root then
                list[#list + 1] = { model = c, hum = h, root = root, team = c:GetAttribute("Team"), name = p.DisplayName, bot = false }
            end
        end
    end
    for _, m in ipairs(Workspace.FPlayers:GetChildren()) do
        if m:IsA("Model") and m:GetAttribute("Deployed") ~= false then
            local h, root = humanoidOf(m), m:FindFirstChild("HumanoidRootPart")
            if h and root then
                list[#list + 1] = { model = m, hum = h, root = root, team = m:GetAttribute("Team"), name = m.Name .. " [BOT]", bot = true }
            end
        end
    end
    return list
end
local function isEnemy(t, teamCheck)
    if not teamCheck then return true end
    local mine = myTeam()
    return t.team == nil or mine == nil or t.team ~= mine
end
local function isProtected(t)
    return t.model:GetAttribute("Protected") == true or t.model:FindFirstChildOfClass("ForceField") ~= nil
end
local function aimPartOf(t, which)
    local m = t.model
    if which == "Torso" then return m:FindFirstChild("UpperTorso") or m:FindFirstChild("Torso") or t.root end
    if which == "Closest" then   -- the body part nearest the crosshair
        local cam = camera()
        local mouse = UserInputService:GetMouseLocation()
        local best, bd
        for _, n in ipairs({ "Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg" }) do
            local p = m:FindFirstChild(n)
            if p then
                local sp, on = cam:WorldToViewportPoint(p.Position)
                local d = on and sp.Z > 0 and (Vector2.new(sp.X, sp.Y) - mouse).Magnitude
                if d and (not bd or d < bd) then best, bd = p, d end
            end
        end
        if best then return best end
    end
    return m:FindFirstChild("Head") or t.root
end

-- ---------- wall check ----------
-- Same rules as the game's bullets (BulletHitDetector.canRayPierce): they fly through parts with CanCollide off and
-- through tools / accessories; anything else that can collide stops them - glass and invisible walls included.
-- Each line is cast twice: in the default collision group, and in "CamCast", the group the game's own gun code uses
-- to find map walls (some map walls don't show up for a plain ray). Blocked in either = behind a wall.
local function mapHelpers()
    local list = {}
    local map = Workspace:FindFirstChild("CurrentMap")
    for _, n in ipairs({ "Pathfinding", "MapSides", "CameraPositions", "Objectives" }) do
        local f = map and map:FindFirstChild(n)
        if f then list[#list + 1] = f end
    end
    return list
end
-- the character model a part belongs to (hitbox parts sit in folders inside the character)
local function characterOf(inst)
    local a = inst.Parent
    while a and a ~= Workspace do
        if a:IsA("Model") and a:FindFirstChildOfClass("Humanoid") then return a end
        a = a.Parent
    end
end
local function bulletPasses(inst)
    if inst == Workspace.Terrain then return false end
    local p = inst.Parent
    return not inst.CanCollide or (p and (p:IsA("Tool") or p:IsA("Accessory")))
end
-- first thing along origin -> origin + dir that a bullet would stop at: returns (hit, characterModel or nil).
-- skipChars = true walks through characters (for "is there a WALL in the way").
local function castBullet(origin, dir, ignore, group, skipChars)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.IgnoreWater = true
    params.FilterDescendantsInstances = ignore
    if group and not pcall(function() params.CollisionGroup = group end) then return nil end
    for _ = 1, 12 do
        local hit = Workspace:Raycast(origin, dir, params)
        if not hit then return nil end
        local inst = hit.Instance
        local char = characterOf(inst)
        if char then
            if not skipChars then return hit, char end
            params:AddToFilter(char)
        elseif bulletPasses(inst) then
            params:AddToFilter(inst)
        else
            return hit, nil
        end
    end
    return nil
end
local GROUPS = { false, "CamCast" }
local function wallBetween(origin, finish, ignore)
    local dir = finish - origin
    for _, g in ipairs(GROUPS) do
        local hit = castBullet(origin, dir, ignore, g or nil, true)
        if hit then return true end
    end
    return false
end
-- visible = no wall between the camera and the part. Cached for a moment: the aimbot, silent aim, trigger bot and
-- ESP all ask about the same parts every frame.
local visCache = setmetatable({}, { __mode = "k" })
local function visible(part, target)
    local now = os.clock()
    local c = visCache[part]
    if c and now - c.t < 0.03 then return c.v end
    local cam = camera()
    local ignore = mapHelpers()
    ignore[#ignore + 1] = myChar()
    ignore[#ignore + 1] = cam
    ignore[#ignore + 1] = target.model
    local v = not wallBetween(cam.CFrame.Position, part.Position, ignore)
    visCache[part] = { t = now, v = v }
    return v
end

-- ---------- gun (ACS framework) ----------
local fwCache = {}
local function shootFn()
    local c = myChar()
    local client = c and c:FindFirstChild("ACS_Client")
    local fw = client and client:FindFirstChild("ACS_Framework")
    if not fw then return end
    if fwCache.script ~= fw then
        local ok, env = pcall(getsenv, fw)
        fwCache = { script = fw, shoot = ok and type(env) == "table" and type(env.Shoot) == "function" and env.Shoot or nil }
    end
    return fwCache.shoot
end
local function gunSettings()
    local shoot = shootFn()
    if not shoot then return end
    local ok, v = pcall(debug.getupvalue, shoot, 1)
    if ok and type(v) == "table" and v.Ammo then return v, shoot end
end

local ZERO_CAM = { camRecoilUp = { 0, 0 }, camRecoilTilt = { 0, 0 }, camRecoilLeft = { 0, 0 }, camRecoilRight = { 0, 0 } }
local ZERO_GUN = { gunRecoilUp = { 0, 0 }, gunRecoilTilt = { 0, 0 }, gunRecoilLeft = { 0, 0 }, gunRecoilRight = { 0, 0 } }
local SPREAD_KEYS = { "MinSpread", "MaxSpread", "AimInaccuracyStepAmount", "WalkMult" }
local originals = {}   -- [settings table] = { camRecoil, gunRecoil, shootRate, shootType, spread = {...} }
local function patchGun(g)
    local o = originals[g]
    if not o then
        o = { camRecoil = g.camRecoil, gunRecoil = g.gunRecoil, shootRate = g.ShootRate, shootType = g.ShootType, spread = {} }
        for _, k in ipairs(SPREAD_KEYS) do o.spread[k] = g[k] end
        originals[g] = o
    end
    -- rapid fire scales the gun's rpm; full auto turns semi/burst (ShootType 1/2) into auto (3).
    -- Pump/bolt guns (4/5) are left alone, they need their cycle animation.
    if tonumber(o.shootRate) then g.ShootRate = S.RapidFire and o.shootRate * S.FireRateMult or o.shootRate end
    if g.Type == "Gun" and (o.shootType == 1 or o.shootType == 2) then g.ShootType = S.FullAuto and 3 or o.shootType end
    if S.NoRecoil then
        g.camRecoil, g.gunRecoil = ZERO_CAM, ZERO_GUN
    else
        g.camRecoil, g.gunRecoil = o.camRecoil, o.gunRecoil
    end
    for _, k in ipairs(SPREAD_KEYS) do
        if o.spread[k] ~= nil then g[k] = S.NoSpread and 0 or o.spread[k] end
    end
end
local function restoreGuns()
    for g, o in pairs(originals) do
        g.camRecoil, g.gunRecoil = o.camRecoil, o.gunRecoil
        g.ShootRate, g.ShootType = o.shootRate, o.shootType
        for k, v in pairs(o.spread) do g[k] = v end
    end
    originals = {}
end
local gunConn = RunService.Heartbeat:Connect(function()
    if not (S.NoRecoil or S.NoSpread or S.NoReload or S.RapidFire or S.FullAuto or next(originals)) then return end
    pcall(function()
        local g, shoot = gunSettings()
        if not g then return end
        patchGun(g)
        if S.NoReload and g.Type == "Gun" then
            -- keep the magazine full so Reload() never runs
            local okA, rounds = pcall(debug.getupvalue, shoot, 6)
            if okA and type(rounds) == "number" and rounds < g.Ammo then debug.setupvalue(shoot, 6, g.Ammo) end
            g.Jammed = false
        end
    end)
end)

-- ---------- hitbox ----------
local HITBOX_PARTS = { Head = { "Head", "HitboxHead" }, Torso = { "UpperTorso", "HitboxUpperTorso" } }
local resized = {}   -- [part] = { size, transparency, canCollide, massless }
local function restorePart(p)
    local o = resized[p]
    if o and p.Parent then
        p.Size, p.Transparency, p.CanCollide, p.Massless = o.size, o.transparency, o.canCollide, o.massless
    end
    resized[p] = nil
end
local function updateHitboxes(targets)
    local keep = {}
    if S.Hitbox then
        local n = S.HitboxSize
        for _, t in ipairs(targets) do
            if isEnemy(t, true) and (t.bot and S.TargetBots or not t.bot and S.TargetPlayers) then
                for _, name in ipairs(HITBOX_PARTS[S.HitboxPart] or HITBOX_PARTS.Head) do
                    local p = t.model:FindFirstChild(name, true)
                    if p and p:IsA("BasePart") then
                        if not resized[p] then
                            resized[p] = { size = p.Size, transparency = p.Transparency, canCollide = p.CanCollide, massless = p.Massless }
                        end
                        keep[p] = true
                        p.Size = Vector3.new(n, n, n)
                        p.CanCollide = false p.Massless = true
                        p.Transparency = S.HitboxVisible and 0.7 or resized[p].transparency
                    end
                end
            end
        end
    end
    for p in pairs(resized) do if not keep[p] then restorePart(p) end end
end

-- ---------- ESP (Drawing) + chams (Highlight) ----------
local hasDrawing = typeof(Drawing) == "table" and Drawing.new ~= nil
local chamFolder = Instance.new("Folder")
chamFolder.Name = "CookiesHubAirsoftChams"
pcall(function() chamFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not chamFolder.Parent then chamFolder.Parent = lp:WaitForChild("PlayerGui") end

local function newDraw(kind, props)
    local d = Drawing.new(kind)
    for k, v in pairs(props) do d[k] = v end
    return d
end
-- R15 bones for the skeleton
local BONES = {
    { "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
    { "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
    { "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
    { "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}
local esp = {}   -- [model] = { d = {all drawings}, box/boxOut, corners/cornersOut, name, info, hpOut, hp, hpText, tracer/tracerOut, bones, arrow, cham, vis, visAt }
local function dropEsp(m)
    local e = esp[m]
    if not e then return end
    for _, d in ipairs(e.d) do pcall(function() d:Remove() end) end
    if e.cham then e.cham:Destroy() end
    esp[m] = nil
end
local function getEsp(m)
    local e = esp[m]
    if e then return e end
    e = { d = {}, corners = {}, cornersOut = {}, bones = {} }
    if hasDrawing then
        local function add(kind, props)
            props.Visible = false
            local d = newDraw(kind, props)
            e.d[#e.d + 1] = d
            return d
        end
        -- outlines first so they draw underneath
        e.tracerOut = add("Line", { Thickness = 3, Color = COLORS.outline, Transparency = 0.6 })
        e.tracer = add("Line", { Thickness = 1.2 })
        e.boxOut = add("Square", { Thickness = 3.5, Filled = false, Color = COLORS.outline })
        e.box = add("Square", { Thickness = 1.5, Filled = false })
        for i = 1, 8 do e.cornersOut[i] = add("Line", { Thickness = 3.5, Color = COLORS.outline }) end
        for i = 1, 8 do e.corners[i] = add("Line", { Thickness = 1.5 }) end
        for i = 1, #BONES do e.bones[i] = add("Line", { Thickness = 1.3 }) end
        e.hpOut = add("Square", { Filled = true, Color = COLORS.hpBack })
        e.hp = add("Square", { Filled = true })
        e.hpText = add("Text", { Center = false, Outline = true, Font = 2, Color = COLORS.white })
        e.name = add("Text", { Center = true, Outline = true, Font = 2 })
        e.info = add("Text", { Center = true, Outline = true, Font = 2, Color = COLORS.info })
        e.arrow = add("Triangle", { Filled = true, Thickness = 1 })
    end
    esp[m] = e
    return e
end
local function hideEsp(e)
    for _, d in ipairs(e.d) do d.Visible = false end
    if e.cham then e.cham.Enabled = false end
end
local function setLine(l, a, b, color)
    l.From = a l.To = b l.Visible = true
    if color then l.Color = color end
end
local fovCircle = hasDrawing and newDraw("Circle", { Thickness = 1.5, NumSides = 64, Filled = false, Color = COLORS.fov, Visible = false }) or nil
local targetLine = hasDrawing and newDraw("Line", { Thickness = 1.5, Color = COLORS.fov, Visible = false }) or nil
local targetText = hasDrawing and newDraw("Text", { Size = 16, Center = true, Outline = true, Font = 2, Color = COLORS.white, Visible = false }) or nil

local function drawEsp(e, t, color, dist, cam, vp, mouse)
    local d = e.d
    for i = 1, #d do d[i].Visible = false end
    if not S.ESP and not S.Tracers then return end
    local head = t.model:FindFirstChild("Head")
    -- box from head top to feet, width from the character's real width as seen from the camera
    local topW = (head and head.Position or t.root.Position + Vector3.new(0, 1.5, 0)) + Vector3.new(0, 0.75, 0)
    local lf, rf = t.model:FindFirstChild("LeftFoot"), t.model:FindFirstChild("RightFoot")
    local footY = (lf and rf) and math.min(lf.Position.Y, rf.Position.Y) - 0.4 or t.root.Position.Y - 3
    local botW = Vector3.new(t.root.Position.X, footY, t.root.Position.Z)
    local top, onT = cam:WorldToViewportPoint(topW)
    local bot, onB = cam:WorldToViewportPoint(botW)
    local onScreen = top.Z > 0 and bot.Z > 0 and (onT or onB)

    if not onScreen then
        -- arrow at the screen edge pointing at them
        if S.ESP and S.Arrows then
            local p = cam:WorldToViewportPoint(t.root.Position)
            local centre = vp / 2
            local dir = Vector2.new(p.X, p.Y) - centre
            if p.Z < 0 then dir = -dir end
            if dir.Magnitude > 1 then
                dir = dir.Unit
                local perp = Vector2.new(-dir.Y, dir.X)
                local tip = centre + dir * (math.min(vp.X, vp.Y) * 0.42)
                e.arrow.PointA = tip
                e.arrow.PointB = tip - dir * 16 + perp * 9
                e.arrow.PointC = tip - dir * 16 - perp * 9
                e.arrow.Color = color e.arrow.Visible = true
            end
        end
        return
    end

    local side = cam:WorldToViewportPoint(t.root.Position + cam.CFrame.RightVector * 1.7)
    local mid = cam:WorldToViewportPoint(t.root.Position)
    local h = math.max(bot.Y - top.Y, 6)
    local w = math.max(math.abs(side.X - mid.X) * 2, h * 0.35)
    local x, y = mid.X - w / 2, top.Y
    local size = S.ESPTextSize

    if S.ESP and S.ESPBoxes then
        if S.BoxStyle == "Full" then
            e.boxOut.Position = Vector2.new(x, y) e.boxOut.Size = Vector2.new(w, h) e.boxOut.Visible = true
            e.box.Position = Vector2.new(x, y) e.box.Size = Vector2.new(w, h) e.box.Color = color e.box.Visible = true
        else
            local cw, ch = w / 4, h / 5
            local pts = {
                { Vector2.new(x, y), Vector2.new(x + cw, y) }, { Vector2.new(x, y), Vector2.new(x, y + ch) },
                { Vector2.new(x + w, y), Vector2.new(x + w - cw, y) }, { Vector2.new(x + w, y), Vector2.new(x + w, y + ch) },
                { Vector2.new(x, y + h), Vector2.new(x + cw, y + h) }, { Vector2.new(x, y + h), Vector2.new(x, y + h - ch) },
                { Vector2.new(x + w, y + h), Vector2.new(x + w - cw, y + h) }, { Vector2.new(x + w, y + h), Vector2.new(x + w, y + h - ch) },
            }
            for i, p in ipairs(pts) do
                setLine(e.cornersOut[i], p[1], p[2])
                setLine(e.corners[i], p[1], p[2], color)
            end
        end
    end
    if S.ESP and S.Skeleton then
        for i, b in ipairs(BONES) do
            local a, c = t.model:FindFirstChild(b[1]), t.model:FindFirstChild(b[2])
            if a and c then
                local pa, oa = cam:WorldToViewportPoint(a.Position)
                local pc, oc = cam:WorldToViewportPoint(c.Position)
                if oa and oc then setLine(e.bones[i], Vector2.new(pa.X, pa.Y), Vector2.new(pc.X, pc.Y), color) end
            end
        end
    end
    if S.ESP and S.ESPHealth then
        local frac = math.clamp(t.hum.Health / math.max(t.hum.MaxHealth, 1), 0, 1)
        local hpColor = Color3.fromHSV(frac * 0.33, 0.85, 1)
        e.hpOut.Position = Vector2.new(x - 7, y - 1) e.hpOut.Size = Vector2.new(4, h + 2) e.hpOut.Visible = true
        e.hp.Position = Vector2.new(x - 6, y + h * (1 - frac)) e.hp.Size = Vector2.new(2, h * frac) e.hp.Color = hpColor e.hp.Visible = true
        if frac < 0.99 then
            e.hpText.Text = tostring(math.floor(t.hum.Health + 0.5)) e.hpText.Size = size - 1
            e.hpText.Position = Vector2.new(x - 9 - e.hpText.TextBounds.X, y + h * (1 - frac) - (size - 1) / 2)
            e.hpText.Visible = true
        end
    end
    if S.ESP and S.ESPNames then
        e.name.Text = t.name .. (S.SpawnTag and isProtected(t) and "  [SPAWN]" or "") e.name.Size = size e.name.Color = color
        e.name.Position = Vector2.new(mid.X, y - size - 3) e.name.Visible = true
    end
    if S.ESP and (S.ESPDistance or S.ESPWeapon) then
        local parts = {}
        if S.ESPDistance then parts[#parts + 1] = dist .. "m" end
        local tool = S.ESPWeapon and t.model:FindFirstChildOfClass("Tool")
        if tool then parts[#parts + 1] = tool.Name end
        if #parts > 0 then
            e.info.Text = table.concat(parts, "  ") e.info.Size = size - 1
            e.info.Position = Vector2.new(mid.X, y + h + 2) e.info.Visible = true
        end
    end
    if S.Tracers then
        local from = S.TracerFrom == "Center" and vp / 2 or S.TracerFrom == "Mouse" and mouse or Vector2.new(vp.X / 2, vp.Y)
        local to = Vector2.new(mid.X, y + h)
        setLine(e.tracerOut, from, to)
        setLine(e.tracer, from, to, color)
    end
end

local function updateEsp(targets)
    local cam = camera()
    local vp = cam.ViewportSize
    local mouse = UserInputService:GetMouseLocation()
    local me = myChar() and myChar():FindFirstChild("HumanoidRootPart")
    local myPos = me and me.Position or cam.CFrame.Position
    local now = os.clock()
    local seen = {}
    for _, t in ipairs(targets) do
        local enemy = isEnemy(t, true)
        local dist = math.floor((t.root.Position - myPos).Magnitude)
        local show = (S.ESP or S.Chams or S.Tracers) and (enemy or not S.ESPTeamCheck) and (S.ESPBots or not t.bot)
            and dist <= S.ESPMaxDistance
        if show then
            seen[t.model] = true
            local e = getEsp(t.model)
            -- line of sight, re-checked 10x a second per target
            if S.VisibleColors and enemy and now - (e.visAt or 0) > 0.1 then
                e.visAt = now
                local head = t.model:FindFirstChild("Head") or t.root
                e.vis = visible(head, t)
            end
            local color = not enemy and COLORS.team or (S.VisibleColors and e.vis and COLORS.visible) or (t.bot and COLORS.bot or COLORS.enemy)
            if S.Chams then
                if not e.cham then
                    local hl = Instance.new("Highlight")
                    hl.OutlineTransparency = 0 hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.Adornee = t.model hl.Parent = chamFolder
                    e.cham = hl
                end
                e.cham.FillTransparency = S.ChamsFill
                e.cham.Enabled = true e.cham.FillColor = color e.cham.OutlineColor = color
            elseif e.cham then
                e.cham.Enabled = false
            end
            if hasDrawing then drawEsp(e, t, color, dist, cam, vp, mouse) end
        end
    end
    for m, e in pairs(esp) do
        if not seen[m] then
            if not m.Parent then dropEsp(m) else hideEsp(e) end
        end
    end
end

-- ---------- aimbot + trigger bot + FOV changer ----------
local function aimHeld()
    if S.AimKey == "Always" then return true end
    local btn = S.AimKey == "Left mouse" and Enum.UserInputType.MouseButton1 or Enum.UserInputType.MouseButton2
    return UserInputService:IsMouseButtonPressed(btn)
end
local function canTarget(t)
    return isEnemy(t, S.TeamCheck) and (t.bot and S.TargetBots or not t.bot and S.TargetPlayers)
        and not (S.IgnoreProtected and isProtected(t))
end
-- the part to aim at: the chosen aim part, or with wall check on, the first other body part that's in the open
-- (head behind cover but legs showing -> legs)
local FALLBACK_PARTS = { "Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg" }
local function visiblePart(t)
    local first = aimPartOf(t, S.AimPart)
    if not S.WallCheck or visible(first, t) then return first end
    for _, n in ipairs(FALLBACK_PARTS) do
        local p = t.model:FindFirstChild(n)
        if p and p ~= first and visible(p, t) then return p end
    end
end
-- inside the FOV circle, the best enemy by the chosen priority (crosshair distance breaks ties)
local function bestTarget(targets)
    local cam = camera()
    local mouse = UserInputService:GetMouseLocation()
    local camPos = cam.CFrame.Position
    local best, bestPart, bestScore, bestD
    for _, t in ipairs(targets) do
        if canTarget(t) then
            -- FOV test on the root first (cheap), wall checks only for enemies near the crosshair
            local rp, ron = cam:WorldToViewportPoint(t.root.Position)
            if ron and rp.Z > 0 and (Vector2.new(rp.X, rp.Y) - mouse).Magnitude <= S.AimFOV + 80 then
                local part = visiblePart(t)
                local pos, on
                if part then pos, on = cam:WorldToViewportPoint(part.Position) end
                if part and on and pos.Z > 0 then
                    local d = (Vector2.new(pos.X, pos.Y) - mouse).Magnitude
                    if d <= S.AimFOV then
                        local score = S.TargetPriority == "Distance" and (part.Position - camPos).Magnitude
                            or S.TargetPriority == "Health" and t.hum.Health or d
                        if not bestScore or score < bestScore or (score == bestScore and d < bestD) then
                            best, bestPart, bestScore, bestD = t, part, score, d
                        end
                    end
                end
            end
        end
    end
    return best, bestPart
end
-- where to aim: lead by bullet travel time, and lift for bullet drop (DropComp = gravity in studs/s^2)
local function aimPoint(t, part)
    local pos = part.Position
    if S.Prediction or S.DropComp > 0 then
        local g = gunSettings()
        local speed = math.max(g and tonumber(g.MuzzleVelocity) or 1500, 100)
        local travel = (pos - camera().CFrame.Position).Magnitude / speed
        if S.Prediction then pos = pos + t.root.AssemblyLinearVelocity * travel end
        if S.DropComp > 0 then pos = pos + Vector3.new(0, 0.5 * S.DropComp * travel * travel, 0) end
    end
    return pos
end

local targetsNow = {}
local savedFOV

-- Mouse aiming works in angles. The ACS camera turns by its own (unknown) amount per mouse pixel, and less while
-- scoped, so moving the mouse by the on-screen pixel gap overshoots and flicks. Instead we measure how far the view
-- really turned per pixel we sent last frame (separately for yaw and pitch) and send just enough to close the gap.
-- The starting guess deliberately under-turns, so it eases in instead of overshooting while it learns.
local aim = { gainX = 0.02, gainY = 0.02, lastCmd = nil, lastYaw = nil, lastPitch = nil, locked = nil }
local function yawPitch(look) return math.atan2(-look.X, -look.Z), math.asin(math.clamp(look.Y, -1, 1)) end
local function wrapAngle(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function learnGain(old, observed, sent)
    if math.abs(sent) < 3 or math.abs(observed) < 1e-4 then return old end
    local sample = math.clamp(math.abs(observed / sent), 2e-4, 0.05)
    return old * 0.7 + sample * 0.3
end
local function aimWithMouse(cam, pos, f)
    local yaw, pitch = yawPitch(cam.CFrame.LookVector)
    if aim.lastCmd and aim.lastYaw then
        aim.gainX = learnGain(aim.gainX, wrapAngle(yaw - aim.lastYaw), aim.lastCmd.X)
        aim.gainY = learnGain(aim.gainY, pitch - aim.lastPitch, aim.lastCmd.Y)
    end
    local wantYaw, wantPitch = yawPitch((pos - cam.CFrame.Position).Unit)
    local errYaw, errPitch = wrapAngle(wantYaw - yaw), wantPitch - pitch
    -- mouse right = yaw goes down (turn right), mouse down = pitch goes down
    local dx = math.clamp(-errYaw / aim.gainX * f, -250, 250)
    local dy = math.clamp(-errPitch / aim.gainY * f, -250, 250)
    aim.lastYaw, aim.lastPitch = yaw, pitch
    if math.abs(dx) < 0.5 and math.abs(dy) < 0.5 then aim.lastCmd = nil return end
    mousemoverel(dx, dy)
    aim.lastCmd = Vector2.new(dx, dy)
end
-- stay on the same enemy while it's still valid instead of hopping between two nearby ones
local function stickyTarget()
    local t = aim.locked
    if t and t.model.Parent and humanoidOf(t.model) and canTarget(t) then
        local part = visiblePart(t)   -- nil = fully behind a wall: let go
        if part then
            local sp, on = camera():WorldToViewportPoint(part.Position)
            if on and sp.Z > 0 and (Vector2.new(sp.X, sp.Y) - UserInputService:GetMouseLocation()).Magnitude <= S.AimFOV * 1.5 then
                return t, part
            end
        end
    end
    local nt, np = bestTarget(targetsNow)
    aim.locked = nt
    return nt, np
end

-- Camera aim: the game turns the camera with Roblox's PlayerModule. Every frame BaseCamera asks
-- CameraInput.getRotation() how far to turn (radians: +X = right, +Y = down) and ACS's CameraRotation
-- module already wraps it for sensitivity. We add the exact angle to the target on top, so the game's own
-- camera does the turning: no fighting the camera, no mouse sensitivity or scope zoom to guess.
local camHooks = {}   -- [CameraInput table] = original getRotation
local frameId = 0
local function aimRotation()
    if not (S.Aimbot and S.AimMode == "Camera" and aimHeld() and myChar() and humanoidOf(myChar())) then return end
    if aim.frame == frameId then return end   -- only once per frame even if the camera asks twice
    aim.frame = frameId
    local t, part = stickyTarget()
    if not t then return end
    local cam = camera()
    local yaw, pitch = yawPitch(cam.CFrame.LookVector)
    local wantYaw, wantPitch = yawPitch((aimPoint(t, part) - cam.CFrame.Position).Unit)
    local f = 1 - math.clamp(S.Smoothness, 0, 0.95)
    aim.hooked = os.clock()
    return Vector2.new(wrapAngle(yaw - wantYaw) * f, (pitch - wantPitch) * f)
end
local function hookTable(m)
    if type(m) ~= "table" or camHooks[m] or type(rawget(m, "getRotation")) ~= "function" then return end
    local orig = m.getRotation
    camHooks[m] = orig
    m.getRotation = function(...)
        local r = orig(...)
        if alive and typeof(r) == "Vector2" then
            local ok, extra = pcall(aimRotation)
            if ok and extra then r = r + extra end
        end
        return r
    end
end
local function hookCamera()
    pcall(function() hookTable(require(lp:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"):WaitForChild("CameraModule"):WaitForChild("CameraInput"))) end)
    -- also catch the copy the camera actually holds, in case the executor's require hands back a separate one
    if getgc then
        pcall(function()
            for _, v in ipairs(getgc(true)) do
                if type(v) == "table" and type(rawget(v, "getRotation")) == "function" and rawget(v, "getZoomDelta") ~= nil then hookTable(v) end
            end
        end)
    end
end
local function unhookCamera()
    for m, orig in pairs(camHooks) do m.getRotation = orig end
    camHooks = {}
end
task.spawn(hookCamera)

-- silent aim: CreateBullet calls ShootModule.fire(LocalPlayer, origin, dir, data) (the client-side shot that finds
-- the hit) and then Events.ServerBullet:FireServer(origin, dir, data) with the same dir. Both get bent to the target.
local silentPos      -- aim point picked every frame
local pendingDir     -- the bent direction, handed from fire() to the ServerBullet call right after it
local shootModule, origFire
local function bend(origin, dir)
    if not (S.SilentAim and silentPos and typeof(origin) == "Vector3" and typeof(dir) == "Vector3") then return dir end
    if math.random(1, 100) > S.SilentHitChance then return dir end
    return (silentPos - origin).Unit * dir.Magnitude
end
local function findShootModule()
    local shoot = shootFn()
    if not shoot then return end
    for _, f in pairs(debug.getupvalues(shoot)) do
        if type(f) == "function" then
            local ok, ups = pcall(debug.getupvalues, f)
            for _, v in pairs(ok and ups or {}) do
                if type(v) == "table" and type(rawget(v, "fire")) == "function" then return v end
            end
        end
    end
end
-- bullet tracers: a thin neon beam from the muzzle to whatever the shot hits, fading out (only on your screen)
local tracerFolder = Instance.new("Folder")
tracerFolder.Name = "CookiesHubAirsoftTracers"
tracerFolder.Parent = Workspace
local function drawShotTracer(origin, dir)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { myChar(), camera(), tracerFolder }
    local hit = Workspace:Raycast(origin, dir.Unit * 1500, params)
    local finish = hit and hit.Position or origin + dir.Unit * 1500
    local len = (finish - origin).Magnitude
    local p = Instance.new("Part")
    p.Anchored = true p.CanCollide = false p.CanQuery = false p.CanTouch = false p.CastShadow = false
    p.Material = Enum.Material.Neon p.Color = COLORS.fov p.Transparency = 0.2
    p.Size = Vector3.new(0.08, 0.08, len)
    p.CFrame = CFrame.lookAt(origin, finish) * CFrame.new(0, 0, -len / 2)
    p.Parent = tracerFolder
    task.spawn(function()
        for i = 1, 10 do
            task.wait(0.06)
            if not p.Parent then return end
            p.Transparency = 0.2 + i * 0.08
        end
        p:Destroy()
    end)
end
local function hookShootModule()
    if shootModule then return end
    local m = findShootModule()
    if not m then return end
    shootModule, origFire = m, m.fire
    m.fire = function(plr, origin, dir, data, ...)
        if alive and plr == lp then
            dir = bend(origin, dir)
            pendingDir = dir
            if S.BulletTracers then pcall(drawShotTracer, origin, dir) end
        end
        return origFire(plr, origin, dir, data, ...)
    end
end
local oldNamecall
pcall(function()
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if alive and pendingDir and not checkcaller() and getnamecallmethod() == "FireServer"
           and typeof(self) == "Instance" and self.Name == "ServerBullet" then
            local args = table.pack(...)
            if typeof(args[2]) == "Vector3" then args[2] = pendingDir end
            pendingDir = nil
            return oldNamecall(self, table.unpack(args, 1, args.n))
        end
        return oldNamecall(self, ...)
    end))
end)
task.spawn(function()
    while alive do
        if S.SilentAim or S.BulletTracers then pcall(hookShootModule) end
        task.wait(1)
    end
end)
local triggerDown, triggerSince, lastClick = false, nil, 0
local function releaseTrigger()
    if triggerDown then triggerDown = false pcall(mouse1release) end
end
-- fires for the trigger bot (crosshair on an enemy) and for auto-shoot (silent aim has a target)
local function stepTrigger(lookup)
    local autoShoot = S.AutoShoot and S.SilentAim
    if not (S.TriggerBot or autoShoot) or not (isrbxactive == nil or isrbxactive()) or not (myChar() and myChar():FindFirstChildOfClass("Tool")) then
        releaseTrigger() triggerSince = nil return
    end
    if autoShoot and silentPos then
        lookup = nil   -- silent aim already picked a valid target, skip the crosshair check
    elseif not S.TriggerBot then
        releaseTrigger() triggerSince = nil return
    end
    local onTarget = lookup == nil
    if not onTarget then
        -- what a bullet fired along the crosshair would hit first, using the same rules as the wall check
        local cam = camera()
        local origin, dir = cam.CFrame.Position, cam.CFrame.LookVector * 2000
        local ignore = mapHelpers()
        ignore[#ignore + 1] = myChar()
        ignore[#ignore + 1] = cam
        local hit, char = castBullet(origin, dir, ignore, nil, false)
        local t = char and lookup[char]
        if t and canTarget(t) then
            ignore[#ignore + 1] = char
            onTarget = not wallBetween(origin, hit.Position, ignore)
        end
    end
    if not onTarget then releaseTrigger() triggerSince = nil return end
    triggerSince = triggerSince or os.clock()
    if os.clock() - triggerSince < S.TriggerDelay then return end
    local g = gunSettings()
    if g and g.ShootType == 3 then   -- full auto: hold
        if not triggerDown then triggerDown = true pcall(mouse1press) end
    elseif os.clock() - lastClick >= 60 / math.max(tonumber(g and g.ShootRate) or 600, 60) then
        lastClick = os.clock()
        pcall(mouse1click)
    end
end

RunService:BindToRenderStep("CookiesHubAirsoft", Enum.RenderPriority.Last.Value, function()
    if not alive then return end
    local cam = camera()
    -- FOV changer (leaves the scope zoom alone while aiming down sights)
    if S.FOVChanger then
        savedFOV = savedFOV or cam.FieldOfView
        if not (S.KeepADSZoom and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)) then cam.FieldOfView = S.FOV end
    elseif savedFOV then
        cam.FieldOfView = savedFOV savedFOV = nil
    end
    -- FOV circle
    if fovCircle then
        fovCircle.Visible = (S.Aimbot or S.SilentAim) and S.ShowFOV
        fovCircle.Position = UserInputService:GetMouseLocation() fovCircle.Radius = S.AimFOV
    end
    -- aimbot. Camera mode normally happens inside the getRotation hook; if that hook hasn't steered for a moment
    -- (not found, or the camera stopped calling it) we turn the camera here instead.
    frameId = frameId + 1
    if S.Aimbot and aimHeld() and myChar() and humanoidOf(myChar()) then
        local f = 1 - math.clamp(S.Smoothness, 0, 0.95)
        if S.AimMode == "Mouse" and mousemoverel then
            local t, part = stickyTarget()
            if t then aimWithMouse(cam, aimPoint(t, part), f) else aim.lastCmd = nil end
        elseif os.clock() - (aim.hooked or 0) > 0.3 then
            local t, part = stickyTarget()
            if t then cam.CFrame = cam.CFrame:Lerp(CFrame.lookAt(cam.CFrame.Position, aimPoint(t, part)), f) end
        end
    else
        aim.locked, aim.lastCmd = nil, nil
    end
    -- silent aim target
    silentPos = nil
    local silentT
    if S.SilentAim and myChar() and humanoidOf(myChar()) then
        local t, part = bestTarget(targetsNow)
        if t then silentPos, silentT = aimPoint(t, part), t end
    end
    -- locked-target readout: a line to them and their name / HP / distance at the top of the screen
    if targetLine then
        local t = (S.Aimbot and aimHeld() and aim.locked) or silentT
        local show = S.TargetInfo and t and t.model.Parent and humanoidOf(t.model)
        targetLine.Visible, targetText.Visible = false, false
        if show then
            local sp, on = cam:WorldToViewportPoint(aimPartOf(t, S.AimPart).Position)
            if on and sp.Z > 0 then
                targetLine.From = cam.ViewportSize / 2 targetLine.To = Vector2.new(sp.X, sp.Y) targetLine.Visible = true
            end
            local me = myChar() and myChar():FindFirstChild("HumanoidRootPart")
            targetText.Text = ("TARGET  %s   %d HP   %dm"):format(t.name, math.floor(t.hum.Health + 0.5),
                me and math.floor((t.root.Position - me.Position).Magnitude) or 0)
            targetText.Position = Vector2.new(cam.ViewportSize.X / 2, 70) targetText.Visible = true
        end
    end
    -- trigger bot
    local lookup = {}
    for _, t in ipairs(targetsNow) do lookup[t.model] = t end
    pcall(stepTrigger, lookup)
end)

-- ---------- radar ----------
-- top-right minimap, rotated so up = where you're looking; enemies at the edge are beyond the range
local radar = {}
if hasDrawing then
    radar.bg = newDraw("Square", { Filled = true, Color = Color3.fromRGB(20, 16, 30), Transparency = 0.65, Visible = false })
    radar.border = newDraw("Square", { Filled = false, Thickness = 1.5, Color = COLORS.fov, Visible = false })
    radar.crossH = newDraw("Line", { Thickness = 1, Color = Color3.fromRGB(90, 80, 110), Visible = false })
    radar.crossV = newDraw("Line", { Thickness = 1, Color = Color3.fromRGB(90, 80, 110), Visible = false })
    radar.me = newDraw("Triangle", { Filled = true, Color = COLORS.white, Visible = false })
    radar.dots = {}
end
local function hideRadar()
    for k, d in pairs(radar) do if k ~= "dots" then d.Visible = false end end
    for _, d in ipairs(radar.dots or {}) do d.Visible = false end
end
local function updateRadar(targets)
    if not hasDrawing then return end
    if not S.Radar then hideRadar() return end
    local cam = camera()
    local size = S.RadarSize
    local half = size / 2
    local pos = Vector2.new(cam.ViewportSize.X - size - 20, 60)
    local centre = pos + Vector2.new(half, half)
    radar.bg.Position = pos radar.bg.Size = Vector2.new(size, size) radar.bg.Visible = true
    radar.border.Position = pos radar.border.Size = Vector2.new(size, size) radar.border.Visible = true
    radar.crossH.From = Vector2.new(pos.X, centre.Y) radar.crossH.To = Vector2.new(pos.X + size, centre.Y) radar.crossH.Visible = true
    radar.crossV.From = Vector2.new(centre.X, pos.Y) radar.crossV.To = Vector2.new(centre.X, pos.Y + size) radar.crossV.Visible = true
    radar.me.PointA = centre + Vector2.new(0, -7) radar.me.PointB = centre + Vector2.new(-5, 5) radar.me.PointC = centre + Vector2.new(5, 5)
    radar.me.Visible = true
    local look = cam.CFrame.LookVector
    local fwd = Vector3.new(look.X, 0, look.Z)
    fwd = fwd.Magnitude > 0 and fwd.Unit or Vector3.new(0, 0, -1)
    local right = Vector3.new(-fwd.Z, 0, fwd.X)
    local me = myChar() and myChar():FindFirstChild("HumanoidRootPart")
    local origin = me and me.Position or cam.CFrame.Position
    local n = 0
    for _, t in ipairs(targets) do
        local enemy = isEnemy(t, true)
        if (enemy or not S.ESPTeamCheck) and (S.ESPBots or not t.bot) then
            n = n + 1
            local dot = radar.dots[n]
            if not dot then
                dot = newDraw("Circle", { Filled = true, Radius = 3.5, NumSides = 12, Visible = false })
                radar.dots[n] = dot
            end
            local rel = t.root.Position - origin
            local v = Vector2.new(rel:Dot(right), -rel:Dot(fwd)) / S.RadarRange * (half - 6)
            if v.Magnitude > half - 6 then v = v.Unit * (half - 6) end
            dot.Position = centre + v
            dot.Color = not enemy and COLORS.team or (t.bot and COLORS.bot or COLORS.enemy)
            dot.Visible = true
        end
    end
    for i = n + 1, #radar.dots do radar.dots[i].Visible = false end
end

-- ---------- full bright / no fog ----------
local Lighting = game:GetService("Lighting")
local LIGHT_PROPS = { "Brightness", "ClockTime", "GlobalShadows", "Ambient", "OutdoorAmbient", "FogEnd", "FogStart" }
local savedLight, savedAtmo
local function applyLighting()
    local want = S.FullBright or S.NoFog
    if want and not savedLight then
        savedLight = {}
        for _, p in ipairs(LIGHT_PROPS) do savedLight[p] = Lighting[p] end
        local a = Lighting:FindFirstChildOfClass("Atmosphere")
        savedAtmo = a and { inst = a, density = a.Density, haze = a.Haze }
    end
    if S.FullBright then
        Lighting.Brightness = 2.5 Lighting.ClockTime = 14 Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(170, 170, 170) Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 170)
    elseif savedLight then
        for _, p in ipairs({ "Brightness", "ClockTime", "GlobalShadows", "Ambient", "OutdoorAmbient" }) do Lighting[p] = savedLight[p] end
    end
    local a = Lighting:FindFirstChildOfClass("Atmosphere")
    if S.NoFog then
        Lighting.FogStart = 1e5 Lighting.FogEnd = 1e5
        if a then a.Density = 0 a.Haze = 0 end
    elseif savedLight then
        Lighting.FogStart, Lighting.FogEnd = savedLight.FogStart, savedLight.FogEnd
        if savedAtmo and savedAtmo.inst.Parent then savedAtmo.inst.Density = savedAtmo.density savedAtmo.inst.Haze = savedAtmo.haze end
    end
    if not want then savedLight, savedAtmo = nil, nil end
end

-- ---------- player: walk speed, jump, noclip, anti-AFK, auto redeploy ----------
local savedMove        -- the game's own WalkSpeed / jump values from before we changed them
local noclipParts = {} -- [part] = true for parts we turned CanCollide off on
local function setJump(h, power)
    if h.UseJumpPower then h.JumpPower = power else h.JumpHeight = power * power / (2 * Workspace.Gravity) end
end
local moveConn = RunService.Heartbeat:Connect(function()
    local c = myChar()
    local h = c and humanoidOf(c)
    if not h then return end
    if (S.WalkSpeedOn or S.JumpOn) and not savedMove then
        savedMove = { walk = h.WalkSpeed, jumpPower = h.JumpPower, jumpHeight = h.JumpHeight, hum = h }
    end
    if S.WalkSpeedOn then h.WalkSpeed = S.WalkSpeed end
    if S.JumpOn then setJump(h, S.JumpPower) end
    if savedMove and savedMove.hum == h then
        if not S.WalkSpeedOn and savedMove.walk then h.WalkSpeed = savedMove.walk savedMove.walk = nil end
        if not S.JumpOn and savedMove.jumpPower then h.JumpPower = savedMove.jumpPower h.JumpHeight = savedMove.jumpHeight savedMove.jumpPower = nil end
        if not S.WalkSpeedOn and not S.JumpOn then savedMove = nil end
    elseif savedMove then
        savedMove = nil   -- respawned: the new humanoid starts with the game's values
    end
end)
local function restoreNoclip()
    for p in pairs(noclipParts) do if p.Parent then p.CanCollide = true end end
    noclipParts = {}
end
local noclipConn = RunService.Stepped:Connect(function()
    if not S.Noclip then
        if next(noclipParts) then restoreNoclip() end
        return
    end
    local c = myChar()
    for _, p in ipairs(c and c:GetDescendants() or {}) do
        if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false noclipParts[p] = true end
    end
end)
local VirtualUser = game:GetService("VirtualUser")
local idleConn = lp.Idled:Connect(function()
    if S.AntiAFK then pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end) end
end)
-- press one of the game's own buttons the way a click would (its MouseButton1Click / Activated handlers)
local function shown(gui)
    local sg = gui:FindFirstAncestorWhichIsA("ScreenGui")
    if not (sg and sg.Enabled) then return false end
    local g = gui
    while g and g ~= sg do
        if g:IsA("GuiObject") and not g.Visible then return false end
        g = g.Parent
    end
    return true
end
local function pressButton(btn)
    if not (getconnections and btn and shown(btn)) then return false end
    for _, sig in ipairs({ "MouseButton1Click", "Activated", "MouseButton1Down" }) do
        local conns = getconnections(btn[sig])
        if #conns > 0 then
            for _, c in ipairs(conns) do pcall(function() c:Fire() end) end
            return true
        end
    end
    return false
end
-- killcam QuickRespawn first, otherwise the main menu's Play
task.spawn(function()
    while alive do
        task.wait(1.5)
        if S.AutoRedeploy then
            pcall(function()
                local c = myChar()
                local dead = not (c and humanoidOf(c))
                if not dead and c and c:GetAttribute("Deployed") == true then return end
                local ui = lp.PlayerGui:FindFirstChild("GameUI")
                local quick = ui and ui:FindFirstChild("QuickRespawn", true)
                if pressButton(quick) then return end
                local menu = ui and ui:FindFirstChild("InitialMenuUI")
                local play = menu and menu:FindFirstChild("Play", true)
                pressButton(play and (play:FindFirstChild("SELECT") or play))
            end)
        end
    end
end)

-- targets / ESP / hitboxes refresh
task.spawn(function()
    while alive do
        local ok, list = pcall(getTargets)
        if ok then targetsNow = list end
        pcall(updateHitboxes, targetsNow)
        task.wait(0.1)
    end
end)
task.spawn(function()
    while alive do
        if S.FullBright or S.NoFog or savedLight then pcall(applyLighting) end
        task.wait(1)   -- the game can re-apply its map lighting, so keep it set
    end
end)
local espConn = RunService.RenderStepped:Connect(function()
    if alive then
        pcall(updateEsp, targetsNow)
        pcall(updateRadar, targetsNow)
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
local W, H = 470, 480
local function corner(p, r) local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, r or 8) c.Parent = p return c end

local gui = Instance.new("ScreenGui")
gui.Name = "CookiesHubAirsoft" gui.ResetOnSpawn = false gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
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
    title.TextXAlignment = Enum.TextXAlignment.Left title.Text = "Cookies Hub  -  Airsoft Battles" title.Parent = bar
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
local TAB_NAMES = { "Aim", "Visuals", "Hitbox", "Gun", "Player", "Camera", "Info" }
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
-- a key picker bound to a KeyCode-name setting: click, then press a key (Backspace/Escape = none)
ui.capturing = false
function ui.keybind(parent, label, key)
    local row = Instance.new("Frame") row.Size = UDim2.new(1, 0, 0, 34) row.BackgroundColor3 = C.row row.BorderSizePixel = 0 row.Parent = parent corner(row, 6)
    local t = Instance.new("TextLabel") t.BackgroundTransparency = 1 t.Position = UDim2.fromOffset(12, 0) t.Size = UDim2.new(1, -130, 1, 0)
    t.Font = Enum.Font.GothamMedium t.TextSize = 13 t.TextColor3 = C.text t.TextXAlignment = Enum.TextXAlignment.Left t.Text = label t.Parent = row
    local b = Instance.new("TextButton") b.Size = UDim2.fromOffset(100, 24) b.Position = UDim2.new(1, -112, 0.5, -12)
    b.BackgroundColor3 = C.bg b.Font = Enum.Font.GothamMedium b.TextSize = 12 b.TextColor3 = C.text b.BorderSizePixel = 0 b.Parent = row corner(b, 6)
    local function render() b.Text = S[key] end
    b.MouseButton1Click:Connect(function()
        if ui.capturing then return end
        ui.capturing = true b.Text = "press a key..."
        local conn
        conn = UserInputService.InputBegan:Connect(function(i)
            if i.UserInputType ~= Enum.UserInputType.Keyboard then return end
            conn:Disconnect()
            local name = i.KeyCode.Name
            S[key] = (name == "Backspace" or name == "Escape") and "None" or name
            saveSettings() render()
            task.defer(function() ui.capturing = false end)   -- don't let this same key press flip the feature
        end)
    end)
    render()
    ui.renders[key] = render
end

for _, n in ipairs(TAB_NAMES) do ui.tab(n) end

do -- Aim
    local p = ui.tabs.Aim
    ui.sec(p, "Aimbot")
    ui.toggle(p, "Aimbot", "Aimbot")
    ui.note(p, "Aim key:")
    ui.choice(p, "AimKey", { "Right mouse", "Left mouse", "Always" })
    ui.note(p, "Aim at:")
    ui.choice(p, "AimPart", { "Head", "Torso", "Closest" })
    ui.note(p, "Pick the target by (inside the FOV circle):")
    ui.choice(p, "TargetPriority", { "Crosshair", "Distance", "Health" })
    ui.note(p, "Method (Camera = steers the game's own camera, best; Mouse = moves your mouse):")
    ui.choice(p, "AimMode", { "Camera", "Mouse" })
    ui.slider(p, "Aim FOV (pixels)", "AimFOV", 20, 600, 5, "%d")
    ui.toggle(p, "Show FOV circle", "ShowFOV")
    ui.slider(p, "Smoothness", "Smoothness", 0, 0.95, 0.05, "%.2f")
    ui.toggle(p, "Prediction (lead moving targets)", "Prediction")
    ui.slider(p, "Bullet drop fix (0 = off; raise if long shots land low)", "DropComp", 0, 200, 5, "%d")
    ui.toggle(p, "Wall check (only visible targets)", "WallCheck")
    ui.toggle(p, "Target info (line + name / HP on screen)", "TargetInfo")
    ui.keybind(p, "Aimbot on/off key", "AimbotToggleKey")
    ui.sec(p, "Silent aim")
    ui.toggle(p, "Silent aim (bullets go to the target, no aim snap)", "SilentAim")
    ui.slider(p, "Hit chance (%)", "SilentHitChance", 1, 100, 1, "%d")
    ui.toggle(p, "Auto shoot (fires whenever silent aim has a target)", "AutoShoot", function(v) if not v then releaseTrigger() end end)
    ui.keybind(p, "Silent aim on/off key", "SilentToggleKey")
    ui.note(p, "Picks the enemy inside the FOV circle using the aim part, priority, prediction and wall check above. Just shoot anywhere near them.")
    ui.sec(p, "Targets")
    ui.toggle(p, "Team check (enemies only)", "TeamCheck")
    ui.toggle(p, "Target players", "TargetPlayers")
    ui.toggle(p, "Target bots", "TargetBots")
    ui.toggle(p, "Ignore spawn-protected targets", "IgnoreProtected")
    ui.sec(p, "Trigger bot")
    ui.toggle(p, "Trigger bot (shoots when your crosshair is on an enemy)", "TriggerBot", function(v) if not v then releaseTrigger() end end)
    ui.slider(p, "Trigger delay (s)", "TriggerDelay", 0, 0.5, 0.01, "%.2f")
    ui.note(p, "Uses the same team / bot / spawn-protection settings as the aimbot. Full-auto guns are held, others are clicked at their fire rate.")
end
do -- Visuals
    local p = ui.tabs.Visuals
    ui.sec(p, "ESP")
    ui.toggle(p, "Player / bot ESP", "ESP")
    ui.toggle(p, "Boxes", "ESPBoxes")
    ui.choice(p, "BoxStyle", { "Corners", "Full" })
    ui.toggle(p, "Skeleton", "Skeleton")
    ui.toggle(p, "Names", "ESPNames")
    ui.toggle(p, "Health bars (+ HP number when hurt)", "ESPHealth")
    ui.toggle(p, "Distance", "ESPDistance")
    ui.toggle(p, "Weapon they're holding", "ESPWeapon")
    ui.toggle(p, "Off-screen arrows", "Arrows")
    ui.toggle(p, "Green when in your line of sight", "VisibleColors")
    ui.slider(p, "Max distance (studs)", "ESPMaxDistance", 100, 3000, 50, "%d")
    ui.slider(p, "Text size", "ESPTextSize", 10, 20, 1, "%d")
    ui.sec(p, "Filters")
    ui.toggle(p, "Team check (enemies only)", "ESPTeamCheck")
    ui.toggle(p, "Show bots", "ESPBots")
    ui.toggle(p, "[SPAWN] tag on spawn-protected enemies", "SpawnTag")
    ui.sec(p, "Radar")
    ui.toggle(p, "Radar (top right, up = where you look)", "Radar")
    ui.slider(p, "Radar range (studs)", "RadarRange", 50, 1000, 25, "%d")
    ui.slider(p, "Radar size (pixels)", "RadarSize", 120, 320, 10, "%d")
    ui.sec(p, "Tracers")
    ui.toggle(p, "Tracers", "Tracers")
    ui.choice(p, "TracerFrom", { "Bottom", "Center", "Mouse" })
    ui.toggle(p, "Bullet tracers (where your shots went)", "BulletTracers")
    ui.sec(p, "World")
    ui.toggle(p, "Full bright", "FullBright")
    ui.toggle(p, "No fog", "NoFog")
    ui.sec(p, "Chams")
    ui.toggle(p, "Chams (see bodies through walls)", "Chams")
    ui.slider(p, "Chams fill (0 = solid, 1 = outline only)", "ChamsFill", 0, 1, 0.05, "%.2f")
    ui.note(p, "Red = enemy player, orange = enemy bot, green = enemy you can see right now, blue = teammate (team check off).")
    if not hasDrawing then ui.note(p, "Your executor has no Drawing library: boxes, names and tracers are unavailable, chams still work.") end
end
do -- Hitbox
    local p = ui.tabs.Hitbox
    ui.sec(p, "Hitbox changer")
    ui.toggle(p, "Bigger enemy hitboxes", "Hitbox")
    ui.choice(p, "HitboxPart", { "Head", "Torso" })
    ui.slider(p, "Size (studs)", "HitboxSize", 2, 20, 0.5, "%.1f")
    ui.toggle(p, "Show hitboxes (see-through)", "HitboxVisible")
    ui.note(p, "Enemies only (players and bots, following the Aim tab's target switches). Head hits count as headshots. Everything is put back when you turn it off.")
end
do -- Gun
    local p = ui.tabs.Gun
    ui.sec(p, "Gun mods")
    ui.toggle(p, "No recoil", "NoRecoil")
    ui.toggle(p, "No spread", "NoSpread")
    ui.toggle(p, "No reload (magazine never empties)", "NoReload")
    ui.toggle(p, "Rapid fire", "RapidFire")
    ui.slider(p, "Fire rate multiplier", "FireRateMult", 1, 4, 0.1, "%.1fx")
    ui.toggle(p, "Full auto on every gun (not pump / bolt guns)", "FullAuto")
    ui.note(p, "Works on whichever gun you have out, and on every gun you switch to or respawn with. Turning a mod off restores the gun's own values. The server may ignore shots fired faster than a gun normally can.")
    ui.gun = ui.note(p, "Gun: -")
end
do -- Player
    local p = ui.tabs.Player
    ui.sec(p, "Movement")
    ui.toggle(p, "Walk speed", "WalkSpeedOn")
    ui.slider(p, "Speed", "WalkSpeed", 16, 60, 1, "%d")
    ui.toggle(p, "Jump power", "JumpOn")
    ui.slider(p, "Jump", "JumpPower", 50, 150, 5, "%d")
    ui.toggle(p, "Noclip (walk through walls)", "Noclip")
    ui.note(p, "All off by default. Server checks can catch big speed / jump values or noclip and kick you; small boosts are the least obvious.")
    ui.sec(p, "Misc")
    ui.toggle(p, "Anti-AFK", "AntiAFK")
    ui.toggle(p, "Auto redeploy (presses Quick Respawn / Play for you)", "AutoRedeploy")
end
do -- Camera
    local p = ui.tabs.Camera
    ui.sec(p, "Field of view")
    ui.toggle(p, "FOV changer", "FOVChanger")
    ui.slider(p, "FOV", "FOV", 50, 120, 1, "%d")
    ui.toggle(p, "Keep scope zoom while aiming (right mouse)", "KeepADSZoom")
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
    ui.note(p, "Teams come from the game's own Red/Blue team tags, so team check works for players and bots. The aimbot locks on to the enemy nearest your crosshair inside the FOV circle while the aim key is held. Gun mods edit your equipped ACS gun's settings.")
    ui.sec(p, "Keys")
    ui.note(p, "RightShift shows/hides the hub. X unloads it and puts hitboxes, guns and FOV back.")
    ui.sec(p, "Unload")
    -- Unload is defined further down, so go through the global
    ui.button(p, "Unload Cookies Hub (turns everything off)", C.danger, function()
        if _G.CookiesHubAirsoft then _G.CookiesHubAirsoft.Unload() end
    end)
end
ui.select("Aim")

-- live gun readout
task.spawn(function()
    while alive do
        task.wait(1)
        pcall(function()
            local g, shoot = gunSettings()
            local tool = myChar() and myChar():FindFirstChildOfClass("Tool")
            if g and tool then
                local _, rounds = pcall(debug.getupvalue, shoot, 6)
                ui.gun.Text = ("Gun: %s   mag %s/%s   %s rpm"):format(tool.Name, tostring(rounds), tostring(g.Ammo), tostring(g.ShootRate))
            else
                ui.gun.Text = "Gun: none equipped"
            end
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
    pcall(function() RunService:UnbindFromRenderStep("CookiesHubAirsoft") end)
    if inputConn then inputConn:Disconnect() end
    for _, c in ipairs(ui.conns) do c:Disconnect() end
    gunConn:Disconnect()
    espConn:Disconnect()
    moveConn:Disconnect()
    noclipConn:Disconnect()
    idleConn:Disconnect()
    releaseTrigger()
    pcall(restoreNoclip)
    pcall(function()
        local h = savedMove and savedMove.hum
        if h and h.Parent then
            if savedMove.walk then h.WalkSpeed = savedMove.walk end
            if savedMove.jumpPower then h.JumpPower = savedMove.jumpPower h.JumpHeight = savedMove.jumpHeight end
        end
    end)
    S.FullBright, S.NoFog = false, false   -- in memory only, so the saved settings keep your choice
    pcall(applyLighting)
    pcall(hideRadar)
    for k, d in pairs(radar) do
        if k == "dots" then for _, dot in ipairs(d) do pcall(function() dot:Remove() end) end
        else pcall(function() d:Remove() end) end
    end
    if targetLine then pcall(function() targetLine:Remove() targetText:Remove() end) end
    pcall(function() tracerFolder:Destroy() end)
    if shootModule and origFire then shootModule.fire = origFire end
    pcall(unhookCamera)
    pcall(restoreGuns)
    for p in pairs(resized) do pcall(restorePart, p) end
    if savedFOV then pcall(function() camera().FieldOfView = savedFOV end) end
    for m in pairs(esp) do pcall(dropEsp, m) end
    if fovCircle then pcall(function() fovCircle:Remove() end) end
    pcall(function() chamFolder:Destroy() end)
    pcall(function() gui:Destroy() end)
    _G.CookiesHubAirsoft = nil
end
closeBtn.MouseButton1Click:Connect(Unload)
inputConn = UserInputService.InputBegan:Connect(function(i, gpe)
    if gpe or ui.capturing then return end
    if i.KeyCode == S.ToggleKey then main.Visible = not main.Visible end
    local name = i.KeyCode.Name
    if name == S.AimbotToggleKey then
        S.Aimbot = not S.Aimbot saveSettings() if ui.renders.Aimbot then ui.renders.Aimbot() end
    end
    if name == S.SilentToggleKey then
        S.SilentAim = not S.SilentAim saveSettings() if ui.renders.SilentAim then ui.renders.SilentAim() end
    end
end)

_G.CookiesHubAirsoft = {
    Unload = Unload, State = S,
    Set = function(k, v)
        if S[k] == nil then return end
        S[k] = v saveSettings()
        if ui.renders[k] then ui.renders[k]() end
        if k == "TriggerBot" and not v then releaseTrigger() end
    end,
    Get = function(k) return S[k] end,
    Targets = function() return targetsNow end,
}
print("[CookiesHub] Airsoft Battles loaded.")

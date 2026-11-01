-- Cookies Hub (Arsenal)  [KEYLESS]
-- RightShift: show/hide | X button or _G.CookiesHubArsenal.Unload(): unload
-- Console: _G.CookiesHubArsenal.Set("Aimbot", true)
--
-- Read live from Arsenal (place 286090429):
--  * Teams: Player.Status.Team (TBC / TRC / Spectator / ...), Player.Status.Alive. The game's own team rule is
--    ReplicatedStorage.Modules.TeamCheck.isteam(me, character) = true for TEAMMATES (verified live: same
--    Status.Team -> true). It also covers FFA, friendly fire, juggernaut and battle-royale modes, so enemy = not isteam.
--  * R15 rigs with invisible hit parts: HeadHB (head, ~1.4 studs) and Hitbox (body, 4.5x4x4).
--  * Guns are hitscan. ReplicatedFirst.Client.Game.BulletsAndProjectiles builds a Ray from the camera along the
--    crosshair (+ spread) and casts it with ReplicatedStorage.Modules.GeneralFunctions.cast(ray, ignoreList),
--    looked up on the module table at every shot. The hit is sent at once (same thread, no yield) through
--    NetClient as HitPart: hit instance, gun id, flags, the camera CFrame and the hit position.
--    HeadHB / Head (or the top of Hitbox) = headshot.
--  * Anti-tamper: the game grabs game's __index with an xpcall trick, so nothing here hooks metamethods.
--    Silent aim swaps the GeneralFunctions.cast field instead and points the camera at the target for the
--    duration of that one shot (put back before the frame is drawn), so the camera in the hit packet agrees.
-- Save this file as UTF-8 WITHOUT a BOM or it won't load.

if _G.CookiesHubArsenal and _G.CookiesHubArsenal.Unload then pcall(_G.CookiesHubArsenal.Unload) end

local Players          = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")
local RF               = game:GetService("ReplicatedFirst")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")
local lp               = Players.LocalPlayer

-- ---------- guard ----------
if not game:IsLoaded() then game.Loaded:Wait() end
local modules = RS:WaitForChild("Modules", 15)
local okGF, GF = pcall(require, modules and modules:WaitForChild("GeneralFunctions", 15))
local okTC, TC = pcall(require, modules and modules:WaitForChild("TeamCheck", 15))
local okST, State = pcall(function() return require(RF:WaitForChild("Client", 15).Utility.State) end)
if not (okGF and type(GF) == "table" and type(GF.cast) == "function" and okTC and type(TC) == "table") then
    warn("[CookiesHub Arsenal] Not Arsenal (missing Modules.GeneralFunctions / TeamCheck). Aborting.")
    return
end
if not (okST and type(State) == "table") then State = {} end
local okSP, Spread = pcall(require, modules:WaitForChild("Spread", 15))
local okGN, General = pcall(function() return require(RF.Client.Utility.General) end)
if not (okSP and type(Spread) == "table" and type(Spread.calcspread) == "function") then Spread = nil end
if not (okGN and type(General) == "table" and type(General.getammo) == "function") then General = nil end
local alive = true   -- cleared on Unload so every loop exits

-- ---------- settings (per account) ----------
local S = {
    -- aim
    Aimbot        = false,
    AimKey        = "Right mouse",   -- Right mouse | Left mouse | Always
    AimPart       = "Head",          -- Head | Torso | Closest (body part nearest the crosshair)
    TargetPriority = "Crosshair",    -- Crosshair | Distance | Health (all inside the FOV circle)
    AimMode       = "Camera",        -- Camera (turns the camera) | Mouse (moves your mouse)
    AimFOV        = 150,             -- pixels from the crosshair
    ShowFOV       = true,
    Smoothness    = 0.5,             -- 0 = snap, higher = slower
    WallCheck     = true,
    TeamCheck     = true,            -- only enemies (the game's own rule, works in every mode)
    IgnoreProtected = true,          -- skip spawn-protected (ForceField) targets
    TargetInfo    = true,
    AimbotToggleKey = "None",
    SilentAim     = false,
    SilentHitChance = 100,
    SilentToggleKey = "None",
    TriggerBot    = false,
    TriggerDelay  = 0.05,
    TriggerToggleKey = "None",
    -- visuals
    ESP           = false,
    ESPBoxes      = true,
    BoxStyle      = "Corners",       -- Corners | Full
    ESPNames      = true,
    ESPHealth     = true,
    ESPDistance   = true,
    Skeleton      = false,
    Arrows        = true,
    ESPTeam       = false,           -- also draw teammates (blue)
    VisibleColors = true,
    ESPMaxDistance = 1500,
    ESPTextSize   = 13,
    Tracers       = false,
    TracerFrom    = "Bottom",        -- Bottom | Center | Mouse
    Chams         = false,
    ChamsFill     = 0.5,
    FullBright    = false,
    NoFog         = false,
    -- hitbox
    Hitbox        = false,
    HitboxPart    = "Head",          -- Head (HeadHB) | Body (Hitbox)
    HitboxSize    = 6,
    HitboxVisible = true,
    -- gun
    NoSpread      = false,
    NoRecoil      = false,
    InfiniteAmmo  = false,
    FullAuto      = false,
    -- player
    SpeedOn       = false,
    SpeedMult     = 1.5,
    JumpOn        = false,
    JumpMult      = 1.5,
    GravityOn     = false,
    GravityMult   = 0.5,
    InfiniteJump  = false,
    Noclip        = false,
    Fly           = false,
    FlySpeed      = 50,
    FlyToggleKey  = "None",
    AntiAFK       = true,
    ToggleKey     = Enum.KeyCode.RightShift,
}
local SETTINGS_FILE = ("CookiesHubArsenal_%d_settings.json"):format(lp.UserId)
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
    enemy = Color3.fromRGB(255, 80, 80), team = Color3.fromRGB(80, 150, 255),
    fov = Color3.fromRGB(171, 113, 235), white = Color3.new(1, 1, 1), hpBack = Color3.fromRGB(20, 20, 20),
    visible = Color3.fromRGB(90, 255, 120), outline = Color3.new(0, 0, 0), info = Color3.fromRGB(220, 220, 230),
}

-- ---------- targets ----------
local function camera() return Workspace.CurrentCamera end
local function myChar() return lp.Character end
local function humanoidOf(m)
    local h = m and m:FindFirstChildOfClass("Humanoid")
    if h and h.Health > 0 then return h end
end
local function statusValue(p, name)
    local st = p:FindFirstChild("Status")
    local v = st and st:FindFirstChild(name)
    return v and v.Value
end
local function iAmAlive()
    return humanoidOf(myChar()) ~= nil and statusValue(lp, "Alive") ~= false
end
-- TeamCheck.isteam(me, character) is true for teammates. It compares Status.Team, so any number of teams works,
-- and it already treats friendly fire / FFA / bots as enemies. If it errors, fall back to comparing Status.Team.
local function isEnemy(m)
    local ok, mate = pcall(TC.isteam, lp, m)
    if ok then return mate ~= true end
    local p = Players:GetPlayerFromCharacter(m)
    if not p then return true end
    local mine, theirs = statusValue(lp, "Team") or lp.Team, statusValue(p, "Team") or p.Team
    return mine == nil or mine ~= theirs
end
-- every other living player
local function getTargets()
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        local m = p ~= lp and p.Character
        local h, root = m and humanoidOf(m), m and m:FindFirstChild("HumanoidRootPart")
        if h and root and statusValue(p, "Alive") ~= false then
            list[#list + 1] = { model = m, hum = h, root = root, player = p, name = p.DisplayName, enemy = isEnemy(m) }
        end
    end
    return list
end
local function isProtected(t) return t.model:FindFirstChildOfClass("ForceField") ~= nil end
local function canTarget(t)
    return (t.enemy or not S.TeamCheck) and not (S.IgnoreProtected and isProtected(t))
end
local CLOSEST_PARTS = { "Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg" }
local function aimPartOf(t, which)
    local m = t.model
    if which == "Torso" then return m:FindFirstChild("UpperTorso") or m:FindFirstChild("Torso") or t.root end
    if which == "Closest" then
        local cam = camera()
        local mouse = UserInputService:GetMouseLocation()
        local best, bd
        for _, n in ipairs(CLOSEST_PARTS) do
            local p = m:FindFirstChild(n)
            if p then
                local sp, on = cam:WorldToViewportPoint(p.Position)
                local d = on and sp.Z > 0 and (Vector2.new(sp.X, sp.Y) - mouse).Magnitude
                if d and (not bd or d < bd) then best, bd = p, d end
            end
        end
        if best then return best end
    end
    return m:FindFirstChild("Head") or m:FindFirstChild("HeadHB") or t.root
end

-- ---------- wall check ----------
-- Mirrors GeneralFunctions.gethitlist: bullets start at the camera and pass through you, the camera (viewmodel),
-- Ray_Ignore and the map's Clips / Spawns / Ignore folders.
local function rayIgnore()
    local list = { myChar(), camera() }
    local function add(i) if i then list[#list + 1] = i end end
    add(Workspace:FindFirstChild("Ray_Ignore"))
    local map = Workspace:FindFirstChild("Map")
    if map then add(map:FindFirstChild("Clips")) add(map:FindFirstChild("Spawns")) add(map:FindFirstChild("Ignore")) end
    return list
end
local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
wallParams.IgnoreWater = true
local visCache = setmetatable({}, { __mode = "k" })
local function visible(part, target)
    local now = os.clock()
    local c = visCache[part]
    if c and now - c.t < 0.03 then return c.v end
    local origin = camera().CFrame.Position
    wallParams.FilterDescendantsInstances = rayIgnore()
    local hit = Workspace:Raycast(origin, (part.Position - origin) * 1.02, wallParams)
    local v = hit == nil or hit.Instance:IsDescendantOf(target.model)
    visCache[part] = { t = now, v = v }
    return v
end

-- ---------- hitbox ----------
local HITBOX_PARTS = { Head = "HeadHB", Body = "Hitbox" }
local resized = {}   -- [part] = { size, transparency }
local function restorePart(p)
    local o = resized[p]
    if o and p.Parent then p.Size, p.Transparency = o.size, o.transparency end
    resized[p] = nil
end
local function updateHitboxes(targets)
    local keep = {}
    if S.Hitbox then
        local n = S.HitboxSize
        for _, t in ipairs(targets) do
            local p = canTarget(t) and t.model:FindFirstChild(HITBOX_PARTS[S.HitboxPart] or "HeadHB")
            if p and p:IsA("BasePart") then
                if not resized[p] then resized[p] = { size = p.Size, transparency = p.Transparency } end
                keep[p] = true
                p.Size = Vector3.new(n, n, n)
                p.Transparency = S.HitboxVisible and 0.7 or resized[p].transparency
            end
        end
    end
    for p in pairs(resized) do if not keep[p] then restorePart(p) end end
end

-- ---------- ESP (Drawing) + chams (Highlight) ----------
local hasDrawing = typeof(Drawing) == "table" and Drawing.new ~= nil
local chamFolder = Instance.new("Folder")
chamFolder.Name = "CookiesHubArsenalChams"
pcall(function() chamFolder.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not chamFolder.Parent then chamFolder.Parent = lp:WaitForChild("PlayerGui") end

local function newDraw(kind, props)
    local d = Drawing.new(kind)
    for k, v in pairs(props) do d[k] = v end
    return d
end
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
    local footY = t.root.Position.Y - 3
    local lf, rf = t.model:FindFirstChild("LeftFoot"), t.model:FindFirstChild("RightFoot")
    if lf and rf then footY = math.min(lf.Position.Y - lf.Size.Y / 2, rf.Position.Y - rf.Size.Y / 2) - 0.1 end
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
        e.name.Text = t.name .. (isProtected(t) and "  [SPAWN]" or "")
        e.name.Size = size e.name.Color = color
        e.name.Position = Vector2.new(mid.X, y - size - 3) e.name.Visible = true
    end
    if S.ESP and S.ESPDistance then
        e.info.Text = dist .. "m" e.info.Size = size - 1
        e.info.Position = Vector2.new(mid.X, y + h + 2) e.info.Visible = true
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
    local myPos = cam.CFrame.Position
    local now = os.clock()
    local seen = {}
    for _, t in ipairs(targets) do
        local dist = math.floor((t.root.Position - myPos).Magnitude)
        local show = (S.ESP or S.Chams or S.Tracers) and (t.enemy or S.ESPTeam) and dist <= S.ESPMaxDistance
        if show then
            seen[t.model] = true
            local e = getEsp(t.model)
            -- line of sight, re-checked 10x a second per target
            if S.VisibleColors and t.enemy and now - (e.visAt or 0) > 0.1 then
                e.visAt = now
                e.vis = visible(aimPartOf(t, "Head"), t) or visible(t.root, t)
            end
            local color = not t.enemy and COLORS.team or (S.VisibleColors and e.vis and COLORS.visible) or COLORS.enemy
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

-- ---------- aimbot ----------
local function aimHeld()
    if S.AimKey == "Always" then return true end
    local btn = S.AimKey == "Left mouse" and Enum.UserInputType.MouseButton1 or Enum.UserInputType.MouseButton2
    return UserInputService:IsMouseButtonPressed(btn)
end
-- the part to aim at: the chosen aim part, or with wall check on, the first other body part that's in the open
local FALLBACK_PARTS = { "Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftLowerLeg", "RightLowerLeg" }
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
        if canTarget(t) and t.model.Parent and t.hum.Health > 0 then
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

local targetsNow = {}

-- Mouse aiming works in angles: we measure how far the view really turned per pixel we sent last frame
-- (separately for yaw and pitch) and send just enough to close the gap, so sensitivity / scope don't matter.
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

-- ---------- silent aim ----------
-- BulletsAndProjectiles casts every bullet with GF.cast(Ray from the camera, ignoreList) and sends the hit in the
-- same thread. For a bullet ray we bend it at the target and turn the camera to match, so the camera CFrame in the
-- hit packet lines up with the hit; the camera is put back (task.defer) before the frame is drawn.
local silentPos      -- aim point picked every frame
local savedCam       -- camera CFrame to put back after a redirected shot
local origCast = GF.cast
local castStats = { bullets = 0, redirected = 0 }   -- shown by Status() for bug reports
local function isBulletCast(ray)
    if typeof(ray) ~= "Ray" or State.equipped == "melee" then return false end
    if (ray.Origin - camera().CFrame.Position).Magnitude > 0.5 then return false end
    local src = debug.info(3, "s")
    return type(src) == "string" and src:find("BulletsAndProjectiles", 1, true) ~= nil
end
GF.cast = function(ray, ignore, ...)
    local bullet = alive and isBulletCast(ray)
    if bullet then castStats.bullets = castStats.bullets + 1 end
    if bullet and S.SilentAim and silentPos and math.random(1, 100) <= S.SilentHitChance then
        castStats.redirected = castStats.redirected + 1
        local cam = camera()
        if not savedCam then
            savedCam = cam.CFrame
            task.defer(function()
                if savedCam then cam.CFrame = savedCam savedCam = nil end
            end)
        end
        cam.CFrame = CFrame.lookAt(cam.CFrame.Position, silentPos)
        ray = Ray.new(ray.Origin, (silentPos - ray.Origin).Unit * math.max(ray.Direction.Magnitude, 1))
    end
    return origCast(ray, ignore, ...)
end

-- ---------- gun mods ----------
-- No spread: every bullet's direction offset comes from Spread.calcspread (looked up on the module per shot).
-- No recoil: the camera kick (ShakeCam) scales with the gun's RecoilControl value in ReplicatedStorage.Weapons,
-- so it's zeroed client-side and put back when turned off. Infinite ammo: the magazine is State.ammocount
-- (primary) / State.ammo2count (secondary), counted down on the client; kept at the gun's full mag size.
local origCalcSpread = Spread and Spread.calcspread
if Spread then
    Spread.calcspread = function(...)
        if alive and S.NoSpread then return CFrame.new() end
        return origCalcSpread(...)
    end
end
local modeForced = false   -- we switched State.mode from semi to automatic
local recoilSaved = {}   -- [RecoilControl value] = original
local function restoreRecoil()
    for v, o in pairs(recoilSaved) do if v.Parent then v.Value = o end end
    recoilSaved = {}
end
local gunConn = RunService.Heartbeat:Connect(function()
    if not alive then return end
    pcall(function()
        local gun = State.gun
        if S.NoRecoil then
            local rc = gun and gun:FindFirstChild("RecoilControl")
            if rc and rc:IsA("ValueBase") then
                if recoilSaved[rc] == nil then recoilSaved[rc] = rc.Value end
                rc.Value = 0
            end
        elseif next(recoilSaved) then
            restoreRecoil()
        end
        -- Full auto: Weapons sets State.mode on every equip ("automatic" only for guns with Auto = true), and
        -- BulletsAndProjectiles lets go of the held button after each shot unless it is "automatic".
        if S.FullAuto then
            if State.mode == "semi" then State.mode = "automatic" modeForced = true end
        elseif modeForced then
            modeForced = false
            local auto = gun and gun:FindFirstChild("Auto")
            if State.mode == "automatic" and not (auto and auto.Value == true) and not State.istouch then State.mode = "semi" end
        end
        if S.InfiniteAmmo and General and gun and not State.reloading then
            local full = General.getammo(gun)
            if State.equipped == "primary" and State.ammocount < full then State.ammocount = full end
            if State.equipped == "secondary" and State.ammo2count < full then State.ammo2count = full end
        end
    end)
end)

-- ---------- player mods ----------
-- The game drives WalkSpeed itself (it eases between values for sprint / crouch / each weapon), so speed and jump
-- are multipliers on the game's own value, not fixed numbers: if the value is not the one we wrote last frame,
-- the game changed it, so that is the new base. Gravity uses the same scheme on workspace.Gravity.
local mulState = {}   -- ["Obj.Prop"] = { obj, prop, base, last }
local function applyMul(id, obj, prop, on, mult)
    local st = mulState[id]
    if on then
        local cur = obj[prop]
        if not st or st.obj ~= obj then
            st = { obj = obj, prop = prop, base = cur, last = cur }
            mulState[id] = st
        elseif cur ~= st.last then
            st.base = cur
        end
        obj[prop] = st.base * mult
        st.last = obj[prop]
    elseif st then
        if st.obj.Parent and st.obj[st.prop] == st.last then st.obj[st.prop] = st.base end
        mulState[id] = nil
    end
end
local function restoreMuls()
    for id in pairs(mulState) do pcall(applyMul, id, nil, nil, false) end
end
local noclipParts = {}   -- [part] = true for parts we turned CanCollide off on
local function restoreNoclip()
    for p in pairs(noclipParts) do if p.Parent then p.CanCollide = true end end
    noclipParts = {}
end
local moveConn = RunService.Heartbeat:Connect(function()
    if not alive then return end
    pcall(function()
        local h = humanoidOf(myChar())
        if h then
            applyMul("walk", h, "WalkSpeed", S.SpeedOn, S.SpeedMult)
            applyMul("jump", h, h.UseJumpPower and "JumpPower" or "JumpHeight", S.JumpOn, S.JumpMult)
        else
            mulState.walk, mulState.jump = nil, nil   -- died: the new character starts with the game's values
        end
        applyMul("grav", Workspace, "Gravity", S.GravityOn, S.GravityMult)
    end)
end)
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
-- Arsenal replaces Roblox's control module, so Humanoid jumps are driven by its own code (which also blocks a
-- jump while the state is Jumping / Freefall) and UserInputService.JumpRequest never fires. So: watch the Space
-- key ourselves and, when you're in the air, give the character the upward speed a normal jump would
-- (sqrt(2 * gravity * height), using the jump multiplier if it's on).
local lastAirJump = 0
local function airJump()
    if not (alive and S.InfiniteJump) or os.clock() - lastAirJump < 0.15 then return end
    local c = myChar()
    local h, root = humanoidOf(c), c and c:FindFirstChild("HumanoidRootPart")
    if not (h and root) or h.FloorMaterial ~= Enum.Material.Air then return end
    lastAirJump = os.clock()
    local v = h.UseJumpPower and h.JumpPower or math.sqrt(2 * Workspace.Gravity * h.JumpHeight)
    root.AssemblyLinearVelocity = Vector3.new(root.AssemblyLinearVelocity.X, v, root.AssemblyLinearVelocity.Z)
end
local jumpConn = UserInputService.InputBegan:Connect(function(i, gpe)
    if not gpe and i.KeyCode == Enum.KeyCode.Space then airJump() end
end)
local jumpReqConn = UserInputService.JumpRequest:Connect(airJump)
-- Fly: every physics step the character's velocity is set from the keys (W/A/S/D relative to where the camera
-- looks, Space up, Left Shift / Left Ctrl down) and stopped dead when no key is held, so gravity can't pull you
-- down. Leaving the toggle off hands control back to the game; you then fall normally.
local flyWasOn = false
local flyConn = RunService.Heartbeat:Connect(function()
    if not alive then return end
    local c = myChar()
    local h, root = humanoidOf(c), c and c:FindFirstChild("HumanoidRootPart")
    if not (S.Fly and h and root) or UserInputService:GetFocusedTextBox() then
        if flyWasOn then flyWasOn = false if h then h.PlatformStand = false end end
        return
    end
    flyWasOn = true
    local cam = camera().CFrame
    local dir = Vector3.zero
    local function down(k) return UserInputService:IsKeyDown(k) end
    if down(Enum.KeyCode.W) then dir += cam.LookVector end
    if down(Enum.KeyCode.S) then dir -= cam.LookVector end
    if down(Enum.KeyCode.D) then dir += cam.RightVector end
    if down(Enum.KeyCode.A) then dir -= cam.RightVector end
    if down(Enum.KeyCode.Space) then dir += Vector3.yAxis end
    if down(Enum.KeyCode.LeftShift) or down(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
    h.PlatformStand = false
    root.AssemblyLinearVelocity = dir.Magnitude > 0 and dir.Unit * S.FlySpeed or Vector3.zero
end)
local VirtualUser = game:GetService("VirtualUser")
local idleConn = lp.Idled:Connect(function()
    if S.AntiAFK then pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end) end
end)

-- ---------- trigger bot ----------
-- Holds left mouse (through the game's own input, so every gun works, automatics included) while what a bullet
-- along the crosshair would hit first is a targetable enemy; lets go as soon as it isn't.
local triggerSince, triggerHeld = nil, false
local function triggerRelease()
    if triggerHeld then triggerHeld = false pcall(mouse1release) end
end
local function stepTrigger(meAlive)
    local on = false
    if S.TriggerBot and meAlive and mouse1press and (isrbxactive == nil or isrbxactive())
       and UserInputService:GetFocusedTextBox() == nil then
        local cam = camera()
        wallParams.FilterDescendantsInstances = rayIgnore()
        local hit = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 2000, wallParams)
        if hit then
            for _, t in ipairs(targetsNow) do
                if hit.Instance:IsDescendantOf(t.model) then on = canTarget(t) break end
            end
        end
    end
    if not on then triggerSince = nil triggerRelease() return end
    triggerSince = triggerSince or os.clock()
    if not triggerHeld and os.clock() - triggerSince >= S.TriggerDelay then
        triggerHeld = true
        pcall(mouse1press)
    end
end

RunService:BindToRenderStep("CookiesHubArsenal", Enum.RenderPriority.Camera.Value + 1, function()
    if not alive then return end
    local cam = camera()
    if fovCircle then
        fovCircle.Visible = (S.Aimbot or S.SilentAim) and S.ShowFOV
        fovCircle.Position = UserInputService:GetMouseLocation() fovCircle.Radius = S.AimFOV
    end
    -- aimbot: runs right after the game's camera, so the turn sticks
    local meAlive = iAmAlive()
    if S.Aimbot and aimHeld() and meAlive then
        local f = 1 - math.clamp(S.Smoothness, 0, 0.95)
        local t, part = stickyTarget()
        if t then
            if S.AimMode == "Mouse" and mousemoverel then
                aimWithMouse(cam, part.Position, f)
            else
                cam.CFrame = cam.CFrame:Lerp(CFrame.lookAt(cam.CFrame.Position, part.Position), f)
            end
        else
            aim.lastCmd = nil
        end
    else
        aim.locked, aim.lastCmd = nil, nil
    end
    -- silent aim target
    silentPos = nil
    local silentT
    if S.SilentAim and meAlive then
        local t, part = bestTarget(targetsNow)
        if t then silentPos, silentT = part.Position, t end
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
            targetText.Text = ("TARGET  %s   %d HP   %dm"):format(t.name, math.floor(t.hum.Health + 0.5),
                math.floor((t.root.Position - cam.CFrame.Position).Magnitude))
            targetText.Position = Vector2.new(cam.ViewportSize.X / 2, 70) targetText.Visible = true
        end
    end
    pcall(stepTrigger, meAlive)
end)

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

-- targets / hitboxes refresh
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
        task.wait(1)   -- the game re-applies its map lighting each round, so keep it set
    end
end)
local espConn = RunService.RenderStepped:Connect(function()
    if alive then pcall(updateEsp, targetsNow) end
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
gui.Name = "CookiesHubArsenal" gui.ResetOnSpawn = false gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
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
    title.TextXAlignment = Enum.TextXAlignment.Left title.Text = "Cookies Hub  -  Arsenal" title.Parent = bar
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
local TAB_NAMES = { "Aim", "Visuals", "Hitbox", "Gun", "Player", "Info" }
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
            if i.UserInputType ~= Enum.UserInputType.Keyboard or i.KeyCode == Enum.KeyCode.Unknown or i.KeyCode.Name == "None" then return end
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
    ui.note(p, "Method (Camera = turns the camera, best; Mouse = moves your mouse):")
    ui.choice(p, "AimMode", { "Camera", "Mouse" })
    ui.slider(p, "Aim FOV (pixels)", "AimFOV", 20, 600, 5, "%d")
    ui.toggle(p, "Show FOV circle", "ShowFOV")
    ui.slider(p, "Smoothness", "Smoothness", 0, 0.95, 0.05, "%.2f")
    ui.toggle(p, "Wall check (only targets your shot can reach)", "WallCheck")
    ui.toggle(p, "Target info (line + name / HP on screen)", "TargetInfo")
    ui.keybind(p, "Aimbot on/off key", "AimbotToggleKey")
    ui.sec(p, "Silent aim")
    ui.toggle(p, "Silent aim (shots go to the target, no aim snap)", "SilentAim")
    ui.slider(p, "Hit chance (%)", "SilentHitChance", 1, 100, 1, "%d")
    ui.keybind(p, "Silent aim on/off key", "SilentToggleKey")
    ui.note(p, "Picks the enemy inside the FOV circle using the aim part, priority and wall check above. Just shoot anywhere near them.")
    ui.sec(p, "Trigger bot")
    ui.toggle(p, "Trigger bot (shoots when your crosshair is on an enemy)", "TriggerBot")
    ui.slider(p, "Trigger delay (s)", "TriggerDelay", 0, 0.5, 0.01, "%.2f")
    ui.keybind(p, "Trigger bot on/off key", "TriggerToggleKey")
    ui.note(p, "Holds fire while the crosshair is on an enemy (automatics keep firing), using the team check and wall rules below. Hide the hub first: with it open your mouse is free and clicks land on the menu.")
    ui.sec(p, "Targets")
    ui.toggle(p, "Team check (enemies only)", "TeamCheck")
    ui.toggle(p, "Ignore spawn-protected targets", "IgnoreProtected")
    ui.note(p, "Team check uses the game's own rule, so it is right in team modes, free-for-all and friendly fire.")
end
do -- Visuals
    local p = ui.tabs.Visuals
    ui.sec(p, "ESP")
    ui.toggle(p, "Player ESP", "ESP")
    ui.toggle(p, "Boxes", "ESPBoxes")
    ui.choice(p, "BoxStyle", { "Corners", "Full" })
    ui.toggle(p, "Skeleton", "Skeleton")
    ui.toggle(p, "Names", "ESPNames")
    ui.toggle(p, "Health bars (+ HP number when hurt)", "ESPHealth")
    ui.toggle(p, "Distance", "ESPDistance")
    ui.toggle(p, "Off-screen arrows", "Arrows")
    ui.toggle(p, "Green when your shot can reach them", "VisibleColors")
    ui.toggle(p, "Show teammates too (blue)", "ESPTeam")
    ui.slider(p, "Max distance (studs)", "ESPMaxDistance", 100, 3000, 50, "%d")
    ui.slider(p, "Text size", "ESPTextSize", 10, 20, 1, "%d")
    ui.sec(p, "Tracers")
    ui.toggle(p, "Tracers", "Tracers")
    ui.choice(p, "TracerFrom", { "Bottom", "Center", "Mouse" })
    ui.sec(p, "Chams")
    ui.toggle(p, "Chams (see bodies through walls)", "Chams")
    ui.slider(p, "Chams fill (0 = solid, 1 = outline only)", "ChamsFill", 0, 1, 0.05, "%.2f")
    ui.sec(p, "World")
    ui.toggle(p, "Full bright", "FullBright")
    ui.toggle(p, "No fog", "NoFog")
    ui.note(p, "Red = enemy, green = enemy your shot can reach right now, blue = teammate.")
    if not hasDrawing then ui.note(p, "Your executor has no Drawing library: boxes, names and tracers are unavailable, chams still work.") end
end
do -- Hitbox
    local p = ui.tabs.Hitbox
    ui.sec(p, "Hitbox changer")
    ui.toggle(p, "Bigger enemy hitboxes", "Hitbox")
    ui.choice(p, "HitboxPart", { "Head", "Body" })
    ui.slider(p, "Size (studs)", "HitboxSize", 2, 20, 0.5, "%.1f")
    ui.toggle(p, "Show hitboxes (see-through)", "HitboxVisible")
    ui.note(p, "Grows the game's own invisible hit parts (HeadHB = head, Hitbox = body) on enemies, following the team check. Head hits count as headshots. Everything is put back when you turn it off.")
end
do -- Gun
    local p = ui.tabs.Gun
    ui.sec(p, "Gun mods")
    ui.toggle(p, "No spread (every bullet goes dead centre)", "NoSpread")
    ui.toggle(p, "No recoil (no camera kick when firing)", "NoRecoil")
    ui.toggle(p, "Infinite ammo (magazine never empties)", "InfiniteAmmo")
    ui.toggle(p, "Full auto on every gun (hold to keep firing)", "FullAuto")
    ui.note(p, "Works on whatever gun you're given each kill. Turning a mod off puts the gun's own values back.")
    if not Spread then ui.note(p, "Couldn't find the game's spread module: no spread is unavailable.") end
    if not General then ui.note(p, "Couldn't find the game's ammo helper: infinite ammo is unavailable.") end
end
do -- Player
    local p = ui.tabs.Player
    ui.sec(p, "Movement")
    ui.toggle(p, "Speed multiplier", "SpeedOn")
    ui.slider(p, "Speed", "SpeedMult", 1, 3, 0.1, "%.1fx")
    ui.toggle(p, "Jump multiplier", "JumpOn")
    ui.slider(p, "Jump", "JumpMult", 1, 4, 0.1, "%.1fx")
    ui.toggle(p, "Low gravity", "GravityOn")
    ui.slider(p, "Gravity (lower = floatier)", "GravityMult", 0.1, 1, 0.05, "%.2fx")
    ui.toggle(p, "Infinite jump (jump again in mid-air)", "InfiniteJump")
    ui.toggle(p, "Noclip (walk through walls)", "Noclip")
    ui.toggle(p, "Fly (WASD + camera, Space up, Shift / Ctrl down)", "Fly")
    ui.slider(p, "Fly speed (studs/s)", "FlySpeed", 10, 150, 5, "%d")
    ui.keybind(p, "Fly on/off key", "FlyToggleKey")
    ui.note(p, "Speed and jump multiply the game's own values (sprinting, crouching and each weapon still change your speed). All off by default. Big values or noclip can get you kicked; small boosts are the least obvious.")
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
    ui.sec(p, "How it works")
    ui.note(p, "The aimbot locks on to the enemy nearest your crosshair inside the FOV circle while the aim key is held. Silent aim bends your own bullets at the target as the game fires them, so hits register like normal shots.")
    ui.sec(p, "Keys")
    ui.note(p, "RightShift shows/hides the hub. X unloads it and puts hitboxes and lighting back.")
    ui.sec(p, "Unload")
    -- Unload is defined further down, so go through the global
    ui.button(p, "Unload Cookies Hub (turns everything off)", C.danger, function()
        if _G.CookiesHubArsenal then _G.CookiesHubArsenal.Unload() end
    end)
end
ui.select("Aim")

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
    pcall(function() RunService:UnbindFromRenderStep("CookiesHubArsenal") end)
    if inputConn then inputConn:Disconnect() end
    for _, c in ipairs(ui.conns) do c:Disconnect() end
    espConn:Disconnect()
    triggerRelease()
    gunConn:Disconnect()
    moveConn:Disconnect()
    noclipConn:Disconnect()
    jumpConn:Disconnect()
    jumpReqConn:Disconnect()
    flyConn:Disconnect()
    idleConn:Disconnect()
    pcall(restoreMuls)
    pcall(restoreNoclip)
    S.FullAuto = false
    pcall(function()
        if modeForced and State.mode == "automatic" and not State.istouch then
            local auto = State.gun and State.gun:FindFirstChild("Auto")
            if not (auto and auto.Value == true) then State.mode = "semi" end
        end
    end)
    pcall(restoreRecoil)
    if Spread then Spread.calcspread = origCalcSpread end
    GF.cast = origCast
    if savedCam then pcall(function() camera().CFrame = savedCam end) savedCam = nil end
    S.FullBright, S.NoFog = false, false   -- in memory only, so the saved settings keep your choice
    pcall(applyLighting)
    if targetLine then pcall(function() targetLine:Remove() targetText:Remove() end) end
    for p in pairs(resized) do pcall(restorePart, p) end
    for m in pairs(esp) do pcall(dropEsp, m) end
    if fovCircle then pcall(function() fovCircle:Remove() end) end
    pcall(function() chamFolder:Destroy() end)
    pcall(function() gui:Destroy() end)
    _G.CookiesHubArsenal = nil
end
closeBtn.MouseButton1Click:Connect(Unload)
inputConn = UserInputService.InputBegan:Connect(function(i, gpe)
    if gpe or ui.capturing then return end
    -- Hotkeys are real keyboard keys only. A mouse click arrives with the key name "None", which is
    -- also what an unset hotkey is stored as, so every shot used to flip every unset toggle at once.
    if i.UserInputType ~= Enum.UserInputType.Keyboard then return end
    local name = i.KeyCode.Name
    if name == "None" or name == "Unknown" then return end
    if i.KeyCode == S.ToggleKey then main.Visible = not main.Visible end
    if name == S.AimbotToggleKey then
        S.Aimbot = not S.Aimbot saveSettings() if ui.renders.Aimbot then ui.renders.Aimbot() end
    end
    if name == S.SilentToggleKey then
        S.SilentAim = not S.SilentAim saveSettings() if ui.renders.SilentAim then ui.renders.SilentAim() end
    end
    if name == S.FlyToggleKey then
        S.Fly = not S.Fly saveSettings() if ui.renders.Fly then ui.renders.Fly() end
    end
    if name == S.TriggerToggleKey then
        S.TriggerBot = not S.TriggerBot saveSettings() if ui.renders.TriggerBot then ui.renders.TriggerBot() end
    end
end)

_G.CookiesHubArsenal = {
    Unload = Unload, State = S,
    Set = function(k, v)
        if S[k] == nil then return end
        S[k] = v saveSettings()
        if ui.renders[k] then pcall(ui.renders[k]) end   -- repainting can fail from a thread without UI access
    end,
    Get = function(k) return S[k] end,
    Targets = function() return targetsNow end,
    Status = function()   -- quick health check for bug reports
        local enemies = 0
        for _, t in ipairs(targetsNow) do if t.enemy then enemies = enemies + 1 end end
        return { alive = iAmAlive(), gun = State.gun and State.gun.Name, targets = #targetsNow, enemies = enemies,
            silentTarget = silentPos ~= nil, locked = aim.locked and aim.locked.name or nil, castHooked = GF.cast ~= origCast, bulletCasts = castStats.bullets, redirected = castStats.redirected, triggerHeld = triggerHeld }
    end,
}
print("[CookiesHub] Arsenal loaded.")

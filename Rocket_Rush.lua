-- Cookies Hub (Rocket Rush)
-- RightShift: show/hide menu | X button or _G.CookiesHub.Unload(): unload

if _G.CookiesHub and _G.CookiesHub.Unload then pcall(_G.CookiesHub.Unload) end
if _G.RocketHub and _G.RocketHub.Unload then pcall(_G.RocketHub.Unload) end
if _G.UnloadRocketHub then pcall(_G.UnloadRocketHub) end

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local Lighting     = game:GetService("Lighting")
local UIS          = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RS           = game:GetService("ReplicatedStorage")
local lp           = Players.LocalPlayer
local guiParent    = (gethui and gethui()) or game:GetService("CoreGui")

local MB1, TOUCH, MOVE = Enum.UserInputType.MouseButton1, Enum.UserInputType.Touch, Enum.UserInputType.MouseMovement

local Hub = { conns = {} }
_G.CookiesHub = Hub

local function bind(c) table.insert(Hub.conns, c) return c end

local function new(class, props)
    local inst = Instance.new(class)
    local parent = props.Parent
    props.Parent = nil
    for k, v in pairs(props) do inst[k] = v end
    inst.Parent = parent
    return inst
end

local function corner(p, r) return new("UICorner", { CornerRadius = UDim.new(0, r or 6), Parent = p }) end

local function tween(inst, props)
    TweenService:Create(inst, TweenInfo.new(0.15, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props):Play()
end

local function prop(tbl, key)
    return function() return tbl[key] end, function(v) tbl[key] = v end
end

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------
local Settings = {
    Fuel = true,
    NoCooldowns = false,
    InfStamina = false,
    NoLimits = false,
    Fullbright = false,
    TextSize = 13,
    TracerOrigin = "Bottom",
    TracerThickness = 1.5,
    ESP = {
        Players  = { Enabled = true, MaxDist = 5000,  Highlight = true,  Outline = true, Fill = 0.75, Name = true, Distance = true, Health = false, Box = false, Tracer = false, Color = Color3.fromRGB(0, 255, 140) },
        Missiles = { Enabled = true, MaxDist = 15000, Highlight = true,  Outline = true, Fill = 0.55, Name = true, Distance = true, Box = true,  Tracer = true,  Color = Color3.fromRGB(255, 70, 70) },
        Targets  = { Enabled = true, MaxDist = 2500,  Highlight = false, Outline = true, Fill = 0.7,  Name = true, Distance = true, Box = true,  Tracer = false, Color = Color3.fromRGB(255, 230, 60) },
        Turrets  = { Enabled = true, MaxDist = 3000,  Highlight = false, Outline = true, Fill = 0.6,  Name = true, Distance = true, Box = true,  Tracer = false, Shells = true, Color = Color3.fromRGB(255, 150, 50) },
        Gates    = { Enabled = true, MaxDist = 2500,  Highlight = false, Outline = true, Fill = 0.7,  Name = true, Distance = true, Box = true,  Tracer = false, Color = Color3.fromRGB(60, 200, 255) },
    },
}

----------------------------------------------------------------------
-- Game config overrides
----------------------------------------------------------------------
local Config do
    local ok, mod = pcall(require, RS:WaitForChild("MissileGame"):WaitForChild("Config"))
    if ok then Config = mod else warn("[CookiesHub] Config module not found") end
end

local COOLDOWN_KEYS = { "OverdriveCooldown", "TimeWarpCooldown", "RewindCooldown", "RewindCooldownMin", "ParachuteCooldown", "ShockwaveCooldown", "GrappleCooldown" }
local NO_LIMITS = {
    AltitudeLimitEnabled = false, CourseSideLimits = false,
    AltitudeKillTime = 1e9, LimitKillTime = 1e9,
    AltitudeKillMargin = 1e9, LimitKillMargin = 1e9, CeilingKillMargin = 1e9, CourseSideKillMargin = 1e9,
    AltitudePushMax = 0, LimitPushMax = 0, AltitudePushPerStud = 0, LimitPushPerStud = 0, CeilingPushPerStud = 0,
}
local TUNE_KEYS = {
    "OverdriveSpeedMult", "OverdriveThrustMult", "OverdriveDuration", "MiniRocketCharges", "ShieldMaxCharges",
    "GrappleRange", "TimeWarpDuration", "RewindMaxTime", "CamFov", "BoostFov", "OverdriveFov",
}

local Orig, Tune = {}, {}
if Config then
    local function snap(k) if Orig[k] == nil then Orig[k] = Config[k] end end
    for _, k in ipairs({ "UnlimitedFuel", "OverdriveMinFuel", "GrappleStaminaDrain", "GrappleStaminaMinToFire" }) do snap(k) end
    for _, k in ipairs(COOLDOWN_KEYS) do snap(k) end
    for k in pairs(NO_LIMITS) do snap(k) end
    for _, k in ipairs(TUNE_KEYS) do snap(k); Tune[k] = Orig[k] end
end

local function applyConfig()
    if not Config then return end
    for k, v in pairs(Orig) do Config[k] = v end
    for k, v in pairs(Tune) do Config[k] = v end
    if Settings.Fuel then
        Config.UnlimitedFuel = true
        Config.OverdriveMinFuel = 0
    end
    if Settings.NoCooldowns then
        for _, k in ipairs(COOLDOWN_KEYS) do Config[k] = 0.05 end
    end
    if Settings.InfStamina then
        Config.GrappleStaminaDrain = 0
        Config.GrappleStaminaMinToFire = 0
    end
    if Settings.NoLimits then
        for k, v in pairs(NO_LIMITS) do Config[k] = v end
    end
end

----------------------------------------------------------------------
-- Fullbright
----------------------------------------------------------------------
local Bright = {
    Ambient = Color3.fromRGB(180, 180, 180),
    OutdoorAmbient = Color3.fromRGB(180, 180, 180),
    Brightness = 2,
    ClockTime = 12,
    FogStart = 0,
    FogEnd = 1e9,
    GlobalShadows = false,
}
local lightSaved, fxSaved = nil, {}

local function setFullbright(on)
    if on then
        if not lightSaved then
            lightSaved = {}
            for k in pairs(Bright) do lightSaved[k] = Lighting[k] end
        end
        for _, v in ipairs(Lighting:GetChildren()) do
            if v:IsA("BloomEffect") or v:IsA("SunRaysEffect") or v:IsA("DepthOfFieldEffect") then
                if fxSaved[v] == nil then fxSaved[v] = { Enabled = v.Enabled } end
                v.Enabled = false
            elseif v:IsA("Atmosphere") then
                if fxSaved[v] == nil then fxSaved[v] = { Density = v.Density, Haze = v.Haze } end
                v.Density, v.Haze = 0, 0
            end
        end
    elseif lightSaved then
        for k, v in pairs(lightSaved) do Lighting[k] = v end
        for inst, props in pairs(fxSaved) do
            if inst.Parent then for k, v in pairs(props) do inst[k] = v end end
        end
        lightSaved, fxSaved = nil, {}
    end
end

bind(RunService.Heartbeat:Connect(function()
    if not Settings.Fullbright then return end
    for k, v in pairs(Bright) do
        if Lighting[k] ~= v then Lighting[k] = v end
    end
end))

----------------------------------------------------------------------
-- ESP
----------------------------------------------------------------------
local espGui   = new("ScreenGui", { Name = "CookiesHubESP", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 998, Parent = guiParent })
local hlFolder = new("Folder", { Name = "CookiesHubHL", Parent = guiParent })
local entries  = {}

local function newEntry(target, kind, name, opts)
    if entries[target] then return end
    opts = opts or {}
    local e = { target = target, kind = kind, name = name, player = opts.player, isShell = opts.isShell, refPart = opts.refPart }
    e.label = new("TextLabel", {
        BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.fromOffset(300, 40),
        Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.3, TextYAlignment = Enum.TextYAlignment.Bottom,
        Visible = false, Parent = espGui,
    })
    e.box = new("Frame", { BackgroundTransparency = 1, Visible = false, Parent = espGui })
    e.boxStroke = new("UIStroke", { Thickness = 1.5, Parent = e.box })
    e.tracer = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, Visible = false, Parent = espGui })
    entries[target] = e
end

local function removeEntry(target)
    local e = entries[target]
    if not e then return end
    entries[target] = nil
    if e.hl then e.hl:Destroy() end
    e.label:Destroy(); e.box:Destroy(); e.tracer:Destroy()
end

local function bounds(target)
    if target:IsA("BasePart") then return target.CFrame, target.Size end
    return target:GetBoundingBox()
end

local SIGNS = { -1, 1 }
local function project(camera, cf, size)
    local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for _, sx in ipairs(SIGNS) do
        for _, sy in ipairs(SIGNS) do
            for _, sz in ipairs(SIGNS) do
                local p = camera:WorldToViewportPoint(cf * Vector3.new(hx * sx, hy * sy, hz * sz))
                if p.Z <= 0 then return nil end
                minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
                minY, maxY = math.min(minY, p.Y), math.max(maxY, p.Y)
            end
        end
    end
    return minX, minY, maxX, maxY
end

local function drawLine(f, a, b, thickness, color)
    local d = b - a
    f.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
    f.Size = UDim2.fromOffset(d.Magnitude, thickness)
    f.Rotation = math.deg(math.atan2(d.Y, d.X))
    f.BackgroundColor3 = color
    f.Visible = true
end

bind(RunService.RenderStepped:Connect(function()
    local camera = workspace.CurrentCamera
    local camPos = camera.CFrame.Position
    local vp = camera.ViewportSize
    local origin
    if Settings.TracerOrigin == "Center" then
        origin = vp / 2
    elseif Settings.TracerOrigin == "Mouse" then
        origin = UIS:GetMouseLocation()
    else
        origin = Vector2.new(vp.X / 2, vp.Y)
    end

    for target, e in pairs(entries) do
        if not target.Parent then
            removeEntry(target)
            continue
        end
        local cfg = Settings.ESP[e.kind]
        local show = cfg.Enabled and not (e.isShell and not cfg.Shells)
        -- Destroyed targets/turrets stay in the folder with their parts hidden
        if show and e.refPart and (not e.refPart.Parent or e.refPart.Transparency >= 0.99) then show = false end
        local cf, size
        if show then
            local ok, a, b = pcall(bounds, target)
            if ok then cf, size = a, b else show = false end
        end
        local dist = show and (cf.Position - camPos).Magnitude or 0
        if dist > cfg.MaxDist then show = false end

        -- Highlights are created only while visible: Roblox caps how many can exist at once
        if show and cfg.Highlight then
            if not e.hl then
                e.hl = new("Highlight", { Adornee = target, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, Parent = hlFolder })
            end
            e.hl.FillColor = cfg.Color
            e.hl.OutlineColor = cfg.Color
            e.hl.FillTransparency = cfg.Fill
            e.hl.OutlineTransparency = cfg.Outline and 0 or 1
        elseif e.hl then
            e.hl:Destroy()
            e.hl = nil
        end

        local minX, minY, maxX, maxY
        if show then minX, minY, maxX, maxY = project(camera, cf, size) end
        local onScreen = minX ~= nil

        if onScreen and cfg.Box then
            e.box.Position = UDim2.fromOffset(minX, minY)
            e.box.Size = UDim2.fromOffset(maxX - minX, maxY - minY)
            e.boxStroke.Color = cfg.Color
            e.box.Visible = true
        else
            e.box.Visible = false
        end

        local text = {}
        if cfg.Name then text[#text + 1] = e.name end
        if cfg.Distance then text[#text + 1] = "[" .. math.floor(dist) .. "m]" end
        if cfg.Health and e.player then
            local hum = target:FindFirstChildOfClass("Humanoid")
            if hum then text[#text + 1] = math.floor(hum.Health) .. " HP" end
        end
        if onScreen and #text > 0 then
            e.label.Text = table.concat(text, " ")
            e.label.TextColor3 = cfg.Color
            e.label.TextSize = Settings.TextSize
            e.label.Position = UDim2.fromOffset((minX + maxX) / 2, minY - 2)
            e.label.Visible = true
        else
            e.label.Visible = false
        end

        if onScreen and cfg.Tracer then
            drawLine(e.tracer, origin, Vector2.new((minX + maxX) / 2, maxY), Settings.TracerThickness, cfg.Color)
        else
            e.tracer.Visible = false
        end
    end
end))

-- Players
local function watchPlayer(p)
    if p == lp then return end
    if p.Character then newEntry(p.Character, "Players", p.Name, { player = p }) end
    bind(p.CharacterAdded:Connect(function(c) newEntry(c, "Players", p.Name, { player = p }) end))
    bind(p.CharacterRemoving:Connect(removeEntry))
end
for _, p in ipairs(Players:GetPlayers()) do watchPlayer(p) end
bind(Players.PlayerAdded:Connect(watchPlayer))

-- World folders
local function findPath(path)
    local node = workspace
    for _, name in ipairs(path) do
        node = node:WaitForChild(name, 15)
        if not node then return nil end
    end
    return node
end

local function watchFolder(path, kind, makeEntry)
    task.spawn(function()
        local folder = findPath(path)
        if not folder or Hub.unloaded then return end
        local function add(child)
            local name, opts = makeEntry(child)
            if name then newEntry(child, kind, name, opts) end
        end
        for _, c in ipairs(folder:GetChildren()) do add(c) end
        bind(folder.ChildAdded:Connect(add))
        bind(folder.ChildRemoved:Connect(removeEntry))
    end)
end

local function refPartOf(m)
    if m:IsA("BasePart") then return m end
    return m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
end

local TARGET_NAMES = { TANK = "Tank", HelicopterTarget = "Helicopter", Helicopter2 = "Helicopter" }

watchFolder({ "MissileReplicas" }, "Missiles", function(m)
    if not m:IsA("Model") then return end
    local owner = (m.Name:gsub("_Missile$", ""))
    if owner ~= lp.Name then return owner end
end)
watchFolder({ "MissileGame", "Targets" }, "Targets", function(m)
    if not (m:IsA("Model") or m:IsA("BasePart")) then return end
    local name = TARGET_NAMES[m.Name] or m.Name
    local points = m:GetAttribute("Points")
    if points then name = name .. " (" .. points .. " pts)" end
    return name, { refPart = refPartOf(m) }
end)
watchFolder({ "MissileGame", "Anti_Aircraft" }, "Turrets", function(m)
    if m:IsA("Model") or m:IsA("BasePart") then return "AA Turret", { refPart = refPartOf(m) } end
end)
watchFolder({ "AAShells" }, "Turrets", function(m)
    if m:IsA("Model") or m:IsA("BasePart") then return "Shell", { isShell = true } end
end)
watchFolder({ "MissileGame", "Points_Boost", "Gates" }, "Gates", function(m)
    if m:IsA("Model") or m:IsA("BasePart") then return "Boost Gate" end
end)

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local Theme = {
    Bg     = Color3.fromRGB(16, 16, 22),
    Panel  = Color3.fromRGB(24, 24, 32),
    Row    = Color3.fromRGB(30, 30, 40),
    Off    = Color3.fromRGB(58, 58, 72),
    Accent = Color3.fromRGB(110, 125, 255),
    Text   = Color3.fromRGB(235, 235, 245),
    Sub    = Color3.fromRGB(145, 145, 165),
    Danger = Color3.fromRGB(215, 65, 80),
}
local Palette = {
    Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 150, 50), Color3.fromRGB(255, 230, 60),
    Color3.fromRGB(0, 255, 140), Color3.fromRGB(60, 200, 255), Color3.fromRGB(110, 125, 255),
    Color3.fromRGB(200, 90, 255), Color3.fromRGB(255, 255, 255),
}

local ui = new("ScreenGui", { Name = "CookiesHubUI", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999, Parent = guiParent })

local WIN_W, WIN_H = 540, 450
local win = new("Frame", {
    Size = UDim2.fromOffset(WIN_W, WIN_H), Position = UDim2.new(0.5, -WIN_W / 2, 0.5, -WIN_H / 2),
    BackgroundColor3 = Theme.Bg, BorderSizePixel = 0, ClipsDescendants = true, Parent = ui,
})
corner(win, 10)
new("UIStroke", { Color = Theme.Accent, Transparency = 0.55, Parent = win })

local top = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Parent = win })
new("Frame", { Size = UDim2.fromOffset(4, 16), Position = UDim2.fromOffset(14, 12), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = top })
new("TextLabel", {
    Text = "COOKIES HUB", Font = Enum.Font.GothamBlack, TextSize = 14, TextColor3 = Theme.Text,
    BackgroundTransparency = 1, Position = UDim2.fromOffset(26, 0), Size = UDim2.new(0, 200, 1, 0),
    TextXAlignment = Enum.TextXAlignment.Left, Parent = top,
})
new("TextLabel", {
    Text = "RShift to hide", Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Theme.Sub,
    BackgroundTransparency = 1, Position = UDim2.new(1, -200, 0, 0), Size = UDim2.new(0, 126, 1, 0),
    TextXAlignment = Enum.TextXAlignment.Right, Parent = top,
})

local function topButton(text, x, color)
    local b = new("TextButton", {
        Text = text, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Theme.Text, AutoButtonColor = false,
        Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, x, 0, 7), BackgroundColor3 = color, Parent = top,
    })
    corner(b, 6)
    return b
end
local minBtn   = topButton("–", -64, Theme.Row)
local closeBtn = topButton("×", -34, Theme.Danger)

local body = new("Frame", { Position = UDim2.fromOffset(0, 40), Size = UDim2.new(1, 0, 1, -40), BackgroundTransparency = 1, Parent = win })
local sidebar = new("Frame", { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0, 120, 1, -10), BackgroundColor3 = Theme.Panel, BorderSizePixel = 0, Parent = body })
corner(sidebar, 8)
new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder, Parent = sidebar })
new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = sidebar })
local pages = new("Frame", { Position = UDim2.fromOffset(140, 0), Size = UDim2.new(1, -150, 1, -10), BackgroundTransparency = 1, Parent = body })

local tabs, sideOrder, refreshers = {}, 0, {}

local function selectTab(sel)
    for _, t in ipairs(tabs) do
        local on = t == sel
        t.page.Visible = on
        tween(t.btn, { BackgroundColor3 = on and Theme.Accent or Theme.Panel })
        t.btn.TextColor3 = on and Theme.Text or Theme.Sub
    end
end

local function SideHeader(text)
    sideOrder += 1
    new("TextLabel", {
        Text = text, Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = Theme.Sub, BackgroundTransparency = 1,
        Size = UDim2.new(1, -6, 0, 20), Position = UDim2.fromOffset(6, 0), TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Bottom, LayoutOrder = sideOrder, Parent = sidebar,
    })
end

local function Tab(name)
    sideOrder += 1
    local btn = new("TextButton", {
        Text = name, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Theme.Sub, AutoButtonColor = false,
        Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = Theme.Panel, LayoutOrder = sideOrder, Parent = sidebar,
    })
    corner(btn, 6)
    local page = new("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false, Parent = pages,
    })
    new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
    new("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 6), Parent = page })
    local t = { btn = btn, page = page, order = 0 }
    btn.MouseButton1Click:Connect(function() selectTab(t) end)
    table.insert(tabs, t)
    return t
end

local function row(t, h)
    t.order += 1
    local r = new("Frame", { Size = UDim2.new(1, 0, 0, h or 34), BackgroundColor3 = Theme.Row, BorderSizePixel = 0, LayoutOrder = t.order, Parent = t.page })
    corner(r, 6)
    new("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.94, Parent = r })
    return r
end

local function rowLabel(r, text)
    return new("TextLabel", {
        Text = text, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = Theme.Text, BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 0, 34), TextXAlignment = Enum.TextXAlignment.Left, Parent = r,
    })
end

local function Section(t, text)
    t.order += 1
    new("TextLabel", {
        Text = text:upper(), Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = Theme.Accent, BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Bottom,
        LayoutOrder = t.order, Parent = t.page,
    })
end

local function Toggle(t, text, get, set, onChange)
    local r = row(t)
    rowLabel(r, text)
    local sw = new("Frame", { Size = UDim2.fromOffset(38, 20), Position = UDim2.new(1, -50, 0.5, -10), BackgroundColor3 = Theme.Off, Parent = r })
    corner(sw, 10)
    local knob = new("Frame", { Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = Color3.new(1, 1, 1), Parent = sw })
    corner(knob, 8)
    local hit = new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = r })
    local function render()
        local on = get()
        tween(sw, { BackgroundColor3 = on and Theme.Accent or Theme.Off })
        tween(knob, { Position = on and UDim2.fromOffset(20, 2) or UDim2.fromOffset(2, 2) })
    end
    hit.MouseButton1Click:Connect(function()
        set(not get())
        if onChange then onChange(get()) end
        render()
    end)
    render()
end

local function Slider(t, text, min, max, step, fmt, get, set)
    local r = row(t, 50)
    rowLabel(r, text)
    local value = new("TextLabel", {
        Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.Sub, BackgroundTransparency = 1,
        Position = UDim2.new(1, -112, 0, 0), Size = UDim2.fromOffset(100, 34), TextXAlignment = Enum.TextXAlignment.Right, Parent = r,
    })
    local bar = new("Frame", { Size = UDim2.new(1, -24, 0, 6), Position = UDim2.fromOffset(12, 34), BackgroundColor3 = Theme.Off, BorderSizePixel = 0, Parent = r })
    corner(bar, 3)
    local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = bar })
    corner(fill, 3)
    local hit = new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), Position = UDim2.new(0, 0, 0.5, -11), Parent = bar })
    local function render()
        local v = get()
        fill.Size = UDim2.fromScale(math.clamp((v - min) / (max - min), 0, 1), 1)
        value.Text = fmt(v)
    end
    local dragging = false
    local function update(x)
        local a = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        set(math.clamp(math.floor((min + a * (max - min)) / step + 0.5) * step, min, max))
        render()
    end
    hit.InputBegan:Connect(function(i)
        if i.UserInputType == MB1 or i.UserInputType == TOUCH then dragging = true; update(i.Position.X) end
    end)
    bind(UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == MOVE or i.UserInputType == TOUCH) then update(i.Position.X) end
    end))
    bind(UIS.InputEnded:Connect(function(i)
        if i.UserInputType == MB1 or i.UserInputType == TOUCH then dragging = false end
    end))
    render()
    table.insert(refreshers, render)
end

local function ColorPicker(t, text, get, set)
    local r = row(t)
    rowLabel(r, text)
    local w = #Palette * 20
    local holder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(w, 16), Position = UDim2.new(1, -w - 8, 0.5, -8), Parent = r })
    new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), Parent = holder })
    local swatches = {}
    local function render()
        for _, s in ipairs(swatches) do s.stroke.Enabled = s.color == get() end
    end
    for i, c in ipairs(Palette) do
        local b = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(16, 16), BackgroundColor3 = c, LayoutOrder = i, Parent = holder })
        corner(b, 8)
        table.insert(swatches, { color = c, stroke = new("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2, Parent = b }) })
        b.MouseButton1Click:Connect(function() set(c); render() end)
    end
    render()
end

local function Cycle(t, text, options, get, set)
    local r = row(t)
    rowLabel(r, text)
    local b = new("TextButton", {
        Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Theme.Text, AutoButtonColor = false,
        Size = UDim2.fromOffset(90, 22), Position = UDim2.new(1, -100, 0.5, -11), BackgroundColor3 = Theme.Off, Parent = r,
    })
    corner(b, 6)
    b.Text = get()
    b.MouseButton1Click:Connect(function()
        local idx = table.find(options, get()) or 0
        set(options[idx % #options + 1])
        b.Text = get()
    end)
end

local function Button(t, text, color, cb)
    t.order += 1
    local b = new("TextButton", {
        Text = text, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Theme.Text, AutoButtonColor = true,
        Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = color, LayoutOrder = t.order, Parent = t.page,
    })
    corner(b, 6)
    b.MouseButton1Click:Connect(cb)
end

local function Note(t, text)
    t.order += 1
    new("TextLabel", {
        Text = text, Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = Theme.Sub, BackgroundTransparency = 1, TextWrapped = true,
        Size = UDim2.new(1, 0, 0, 28), TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = t.order, Parent = t.page,
    })
end

-- Formatters
local pct   = function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
local mult  = function(v) return string.format("%.2fx", v) end
local secs  = function(v) return string.format("%.1fs", v) end
local int   = function(v) return tostring(math.floor(v + 0.5)) end
local deg   = function(v) return math.floor(v + 0.5) .. "°" end
local studs = function(v) return math.floor(v + 0.5) .. " studs" end

local function FlagToggle(t, text, key, onChange)
    Toggle(t, text, function() return Settings[key] end, function(v) Settings[key] = v end, onChange or applyConfig)
end

local function TuneSlider(t, text, key, min, max, step, fmt)
    if Tune[key] == nil then return end
    Slider(t, text, min, max, step, fmt, function() return Tune[key] end, function(v) Tune[key] = v; applyConfig() end)
end

local function buildEspPage(t, cfg, extra)
    Section(t, "General")
    Toggle(t, "Enabled", prop(cfg, "Enabled"))
    Slider(t, "Max distance", 100, 20000, 100, studs, prop(cfg, "MaxDist"))
    Section(t, "Chams")
    Toggle(t, "Highlight", prop(cfg, "Highlight"))
    Toggle(t, "Outline", prop(cfg, "Outline"))
    Slider(t, "Fill transparency", 0, 1, 0.05, pct, prop(cfg, "Fill"))
    Section(t, "Overlay")
    Toggle(t, "Name", prop(cfg, "Name"))
    Toggle(t, "Distance", prop(cfg, "Distance"))
    if extra == "player" then Toggle(t, "Health", prop(cfg, "Health")) end
    if extra == "turret" then Toggle(t, "Show AA shells", prop(cfg, "Shells")) end
    Toggle(t, "Box", prop(cfg, "Box"))
    Toggle(t, "Tracer", prop(cfg, "Tracer"))
    Section(t, "Color")
    ColorPicker(t, "Color", prop(cfg, "Color"))
end

----------------------------------------------------------------------
-- Pages
----------------------------------------------------------------------
SideHeader("MAIN")

local rocketTab = Tab("Rocket")
Section(rocketTab, "Fuel")
FlagToggle(rocketTab, "Unlimited fuel", "Fuel")
Section(rocketTab, "Overdrive")
TuneSlider(rocketTab, "Speed multiplier", "OverdriveSpeedMult", 1, 5, 0.05, mult)
TuneSlider(rocketTab, "Thrust multiplier", "OverdriveThrustMult", 1, 8, 0.1, mult)
TuneSlider(rocketTab, "Duration", "OverdriveDuration", 1, 30, 0.5, secs)
Section(rocketTab, "Charges")
TuneSlider(rocketTab, "Mini-rockets", "MiniRocketCharges", 1, 20, 1, int)
TuneSlider(rocketTab, "Shields", "ShieldMaxCharges", 1, 20, 1, int)

local abilityTab = Tab("Abilities")
Section(abilityTab, "Cooldowns")
FlagToggle(abilityTab, "No cooldowns", "NoCooldowns")
Note(abilityTab, "Overdrive, Time Warp, Rewind, Parachute, Shockwave, Grapple")
Section(abilityTab, "Grapple")
FlagToggle(abilityTab, "Infinite stamina", "InfStamina")
TuneSlider(abilityTab, "Range", "GrappleRange", 100, 2000, 10, studs)
Section(abilityTab, "Time")
TuneSlider(abilityTab, "Time Warp duration", "TimeWarpDuration", 5, 60, 1, secs)
TuneSlider(abilityTab, "Rewind length", "RewindMaxTime", 2, 15, 0.5, secs)

local worldTab = Tab("World")
Section(worldTab, "Map")
FlagToggle(worldTab, "No map limits", "NoLimits")
Note(worldTab, "Removes altitude ceiling, side walls and out-of-bounds kill timers")
Section(worldTab, "Lighting")
FlagToggle(worldTab, "Fullbright", "Fullbright", setFullbright)
Section(worldTab, "Camera")
TuneSlider(worldTab, "FOV", "CamFov", 50, 120, 1, deg)
TuneSlider(worldTab, "Boost FOV", "BoostFov", 50, 130, 1, deg)
TuneSlider(worldTab, "Overdrive FOV", "OverdriveFov", 60, 140, 1, deg)

SideHeader("ESP")
buildEspPage(Tab("Players"), Settings.ESP.Players, "player")
buildEspPage(Tab("Missiles"), Settings.ESP.Missiles)
buildEspPage(Tab("Targets"), Settings.ESP.Targets)
buildEspPage(Tab("Turrets"), Settings.ESP.Turrets, "turret")
buildEspPage(Tab("Gates"), Settings.ESP.Gates)

SideHeader("OTHER")
local setTab = Tab("Settings")
Section(setTab, "ESP")
Slider(setTab, "Text size", 8, 24, 1, int, prop(Settings, "TextSize"))
Slider(setTab, "Tracer thickness", 1, 5, 0.5, tostring, prop(Settings, "TracerThickness"))
Cycle(setTab, "Tracer origin", { "Bottom", "Center", "Mouse" }, prop(Settings, "TracerOrigin"))
Note(setTab, "Roblox renders about 31 highlights at once; boxes and labels have no limit.")
Section(setTab, "Script")
Button(setTab, "Reset tuning sliders", Theme.Row, function()
    for k, v in pairs(Orig) do if Tune[k] ~= nil then Tune[k] = v end end
    applyConfig()
    for _, r in ipairs(refreshers) do r() end
end)
Button(setTab, "Unload", Theme.Danger, function() Hub.Unload() end)

selectTab(rocketTab)

-- Drag
do
    local dragging, dragStart, startPos
    top.InputBegan:Connect(function(i)
        if i.UserInputType == MB1 or i.UserInputType == TOUCH then
            dragging, dragStart, startPos = true, i.Position, win.Position
        end
    end)
    bind(UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == MOVE or i.UserInputType == TOUCH) then
            local d = i.Position - dragStart
            win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    bind(UIS.InputEnded:Connect(function(i)
        if i.UserInputType == MB1 or i.UserInputType == TOUCH then dragging = false end
    end))
end

local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    tween(win, { Size = UDim2.fromOffset(WIN_W, minimized and 40 or WIN_H) })
end)
closeBtn.MouseButton1Click:Connect(function() Hub.Unload() end)

bind(UIS.InputBegan:Connect(function(i, processed)
    if not processed and i.KeyCode == Enum.KeyCode.RightShift then ui.Enabled = not ui.Enabled end
end))

----------------------------------------------------------------------
-- Unload
----------------------------------------------------------------------
function Hub.Unload()
    if Hub.unloaded then return end
    Hub.unloaded = true
    for _, c in ipairs(Hub.conns) do pcall(function() c:Disconnect() end) end
    for target in pairs(entries) do removeEntry(target) end
    Settings.Fullbright = false
    setFullbright(false)
    if Config then for k, v in pairs(Orig) do Config[k] = v end end
    ui:Destroy()
    espGui:Destroy()
    hlFolder:Destroy()
    if _G.CookiesHub == Hub then _G.CookiesHub = nil end
    print("[CookiesHub] Unloaded.")
end

applyConfig()
setFullbright(Settings.Fullbright)
print("[CookiesHub] Loaded. RightShift to hide.")

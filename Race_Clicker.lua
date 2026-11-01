-- Cookies Hub (Race Clicker)  [KEYLESS]
-- RightShift: show/hide | X button or _G.CookiesHubRaceClicker.Unload(): unload
-- Console: _G.CookiesHubRaceClicker.Set("AutoClick", true)
--
-- Read from Race Clicker (place 9285238704, Knit):
--  * Rounds: "Clicking" phase (clicks build your speed) -> "Race" phase (the game's RaceSteering runs you down
--    the track along -X by itself). Phase = Knit.ReplicaInterface:GetReplicas("Race")[1].Data.State.
--  * Clicks: ClickService.RF.Click (only counts while State == "Clicking").
--  * Wins: CharacterController reports RaceService:ReachedCheckpoint(Stage, i) once your X passes
--    TrackData:GetCheckpointWinXPositions()[World][Stage][i] (negated). The track starts at X = -70.
--  * RebirthService.RF.Rebirth() / Upgrade(name in RebirthData.RebirthShop).
--  * Eggs: workspace.LoadedWorld.WorldMain.EggMachines.<EggName>.Root (prompt range 15).
--    EggService.RF.Open(eggName, "1" | "3", deleteSet {[petName]=true}, nil).
--  * PetsService.RF.EquipBest() / CraftAll(). PlaytimeGiftsService.RF.Claim(i). DailyRewardService.RF.Claim()
--    (group chest). FreePetService.RF.Claim(). SpinWheelService.RF.SpinUIWheel() (Data.SpinWheels.Home.Spins).
--  * AFKController fires RaceService.RE.stopRaceRequest when you go idle, which stops your race.
-- Save this file as UTF-8 WITHOUT a BOM or it won't load.

if _G.CookiesHubRaceClicker and _G.CookiesHubRaceClicker.Unload then pcall(_G.CookiesHubRaceClicker.Unload) end

local Players          = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local Workspace        = game:GetService("Workspace")
local lp               = Players.LocalPlayer

-- ---------- guard ----------
if not game:IsLoaded() then game.Loaded:Wait() end
local Packages = RS:WaitForChild("Packages", 15)
local KnitFolder = Packages and Packages:FindFirstChild("Knit")
local ServicesFolder = KnitFolder and KnitFolder:WaitForChild("Services", 15)
if not (ServicesFolder and ServicesFolder:FindFirstChild("ClickService")) then
    warn("[CookiesHub RaceClicker] Not Race Clicker (missing Knit ClickService). Aborting.")
    return
end
local alive = true   -- cleared on Unload so every loop exits

-- ---------- settings (per account) ----------
local S = {
    -- farm
    AutoClick       = false,
    ClicksPerSecond = 30,      -- 30 = the most the server counts
    ClickMax        = false,   -- send just over the server's cap so every countable click counts
    ClickEffects    = true,    -- the game's "+N" popups for clicks that counted
    SpeedMultOn     = false,   -- multiply the race speed the game sets
    SpeedMult       = 2,
    AutoRebirth     = false,
    AutoRebirthShop = false,
    InstantWin      = false,   -- moves you through the checkpoints during a race
    WinStepDelay    = 0.35,    -- seconds between checkpoint jumps
    BlockAFKStop    = true,    -- the game's AFK check can't stop your race
    -- pets
    AutoHatch       = false,
    HatchEgg        = "Starter01",
    HatchAmount     = "1",     -- 1 | 3 (3 needs the X3 Hatch pass / rebirth upgrade)
    AutoEquipBest   = false,
    AutoCraftAll    = false,
    -- rewards
    AutoPlaytime    = false,
    AutoDailyChest  = false,
    AutoFreePet     = false,
    AutoSpin        = false,
    -- player
    WalkSpeedOn     = false,
    WalkSpeed       = 32,
    JumpOn          = false,
    JumpPower       = 60,
    AntiAFK         = true,
    ToggleKey       = Enum.KeyCode.RightShift,
}
local SETTINGS_FILE = ("CookiesHubRaceClicker_%d_settings.json"):format(lp.UserId)
pcall(function()
    for k, v in pairs(HttpService:JSONDecode(readfile(SETTINGS_FILE))) do
        if S[k] ~= nil and type(S[k]) == type(v) then S[k] = v end
    end
end)
S.ClicksPerSecond = math.clamp(S.ClicksPerSecond, 1, 30)   -- older saves allowed up to 500
local function saveSettings()
    local out = {}
    for k, v in pairs(S) do if type(v) ~= "userdata" then out[k] = v end end
    pcall(function() writefile(SETTINGS_FILE, HttpService:JSONEncode(out)) end)
end

-- ---------- game access ----------
-- server calls go straight to Knit's RemoteFunctions: Services.<Service>.RF.<Method>
local function remote(service, method, kind)
    local s = ServicesFolder:FindFirstChild(service)
    local f = s and s:FindFirstChild(kind or "RF")
    return f and f:FindFirstChild(method)
end
local function invoke(service, method, ...)
    local rf = remote(service, method)
    if not rf then return false, "missing " .. service .. "." .. method end
    return pcall(rf.InvokeServer, rf, ...)
end

-- replicas (player data + round state) through the game's own Knit, if this executor shares its require cache
local Knit
pcall(function() Knit = require(KnitFolder) end)
local function playerData()
    local ok, rep = pcall(function() return Knit.GetController("DataController"):GetReplica() end)
    return ok and rep and rep.Data or nil
end
local function raceState()
    local ok, st = pcall(function()
        local r = Knit.ReplicaInterface:GetReplicas("Race")[1]
        return r and r.Data.State
    end)
    if ok and type(st) == "string" then return st end
end

local TrackData
pcall(function() TrackData = require(RS.Shared.Modules.TrackData) end)
local FORCE_X = TrackData and TrackData.FORCE_RACE_START_X or -70

local function myChar() return lp.Character end
local function myRoot() local c = myChar() return c and c:FindFirstChild("HumanoidRootPart") end
local function myHum()
    local c = myChar()
    local h = c and c:FindFirstChildOfClass("Humanoid")
    if h and h.Health > 0 then return h end
end
-- racing = the round is in Race and you're past the start line (the game uses the same test)
local function onTrack()
    local root = myRoot()
    return root ~= nil and root.Position.X <= FORCE_X
end
local function isRacing()
    local st = raceState()
    if st then return st == "Race" and onTrack() end
    return onTrack()
end
local function inLobby()
    return not onTrack() and not lp:GetAttribute("InSeat")
end

-- ---------- stats readout ----------
-- leaderstats are StringValues with an emoji in front ("🏁Wins", "😇Rebirths"), already formatted by the game
local function leaderstat(name)
    local ls = lp:FindFirstChild("leaderstats")
    for _, v in ipairs(ls and ls:GetChildren() or {}) do
        if v.Name:sub(-#name) == name then return tostring(v.Value) end
    end
    return "-"
end
local function short(n)
    n = tonumber(n)
    if not n then return "-" end
    local units = { "", "K", "M", "B", "T", "Qd", "Qn", "Sx", "Sp", "Oc" }
    local i = 1
    while math.abs(n) >= 1000 and i < #units do n = n / 1000 i = i + 1 end
    return (i == 1 and "%d%s" or "%.2f%s"):format(n, units[i])
end

-- ---------- auto click ----------
-- Measured live: the server counts about 30 clicks per second per player and answers the rest with nil
-- (20/s -> all counted, 70/s -> ~29/s counted, a 2,300/s flood -> still ~30/s). So "max" is just over the cap:
-- sending thousands only lags you. Clicks are spread evenly over the frames.
local MAX_RATE = 70
local clicksSent, clicksCounted, inFlight, clickAcc = 0, 0, 0, 0
local clickRF = remote("ClickService", "Click")
local clickController
pcall(function() clickController = Knit.GetController("ClickController") end)
local function sendClick()
    inFlight = inFlight + 1
    clicksSent = clicksSent + 1
    task.spawn(function()
        local ok, amount = pcall(clickRF.InvokeServer, clickRF)
        inFlight = inFlight - 1
        if ok and amount ~= nil then
            clicksCounted = clicksCounted + 1
            if S.ClickEffects and clickController then pcall(clickController.DoClickEffect, clickController, amount, true) end
        end
    end)
end
local clickConn = RunService.Heartbeat:Connect(function(dt)
    if not (alive and S.AutoClick and clickRF) then clickAcc = 0 return end
    local st = raceState()
    if st and st ~= "Clicking" then clickAcc = 0 return end
    local rate = S.ClickMax and MAX_RATE or S.ClicksPerSecond
    clickAcc = math.min(clickAcc + dt * rate, rate)
    local n = math.floor(clickAcc)
    clickAcc = clickAcc - n
    for _ = 1, n do
        if inFlight >= 40 then break end
        sendClick()
    end
end)

-- ---------- race speed multiplier ----------
-- During a race CharacterController sets Humanoid.WalkSpeed from your ServerWalkSpeed every frame, and its
-- steering clamps your velocity to WalkSpeed. Multiplying the value it writes speeds up the game's own race motion.
local speedHum   -- your humanoid, cached so the hook stays cheap
local oldNewindex
pcall(function()
    oldNewindex = hookmetamethod(game, "__newindex", newcclosure(function(self, key, value)
        if alive and S.SpeedMultOn and key == "WalkSpeed" and self == speedHum and type(value) == "number"
           and not checkcaller() then
            return oldNewindex(self, key, value * S.SpeedMult)
        end
        return oldNewindex(self, key, value)
    end))
end)

-- ---------- instant win: step through the checkpoints during the race ----------
-- The game counts a checkpoint once your X passes it and reports it itself (ReachedCheckpoint); we only move you.
local function checkpointXs()
    local d = playerData()
    if not (TrackData and d and d.World and d.NonPersistent) then return end
    local ok, all = pcall(function() return TrackData:GetCheckpointWinXPositions() end)
    local list = ok and all[d.World] and all[d.World][d.NonPersistent.Stage]
    return list
end
task.spawn(function()
    while alive do
        if S.InstantWin and isRacing() then
            local list = checkpointXs()
            local root = myRoot()
            if list and root then
                for _, x in ipairs(list) do
                    if not (alive and S.InstantWin and isRacing()) then break end
                    root = myRoot()
                    if not root then break end
                    local target = -x - 4
                    if root.Position.X > target then
                        root.CFrame = CFrame.new(target, root.Position.Y, root.Position.Z) * root.CFrame.Rotation
                        root.AssemblyLinearVelocity = Vector3.new(-50, 0, 0)
                        task.wait(S.WinStepDelay)
                    end
                end
            end
            task.wait(0.5)
        else
            task.wait(0.5)
        end
    end
end)

-- block the AFK controller's "stop my race" request
local oldNamecall
pcall(function()
    local stopRE = remote("RaceService", "stopRaceRequest", "RE")
    if not stopRE then return end
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if alive and S.BlockAFKStop and self == stopRE and not checkcaller() and getnamecallmethod() == "FireServer" then
            return nil
        end
        return oldNamecall(self, ...)
    end))
end)

-- ---------- rebirth ----------
local rebirthNames = {}
pcall(function()
    local data = require(RS.Shared.Modules.RebirthData)
    for name in pairs(data.RebirthShop or {}) do rebirthNames[#rebirthNames + 1] = name end
    table.sort(rebirthNames)
end)
task.spawn(function()
    while alive do
        if S.AutoRebirth then invoke("RebirthService", "Rebirth") end
        task.wait(2)
    end
end)
task.spawn(function()
    while alive do
        if S.AutoRebirthShop then
            for _, name in ipairs(rebirthNames) do
                if not (alive and S.AutoRebirthShop) then break end
                invoke("RebirthService", "Upgrade", name)
                task.wait(0.3)
            end
        end
        task.wait(8)
    end
end)

-- ---------- eggs / pets ----------
local function eggMachines()
    local world = Workspace:FindFirstChild("LoadedWorld")
    local main = world and world:FindFirstChild("WorldMain")
    return main and main:FindFirstChild("EggMachines")
end
local function eggNames()
    local list = {}
    local f = eggMachines()
    for _, m in ipairs(f and f:GetChildren() or {}) do
        if m:IsA("Model") and m:FindFirstChild("Root") and not m.Name:find("Robux") then list[#list + 1] = m.Name end
    end
    table.sort(list)
    return list
end
local hatched, lastHatchMsg = 0, "-"
task.spawn(function()
    while alive do
        if S.AutoHatch and inLobby() and myHum() then
            local f = eggMachines()
            local egg = f and f:FindFirstChild(S.HatchEgg)
            local eggRoot = egg and egg:FindFirstChild("Root")
            local root = myRoot()
            if eggRoot and root then
                -- stand next to the egg (the game's prompt range is 15 studs), open, step back
                local back = root.CFrame
                local far = (root.Position - eggRoot.Position).Magnitude > 10
                if far then root.CFrame = eggRoot.CFrame * CFrame.new(0, 0, -6) task.wait(0.25) end
                local ok, success, msg = invoke("EggService", "Open", S.HatchEgg, S.HatchAmount, {}, nil)
                if ok and success then
                    hatched = hatched + (tonumber(S.HatchAmount) or 1)
                    lastHatchMsg = "ok"
                else
                    lastHatchMsg = tostring(msg or success or "failed")
                end
                if far and myRoot() and inLobby() then myRoot().CFrame = back end
                task.wait(ok and success and 1.2 or 3)
            else
                lastHatchMsg = "egg not in this world: " .. tostring(S.HatchEgg)
                task.wait(2)
            end
        else
            task.wait(0.5)
        end
    end
end)
task.spawn(function()
    while alive do
        if S.AutoCraftAll then invoke("PetsService", "CraftAll") task.wait(1) end
        if S.AutoEquipBest then invoke("PetsService", "EquipBest") end
        task.wait(15)
    end
end)

-- ---------- rewards ----------
local giftCount = 12
pcall(function()
    local d = require(RS.Shared.Modules.PlaytimeGiftsData)
    local n = 0
    for _ in pairs(d.Gifts or d.Rewards or d) do n = n + 1 end
    if n > 0 then giftCount = math.min(n, 30) end
end)
task.spawn(function()
    while alive do
        if S.AutoPlaytime then
            for i = 1, giftCount do
                if not (alive and S.AutoPlaytime) then break end
                invoke("PlaytimeGiftsService", "Claim", i)
                task.wait(0.2)
            end
        end
        if S.AutoDailyChest then invoke("DailyRewardService", "Claim") end
        if S.AutoFreePet then invoke("FreePetService", "Claim") end
        task.wait(30)
    end
end)
task.spawn(function()
    while alive do
        if S.AutoSpin then
            local d = playerData()
            local spins = d and d.SpinWheels and d.SpinWheels.Home and d.SpinWheels.Home.Spins
            if spins == nil or spins > 0 then
                invoke("SpinWheelService", "SpinUIWheel")
                task.wait(spins and 4 or 30)
            else
                task.wait(10)
            end
        else
            task.wait(1)
        end
    end
end)

-- ---------- player: walk speed / jump (lobby only, the race sets its own speed) ----------
local savedMove
local function setJump(h, power)
    if h.UseJumpPower then h.JumpPower = power else h.JumpHeight = power * power / (2 * Workspace.Gravity) end
end
local moveConn = RunService.Heartbeat:Connect(function()
    local h = myHum()
    speedHum = h
    if not h then return end
    local want = (S.WalkSpeedOn or S.JumpOn) and not onTrack()
    if want and not savedMove then
        savedMove = { walk = h.WalkSpeed, jumpPower = h.JumpPower, jumpHeight = h.JumpHeight, hum = h }
    end
    if want then
        if S.WalkSpeedOn then h.WalkSpeed = S.WalkSpeed end
        if S.JumpOn then setJump(h, S.JumpPower) end
    elseif savedMove then
        if savedMove.hum == h and not onTrack() then
            h.WalkSpeed = savedMove.walk
            h.JumpPower = savedMove.jumpPower h.JumpHeight = savedMove.jumpHeight
        end
        savedMove = nil
    end
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
gui.Name = "CookiesHubRaceClicker" gui.ResetOnSpawn = false gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
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
    title.TextXAlignment = Enum.TextXAlignment.Left title.Text = "Cookies Hub  -  Race Clicker" title.Parent = bar
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
local TAB_NAMES = { "Farm", "Pets", "Rewards", "Player", "Info" }
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
-- a button that cycles a string setting through a list that can change (e.g. the eggs in the current world)
function ui.cycle(parent, label, key, getOptions)
    local b = ui.button(parent, "", C.row, function() end)
    local function render() b.Text = label .. ":  " .. tostring(S[key]) .. "   (click to change)" end
    b.MouseButton1Click:Connect(function()
        local opts = getOptions()
        if #opts == 0 then return end
        local i = table.find(opts, S[key]) or 0
        S[key] = opts[i % #opts + 1] saveSettings() render()
    end)
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
    ui.sec(p, "Clicking")
    ui.toggle(p, "Auto click (builds speed every round)", "AutoClick")
    ui.slider(p, "Clicks per second (30 = server max)", "ClicksPerSecond", 1, 30, 1, "%d")
    ui.toggle(p, "MAX click mode (fastest the server allows)", "ClickMax")
    ui.toggle(p, "Show click popups", "ClickEffects")
    ui.note(p, "The server only counts about 30 clicks per second - extra clicks are thrown away, so MAX already gets you the most speed possible. Clicks only count in the clicking phase (not during the race or intermission), so the hub waits for it.")
    ui.sec(p, "Speed")
    ui.toggle(p, "Race speed multiplier", "SpeedMultOn")
    ui.slider(p, "Multiplier", "SpeedMult", 1, 10, 0.25, "%.2fx")
    ui.note(p, "Multiplies the speed the game gives you during a race, so you cover more track (= more wins) per race. The server may check your speed; start low.")
    ui.sec(p, "Racing")
    ui.toggle(p, "Instant win (jumps you through every checkpoint)", "InstantWin")
    ui.slider(p, "Delay between checkpoint jumps (s)", "WinStepDelay", 0.1, 2, 0.05, "%.2f")
    ui.toggle(p, "Stop the AFK check ending your race", "BlockAFKStop")
    ui.note(p, "The race runs by itself. Instant win moves you forward during the race and the game pays the checkpoints like normal. If wins stop counting, raise the delay or turn it off.")
    ui.sec(p, "Rebirth")
    ui.toggle(p, "Auto rebirth (as soon as you can afford it)", "AutoRebirth")
    ui.toggle(p, "Auto buy rebirth shop upgrades", "AutoRebirthShop")
    ui.sec(p, "Stats")
    ui.stats = ui.note(p, "-")
end
do -- Pets
    local p = ui.tabs.Pets
    ui.sec(p, "Auto hatch")
    ui.toggle(p, "Auto hatch", "AutoHatch")
    ui.cycle(p, "Egg", "HatchEgg", eggNames)
    ui.note(p, "Hatch amount:")
    ui.choice(p, "HatchAmount", { "1", "3" })
    ui.note(p, "Hatches in the lobby only (it walks you to the egg and back). x3 needs the X3 Hatch pass or rebirth upgrade. The egg list follows the world you're in.")
    ui.hatch = ui.note(p, "Hatched: 0")
    ui.sec(p, "Pet management")
    ui.toggle(p, "Auto equip best (every 15 s)", "AutoEquipBest")
    ui.toggle(p, "Auto craft all (every 15 s)", "AutoCraftAll")
    ui.button(p, "Equip best now", nil, function() invoke("PetsService", "EquipBest") end)
    ui.button(p, "Craft all now", nil, function() invoke("PetsService", "CraftAll") end)
end
do -- Rewards
    local p = ui.tabs.Rewards
    ui.sec(p, "Auto claim")
    ui.toggle(p, "Playtime gifts", "AutoPlaytime")
    ui.toggle(p, "Daily group chest (you must be in the group)", "AutoDailyChest")
    ui.toggle(p, "Free pet", "AutoFreePet")
    ui.toggle(p, "Spin the wheel when you have spins", "AutoSpin")
    ui.note(p, "Checked every 30 seconds; anything not ready yet is just skipped.")
    ui.sec(p, "Codes")
    ui.input(p, "type a code", "Redeem", function(code, btn)
        code = (code or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if code == "" then return end
        local ok, a, b = invoke("CodesService", "Redeem", code)
        btn.Text = (ok and (a or b == nil)) and "Redeemed!" or "Failed"
        task.delay(2, function() if btn.Parent then btn.Text = "Redeem" end end)
    end)
end
do -- Player
    local p = ui.tabs.Player
    ui.sec(p, "Movement (lobby)")
    ui.toggle(p, "Walk speed", "WalkSpeedOn")
    ui.slider(p, "Speed", "WalkSpeed", 16, 150, 1, "%d")
    ui.toggle(p, "Jump power", "JumpOn")
    ui.slider(p, "Jump", "JumpPower", 50, 200, 5, "%d")
    ui.note(p, "Only applied in the lobby; during a race the game controls your speed.")
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
    ui.note(p, "Every round has a clicking phase (clicks = speed) and a race (you run by yourself; distance = wins). Turn on Auto click + Auto rebirth and leave it running. Everything calls the game's own server functions.")
    ui.sec(p, "Status")
    ui.status = ui.note(p, "-")
    ui.sec(p, "Keys")
    ui.note(p, "RightShift shows/hides the hub. X unloads it.")
    ui.sec(p, "Unload")
    ui.button(p, "Unload Cookies Hub (turns everything off)", C.danger, function()
        if _G.CookiesHubRaceClicker then _G.CookiesHubRaceClicker.Unload() end
    end)
end
ui.select("Farm")

-- live readouts
task.spawn(function()
    while alive do
        pcall(function()
            ui.stats.Text = ("Wins: %s   Rebirths: %s   Top speed: %s\nClicks counted: %s / sent %s\nPhase: %s"):format(
                leaderstat("Wins"), leaderstat("Rebirths"), leaderstat("TopSpeed"), short(clicksCounted), short(clicksSent),
                raceState() or (onTrack() and "Race (on track)" or "lobby / unknown"))
            ui.hatch.Text = ("Hatched this session: %d   last: %s"):format(hatched, lastHatchMsg)
            ui.status.Text = ("Knit replicas: %s   |   AFK block: %s   |   speed hook: %s   |   eggs here: %d"):format(
                playerData() and "ok" or "not reachable (phase by position)",
                oldNamecall and "ok" or "unavailable", oldNewindex and "ok" or "unavailable", #eggNames())
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
    moveConn:Disconnect()
    clickConn:Disconnect()
    idleConn:Disconnect()
    pcall(function()
        local h = savedMove and savedMove.hum
        if h and h.Parent then
            h.WalkSpeed = savedMove.walk
            h.JumpPower = savedMove.jumpPower h.JumpHeight = savedMove.jumpHeight
        end
    end)
    pcall(function() gui:Destroy() end)
    _G.CookiesHubRaceClicker = nil
end
closeBtn.MouseButton1Click:Connect(Unload)
inputConn = UserInputService.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == S.ToggleKey then main.Visible = not main.Visible end
end)

_G.CookiesHubRaceClicker = {
    Unload = Unload, State = S,
    Set = function(k, v)
        if S[k] == nil then return end
        S[k] = v saveSettings()
        if ui.renders[k] then ui.renders[k]() end
    end,
    Get = function(k) return S[k] end,
}
print("[CookiesHub] Race Clicker loaded.")

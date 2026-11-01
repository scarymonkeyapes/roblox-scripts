-- Cookies Hub (Roblox Stock Exchange)  [KEYLESS]
-- RightShift: show/hide (changeable) | X button or _G.CookiesHubSX.Unload(): unload
-- Console: _G.CookiesHubSX.Set("AutoTrade", true)  /  _G.CookiesHubSX.Set("Mode", "Aggressive")
--
-- How it works (verified live against Roblox Stock Exchange 2, placeId 110527353762049):
--  * Every asset's price is a PURE, deterministic function of a fixed account seed + the
--    (accelerated ~120x) market clock. ReplicatedStorage.Shared.PriceEngine.markPrice(seed, asset, t)
--    returns the price at ANY time t, including the future. Verified: predictions for fixed
--    timestamps stay identical as real time passes (true foresight, stable hours ahead).
--  * So the bot scans every asset, finds the biggest predicted move over the next horizon,
--    and trades toward it, closing at the EXACT predicted-extreme timestamp.
--  * The catch (learned the hard way): order size matters. Big orders on thin/low-priced assets
--    get destroyed by slippage (PriceEngine.executionCostFor). The bot shrinks each order until
--    the modeled round-trip cost is small, and only trades when the net edge still clears the
--    mode threshold. Commodities/baskets (e.g. BGLD) have ~0 slippage and are ideal.
--
-- Modes:
--  * Safe       : 1x leverage, small size (<=25% cash), only trades with >=1.5% net edge, 1 open at a time.
--  * Aggressive : up to 3x leverage, larger size (<=80% cash), >=0.8% net edge, up to 3 open at a time.
--  * Simulate   : logs the trades it WOULD make (predicted vs modeled) and spends NOTHING.

if _G.CookiesHubSX and _G.CookiesHubSX.Unload then pcall(_G.CookiesHubSX.Unload) end

local Players            = game:GetService("Players")
local RS                 = game:GetService("ReplicatedStorage")
local UserInputService   = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")
local TweenService       = game:GetService("TweenService")
local lp                 = Players.LocalPlayer

-- ---------- guard: make sure this is the right game ----------
local Shared = RS:FindFirstChild("Shared")
local Remotes = RS:FindFirstChild("Remotes")
local clientFolder = lp:FindFirstChild("PlayerScripts") and lp.PlayerScripts:FindFirstChild("Client")
if not (Shared and Shared:FindFirstChild("PriceEngine") and clientFolder and clientFolder:FindFirstChild("State")) then
    warn("[CookiesHub SX] This isn't Roblox Stock Exchange (missing Shared.PriceEngine / Client.State). Aborting.")
    return
end

local okPE, PriceEngine = pcall(require, Shared.PriceEngine)
local okCfg, Config      = pcall(require, Shared:FindFirstChild("Config"))
local okState, State     = pcall(require, clientFolder.State)
if not (okPE and okState and type(PriceEngine)=="table" and type(State)=="table") then
    warn("[CookiesHub SX] Failed to load PriceEngine/State. Aborting.")
    return
end
if not okCfg then Config = nil end

-- ---------- settings ----------
local S = {
    AutoTrade   = false,
    Mode        = "Simulate",  -- "Safe" | "Aggressive" | "Simulate" — defaults to risk-free Simulate
    AutoDaily   = false,
    AutoClaim   = false,       -- claim rewards/career/desk when ready
    ToggleKey   = Enum.KeyCode.RightShift,
}

-- mode parameters
local MODES = {
    Safe       = { capFrac = 0.25, maxLev = 1, minEdge = 0.015, maxOpen = 1, sim = false },
    Aggressive = { capFrac = 0.80, maxLev = 3, minEdge = 0.008, maxOpen = 3, sim = false },
    Simulate   = { capFrac = 0.50, maxLev = 2, minEdge = 0.010, maxOpen = 3, sim = true  },
}
local function modeCfg() return MODES[S.Mode] or MODES.Safe end

-- ---------- engine helpers ----------
local function seed() return State.seed() end
local function clock() return State.now() end
local function profile() return State.profile end
local function cash() local p = profile() return (p and p.cash) or 0 end
local function netWorth() local ok, v = pcall(State.netWorth) return ok and v or cash() end

local function slippage() if Config and Config.slippageFactor then local ok,v=pcall(Config.slippageFactor, profile()) if ok then return v end end return 0 end
local function maintenance() if Config and Config.maintenanceRatioFor then local ok,v=pcall(Config.maintenanceRatioFor, profile()) if ok then return v end end return 0.25 end

-- all tradable procedural assets as resolved objects
local function assets()
    local out = {}
    local ok, list = pcall(State.listedAssets)
    if not ok or type(list) ~= "table" then return out end
    for _, a in ipairs(list) do
        local id = type(a) == "table" and (a.id or a.assetId or a.Id) or a
        local o = State.resolveAsset(id)
        if o and State.assetIsProcedural(o) then out[#out + 1] = o end
    end
    return out
end

local function priceAt(obj, t)
    local ok, v = pcall(PriceEngine.markPrice, seed(), obj, t)
    if ok and type(v) == "number" then return v end
    return nil
end

-- round-trip cost FRACTION for a given order size (mirrors TradePanel's execution-cost usage)
local function roundTripCostFrac(obj, qty, price)
    local sf = 1
    local okS, s = pcall(PriceEngine.splitFactorAt, seed(), obj, clock())
    if okS and type(s) == "number" then sf = s end
    local okC, c = pcall(PriceEngine.executionCostFor, obj, qty, price, sf, slippage())
    if not okC or type(c) ~= "number" or c <= 0 then return 0 end
    -- one leg of slippage ~= 1 - exp(-2c); count entry + exit
    local leg = 1 - math.exp(-2 * c)
    return leg * 2
end

-- For an asset, find the best directional move over the horizon and the exact timestamp of it.
-- Returns {dir, entry, exitPrice, exitT, movePct} or nil.
local HORIZON_STEP = 30
local function bestMove(obj, horizon)
    local now = clock()
    local p0 = priceAt(obj, now + 20)          -- price shortly after we'd fill
    if not p0 or p0 <= 0 then return nil end
    local hi, hiT, lo, loT = -math.huge, nil, math.huge, nil
    for dt = 90, horizon, HORIZON_STEP do
        local p = priceAt(obj, now + dt)
        if p then
            if p > hi then hi, hiT = p, now + dt end
            if p < lo then lo, loT = p, now + dt end
        end
    end
    if not hiT then return nil end
    local longG  = (hi - p0) / p0
    local shortG = (p0 - lo) / p0
    if longG >= shortG then
        return { dir = 1, entry = p0, exitPrice = hi, exitT = hiT, move = longG }
    else
        return { dir = -1, entry = p0, exitPrice = lo, exitT = loT, move = shortG }
    end
end

-- Pick an order size for a candidate that keeps slippage small and still clears the edge.
-- Returns qty (>=1) and net edge fraction, or nil if nothing qualifies.
local function sizeOrder(obj, cand, cfg)
    local lev = cfg.maxLev
    local budget = math.max(0, cash()) * cfg.capFrac * lev
    if budget < cand.entry then return nil end
    local qty = math.floor(budget / cand.entry)
    while qty >= 1 do
        local rt = roundTripCostFrac(obj, qty, cand.entry)
        local netFrac = cand.move - rt
        if netFrac >= cfg.minEdge then
            return qty, netFrac, rt
        end
        qty = math.floor(qty * 0.5)
    end
    return nil
end

-- ---------- trade execution ----------
local botTrades = {}   -- [n] = {id, dir, qty, exitT, entry, exitPrice, netFrac, sim, opened}
-- real = trades that spent/earned actual cash; sim = Simulate-mode paper trades
local session = {
    real = { pnl = 0, trades = 0, wins = 0, losses = 0, best = nil, worst = nil },
    sim  = { pnl = 0, trades = 0, wins = 0, losses = 0, best = nil, worst = nil },
    startWorth = netWorth(),
    log = {},
}

local function logLine(txt)
    table.insert(session.log, 1, ("[%s] %s"):format(os.date("%H:%M:%S"), txt))
    if #session.log > 40 then session.log[#session.log] = nil end
end

-- record a closed trade's realized P&L into the right bucket
local function recordRealized(bucket, id, realized)
    bucket.pnl = bucket.pnl + realized
    bucket.trades = bucket.trades + 1
    if realized >= 0 then bucket.wins = bucket.wins + 1 else bucket.losses = bucket.losses + 1 end
    if not bucket.best or realized > bucket.best.pnl then bucket.best = { id = id, pnl = realized } end
    if not bucket.worst or realized < bucket.worst.pnl then bucket.worst = { id = id, pnl = realized } end
end

-- live unrealized P&L of currently-open bot trades (moves up and down with the market).
-- real trades are marked against the ACTUAL server position (avg cost + real qty) so the
-- number matches the game's own P&L; sim trades mark against the predicted entry.
-- returns realUnreal, realCount, simUnreal, simCount
local function unrealized()
    local rU, rN, sU, sN = 0, 0, 0, 0
    local now = clock()
    local positions = (profile() and profile().positions) or {}
    for _, t in ipairs(botTrades) do
        local mk = priceAt(t.obj, now)
        if mk then
            if t.sim then
                sU = sU + t.qty * (mk - t.entry) * t.dir
                sN = sN + 1
            else
                for _, pos in ipairs(positions) do
                    local sideOk = (t.dir == 1 and pos.qty > 0) or (t.dir == -1 and pos.qty < 0)
                    if tostring(pos.id) == t.id and sideOk and pos.avg then
                        rU = rU + math.abs(pos.qty) * (mk - pos.avg) * t.dir
                        rN = rN + 1
                        break
                    end
                end
            end
        end
    end
    return rU, rN, sU, sN
end

local function openTrade(obj, cand, qty, netFrac, cfg)
    if cfg.sim then
        local t = { id = tostring(obj.id), obj = obj, dir = cand.dir, qty = qty, exitT = cand.exitT,
                    entry = cand.entry, exitPrice = cand.exitPrice, netFrac = netFrac, sim = true, opened = clock() }
        botTrades[#botTrades + 1] = t
        logLine(("SIM open %s %s x%d  edge %.2f%%"):format(t.id, cand.dir == 1 and "LONG" or "SHORT", qty, netFrac * 100))
        return true
    end
    local res = State.trade({ action = "open", id = obj.id, qty = qty, direction = cand.dir, lev = cfg.maxLev })
    if res and res.ok then
        local t = { id = tostring(obj.id), obj = obj, dir = cand.dir, qty = qty, exitT = cand.exitT,
                    entry = cand.entry, exitPrice = cand.exitPrice, netFrac = netFrac, sim = false, opened = clock(),
                    lev = cfg.maxLev }
        botTrades[#botTrades + 1] = t
        logLine(("OPEN %s %s x%d  edge %.2f%%"):format(t.id, cand.dir == 1 and "LONG" or "SHORT", qty, netFrac * 100))
        return true
    else
        logLine(("open FAILED %s: %s"):format(tostring(obj.id), res and tostring(res.err) or "no response"))
        return false
    end
end

-- find the live position index for one of our bot trades
local function positionIndexFor(t)
    local p = profile()
    if not (p and type(p.positions) == "table") then return nil end
    for i, pos in ipairs(p.positions) do
        local sideOk = (t.dir == 1 and pos.qty > 0) or (t.dir == -1 and pos.qty < 0)
        if tostring(pos.id) == t.id and sideOk and math.abs(math.abs(pos.qty) - t.qty) < math.max(1, t.qty * 0.05) then
            return i
        end
    end
    return nil
end

local function closeTrade(t)
    if t.sim then
        -- net of modeled round-trip cost (netFrac = predicted move - fees/slippage), so sim
        -- reflects what a real fill would roughly net, not the optimistic gross move.
        local realized = t.qty * t.entry * t.netFrac
        recordRealized(session.sim, t.id, realized)
        logLine(("SIM close %s  pnl ~$%.2f"):format(t.id, realized))
        return true
    end
    local idx = positionIndexFor(t)
    if not idx then logLine(("close: position for %s not found"):format(t.id)); return false end
    local before = cash()
    local res = State.trade({ action = "close", index = idx, fraction = 1,
                              expectedAssetId = t.id, expectedSide = t.dir, expectedLev = t.lev or 1 })
    task.wait(0.15)
    if res and res.ok then
        local realized = cash() - before
        recordRealized(session.real, t.id, realized)
        logLine(("CLOSE %s  pnl $%.2f"):format(t.id, realized))
        return true
    end
    logLine(("close FAILED %s: %s"):format(t.id, res and tostring(res.err) or "no response"))
    return false
end

-- ---------- auto-trade loop ----------
local running = true
task.spawn(function()
    while running do
        task.wait(0.4)
        if not S.AutoTrade then continue end
        local ok = pcall(function()
            local cfg = modeCfg()
            local now = clock()

            -- 1) close any of our trades that have reached (or passed) their target exit time
            for i = #botTrades, 1, -1 do
                local t = botTrades[i]
                if now >= t.exitT then
                    closeTrade(t)
                    table.remove(botTrades, i)
                end
            end

            -- 2) open new trades if we have room
            if #botTrades >= cfg.maxOpen then return end
            local horizon = 2000
            local best, bestObj, bestQty, bestNet
            for _, obj in ipairs(assets()) do
                -- skip assets we already hold a bot trade in
                local held = false
                for _, t in ipairs(botTrades) do if t.id == tostring(obj.id) then held = true break end end
                if not held then
                    local cand = bestMove(obj, horizon)
                    if cand and cand.move > cfg.minEdge then
                        local qty, netFrac = sizeOrder(obj, cand, cfg)
                        if qty then
                            -- score by net $ profit
                            local net = qty * cand.entry * netFrac
                            if not best or net > best.netDollar then
                                best, bestObj, bestQty, bestNet = cand, obj, qty, netFrac
                                best.netDollar = net
                            end
                        end
                    end
                end
            end
            if best and bestObj then
                openTrade(bestObj, best, bestQty, bestNet, cfg)
            end
        end)
        if not ok then task.wait(1) end
    end
end)

-- ---------- rewards / claims ----------
local function invoke(name, ...)
    local r = Remotes and Remotes:FindFirstChild(name)
    if not r then return nil end
    local ok, res = pcall(function(...) return r:InvokeServer(...) end, ...)
    return ok and res or nil
end

task.spawn(function()
    while running do
        task.wait(5)
        if S.AutoDaily then
            local ok, boot = pcall(function() return Remotes.GetBootstrap:InvokeServer() end)
            if ok and boot and boot.dailyReady then
                invoke("ClaimDaily")
                logLine("Claimed daily reward")
            end
        end
        if S.AutoClaim then
            for _, n in ipairs({ "ClaimReward", "ClaimCareer", "ClaimDesk" }) do
                pcall(function() invoke(n) end)
            end
        end
    end
end)

-- ======================================================================
-- UI
-- ======================================================================
local COLORS = {
    bg      = Color3.fromRGB(18, 20, 26),
    panel   = Color3.fromRGB(26, 29, 38),
    row     = Color3.fromRGB(34, 38, 49),
    accent  = Color3.fromRGB(88, 196, 140),
    accent2 = Color3.fromRGB(70, 150, 240),
    danger  = Color3.fromRGB(226, 90, 90),
    text    = Color3.fromRGB(235, 238, 245),
    text2   = Color3.fromRGB(150, 158, 172),
}

local gui = Instance.new("ScreenGui")
gui.Name = "CookiesHubSX"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
gui.DisplayOrder = 9999
pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = lp:WaitForChild("PlayerGui") end

local function corner(p, r) local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, r or 8) c.Parent = p return c end
local function pad(p, n) local u = Instance.new("UIPadding") u.PaddingLeft=UDim.new(0,n) u.PaddingRight=UDim.new(0,n) u.PaddingTop=UDim.new(0,n) u.PaddingBottom=UDim.new(0,n) u.Parent=p return u end

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(440, 500)
main.Position = UDim2.new(0.5, -220, 0.5, -250)
main.BackgroundColor3 = COLORS.bg
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui
corner(main, 12)

-- title bar
local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, 0, 0, 40)
bar.BackgroundColor3 = COLORS.panel
bar.BorderSizePixel = 0
bar.Parent = main
corner(bar, 12)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(14, 0)
title.Size = UDim2.new(1, -90, 1, 0)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextColor3 = COLORS.text
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Cookies Hub  ·  Stock Exchange"
title.Parent = bar

local function topBtn(txt, x, col)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(24, 24)
    b.Position = UDim2.new(1, x, 0.5, -12)
    b.BackgroundColor3 = col
    b.Text = txt
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.TextColor3 = COLORS.text
    b.BorderSizePixel = 0
    b.Parent = bar
    corner(b, 6)
    return b
end
local minBtn   = topBtn("–", -62, COLORS.row)
local closeBtn = topBtn("×", -32, COLORS.danger)

-- tab row
local tabRow = Instance.new("Frame")
tabRow.Size = UDim2.new(1, -20, 0, 32)
tabRow.Position = UDim2.fromOffset(10, 48)
tabRow.BackgroundTransparency = 1
tabRow.Parent = main
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.Parent = tabRow

local body = Instance.new("Frame")
body.Size = UDim2.new(1, -20, 1, -92)
body.Position = UDim2.fromOffset(10, 86)
body.BackgroundTransparency = 1
body.Parent = main

local tabs, tabBtns = {}, {}
local function selectTab(name)
    for n, page in pairs(tabs) do page.Visible = (n == name) end
    for n, b in pairs(tabBtns) do
        b.BackgroundColor3 = (n == name) and COLORS.accent or COLORS.row
        b.TextColor3 = (n == name) and COLORS.bg or COLORS.text2
    end
end
local function addTab(name)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 96, 1, 0)
    b.BackgroundColor3 = COLORS.row
    b.Text = name
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 13
    b.TextColor3 = COLORS.text2
    b.BorderSizePixel = 0
    b.Parent = tabRow
    corner(b, 6)
    local page = Instance.new("ScrollingFrame")
    page.Size = UDim2.fromScale(1, 1)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    page.ScrollBarThickness = 3
    page.CanvasSize = UDim2.new()
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y
    page.Visible = false
    page.Parent = body
    local l = Instance.new("UIListLayout")
    l.Padding = UDim.new(0, 8)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = page
    tabs[name] = page
    tabBtns[name] = b
    b.MouseButton1Click:Connect(function() selectTab(name) end)
    return page
end

-- components
local function sectionLabel(parent, txt)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, 0, 0, 20)
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.GothamBold
    l.TextSize = 12
    l.TextColor3 = COLORS.text2
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = string.upper(txt)
    l.Parent = parent
    return l
end

local function Toggle(parent, label, key, onChange)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 38)
    row.BackgroundColor3 = COLORS.row
    row.BorderSizePixel = 0
    row.Parent = parent
    corner(row, 6)
    local t = Instance.new("TextLabel")
    t.BackgroundTransparency = 1
    t.Position = UDim2.fromOffset(12, 0)
    t.Size = UDim2.new(1, -70, 1, 0)
    t.Font = Enum.Font.GothamMedium
    t.TextSize = 13
    t.TextColor3 = COLORS.text
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.Text = label
    t.Parent = row
    local knob = Instance.new("TextButton")
    knob.Size = UDim2.fromOffset(44, 22)
    knob.Position = UDim2.new(1, -56, 0.5, -11)
    knob.BackgroundColor3 = S[key] and COLORS.accent or COLORS.bg
    knob.Text = ""
    knob.BorderSizePixel = 0
    knob.Parent = row
    corner(knob, 11)
    local dot = Instance.new("Frame")
    dot.Size = UDim2.fromOffset(18, 18)
    dot.Position = S[key] and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9)
    dot.BackgroundColor3 = COLORS.text
    dot.BorderSizePixel = 0
    dot.Parent = knob
    corner(dot, 9)
    local function render()
        knob.BackgroundColor3 = S[key] and COLORS.accent or COLORS.bg
        dot:TweenPosition(S[key] and UDim2.new(1, -20, 0.5, -9) or UDim2.new(0, 2, 0.5, -9),
            Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.12, true)
    end
    knob.MouseButton1Click:Connect(function()
        S[key] = not S[key]
        render()
        if onChange then pcall(onChange, S[key]) end
    end)
    return { set = function(v) S[key] = v render() end }
end

local function Button(parent, label, col, onClick)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 34)
    b.BackgroundColor3 = col or COLORS.accent2
    b.Text = label
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 13
    b.TextColor3 = COLORS.text
    b.BorderSizePixel = 0
    b.Parent = parent
    corner(b, 6)
    b.MouseButton1Click:Connect(function() pcall(onClick) end)
    return b
end

local function Note(parent, txt)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, 0, 0, 16)
    l.AutomaticSize = Enum.AutomaticSize.Y
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.Gotham
    l.TextSize = 12
    l.TextColor3 = COLORS.text2
    l.TextWrapped = true
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = txt
    l.Parent = parent
    return l
end

-- ---------- Trade tab ----------
local tradeTab = addTab("Trade")

sectionLabel(tradeTab, "Mode")
local modeRow = Instance.new("Frame")
modeRow.Size = UDim2.new(1, 0, 0, 34)
modeRow.BackgroundTransparency = 1
modeRow.Parent = tradeTab
local modeLayout = Instance.new("UIListLayout")
modeLayout.FillDirection = Enum.FillDirection.Horizontal
modeLayout.Padding = UDim.new(0, 6)
modeLayout.Parent = modeRow
local modeBtns = {}
local function renderMode()
    for n, b in pairs(modeBtns) do
        b.BackgroundColor3 = (S.Mode == n) and COLORS.accent or COLORS.row
        b.TextColor3 = (S.Mode == n) and COLORS.bg or COLORS.text2
    end
end
for _, n in ipairs({ "Safe", "Aggressive", "Simulate" }) do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0.333, -4, 1, 0)
    b.BackgroundColor3 = COLORS.row
    b.Text = n
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 12
    b.TextColor3 = COLORS.text2
    b.BorderSizePixel = 0
    b.Parent = modeRow
    corner(b, 6)
    modeBtns[n] = b
    b.MouseButton1Click:Connect(function() S.Mode = n renderMode() end)
end
renderMode()

local modeNote = Note(tradeTab,
    "Safe: 1x, small size, >=1.5% net edge, 1 open.  Aggressive: up to 3x, big size, >=0.8% net edge, 3 open.  Simulate: spends nothing, logs what it would do.")

Toggle(tradeTab, "Auto trade", "AutoTrade", function(v)
    logLine(v and ("Auto trade ON (" .. S.Mode .. ")") or "Auto trade OFF")
end)

sectionLabel(tradeTab, "Bot profit / loss  (live)")
-- big headline = realized + open, moves up and down live
local profitBig = Instance.new("TextLabel")
profitBig.Size = UDim2.new(1, 0, 0, 40)
profitBig.BackgroundTransparency = 1
profitBig.Font = Enum.Font.GothamBold
profitBig.TextSize = 28
profitBig.TextColor3 = COLORS.accent
profitBig.TextXAlignment = Enum.TextXAlignment.Left
profitBig.Text = "$0.00"
profitBig.Parent = tradeTab
local statReal  = Note(tradeTab, "Closed: $0.00  ·  0 trades")
local statOpenPL= Note(tradeTab, "Open: $0.00  ·  0 positions")
local statSim   = Note(tradeTab, "Simulated: $0.00  ·  0 trades")
local statBest  = Note(tradeTab, "Best: —   Worst: —")

sectionLabel(tradeTab, "Live account")
local statWorth = Note(tradeTab, "Net worth: —")
local statCash  = Note(tradeTab, "Cash: —")
local statOpen  = Note(tradeTab, "Open bot trades: 0")

Button(tradeTab, "Close all my bot trades now", COLORS.danger, function()
    for i = #botTrades, 1, -1 do
        closeTrade(botTrades[i])
        table.remove(botTrades, i)
    end
end)

sectionLabel(tradeTab, "Top predicted moves (next ~17s)")
local predBox = Note(tradeTab, "scanning…")

sectionLabel(tradeTab, "Activity")
local logBox = Note(tradeTab, "—")

-- ---------- Rewards tab ----------
local rewardTab = addTab("Rewards")
sectionLabel(rewardTab, "Passive claims")
Toggle(rewardTab, "Auto daily reward", "AutoDaily")
Toggle(rewardTab, "Auto claim rewards/career/desk", "AutoClaim")
Button(rewardTab, "Claim daily now", COLORS.accent2, function()
    invoke("ClaimDaily") logLine("Manual daily claim")
end)
Button(rewardTab, "Redeem (open codes in-game)", COLORS.row, function() end)
Note(rewardTab, "Claims are safe passive income — no money risked.")

-- ---------- Info tab ----------
local infoTab = addTab("Info")
sectionLabel(infoTab, "How this works")
Note(infoTab, "Prices in this game are a deterministic function of your account seed and the market clock, so the price at any FUTURE time is computable exactly. The bot reads the future, buys what will rise / shorts what will fall, and closes at the precise predicted turning point.")
sectionLabel(infoTab, "Why size matters")
Note(infoTab, "Large orders on thin assets get eaten by slippage. The bot shrinks each order until the modeled round-trip cost is small and only trades when the net edge still clears your mode's threshold. Commodities/baskets have ~0 slippage and are favoured.")
sectionLabel(infoTab, "Safety")
Note(infoTab, "The bot only closes positions it opened — your existing holdings are never touched. Start in Simulate to watch it with zero risk, then switch to Safe.")

selectTab("Trade")

-- ---------- live stats refresh ----------
task.spawn(function()
    while running do
        task.wait(1)
        pcall(function()
            local r, sm = session.real, session.sim
            local rU, rN, sU, sN = unrealized()
            local function money(v) return (v >= 0 and "+$" or "-$") .. string.format("%.2f", math.abs(v)) end
            -- headline follows the ACTIVE mode so it always moves live: Simulate shows paper P&L,
            -- Safe/Aggressive show real P&L. Both include open positions, so it ticks up AND down.
            local simActive = (S.Mode == "Simulate")
            local total = simActive and (sm.pnl + sU) or (r.pnl + rU)
            profitBig.Text = money(total) .. (simActive and "  (sim)" or "")
            profitBig.TextColor3 = total >= 0 and COLORS.accent or COLORS.danger
            local rWR = r.trades > 0 and (r.wins / r.trades * 100) or 0
            statReal.Text  = ("Closed: %s  ·  %d trades  ·  %dW/%dL  ·  %.0f%% win")
                :format(money(r.pnl), r.trades, r.wins, r.losses, rWR)
            statOpenPL.Text= ("Open: %s  ·  %d position%s (live)")
                :format(money(rU), rN, rN == 1 and "" or "s")
            statSim.Text   = ("Simulated: %s closed + %s open  ·  %d trades")
                :format(money(sm.pnl), money(sU), sm.trades)
            local function tradeStr(x) return x and ("%s %s"):format(x.id, money(x.pnl)) or "—" end
            statBest.Text  = ("Best: %s    Worst: %s"):format(tradeStr(r.best or sm.best), tradeStr(r.worst or sm.worst))

            statWorth.Text = ("Net worth: $%s  (%+.2f since load)")
                :format(string.format("%.2f", netWorth()), netWorth() - session.startWorth)
            statCash.Text  = ("Cash: $%s"):format(string.format("%.2f", cash()))
            statOpen.Text  = ("Open bot trades: %d / %d"):format(#botTrades, modeCfg().maxOpen)
            logBox.Text = (#session.log > 0) and table.concat(session.log, "\n", 1, math.min(10, #session.log)) or "—"

            -- top predicted movers
            local now = clock()
            local ranked = {}
            for _, obj in ipairs(assets()) do
                local c = bestMove(obj, 2000)
                if c then ranked[#ranked + 1] = { id = tostring(obj.id), dir = c.dir, move = c.move } end
            end
            table.sort(ranked, function(a, b) return a.move > b.move end)
            local lines = {}
            for i = 1, math.min(5, #ranked) do
                local r = ranked[i]
                lines[#lines + 1] = ("%s  %s  %+.2f%%"):format(r.id, r.dir == 1 and "▲" or "▼", r.move * 100 * (r.dir == 1 and 1 or 1))
            end
            predBox.Text = (#lines > 0) and table.concat(lines, "\n") or "no strong moves right now"
        end)
    end
end)

-- ---------- drag ----------
do
    local dragging, startPos, startMouse
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true startPos = main.Position startMouse = i.Position
            i.Changed:Connect(function() if i.UserInputState == Enum.UserInputState.End then dragging = false end end)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - startMouse
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

-- ---------- minimize / close / keybind ----------
local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    tabRow.Visible = not minimized
    main.Size = minimized and UDim2.fromOffset(440, 40) or UDim2.fromOffset(440, 500)
end)

local inputConn
local function Unload()
    running = false
    S.AutoTrade = false
    if inputConn then inputConn:Disconnect() end
    pcall(function() gui:Destroy() end)
    _G.CookiesHubSX = nil
end
closeBtn.MouseButton1Click:Connect(Unload)

inputConn = UserInputService.InputBegan:Connect(function(i, gpe)
    if gpe then return end
    if i.KeyCode == S.ToggleKey then main.Visible = not main.Visible end
end)

-- ---------- public API ----------
_G.CookiesHubSX = {
    Unload = Unload,
    Set = function(k, v) if S[k] ~= nil then S[k] = v end end,
    Get = function(k) return S[k] end,
    State = S,
    Session = session,
}

logLine("Cookies Hub (Stock Exchange) loaded. Start in Simulate to watch it risk-free.")

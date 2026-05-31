-- GrindTracker.lua (Release v1.1.0)
-- A lightweight grind / farming session tracker for ArcheAge (x2 addon API).
-- Made by: Loctus & AI
--
-- Tracks while running:
--   Time, Kills + K/h, XP + XP/h, Coin looted + Gold/h (GPH),
--   total Items, and a live loot list (name + count).
-- Controls: Start/Pause, Reset, close (X). Always-on draggable panel.
-- Nothing is saved to disk -- pure in-memory session counters.
--
-- NOTE on Kills: ArcheAge gives no clean "the mob I killed died" event, so a
-- kill is counted on each EXP_CHANGED gain (one XP tick == one kill while
-- grinding). At max level XP is 0, so Kills/K-h stay at 0; coin, loot and GPH
-- all still work.

if API_TYPE == nil then
    ADDON:ImportAPI(8)
    X2Chat:DispatchChatMessage(CMF_SYSTEM, "Missing important files.")
    return
end

ADDON:ImportObject(OBJECT_TYPE.WINDOW)
ADDON:ImportObject(OBJECT_TYPE.TEXT_STYLE)
ADDON:ImportObject(OBJECT_TYPE.BUTTON)
ADDON:ImportObject(OBJECT_TYPE.LABEL)
ADDON:ImportObject(OBJECT_TYPE.DRAWABLE)
ADDON:ImportObject(OBJECT_TYPE.COLOR_DRAWABLE)

ADDON:ImportAPI(API_TYPE.CHAT.id)
ADDON:ImportAPI(API_TYPE.UNIT.id)
ADDON:ImportAPI(API_TYPE.ITEM.id)

local ADDON_NAME = "GrindTracker"
local VERSION    = "1.1.2"

-- =========================
-- Settings (editable knobs)
-- =========================
local DEFAULT_PANEL_X = 740
local DEFAULT_PANEL_Y = 220
local UI_REFRESH_SEC  = 1.0    -- label refresh throttle
local MAX_LOOT_ROWS   = 11     -- visible loot rows before "+N more"

-- Colours
local C_LABEL = { 0.78, 0.74, 0.62 }
local C_VALUE = { 1.00, 1.00, 1.00 }
local C_GOLD  = { 0.95, 0.80, 0.30 }
local C_XP    = { 0.55, 0.80, 1.00 }
local C_HDR   = { 0.95, 0.85, 0.55 }

-- =========================
-- Logging / safe helpers
-- =========================
local function Log(msg)
    X2Chat:DispatchChatMessage(CMF_SYSTEM, "[" .. ADDON_NAME .. " " .. VERSION .. "] " .. tostring(msg))
end

local function SafePcall(tag, fn)
    local ok, err = pcall(fn)
    if not ok then Log(tag .. " ERROR: " .. tostring(err)) end
    return ok, err
end

local function ToBool(v) return (v and true) or false end

local function AddAnchorSafe(obj, ...)
    if obj and type(obj.AddAnchor) == "function" then obj:AddAnchor(...); return true end
    return false
end

local function RemoveAllAnchorsSafe(obj)
    if obj and type(obj.RemoveAllAnchors) == "function" then obj:RemoveAllAnchors(); return true end
    return false
end

local function EnablePickSafe(obj, enabled)
    enabled = ToBool(enabled)
    if obj and type(obj.EnablePick) == "function" then obj:EnablePick(enabled) end
end

local function ShowSafe(obj, show)
    show = ToBool(show)
    if obj and type(obj.Show)       == "function" then obj:Show(show);       return end
    if obj and type(obj.SetVisible) == "function" then obj:SetVisible(show)        end
end

local function SetExtentSafe(obj, w, h)
    if obj and type(obj.SetExtent) == "function" then obj:SetExtent(w, h) end
end

-- =========================
-- Session state
-- =========================
local panelPosX = DEFAULT_PANEL_X
local panelPosY = DEFAULT_PANEL_Y

-- =========================
-- Persistence (panel position + visibility)
-- Uses ADDON:SaveData / LoadData / ClearData (per-character key-value).
-- =========================
local function SavePanel(key, x, y, visible)
    SafePcall("SavePanel:" .. key, function()
        ADDON:ClearData(key)
        ADDON:SaveData(key, {
            x = tonumber(x) or 0,
            y = tonumber(y) or 0,
            visible = visible and 1 or 0,
        })
    end)
end

local function LoadPanel(key)
    local x, y, vis = nil, nil, nil
    SafePcall("LoadPanel:" .. key, function()
        local d = ADDON:LoadData(key)
        if type(d) == "table" then
            x   = tonumber(d.x)
            y   = tonumber(d.y)
            vis = (tonumber(d.visible) or 0) == 1
        end
    end)
    return x, y, vis
end

local S = {
    running   = false,
    elapsed   = 0,    -- accumulated active seconds
    kills     = 0,
    xp        = 0,    -- total XP gained this session
    coin      = 0,    -- total copper looted this session
    lootOrder = {},   -- insertion order of item names
    lootCount = {},   -- itemName -> count
    lootTotal = 0,    -- total individual items
}

local playerName  = nil
local valLabels   = {}
local lootNameLbls = {}
local lootCountLbls = {}
local lootMoreLbl = nil
local startBtn    = nil

-- =========================
-- Formatting
-- =========================
local function fmtTime(t)
    t = math.floor(t or 0)
    local h = math.floor(t / 3600); t = t % 3600
    local m = math.floor(t / 60);   local s = t % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function fmtMoney(cp)
    cp = math.floor(cp or 0)
    local g = math.floor(cp / 10000); cp = cp % 10000
    local s = math.floor(cp / 100);   local c = cp % 100
    if g > 0 then return string.format("%dg %02ds %02dc", g, s, c) end
    if s > 0 then return string.format("%ds %02dc", s, c) end
    return string.format("%dc", c)
end

local function parseMoney(str)
    if not str then return 0 end
    str = tostring(str)
    local g = tonumber(str:match("(%d+)%s*g")) or 0
    local s = tonumber(str:match("(%d+)%s*s")) or 0
    local c = tonumber(str:match("(%d+)%s*c")) or 0
    if g == 0 and s == 0 and c == 0 then
        local plain = tonumber((str:gsub("%D", "")))
        return plain or 0
    end
    return g * 10000 + s * 100 + c
end

local function cleanItemName(link)
    if not link then return "Item" end
    link = tostring(link)
    local name = link:match("%[(.-)%]")
    if name and name ~= "" then return name end
    name = link:gsub("|%a+", ""):gsub("|%x+", ""):gsub("%c", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "Item" end
    return name
end

local function commafy(n)
    n = math.floor(n or 0)
    local out = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function perHour(total)
    if S.elapsed < 1 then return 0 end
    return total / (S.elapsed / 3600)
end

-- Abbreviate large numbers: 1234 -> "1.2k", 2_900_000 -> "2.9M"
local function shortNum(n)
    n = n or 0
    local a = math.abs(n)
    if a >= 1e9 then return string.format("%.1fB", n / 1e9):gsub("%.0B", "B")
    elseif a >= 1e6 then return (string.format("%.1f", n / 1e6):gsub("%.0$", "")) .. "M"
    elseif a >= 1e3 then return (string.format("%.1f", n / 1e3):gsub("%.0$", "")) .. "k"
    else return string.format("%d", math.floor(n + 0.5)) end
end

-- Money formatter that drops copper once we have at least 1 gold.
-- < 1g  -> "85s 30c" / "30c"
-- >= 1g -> "30g 85s"   (copper dropped for cleanliness)
local function fmtMoneyClean(cp)
    cp = math.floor(cp or 0)
    local g = math.floor(cp / 10000); local rem = cp % 10000
    local s = math.floor(rem / 100);  local c = rem % 100
    if g > 0 then
        if s > 0 then return string.format("%dg %ds", g, s) end
        return string.format("%dg", g)
    end
    if s > 0 then return string.format("%ds %dc", s, c) end
    return string.format("%dc", c)
end

-- Money formatter for per-hour, abbreviated gold (e.g. "6g/h" stays small).
local function fmtMoneyShort(cp)
    cp = math.floor(cp or 0)
    local g = cp / 10000
    if g >= 1 then return shortNum(g) .. "g" end
    local s = math.floor(cp / 100); local c = cp % 100
    if s > 0 then return string.format("%ds %dc", s, c) end
    return string.format("%dc", c)
end

-- =========================
-- UI helpers (mirrors PrivateMark)
-- =========================
local function MakeBtn(parent, id, text, x, y, w, h, onClick)
    local b = parent:CreateChildWidget("button", id, 0, true)
    SetExtentSafe(b, w, h)
    AddAnchorSafe(b, "TOPLEFT", parent, x, y)
    b:SetText(text)
    b:SetHandler("OnClick", onClick)
    return b
end

local function MakeLabel(parent, id, text, x, y, w, h, size, align, color)
    local t = parent:CreateChildWidget("label", id, 0, false)
    SetExtentSafe(t, w, h)
    RemoveAllAnchorsSafe(t)
    AddAnchorSafe(t, "TOPLEFT", parent, x, y)
    t.style:SetAlign(align or ALIGN_LEFT)
    t.style:SetFontSize(size or 14)
    local c = color or C_VALUE
    t.style:SetColor(c[1], c[2], c[3], 1)
    t.style:SetOutline(true)
    t.style:SetShadow(true)
    if t.style.SetEllipsis then t.style:SetEllipsis(true) end
    t:SetText(text or "")
    EnablePickSafe(t, false)
    return t
end

local function ApplyDefaultWindowSkin(win, alpha)
    SafePcall("ApplyDefaultWindowSkin", function()
        if not win or win._pgSkinApplied then return end
        alpha = alpha or 0.60

        local bgHost = win:CreateChildWidget("window", "pg_bgHost", 0, false)
        SetExtentSafe(bgHost,
            (type(win.GetWidth)  == "function" and win:GetWidth()  or 10),
            (type(win.GetHeight) == "function" and win:GetHeight() or 10))
        EnablePickSafe(bgHost, false)
        ShowSafe(bgHost, true)
        if type(bgHost.Lower) == "function" then bgHost:Lower() end
        RemoveAllAnchorsSafe(bgHost)
        AddAnchorSafe(bgHost, "TOPLEFT",     win, 0, 0)
        AddAnchorSafe(bgHost, "BOTTOMRIGHT", win, 0, 0)

        local col = nil
        if type(bgHost.CreateColorDrawable) == "function" then
            col = bgHost:CreateColorDrawable(0, 0, 0, alpha, "background")
        end
        if col then
            AddAnchorSafe(col, "TOPLEFT",     bgHost, -6, -6)
            AddAnchorSafe(col, "BOTTOMRIGHT", bgHost,  6,  6)
            ShowSafe(col, true)
        end

        win._pgSkinApplied = true
        win._pgBgHost = bgHost
    end)
end

local function MakeDraggable(win, onMoved)
    SafePcall("MakeDraggable", function()
        EnablePickSafe(win, true)
        if type(win.EnableDrag) == "function" then win:EnableDrag(true) end
        win:SetHandler("OnDragStart", function(self)
            self:StartMoving(); return true
        end)
        win:SetHandler("OnDragStop", function(self)
            self:StopMovingOrSizing()
            if type(self.CorrectOffsetByScreen) == "function" then self:CorrectOffsetByScreen() end
            if type(onMoved) == "function" and type(self.GetOffset) == "function" then
                local x, y = self:GetOffset()
                onMoved(x, y)
            end
            return true
        end)
    end)
end

-- Show/hide a window AND persist the visibility under `key`.
-- The window's current x,y is captured at the moment of save so a "visible=true"
-- always reflects the most recent position too.
local function ShowAndPersist(win, key, show)
    show = show and true or false
    ShowSafe(win, show)
    SafePcall("ShowAndPersist:" .. key, function()
        local x, y = 0, 0
        if type(win.GetOffset) == "function" then x, y = win:GetOffset() end
        SavePanel(key, x, y, show)
    end)
end

-- =========================
-- Build the tracker window
-- =========================
local WIN_W   = 300
local ROW_H   = 22
local LOOT_RH = 20

-- Load any saved position / visibility for the main panel.
local savedMainX, savedMainY, savedMainVisible = LoadPanel("panel")
if savedMainX and savedMainY then
    panelPosX, panelPosY = savedMainX, savedMainY
end

local win = CreateEmptyWindow("GT_win", "UIParent")
RemoveAllAnchorsSafe(win)
AddAnchorSafe(win, "TOPLEFT", "UIParent", panelPosX, panelPosY)

-- Title row
MakeLabel(win, "pgTitle", "Grind Tracker", 0, 10, WIN_W, ROW_H, 17, ALIGN_CENTER, C_HDR)

MakeBtn(win, "gtClose", "X", WIN_W - 32, 8, 22, 18, function()
    ShowAndPersist(win, "panel", false)
end)

-- Compact stat rows. Values are split into TWO columns so totals and per-hour
-- values line up vertically across rows:
--   Time   00:01:09
--   Kills       9   (467/h)
--   XP      32.4k   (1.7M/h)
--   Gold   9s 30c   (5g/h)
-- The total column is right-aligned at a fixed column edge; the /h column is
-- left-aligned starting just to the right of it.
local LABEL_X      = 14
local TOTAL_RIGHT  = 180   -- right edge of the total column
local HOURLY_X     = 192   -- left edge of the /h column
local function makeColLabel(parent, id, anchorSide, x, yy, w, color, align)
    local lbl = parent:CreateChildWidget("label", id, 0, false)
    SetExtentSafe(lbl, w, ROW_H)
    RemoveAllAnchorsSafe(lbl)
    AddAnchorSafe(lbl, anchorSide, parent, x, yy)
    lbl.style:SetAlign(align)
    lbl.style:SetFontSize(15)
    lbl.style:SetColor(color[1], color[2], color[3], 1)
    lbl.style:SetOutline(true)
    lbl.style:SetShadow(true)
    if lbl.style.SetEllipsis then lbl.style:SetEllipsis(true) end
    lbl:SetText("")
    EnablePickSafe(lbl, false)
    return lbl
end

local function StatRow(key, labelText, yy, valueColor)
    MakeLabel(win, "gt_n_" .. key, labelText, LABEL_X, yy, 90, ROW_H, 15, ALIGN_LEFT, C_LABEL)
    local c = valueColor or C_VALUE
    -- Total: anchored TOPLEFT with width chosen so its right edge sits at TOTAL_RIGHT,
    -- text right-aligned within the slot.
    local total  = makeColLabel(win, "gt_t_" .. key, "TOPLEFT", LABEL_X + 76, yy, TOTAL_RIGHT - (LABEL_X + 76), c, ALIGN_RIGHT)
    -- Hourly: left-anchored at HOURLY_X, fills the remaining width.
    local hourly = makeColLabel(win, "gt_h_" .. key, "TOPLEFT", HOURLY_X,        yy, WIN_W - HOURLY_X - 14,        c, ALIGN_LEFT)
    valLabels[key] = { total = total, hourly = hourly }
end

local y = 40
StatRow("time",  "Time",  y, C_VALUE); y = y + ROW_H
StatRow("kills", "Kills", y, C_VALUE); y = y + ROW_H
StatRow("xp",    "XP",    y, C_XP);    y = y + ROW_H
StatRow("gold",  "Gold",  y, C_GOLD);  y = y + ROW_H
StatRow("items", "Items", y, C_VALUE); y = y + ROW_H
y = y + 8

-- Three buttons on one row: Start/Pause | Reset | Loot
local btnW = math.floor((WIN_W - 28 - 12) / 3)  -- 3 buttons, 6px gaps
local lootWin  -- forward declaration

startBtn = MakeBtn(win, "pgStart", "Start", 14, y, btnW, 26, function()
    S.running = not S.running
    startBtn:SetText(S.running and "Pause" or "Resume")
end)

MakeBtn(win, "pgReset", "Reset", 14 + btnW + 6, y, btnW, 26, function()
    S.running   = false
    S.elapsed   = 0
    S.kills     = 0
    S.xp        = 0
    S.coin      = 0
    S.lootOrder = {}
    S.lootCount = {}
    S.lootTotal = 0
    if startBtn then startBtn:SetText("Start") end
end)

MakeBtn(win, "gtLootBtn", "Loot", 14 + (btnW + 6) * 2, y, btnW, 26, function()
    if lootWin then ShowAndPersist(lootWin, "loot", not lootWin:IsVisible()) end
end)
y = y + 26 + 14

SetExtentSafe(win, WIN_W, y)
ApplyDefaultWindowSkin(win, 0.55)
MakeDraggable(win, function(x, y) SavePanel("panel", x, y, win:IsVisible()) end)
-- Restore visibility from save (defaults to hidden -- user opens via ESC menu).
ShowSafe(win, savedMainVisible and true or false)

-- =========================
-- Separate Loot window
-- =========================
local LOOT_W = 340

-- Load saved position / visibility for the loot window.
local savedLootX, savedLootY, savedLootVisible = LoadPanel("loot")

lootWin = CreateEmptyWindow("GT_lootWin", "UIParent")
RemoveAllAnchorsSafe(lootWin)
if savedLootX and savedLootY then
    AddAnchorSafe(lootWin, "TOPLEFT", "UIParent", savedLootX, savedLootY)
else
    AddAnchorSafe(lootWin, "TOPLEFT", win, 0, y + 6)
end

MakeLabel(lootWin, "lwTitle", "Loot", 0, 10, LOOT_W, ROW_H, 16, ALIGN_CENTER, C_HDR)
MakeBtn(lootWin, "lwClose", "X", LOOT_W - 32, 8, 22, 18, function()
    ShowAndPersist(lootWin, "loot", false)
end)

local ly = 36

-- Loot rows: name takes the left ~75%, count takes a fixed 60px on the right
-- with a clean 12px gap between them. SetEllipsis(true) clips long names with "..."
-- (set inside MakeLabel via style:SetEllipsis).
local NAME_X     = 18
local COUNT_W    = 60
local COUNT_PAD  = 14   -- right margin
local GAP        = 12   -- space between name end and count start
local COUNT_X    = LOOT_W - COUNT_PAD - COUNT_W   -- left edge of count column
local NAME_W     = COUNT_X - GAP - NAME_X         -- name fills everything to its left

for i = 1, MAX_LOOT_ROWS do
    lootNameLbls[i]  = MakeLabel(lootWin, "lw_n_" .. i, "", NAME_X,  ly, NAME_W,  LOOT_RH, 14, ALIGN_LEFT,  { 0.9, 0.9, 0.9 })
    lootCountLbls[i] = MakeLabel(lootWin, "lw_c_" .. i, "", COUNT_X, ly, COUNT_W, LOOT_RH, 14, ALIGN_RIGHT, C_GOLD)
    ly = ly + LOOT_RH
end
lootMoreLbl = MakeLabel(lootWin, "lw_more", "", NAME_X, ly, LOOT_W - NAME_X - COUNT_PAD, LOOT_RH, 13, ALIGN_LEFT, { 0.7, 0.7, 0.7 })
ly = ly + LOOT_RH + 12

SetExtentSafe(lootWin, LOOT_W, ly)
ApplyDefaultWindowSkin(lootWin, 0.60)
MakeDraggable(lootWin, function(x, y) SavePanel("loot", x, y, lootWin:IsVisible()) end)
ShowSafe(lootWin, savedLootVisible and true or false)

-- =========================
-- ESC menu button (Shop/Quality of Life tab) -- opens the panel.
-- =========================
local UIC_GRIND = 1551   -- custom UI category (>1000 to avoid conflicts)

SafePcall("EscMenuRegister", function()
    -- Trigger function: explicitly toggle the panel's visibility.
    -- (ADDON:ToggleContent does not directly show custom windows, so we do it here.)
    ADDON:RegisterContentTriggerFunc(UIC_GRIND, function(show)
        if win and win:IsValidUIObject() then
            if show == nil then
                ShowAndPersist(win, "panel", not win:IsVisible())
            else
                ShowAndPersist(win, "panel", show and true or false)
            end
        end
    end)
    -- Category 3 = Shop/Quality of Life.
    ADDON:AddEscMenuButton(3, UIC_GRIND, "info", "Grind Tracker")
end)

-- =========================
-- Refresh labels
-- =========================
local function setRow(key, totalText, hourlyText)
    local row = valLabels[key]
    if not row then return end
    row.total:SetText(totalText or "")
    row.hourly:SetText(hourlyText or "")
end

local function Refresh()
    if not valLabels.time then return end

    -- Time: just the clock in the total column, hourly empty.
    setRow("time", fmtTime(S.elapsed), "")

    -- Kills / XP: abbreviated.
    setRow("kills", shortNum(S.kills), "(" .. shortNum(perHour(S.kills)) .. "/h)")
    setRow("xp",    shortNum(S.xp),    "(" .. shortNum(perHour(S.xp))    .. "/h)")

    -- Gold: clean total + abbreviated per-hour.
    setRow("gold", fmtMoneyClean(S.coin), "(" .. fmtMoneyShort(perHour(S.coin)) .. "/h)")

    -- Items: total (per-hour).
    setRow("items", shortNum(S.lootTotal), "(" .. shortNum(perHour(S.lootTotal)) .. "/h)")

    -- ---- Loot window ----
    -- Sort loot most-first into a scratch list.
    local sorted = {}
    for _, nm in ipairs(S.lootOrder) do sorted[#sorted + 1] = nm end
    table.sort(sorted, function(a, b)
        return (S.lootCount[a] or 0) > (S.lootCount[b] or 0)
    end)

    local shown = math.min(#sorted, MAX_LOOT_ROWS)
    for i = 1, MAX_LOOT_ROWS do
        if i <= shown then
            local name = sorted[i]
            lootNameLbls[i]:SetText(name)
            lootCountLbls[i]:SetText("x" .. (S.lootCount[name] or 0))
        else
            lootNameLbls[i]:SetText("")
            lootCountLbls[i]:SetText("")
        end
    end
    local extra = #sorted - MAX_LOOT_ROWS
    lootMoreLbl:SetText(extra > 0 and ("+ " .. extra .. " more...") or "")
end

-- =========================
-- Game event handlers
-- =========================

-- Extract a clean item name from an ADDON_ITEM link.
-- The link is a raw token like "|i{itemType},{grade},{kind},{data}", NOT "[Name]".
-- Best path: ask the game to resolve it via X2Item:InfoFromLink(...).name
local function ItemName(link)
    if type(link) ~= "string" or link == "" then return "Item" end

    -- Strategy 1: resolve through the item API
    local ok, info = pcall(function() return X2Item:InfoFromLink(link) end)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
        return info.name
    end

    -- Strategy 2: classic [Name] form (some links carry it)
    local n = link:match("%[(.-)%]")
    if n and n ~= "" then return n end

    -- Strategy 3: longest readable run as a last resort
    local best = ""
    for chunk in link:gmatch("[%a][%a '%-]+") do
        if #chunk > #best then best = chunk end
    end
    best = best:gsub("^%s+", ""):gsub("%s+$", "")
    if #best >= 3 then return best end

    return "Item"
end

SafePcall("ExpHook", function()
    UIParent:SetEventHandler(UIEVENT_TYPE.EXP_CHANGED, function(stringId, expNum, expStr)
        if not S.running then return end
        local n = tonumber(expNum) or 0
        if n > 0 then
            S.xp = S.xp + n
            S.kills = S.kills + 1
        end
    end)
end)

SafePcall("MoneyHook", function()
    UIParent:SetEventHandler(UIEVENT_TYPE.PLAYER_MONEY, function(change, changeStr, itemTaskType, info)
        if not S.running then return end
        local delta = tonumber(change) or 0
        if delta > 0 then S.coin = S.coin + delta end
    end)
end)

SafePcall("ItemHook", function()
    UIParent:SetEventHandler(UIEVENT_TYPE.ADDED_ITEM, function(itemLink, itemCount, itemTaskType, tradeOtherName)
        if not S.running then return end
        local cnt  = tonumber(itemCount) or 1
        local name = ItemName(itemLink)
        if not S.lootCount[name] then
            S.lootCount[name] = 0
            table.insert(S.lootOrder, name)
        end
        S.lootCount[name] = S.lootCount[name] + cnt
        S.lootTotal = S.lootTotal + cnt
    end)
end)

-- =========================
-- Update loop (offscreen ticker)
-- =========================
local updater = CreateEmptyWindow("PG_updater", "UIParent")
SetExtentSafe(updater, 1, 1)
RemoveAllAnchorsSafe(updater)
AddAnchorSafe(updater, "TOPLEFT", "UIParent", -2000, -2000)
ShowSafe(updater, true)

local acc = 0
updater:SetHandler("OnUpdate", function(self, frameTime)
    -- frameTime is in milliseconds; convert to seconds.
    local dt = (tonumber(frameTime) or 0) / 1000
    if S.running then S.elapsed = S.elapsed + dt end
    acc = acc + dt
    if acc < UI_REFRESH_SEC then return end
    acc = 0
    Refresh()
end)

Refresh()
Log("Loaded v" .. VERSION .. " - open from ESC menu (Shop/Quality of Life).")

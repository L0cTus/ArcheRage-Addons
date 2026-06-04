-- GrindTracker.lua (v1.2.0)
-- Lightweight grind session tracker for ArcheAge (x2 addon API).
-- Made by: Loctus
--
-- Tracks: Time, Kills/h, XP/h, Gold/h (coin + AH item value), Items/h, Honor/h.
-- Opens via ESC menu > Shop / Quality of Life.
--
-- NOTE: Kills are counted on EXP_CHANGED ticks. At max level XP = 0, so
-- Kills/h stays at 0; coin, loot and Gold/h still work normally.

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
ADDON:ImportAPI(API_TYPE.AUCTION.id)

local ADDON_NAME = "GrindTracker"
local VERSION    = "1.2.0"

local DEFAULT_PANEL_X = 740
local DEFAULT_PANEL_Y = 220
local UI_REFRESH_SEC  = 1.0
local MAX_LOOT_ROWS   = 11

local C_LABEL = { 0.78, 0.74, 0.62 }
local C_VALUE = { 1.00, 1.00, 1.00 }
local C_GOLD  = { 0.95, 0.80, 0.30 }
local C_XP    = { 0.55, 0.80, 1.00 }
local C_HDR   = { 0.95, 0.85, 0.55 }
local C_HONOR = { 0.80, 0.55, 1.00 }

-- Honor granted per item on loot. Edit to match your server.
local ITEM_HONOR = {
    ["Dimmed Honor Gem"] = 100,
    ["Vivid Honor Gem"]  = 200,
}

-- AH price state: items are queued and triggered one at a time (AH_COOLDOWN seconds
-- apart) via GetLowestPrice. Once the server responds the price is cached for the session.
local priceCache    = {}
local priceQueue    = {}
local pricePending  = {}
local priceSearched = {}
local ahLastTrigger = 0
local AH_COOLDOWN   = 2

-- -------------------------
-- Helpers
-- -------------------------
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

-- -------------------------
-- Persistence
-- -------------------------
local panelPosX = DEFAULT_PANEL_X
local panelPosY = DEFAULT_PANEL_Y

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

-- -------------------------
-- Session state
-- -------------------------
local S = {
    running    = false,
    elapsed    = 0,
    kills      = 0,
    xp         = 0,
    coin       = 0,
    honor      = 0,
    lootOrder  = {},
    lootCount  = {},
    lootHidden = {},
    lootTotal  = 0,
}

local playerName    = nil
local valLabels     = {}
local lootNameLbls  = {}
local lootCountLbls = {}
local lootHideBtns  = {}
local lootRowItems  = {}
local lootMoreLbl   = nil
local startBtn      = nil

-- -------------------------
-- Formatting
-- -------------------------
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
        return tonumber((str:gsub("%D", ""))) or 0
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

local function shortNum(n)
    n = n or 0
    local a = math.abs(n)
    if a >= 1e9 then return string.format("%.1fB", n / 1e9):gsub("%.0B", "B")
    elseif a >= 1e6 then return (string.format("%.1f", n / 1e6):gsub("%.0$", "")) .. "M"
    elseif a >= 1e3 then return (string.format("%.1f", n / 1e3):gsub("%.0$", "")) .. "k"
    else return string.format("%d", math.floor(n + 0.5)) end
end

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

local function fmtMoneyShort(cp)
    cp = math.floor(cp or 0)
    local g = cp / 10000
    if g >= 1 then return shortNum(g) .. "g" end
    local s = math.floor(cp / 100); local c = cp % 100
    if s > 0 then return string.format("%ds %dc", s, c) end
    return string.format("%dc", c)
end

-- -------------------------
-- UI helpers
-- -------------------------
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

local function ShowAndPersist(win, key, show)
    show = show and true or false
    ShowSafe(win, show)
    SafePcall("ShowAndPersist:" .. key, function()
        local x, y = 0, 0
        if type(win.GetOffset) == "function" then x, y = win:GetOffset() end
        SavePanel(key, x, y, show)
    end)
end

-- -------------------------
-- Main window
-- -------------------------
local WIN_W   = 300
local ROW_H   = 22
local LOOT_RH = 20

local savedMainX, savedMainY, savedMainVisible = LoadPanel("panel")
if savedMainX and savedMainY then
    panelPosX, panelPosY = savedMainX, savedMainY
end

local win = CreateEmptyWindow("GT_win", "UIParent")
RemoveAllAnchorsSafe(win)
AddAnchorSafe(win, "TOPLEFT", "UIParent", panelPosX, panelPosY)

MakeLabel(win, "pgTitle", "Grind Tracker", 0, 10, WIN_W, ROW_H, 17, ALIGN_CENTER, C_HDR)

MakeBtn(win, "gtClose", "X", WIN_W - 32, 8, 22, 18, function()
    ShowAndPersist(win, "panel", false)
end)

local LABEL_X     = 14
local TOTAL_RIGHT = 180
local HOURLY_X    = 192

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
    local total  = makeColLabel(win, "gt_t_" .. key, "TOPLEFT", LABEL_X + 76, yy, TOTAL_RIGHT - (LABEL_X + 76), c, ALIGN_RIGHT)
    local hourly = makeColLabel(win, "gt_h_" .. key, "TOPLEFT", HOURLY_X,     yy, WIN_W - HOURLY_X - 14,        c, ALIGN_LEFT)
    valLabels[key] = { total = total, hourly = hourly }
end

local y = 40
StatRow("time",  "Time",  y, C_VALUE); y = y + ROW_H
StatRow("kills", "Kills", y, C_VALUE); y = y + ROW_H
StatRow("xp",    "XP",    y, C_XP);    y = y + ROW_H
StatRow("gold",  "Gold",  y, C_GOLD);  y = y + ROW_H
StatRow("items", "Items", y, C_VALUE); y = y + ROW_H
StatRow("honor", "Honor", y, C_HONOR); y = y + ROW_H
y = y + 8

local btnW    = math.floor((WIN_W - 28 - 12) / 3)
local lootWin

startBtn = MakeBtn(win, "pgStart", "Start", 14, y, btnW, 26, function()
    S.running = not S.running
    startBtn:SetText(S.running and "Pause" or "Resume")
end)

MakeBtn(win, "pgReset", "Reset", 14 + btnW + 6, y, btnW, 26, function()
    S.running    = false
    S.elapsed    = 0
    S.kills      = 0
    S.xp         = 0
    S.coin       = 0
    S.honor      = 0
    S.lootOrder  = {}
    S.lootCount  = {}
    S.lootHidden = {}
    S.lootTotal  = 0
    if startBtn then startBtn:SetText("Start") end
end)

MakeBtn(win, "gtLootBtn", "Loot", 14 + (btnW + 6) * 2, y, btnW, 26, function()
    if lootWin then ShowAndPersist(lootWin, "loot", not lootWin:IsVisible()) end
end)
y = y + 26 + 14

SetExtentSafe(win, WIN_W, y)
ApplyDefaultWindowSkin(win, 0.55)
MakeDraggable(win, function(x, y) SavePanel("panel", x, y, win:IsVisible()) end)
ShowSafe(win, savedMainVisible and true or false)

-- -------------------------
-- Loot window
-- -------------------------
local LOOT_W    = 340

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

local ly        = 36
local NAME_X    = 18
local HIDE_W    = 16
local HIDE_PAD  = 8
local HIDE_X    = LOOT_W - HIDE_PAD - HIDE_W
local COUNT_W   = 52
local COUNT_GAP = 4
local COUNT_X   = HIDE_X - COUNT_GAP - COUNT_W
local GAP       = 10
local NAME_W    = COUNT_X - GAP - NAME_X

for i = 1, MAX_LOOT_ROWS do
    lootNameLbls[i]  = MakeLabel(lootWin, "lw_n_" .. i, "", NAME_X,  ly, NAME_W,  LOOT_RH, 14, ALIGN_LEFT,  { 0.9, 0.9, 0.9 })
    lootCountLbls[i] = MakeLabel(lootWin, "lw_c_" .. i, "", COUNT_X, ly, COUNT_W, LOOT_RH, 14, ALIGN_RIGHT, C_GOLD)
    local idx = i
    lootHideBtns[i] = MakeBtn(lootWin, "lw_x_" .. i, "x", HIDE_X, ly + 2, HIDE_W, LOOT_RH - 4, function()
        local name = lootRowItems[idx]
        if name and name ~= "" then
            S.lootHidden[name] = true
        end
    end)
    ShowSafe(lootHideBtns[i], false)
    ly = ly + LOOT_RH
end
lootMoreLbl = MakeLabel(lootWin, "lw_more", "", NAME_X, ly, LOOT_W - NAME_X - HIDE_PAD, LOOT_RH, 13, ALIGN_LEFT, { 0.7, 0.7, 0.7 })
ly = ly + LOOT_RH + 12

SetExtentSafe(lootWin, LOOT_W, ly)
ApplyDefaultWindowSkin(lootWin, 0.60)
MakeDraggable(lootWin, function(x, y) SavePanel("loot", x, y, lootWin:IsVisible()) end)
ShowSafe(lootWin, savedLootVisible and true or false)

-- -------------------------
-- ESC menu
-- -------------------------
local UIC_GRIND = 1551

SafePcall("EscMenuRegister", function()
    ADDON:RegisterContentTriggerFunc(UIC_GRIND, function(show)
        if win and win:IsValidUIObject() then
            if show == nil then
                ShowAndPersist(win, "panel", not win:IsVisible())
            else
                ShowAndPersist(win, "panel", show and true or false)
            end
        end
    end)
    ADDON:AddEscMenuButton(3, UIC_GRIND, "info", "Grind Tracker")
end)

-- -------------------------
-- Refresh
-- -------------------------
local function setRow(key, totalText, hourlyText)
    local row = valLabels[key]
    if not row then return end
    row.total:SetText(totalText or "")
    row.hourly:SetText(hourlyText or "")
end

local function Refresh()
    if not valLabels.time then return end

    setRow("time",  fmtTime(S.elapsed), "")
    setRow("kills", shortNum(S.kills), "(" .. shortNum(perHour(S.kills)) .. "/h)")
    setRow("xp",    shortNum(S.xp),    "(" .. shortNum(perHour(S.xp))    .. "/h)")

    local ahValue = 0
    for _, nm in ipairs(S.lootOrder) do
        ahValue = ahValue + (priceCache[nm] or 0) * (S.lootCount[nm] or 0)
    end
    local totalGold = S.coin + ahValue
    setRow("gold",  fmtMoneyClean(totalGold), "(" .. fmtMoneyShort(perHour(totalGold)) .. "/h)")
    setRow("items", shortNum(S.lootTotal),     "(" .. shortNum(perHour(S.lootTotal))    .. "/h)")
    setRow("honor", commafy(S.honor),          "(" .. shortNum(perHour(S.honor))        .. "/h)")

    local sorted = {}
    for _, nm in ipairs(S.lootOrder) do
        if not S.lootHidden[nm] then sorted[#sorted + 1] = nm end
    end
    table.sort(sorted, function(a, b)
        return (S.lootCount[a] or 0) > (S.lootCount[b] or 0)
    end)

    local shown = math.min(#sorted, MAX_LOOT_ROWS)
    for i = 1, MAX_LOOT_ROWS do
        if i <= shown then
            local name = sorted[i]
            lootRowItems[i] = name
            lootNameLbls[i]:SetText(name)
            lootCountLbls[i]:SetText("x" .. (S.lootCount[name] or 0))
            ShowSafe(lootHideBtns[i], true)
        else
            lootRowItems[i] = nil
            lootNameLbls[i]:SetText("")
            lootCountLbls[i]:SetText("")
            ShowSafe(lootHideBtns[i], false)
        end
    end

    local extra = #sorted - MAX_LOOT_ROWS
    local hiddenCount = 0
    for _ in pairs(S.lootHidden) do hiddenCount = hiddenCount + 1 end
    local moreParts = {}
    if extra > 0       then moreParts[#moreParts + 1] = "+ " .. extra .. " more..." end
    if hiddenCount > 0 then moreParts[#moreParts + 1] = "(" .. hiddenCount .. " hidden)" end
    lootMoreLbl:SetText(table.concat(moreParts, "  "))
end

-- -------------------------
-- Event handlers
-- -------------------------
local function ItemName(link)
    if type(link) ~= "string" or link == "" then return "Item" end
    local ok, info = pcall(function() return X2Item:InfoFromLink(link) end)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
        return info.name
    end
    local n = link:match("%[(.-)%]")
    if n and n ~= "" then return n end
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
            S.xp    = S.xp    + n
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
        S.lootTotal       = S.lootTotal + cnt
        if not priceSearched[name] then
            priceSearched[name] = true
            SafePcall("ItemInfo:" .. name, function()
                local iinfo = X2Item:InfoFromLink(itemLink)
                if type(iinfo) == "table" and iinfo.itemType then
                    table.insert(priceQueue, {
                        name      = name,
                        itemType  = iinfo.itemType,
                        itemGrade = iinfo.itemGrade or 0,
                    })
                end
            end)
        end
        local honor = ITEM_HONOR[name]
        if honor then S.honor = S.honor + honor * cnt end
    end)
end)

-- -------------------------
-- Update loop
-- -------------------------
local updater = CreateEmptyWindow("PG_updater", "UIParent")
SetExtentSafe(updater, 1, 1)
RemoveAllAnchorsSafe(updater)
AddAnchorSafe(updater, "TOPLEFT", "UIParent", -2000, -2000)
ShowSafe(updater, true)

local acc = 0
updater:SetHandler("OnUpdate", function(self, frameTime)
    local dt = (tonumber(frameTime) or 0) / 1000
    if S.running then S.elapsed = S.elapsed + dt end
    acc = acc + dt
    if acc < UI_REFRESH_SEC then return end
    acc = 0
    Refresh()

    if #priceQueue > 0 and os.time() - ahLastTrigger >= AH_COOLDOWN then
        local req     = table.remove(priceQueue, 1)
        ahLastTrigger = os.time()
        pricePending[req.name] = req
        SafePcall("AHTrigger:" .. req.name, function()
            X2Auction:GetLowestPrice(req.itemType, req.itemGrade)
        end)
    end
    for nm, req in pairs(pricePending) do
        local p
        SafePcall("AHPoll:" .. nm, function()
            p = X2Auction:GetLowestPrice(req.itemType, req.itemGrade)
        end)
        if p ~= nil then
            priceCache[nm]    = parseMoney(tostring(p))
            pricePending[nm]  = nil
        end
    end
end)

Refresh()
Log("Loaded v" .. VERSION .. " - open from ESC menu (Shop/Quality of Life).")

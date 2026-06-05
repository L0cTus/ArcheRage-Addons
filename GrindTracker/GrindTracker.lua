-- GrindTracker.lua
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
ADDON:ImportAPI(API_TYPE.AUCTION.id)
ADDON:ImportAPI(API_TYPE.MAP.id)

local ADDON_NAME = "GrindTracker"
local VERSION    = "1.2.1"

-- =========================
-- Settings (editable knobs)
-- =========================
local DEFAULT_PANEL_X = 740
local DEFAULT_PANEL_Y = 220
local UI_REFRESH_SEC  = 1.0    -- label refresh throttle
local MAX_LOOT_ROWS   = 11     -- visible loot rows before "+N more"
local MAX_SESSIONS         = 10     -- kept for legacy; use MAX_HIST_ROWS / MAX_STORED_SESSIONS
local MAX_HIST_ROWS        = 20     -- pre-created UI row slots (max sessions displayed per page)
local MAX_STORED_SESSIONS  = 100    -- total sessions saved to disk
local MAX_DETAIL_LOOT      = 20
local DETAIL_W        = 480
local DETAIL_PAD      = 16
local HIST_W    = 520
local HIST_RH1  = 16
local HIST_RH2  = 15
local HIST_GAP  = 7
local HIST_PAD  = 18

-- Colours
local C_LABEL = { 0.78, 0.74, 0.62 }
local C_VALUE = { 1.00, 1.00, 1.00 }
local C_GOLD  = { 0.95, 0.80, 0.30 }
local C_XP    = { 0.55, 0.80, 1.00 }
local C_HDR   = { 0.95, 0.85, 0.55 }
local C_HONOR = { 0.80, 0.55, 1.00 }

-- Honor granted per gem on loot. Values confirmed from in-game tooltips.
-- Edit names/values if your server uses different tiers.
local ITEM_HONOR = {
    ["Faint Honor Gem"]     =  50,
    ["Dim Honor Gem"]       = 100,
    ["Vivid Honor Gem"]     = 200,
    ["Brilliant Honor Gem"] = 500,
}

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
            local lx = tonumber(d.x)
            local ly = tonumber(d.y)
            -- Discard coords that are clearly off-screen (prevents stuck windows).
            if lx and ly and lx >= -50 and lx <= 3840 and ly >= -50 and ly <= 2160 then
                x = lx
                y = ly
            end
            vis = (tonumber(d.visible) or 0) == 1
        end
    end)
    return x, y, vis
end

-- Forward declarations so ResetPositions can reference the windows.
local win, lootWin, histWin
local noteLabel   -- note display on main window
local RefreshHistory  -- forward declaration; defined after history window is built
local ratesLabel  -- DEPRECATED, kept for back-compat with Refresh
local xpRateLabel    -- compact XP% display, top-left of main window
local dropRateLabel  -- compact Drop% display, top-left of main window
local histDateLbls  = {}
local histStatsLbls = {}
local histDeleteBtns = {}

local histClickBtns = {}
local hwClearBtn    = nil

-- Pagination state (forward-declared so all closures can capture them)
local sessionsPerPage   = 10   -- 10 or 20; user-toggleable
local histPage          = 1    -- current page (1-indexed)
local histSessionIdxFor = {}   -- maps UI row slot -> actual session list index
local histPageLabel     = nil
local histPrevBtn       = nil
local histNextBtn       = nil
local histPerPageBtn    = nil
local detailCurrentIdx  = 0
local dtNoteLabel       = nil
local dtDateLabel       = nil
local dtStatsLabel      = nil
local dtRatesLabel      = nil
local dtLootHdrLabel    = nil
local dtItemNameLbls    = {}
local dtItemCountLbls   = {}
local dtItemPriceLbls   = {}
local dtMoreLabel       = nil
local dtDeleteBtn       = nil
local dtExportBtn       = nil
local dtColQtyLabel     = nil   -- "Qty" column header (hidden in list view)
local dtColPriceLabel   = nil   -- "Value" column header (hidden in list view)

local function ResetPositions()
    SafePcall("ResetPositions", function()
        ADDON:ClearData("panel")
        ADDON:ClearData("loot")
        -- Move live windows back to default right now, don't wait for reload.
        if win and type(win.RemoveAllAnchors) == "function" then
            RemoveAllAnchorsSafe(win)
            AddAnchorSafe(win, "TOPLEFT", "UIParent", DEFAULT_PANEL_X, DEFAULT_PANEL_Y)
            ShowSafe(win, true)
        end
        if lootWin and type(lootWin.RemoveAllAnchors) == "function" then
            RemoveAllAnchorsSafe(lootWin)
            AddAnchorSafe(lootWin, "TOPLEFT", "UIParent", DEFAULT_PANEL_X + 310, DEFAULT_PANEL_Y)
        end
        if histWin and type(histWin.RemoveAllAnchors) == "function" then
            RemoveAllAnchorsSafe(histWin)
            AddAnchorSafe(histWin, "TOPLEFT", "UIParent", DEFAULT_PANEL_X, DEFAULT_PANEL_Y + 220)
        end
        Log("Positions reset. Windows moved to default.")
    end)
end

local S = {
    running   = false,
    elapsed   = 0,
    kills     = 0,
    xp        = 0,
    coin      = 0,
    deaths    = 0,
    honor     = 0,    -- honor from ITEM_HONOR gem drops
    note      = "",
    zone      = "",
    mainZone  = "",
    startTs   = 0,
    lootOrder  = {},
    lootCount  = {},
    lootHidden = {},  -- items hidden from the loot display
    lootTotal  = 0,
    lootMeta   = {},
}

local playerName  = nil
local valLabels   = {}
local lootNameLbls = {}
local lootCountLbls = {}
local lootHideBtns  = {}
local lootRowItems  = {}   -- name currently displayed in each row slot
local lootMoreLbl = nil
local startBtn    = nil

-- =========================
-- Auction House price lookup
-- ==========================
-- Architecture:
--   * Each unique looted item is queued for one AH search after first looting.
--   * Searches run in the background, throttled by AH_COOLDOWN seconds.
--   * Searches pause while the AH window is open (avoid interrupting the user).
--   * Cached prices last 1 day (AH_CACHE_TTL). Persisted via SaveData so the
--     cache survives client restarts.
--   * Items that return zero matching results are blacklisted for 1 day so
--     we don't keep hammering on unsellables.
--   * Lookups can be toggled on/off via a panel button.
-- =========================
local AH_COOLDOWN   = 1.5      -- seconds between AH searches (a little above ahscanner's 1.2)
local AH_TIMEOUT    = 5        -- give up after this many seconds
local AH_CACHE_TTL  = 86400    -- 1 day in seconds

local AH = {
    enabled       = true,      -- toggled by user via button
    ahWindowOpen  = false,     -- true while in-game AH UI is open (best-effort)
    queue         = {},        -- list of { name, itemType, grade } to look up
    queuedSet     = {},        -- name -> true to dedupe queue entries
    cache         = {},        -- name -> { price = copper_per_item, ts = os.time() }
    blacklist     = {},        -- name -> ts  (unsellable; will retry after TTL)
    inFlight      = nil,       -- the entry currently being searched, or nil
    inFlightStart = 0,         -- os.time() when current search began
    lastSearchAt  = 0,         -- os.time() of last search dispatched
}

-- Helper: estimated total item value across the whole session.
local function ahItemTotalCopper()
    local total = 0
    for name, count in pairs(S.lootCount) do
        local row = AH.cache[name]
        if row and row.price and row.price > 0 then
            total = total + row.price * count
        end
    end
    return total
end

local function ahLoadCache()
    SafePcall("AH.LoadCache", function()
        local d = ADDON:LoadData("ah_cache")
        if type(d) == "table" then
            local now = os.time()
            for name, row in pairs(d) do
                if type(row) == "table" and tonumber(row.ts) and tonumber(row.price)
                   and (now - row.ts) < AH_CACHE_TTL then
                    AH.cache[name] = { price = tonumber(row.price), ts = tonumber(row.ts) }
                end
            end
        end
        local b = ADDON:LoadData("ah_blacklist")
        if type(b) == "table" then
            local now = os.time()
            for name, ts in pairs(b) do
                if tonumber(ts) and (now - ts) < AH_CACHE_TTL then
                    AH.blacklist[name] = tonumber(ts)
                end
            end
        end
        local s = ADDON:LoadData("ah_settings")
        if type(s) == "table" and s.enabled ~= nil then
            AH.enabled = (tonumber(s.enabled) or 1) == 1
        end
    end)
end

local function ahSaveCache()
    SafePcall("AH.SaveCache", function()
        ADDON:ClearData("ah_cache")
        ADDON:SaveData("ah_cache", AH.cache)
    end)
end

local function ahSaveBlacklist()
    SafePcall("AH.SaveBlacklist", function()
        ADDON:ClearData("ah_blacklist")
        ADDON:SaveData("ah_blacklist", AH.blacklist)
    end)
end

local function ahSaveSettings()
    SafePcall("AH.SaveSettings", function()
        ADDON:ClearData("ah_settings")
        ADDON:SaveData("ah_settings", { enabled = AH.enabled and 1 or 0 })
    end)
end

-- Enqueue an item if it isn't already known.
local function ahMaybeEnqueue(name, itemType, grade)
    if not AH.enabled then return end
    if not name or name == "" or name == "Item" then return end
    if not itemType or itemType <= 0 then return end
    if AH.cache[name] then return end          -- already priced
    if AH.blacklist[name] then return end       -- known unsellable
    if AH.queuedSet[name] then return end       -- already pending
    AH.queuedSet[name] = true
    table.insert(AH.queue, { name = name, itemType = itemType, grade = grade or 1 })
end

-- Drain one item off the queue per AH_COOLDOWN seconds, only if AH UI is closed.
-- Called from the main OnUpdate loop.
local function ahTick(nowSec)
    if not AH.enabled then return end
    if AH.ahWindowOpen then return end

    -- Time out a stuck search.
    if AH.inFlight and (nowSec - AH.inFlightStart) > AH_TIMEOUT then
        AH.blacklist[AH.inFlight.name] = nowSec  -- conservatively treat as unfindable
        AH.queuedSet[AH.inFlight.name] = nil
        AH.inFlight = nil
        ahSaveBlacklist()
    end

    if AH.inFlight then return end                                -- waiting for result
    if (nowSec - AH.lastSearchAt) < AH_COOLDOWN then return end   -- cooldown
    if #AH.queue == 0 then return end                             -- nothing to do

    local entry = table.remove(AH.queue, 1)
    AH.inFlight       = entry
    AH.inFlightStart  = nowSec
    AH.lastSearchAt   = nowSec

    -- X2Auction:SearchAuctionArticle(page, minLvl, maxLvl, gradeFilter=1(ALL),
    --   category=0(ALL), exactMatch=false, keywords, minPrice, maxPrice)
    SafePcall("AH.Search", function()
        X2Auction:SearchAuctionArticle(1, 0, 999, 1, 0, false, entry.name, "0", "0")
    end)
end

-- AUCTION_ITEM_SEARCHED handler: read the page-1 results and store best price.
-- AH search is substring-based, so we must compare names exactly to avoid e.g.
-- "Iron Ingot" picking up "Iron Ingot Box" listings.
local function ahOnSearched()
    if not AH.inFlight then return end
    local entry = AH.inFlight
    AH.inFlight = nil

    local best = nil
    SafePcall("AH.ReadResults", function()
        local count = X2Auction:GetSearchedItemCount() or 0
        for i = 1, count do
            local info = X2Auction:GetSearchedItemInfo(i)
            if info and info.name == entry.name then
                local totalCp  = tonumber(info.directPriceStr) or 0
                local stack    = math.max(1, tonumber(info.stack) or 1)
                local perItem  = totalCp / stack
                if perItem > 0 and (best == nil or perItem < best) then
                    best = perItem
                end
            end
        end
    end)

    if best and best > 0 then
        AH.cache[entry.name] = { price = best, ts = os.time() }
        AH.queuedSet[entry.name] = nil
        ahSaveCache()
    else
        AH.blacklist[entry.name] = os.time()
        AH.queuedSet[entry.name] = nil
        ahSaveBlacklist()
    end
end

local function ahOnToggle()
    -- Fires on both open and close; flip the flag conservatively. Searches
    -- only run while it is false, so if we get this wrong it just means we
    -- skip some searches until the next toggle.
    AH.ahWindowOpen = not AH.ahWindowOpen
end

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

-- 2-decimal variant used for kills/h where extra precision is useful.
-- 1734 -> "1.73k",  234 -> "234",  1200000 -> "1.2M" (M+ stays 1dp, plenty)
local function shortNum2(n)
    n = n or 0
    local a = math.abs(n)
    if a >= 1e9 then return string.format("%.1fB", n / 1e9)
    elseif a >= 1e6 then return (string.format("%.1f", n / 1e6):gsub("%.0$","")) .. "M"
    elseif a >= 1e3 then return string.format("%.2f", n / 1e3):gsub("%.?0+$","") .. "k"
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

-- For estimate prices in the loot list: show only the single most significant unit.
-- Estimates aren't precise enough to warrant full breakdown, and it keeps columns compact.
-- >= 1g  →  "2g" / "14g"
-- >= 1s  →  "50s"
-- < 1s   →  "30c"
local function fmtPriceEst(cp)
    cp = math.floor(cp or 0)
    local g = math.floor(cp / 10000)
    if g >= 1 then return g .. "g" end
    local s = math.floor(cp / 100)
    if s >= 1 then return s .. "s" end
    return cp .. "c"
end

-- =========================
-- Session history
-- =========================
-- Scan all zone IDs to find the one where isCurrentZone==true.
-- GetZoneStateInfoByZoneId returns a table with zoneName and isCurrentZone fields.
-- Stops at the first match so it's fast in practice.
local ZONE_ID_MAX = 160   -- extend if new zones are added
local function GetCurrentZoneName()
    local result = ""
    SafePcall("GetCurrentZoneName", function()
        for id = 0, ZONE_ID_MAX do
            local ok, info = pcall(function()
                return X2Map:GetZoneStateInfoByZoneId(id)
            end)
            if ok and type(info) == "table" and info.isCurrentZone then
                local name = tostring(info.zoneName or "")
                if name ~= "" then
                    result = name
                    break
                end
            end
        end
    end)
    return result
end

local function GetTopLoot(n)
    local sorted = {}
    for _, name in ipairs(S.lootOrder) do
        table.insert(sorted, { name = name, count = S.lootCount[name] or 0 })
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    local result = {}
    for i = 1, math.min(n, #sorted) do
        table.insert(result, sorted[i].name .. " x" .. sorted[i].count)
    end
    return result
end

local function LoadSessions()
    local d = ADDON:LoadData("sessions")
    if type(d) == "table" and type(d.list) == "table" then return d.list end
    return {}
end

local function GetRates()
    local xp_bonus, drop_bonus = 0, 0
    SafePcall("GetRates", function()
        local info = X2Unit:UnitInfo("player")
        if type(info) == "table" then
            xp_bonus   = tonumber(info.exp_mul)      or 0
            drop_bonus = tonumber(info.drop_rate_mul) or 0
        end
    end)
    return xp_bonus, drop_bonus
end

local function SaveSession()
    if S.elapsed < 5 then
        Log("Session too short to save (" .. math.floor(S.elapsed) .. "s < 5s)")
        return
    end
    SafePcall("SaveSession", function()
        local xp_bonus, drop_bonus = GetRates()
        local top3 = table.concat(GetTopLoot(3), " | ")
        local zone = (S.note ~= "") and S.note
                  or (S.mainZone ~= "" and S.zone ~= "") and (S.mainZone .. " - " .. S.zone)
                  or (S.mainZone ~= "") and S.mainZone
                  or S.zone
        -- Loot snapshot: save full item list as pipe-separated strings.
        -- Sorted by count descending so the most-looted items are first.
        local lootSorted = {}
        for _, nm in ipairs(S.lootOrder) do
            lootSorted[#lootSorted+1] = { n = nm, c = S.lootCount[nm] or 0 }
        end
        table.sort(lootSorted, function(a, b) return a.c > b.c end)
        local lootNames, lootCounts = {}, {}
        for _, row in ipairs(lootSorted) do
            lootNames[#lootNames+1]  = row.n
            lootCounts[#lootCounts+1] = tostring(row.c)
        end
        local startTsKey = tostring(S.startTs)
        local entry = {
            ts         = os.time(),
            startTs    = startTsKey,
            elapsed    = math.floor(S.elapsed),
            kills      = S.kills,
            xp         = S.xp,
            coin       = S.coin,
            deaths     = S.deaths,
            honor      = S.honor,
            items      = S.lootTotal,
            value      = ahItemTotalCopper(),
            note       = zone,
            top3       = top3,
            xp_bonus   = xp_bonus,
            drop_bonus = drop_bonus,
            honor      = S.honor,
            lootOrder  = table.concat(lootNames,  " | "),
            lootCounts = table.concat(lootCounts, " | "),
        }
        local sessions = LoadSessions()
        -- Compare as strings -- robust against number/string deserialisation quirks.
        local same = (#sessions > 0)
                    and S.startTs ~= 0
                    and tostring(sessions[1].startTs) == startTsKey
        if same then
            sessions[1] = entry
        else
            table.insert(sessions, 1, entry)
            while #sessions > MAX_STORED_SESSIONS do table.remove(sessions) end
        end
        ADDON:ClearData("sessions")
        ADDON:SaveData("sessions", { list = sessions })
        Log("Session saved.")
        -- Live-refresh the history window if it's open (guard against scope/definition issues).
        if histWin and histWin:IsValidUIObject() and histWin:IsVisible() then
            SafePcall("RefreshHistory", function()
                if type(RefreshHistory) == "function" then RefreshHistory() end
            end)
        end
    end)
end

local MONTHS = { "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec" }

-- Rebuild {order, counts} from a saved session's pipe-separated loot strings.
local function lootFromSession(s)
    local order, counts = {}, {}
    if type(s.lootOrder) ~= "string" or s.lootOrder == "" then return order, counts end
    for name in s.lootOrder:gmatch("([^|]+)") do
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then order[#order+1] = name end
    end
    local i = 0
    for cnt in (s.lootCounts or ""):gmatch("([^|]+)") do
        i = i + 1
        if order[i] then counts[order[i]] = tonumber(cnt:match("^%s*(.-)%s*$")) or 0 end
    end
    return order, counts
end

-- Export a session entry to GrindTracker_export.txt (appended, one entry per export).
local function ExportSession(s)
    if not s then return end
    SafePcall("ExportSession", function()
        local dateStr = "?"
        SafePcall("expDate", function()
            local t = os.date("*t", s.ts or 0)
            dateStr = string.format("%s %02d %02d:%02d",
                MONTHS[t.month] or "?", t.day, t.hour, t.min)
        end)
        local el = s.elapsed or 0
        local h  = math.floor(el / 3600)
        local m  = math.floor((el % 3600) / 60)
        local sec = el % 60
        local dur = (h > 0) and (h .. "h " .. m .. "m")
               or   (m > 0) and (m .. "m " .. sec .. "s")
               or   (sec .. "s")
        local lines = {
            "=== GrindTracker Session ===",
            "Date:      " .. dateStr,
            "Zone:      " .. (s.note or ""),
            "Duration:  " .. dur,
            "Kills:     " .. tostring(s.kills or 0),
            "Gold:      " .. fmtMoneyClean(s.coin or 0),
            "Items est: " .. fmtMoneyClean(s.value or 0),
            "Deaths:    " .. tostring(s.deaths or 0),
        }
        local xpb  = tonumber(s.xp_bonus)  or 0
        local drpb = tonumber(s.drop_bonus) or 0
        if xpb > 0 or drpb > 0 then
            lines[#lines+1] = string.format("XP Bonus:  %d%%  |  Drop Bonus: %d%%", 100+xpb, 100+drpb)
        end
        local order, counts = lootFromSession(s)
        if #order > 0 then
            lines[#lines+1] = "--- Loot ---"
            for _, name in ipairs(order) do
                lines[#lines+1] = string.format("  %-38s x%d", name, counts[name] or 0)
            end
        elseif type(s.top3) == "string" and s.top3 ~= "" then
            lines[#lines+1] = "Top items: " .. s.top3
        end
        lines[#lines+1] = ""
        local f = io.open("GrindTracker_export.txt", "a")
        if f then
            f:write(table.concat(lines, "\n") .. "\n")
            f:close()
            Log("Exported to GrindTracker_export.txt (in game folder)")
        else
            Log("Export failed -- cannot create file")
        end
    end)
end

-- ShowDetail: populate and open the detail window for the i-th session slot.
local histListH = 0

local function ComputeHistListH()
    local rowH = HIST_RH1 + 1 + HIST_RH2 + HIST_GAP
    return 40 + sessionsPerPage * rowH + 62  -- 62px footer: nav row + per-page row
end

local function ShowHistList()
    for i = 1, MAX_HIST_ROWS do
        if histDateLbls[i]  then ShowSafe(histDateLbls[i],  true) end
        if histStatsLbls[i] then ShowSafe(histStatsLbls[i], true) end
    end
    if hwClearBtn    then ShowSafe(hwClearBtn, true) end
    if histPageLabel then ShowSafe(histPageLabel, true) end
    if histPrevBtn   then ShowSafe(histPrevBtn, true) end
    if histNextBtn   then ShowSafe(histNextBtn, true) end
    if histPerPageBtn then ShowSafe(histPerPageBtn, true) end
    local dw = { dtBackBtn, dtNoteLabel, dtDateLabel, dtStatsLabel, dtRatesLabel,
                 dtLootHdrLabel, dtColQtyLabel, dtColPriceLabel, dtMoreLabel, dtExportBtn, dtDeleteBtn }
    for _, w in ipairs(dw) do if w then ShowSafe(w, false) end end
    for i = 1, MAX_DETAIL_LOOT do
        if dtItemNameLbls[i]  then ShowSafe(dtItemNameLbls[i],  false) end
        if dtItemCountLbls[i] then ShowSafe(dtItemCountLbls[i], false) end
        if dtItemPriceLbls[i] then ShowSafe(dtItemPriceLbls[i], false) end
    end
    histListH = ComputeHistListH()
    SetExtentSafe(histWin, HIST_W, histListH)
end

local function ShowDetail(idx)
    if not histWin or not dtNoteLabel then return end
    local sessions = LoadSessions()
    local s = sessions[idx]
    if not s then return end
    detailCurrentIdx = idx

    for i = 1, MAX_HIST_ROWS do
        if histDateLbls[i]  then ShowSafe(histDateLbls[i],  false) end
        if histStatsLbls[i] then ShowSafe(histStatsLbls[i], false) end
        if histClickBtns[i] then ShowSafe(histClickBtns[i], false) end
    end
    if hwClearBtn     then ShowSafe(hwClearBtn,     false) end
    if histPrevBtn    then ShowSafe(histPrevBtn,    false) end
    if histNextBtn    then ShowSafe(histNextBtn,    false) end
    if histPageLabel  then ShowSafe(histPageLabel,  false) end
    if histPerPageBtn then ShowSafe(histPerPageBtn, false) end
    if dtBackBtn      then ShowSafe(dtBackBtn,      true)  end

    local dateStr = "[ -- ]"
    SafePcall("dtDate", function()
        local t = os.date("*t", s.ts or 0)
        dateStr = string.format("[%s %02d %02d:%02d]",
            MONTHS[t.month] or "?", t.day, t.hour, t.min)
    end)
    dtNoteLabel:SetText((s.note and s.note ~= "") and s.note or "(no label)")
    ShowSafe(dtNoteLabel, true)
    dtDateLabel:SetText(dateStr)
    ShowSafe(dtDateLabel, true)

    local el  = s.elapsed or 0
    local h   = math.floor(el / 3600)
    local m   = math.floor((el % 3600) / 60)
    local sec = el % 60
    local dur = (h > 0) and (h .. "h " .. m .. "m")
             or (m > 0) and (m .. "m " .. sec .. "s")
             or (sec .. "s")
    local sp = { dur, shortNum2(s.kills or 0) .. " kills", fmtMoneyClean(s.coin or 0) .. " looted" }
    if (s.deaths or 0) > 0 then sp[#sp+1] = (s.deaths) .. " deaths" end
    if (s.value or 0) > 0  then sp[#sp+1] = "~" .. fmtMoneyClean(s.value) .. " est" end
    if (s.honor or 0) > 0  then sp[#sp+1] = commafy(s.honor) .. " honor" end
    dtStatsLabel:SetText(table.concat(sp, "  |  "))
    ShowSafe(dtStatsLabel, true)

    local xpb  = tonumber(s.xp_bonus)  or 0
    local drpb = tonumber(s.drop_bonus) or 0
    if xpb > 0 or drpb > 0 then
        dtRatesLabel:SetText(string.format("XP %d%%   .   Drop %d%%", 100+xpb, 100+drpb))
        ShowSafe(dtRatesLabel, true)
    else
        ShowSafe(dtRatesLabel, false)
    end
    ShowSafe(dtLootHdrLabel, true)

    local order, counts = lootFromSession(s)
    local hasLootData = #order > 0
    local shown = math.min(#order, MAX_DETAIL_LOOT)
    for i = 1, MAX_DETAIL_LOOT do
        if i <= shown then
            local name = order[i]
            local cnt  = counts[name] or 0
            dtItemNameLbls[i]:SetText(name)
            dtItemCountLbls[i]:SetText("x" .. cnt)
            local priceRow = AH.cache[name]
            if priceRow and (priceRow.price or 0) > 0 then
                dtItemPriceLbls[i]:SetText(fmtPriceEst(priceRow.price * cnt))
            else
                dtItemPriceLbls[i]:SetText("")
            end
            ShowSafe(dtItemNameLbls[i], true)
            ShowSafe(dtItemCountLbls[i], true)
            ShowSafe(dtItemPriceLbls[i], true)
        else
            ShowSafe(dtItemNameLbls[i], false)
            ShowSafe(dtItemCountLbls[i], false)
            ShowSafe(dtItemPriceLbls[i], false)
        end
    end

    local extra = #order - MAX_DETAIL_LOOT
    local moreTxt = nil
    if extra > 0 then moreTxt = "+ " .. extra .. " more items"
    elseif not hasLootData then
        moreTxt = (type(s.top3) == "string" and s.top3 ~= "") and ("Top: " .. s.top3)
                  or "No loot data (pre-dates this feature)"
    end

    local DT_ITEM_H   = 20
    local DT_LOOT_TOP = 164
    local contentBot  = DT_LOOT_TOP + shown * DT_ITEM_H
    if moreTxt then
        RemoveAllAnchorsSafe(dtMoreLabel)
        AddAnchorSafe(dtMoreLabel, "TOPLEFT", histWin, HIST_PAD, contentBot + 2)
        dtMoreLabel:SetText(moreTxt)
        ShowSafe(dtMoreLabel, true)
        contentBot = contentBot + DT_ITEM_H
    else
        ShowSafe(dtMoreLabel, false)
    end

    local btnY = contentBot + 8
    RemoveAllAnchorsSafe(dtExportBtn)
    AddAnchorSafe(dtExportBtn, "TOPLEFT", histWin, HIST_PAD, btnY)
    RemoveAllAnchorsSafe(dtDeleteBtn)
    AddAnchorSafe(dtDeleteBtn, "TOPLEFT", histWin, HIST_W - HIST_PAD - 116, btnY)
    ShowSafe(dtExportBtn, true)
    ShowSafe(dtDeleteBtn, true)

    SetExtentSafe(histWin, HIST_W, btnY + 36)
end


-- =========================
-- UI Helpers (widget factories used throughout all windows)
-- =========================

local function MakeBtn(parent, id, text, x, y, w, h, onClick)
    local b = parent:CreateChildWidget("button", id, 0, true)
    SetExtentSafe(b, w, h)
    RemoveAllAnchorsSafe(b)
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
        local col
        if type(bgHost.CreateColorDrawable) == "function" then
            col = bgHost:CreateColorDrawable(0, 0, 0, alpha, "background")
        end
        if col then
            AddAnchorSafe(col, "TOPLEFT",     bgHost, -6, -6)
            AddAnchorSafe(col, "BOTTOMRIGHT", bgHost,  6,  6)
            ShowSafe(col, true)
        end
        win._pgSkinApplied = true
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
            if type(self.CorrectOffsetByScreen) == "function" then
                self:CorrectOffsetByScreen()
            end
            if type(onMoved) == "function" then
                local x, y = 0, 0
                if type(self.GetEffectiveOffset) == "function" then
                    x, y = self:GetEffectiveOffset()
                elseif type(self.GetOffset) == "function" then
                    x, y = self:GetOffset()
                end
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
        if type(win.GetEffectiveOffset) == "function" then
            x, y = win:GetEffectiveOffset()
        elseif type(win.GetOffset) == "function" then
            x, y = win:GetOffset()
        end
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

win = CreateEmptyWindow("GT_win", "UIParent")
RemoveAllAnchorsSafe(win)
AddAnchorSafe(win, "TOPLEFT", "UIParent", panelPosX, panelPosY)

-- Title row
MakeLabel(win, "pgTitle", "Grind Tracker", 0, 10, WIN_W, ROW_H, 17, ALIGN_CENTER, C_HDR)

-- Compact XP / Drop rate display in the top-left corner (2 lines, small font).
-- Stays empty when no bonus is active.
xpRateLabel   = MakeLabel(win, "gt_xp_rate",   "", 8,  6, 82, 12, 10, ALIGN_LEFT, { 0.55, 0.75, 0.55 })
dropRateLabel = MakeLabel(win, "gt_drop_rate", "", 8, 19, 82, 12, 10, ALIGN_LEFT, { 0.55, 0.75, 0.55 })

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
local TOTAL_RIGHT  = 172   -- right edge of the total column
local HOURLY_X     = 196   -- left edge of the /h column (24px gap for breathing room)
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
StatRow("honor", "Honor", y, C_HONOR); y = y + ROW_H
y = y + 8

-- Four buttons: Start/Pause | Reset | Loot | History
local btnW = math.floor((WIN_W - 28 - 18) / 4)  -- 4 buttons, 6px gaps

startBtn = MakeBtn(win, "pgStart", "Start", 14, y, btnW, 26, function()
    S.running = not S.running
    if S.running then
        if S.startTs == 0 then S.startTs = os.time() end
        -- Refresh main zone on Start (catches teleports since last activity).
        local z = GetCurrentZoneName()
        if z ~= "" then S.mainZone = z end
    else
        SaveSession()
    end
    startBtn:SetText(S.running and "Pause" or "Resume")
end)

MakeBtn(win, "gtReset", "Reset", 14 + (btnW + 6), y, btnW, 26, function()
    SaveSession()
    S.running   = false
    S.elapsed   = 0
    S.kills     = 0
    S.xp        = 0
    S.coin      = 0
    S.deaths    = 0
    S.honor     = 0
    S.startTs   = 0
    S.lootOrder  = {}
    S.lootCount  = {}
    S.lootHidden = {}
    S.lootTotal  = 0
    S.lootMeta   = {}
    if startBtn then startBtn:SetText("Start") end
end)

MakeBtn(win, "gtLootBtn", "Loot", 14 + (btnW + 6) * 2, y, btnW, 26, function()
    if lootWin then ShowAndPersist(lootWin, "loot", not lootWin:IsVisible()) end
end)

MakeBtn(win, "gtHistBtn", "History", 14 + (btnW + 6) * 3, y, btnW, 26, function()
    if histWin then
        local show = not histWin:IsVisible()
        if show then
            ShowHistList()
            RefreshHistory()
        end
        ShowAndPersist(histWin, "history", show)
    end
end)

y = y + 26 + 6

-- Note display row (set via !gt note <text>)
noteLabel = MakeLabel(win, "gt_note_display", "No note  --  use !gt note <text>",
    8, y, WIN_W - 16, 16, 10, ALIGN_CENTER, { 0.50, 0.50, 0.50 })
y = y + 16 + 8

SetExtentSafe(win, WIN_W, y)
ApplyDefaultWindowSkin(win, 0.55)
MakeDraggable(win, function(x, y) SavePanel("panel", x, y, win:IsVisible()) end)
-- Restore visibility from save (defaults to hidden -- user opens via ESC menu).
ShowSafe(win, savedMainVisible and true or false)

-- =========================
-- Separate Loot window
-- =========================
local LOOT_W = 400

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

-- ---- Gold breakdown header: two rows only (Total visible on main panel) ----
local ly = 36

local BD_LABEL_X  = 18
local BD_VALUE_W  = 150
local BD_VALUE_X  = LOOT_W - 14 - BD_VALUE_W

local lwLootedLbl = MakeLabel(lootWin, "lw_looted_l", "Looted gold:",  BD_LABEL_X, ly, 150, LOOT_RH, 14, ALIGN_LEFT,  C_LABEL)
local lwLootedVal = MakeLabel(lootWin, "lw_looted_v", "0c",            BD_VALUE_X, ly, BD_VALUE_W, LOOT_RH, 14, ALIGN_RIGHT, C_GOLD)
ly = ly + LOOT_RH

local lwItemsLbl  = MakeLabel(lootWin, "lw_items_l",  "Items (est):",  BD_LABEL_X, ly, 150, LOOT_RH, 14, ALIGN_LEFT,  C_LABEL)
local lwItemsVal  = MakeLabel(lootWin, "lw_items_v",  "0c",            BD_VALUE_X, ly, BD_VALUE_W, LOOT_RH, 14, ALIGN_RIGHT, C_GOLD)
ly = ly + LOOT_RH + 4

-- AH status line + toggle button on the same row.
local lwAhStatus = MakeLabel(lootWin, "lw_ah_status", "", BD_LABEL_X, ly, LOOT_W - BD_LABEL_X - 110, LOOT_RH, 12, ALIGN_LEFT, { 0.7, 0.7, 0.7 })
local lwAhToggle = nil
lwAhToggle = MakeBtn(lootWin, "lw_ah_toggle", AH.enabled and "AH: ON" or "AH: OFF",
    LOOT_W - 100, ly - 2, 86, 22, function()
        AH.enabled = not AH.enabled
        ahSaveSettings()
        lwAhToggle:SetText(AH.enabled and "AH: ON" or "AH: OFF")
        if AH.enabled then
            for nm, meta in pairs(S.lootMeta) do
                ahMaybeEnqueue(nm, meta.itemType, meta.grade)
            end
        end
    end)
ly = ly + LOOT_RH + 8

-- Name | Count | Price
-- Count is narrow (just "x15") right-aligned in its own column so all counts
-- line up. Price is a separate right-aligned column that is empty when unknown.
-- This way nothing gets crammed together and names have maximum space.
local PAD       = 14
local HIDE_W    = 14
local HIDE_X    = LOOT_W - PAD - HIDE_W
local PRICE_W   = 58   -- "14g 28s" still fits
local COUNT_W2  = 44   -- "x9999" fits fine
local COL_GAP   = 5
local PRICE_X   = HIDE_X - COL_GAP - PRICE_W
local COUNT_X2  = PRICE_X - COL_GAP - COUNT_W2
local NAME_X    = 18
local NAME_W    = COUNT_X2 - COL_GAP - NAME_X

local lootPriceLbls = {}
for i = 1, MAX_LOOT_ROWS do
    lootNameLbls[i]  = MakeLabel(lootWin, "lw_n_" .. i, "", NAME_X,   ly, NAME_W,  LOOT_RH, 14, ALIGN_LEFT,  { 0.9, 0.9, 0.9 })
    lootCountLbls[i] = MakeLabel(lootWin, "lw_c_" .. i, "", COUNT_X2, ly, COUNT_W2, LOOT_RH, 14, ALIGN_RIGHT, C_VALUE)
    if lootCountLbls[i].style and lootCountLbls[i].style.SetEllipsis then
        lootCountLbls[i].style:SetEllipsis(false)
    end
    lootPriceLbls[i] = MakeLabel(lootWin, "lw_p_" .. i, "", PRICE_X,  ly, PRICE_W, LOOT_RH, 14, ALIGN_RIGHT, C_GOLD)
    local idx = i
    lootHideBtns[i] = MakeBtn(lootWin, "lw_hide_" .. i, "-", HIDE_X, ly + 2, HIDE_W, LOOT_RH - 4, function()
        local name = lootRowItems[idx]
        if name and name ~= "" then
            S.lootHidden[name] = true
        end
    end)
    ShowSafe(lootHideBtns[i], false)
    ly = ly + LOOT_RH
end
lootMoreLbl = MakeLabel(lootWin, "lw_more", "", NAME_X, ly, LOOT_W - NAME_X - PAD, LOOT_RH, 13, ALIGN_LEFT, { 0.7, 0.7, 0.7 })
ly = ly + LOOT_RH + 12

SetExtentSafe(lootWin, LOOT_W, ly)
ApplyDefaultWindowSkin(lootWin, 0.60)
MakeDraggable(lootWin, function(x, y) SavePanel("loot", x, y, lootWin:IsVisible()) end)
ShowSafe(lootWin, savedLootVisible and true or false)

-- =========================
-- Session History window
-- =========================
-- History window constants are defined at the top of the file.

local savedHistX, savedHistY, savedHistVisible = LoadPanel("history")

histWin = CreateEmptyWindow("GT_histWin", "UIParent")
RemoveAllAnchorsSafe(histWin)
if savedHistX and savedHistY then
    AddAnchorSafe(histWin, "TOPLEFT", "UIParent", savedHistX, savedHistY)
else
    AddAnchorSafe(histWin, "TOPLEFT", "UIParent", DEFAULT_PANEL_X + 310, DEFAULT_PANEL_Y)
end

MakeLabel(histWin, "hw_title", "Session History", 0, 10, HIST_W, ROW_H, 17, ALIGN_CENTER, C_HDR)
MakeBtn(histWin, "hw_close", "X", HIST_W - 32, 8, 22, 18, function()
    ShowHistList()
    ShowAndPersist(histWin, "history", false)
end)

-- Note: session deletion is handled by the Delete button inside the detail window.

local hy = 40
for i = 1, MAX_HIST_ROWS do
    -- Date+note label (display only, no pick).
    histDateLbls[i] = MakeLabel(histWin, "hw_d_" .. i, "",
        HIST_PAD, hy, HIST_W - HIST_PAD * 2 - 28, HIST_RH1, 12, ALIGN_LEFT, C_HDR)
    -- Small ">" button — uses histSessionIdxFor for correct page-aware index.
    local rowIdx = i
    local arrowBtn = MakeBtn(histWin, "hw_btn_" .. i, ">",
        HIST_W - HIST_PAD - 22, hy, 22, HIST_RH1,
        function()
            SafePcall("ShowDetail", function()
                ShowDetail(histSessionIdxFor[rowIdx] or rowIdx)
            end)
        end)
    ShowSafe(arrowBtn, false)
    histClickBtns[i] = arrowBtn
    hy = hy + HIST_RH1 + 1
    histStatsLbls[i] = MakeLabel(histWin, "hw_s_" .. i, "",
        HIST_PAD, hy, HIST_W - HIST_PAD * 2, HIST_RH2, 11, ALIGN_LEFT, C_LABEL)
    hy = hy + HIST_RH2 + HIST_GAP
end

-- History window sized to fit MAX_HIST_ROWS; ShowHistList resizes to sessionsPerPage.
hy = hy + 4   -- small gap after last row
SetExtentSafe(histWin, HIST_W, hy + 62)
ApplyDefaultWindowSkin(histWin, 0.55)

-- ── Footer buttons anchored to BOTTOM so they stay in place when window resizes ──
-- Row 1 (navigation): [< Prev]  Page x/y  [Next >]
histPrevBtn = MakeBtn(histWin, "hw_prev", "< Prev",
    HIST_PAD, 0, 70, 24, function()
        if histPage > 1 then
            histPage = histPage - 1
            RefreshHistory()
        end
    end)
RemoveAllAnchorsSafe(histPrevBtn)
AddAnchorSafe(histPrevBtn, "BOTTOMLEFT", histWin, HIST_PAD, -34)

histPageLabel = MakeLabel(histWin, "hw_page", "Page 1 / 1",
    0, 0, HIST_W, 20, 11, ALIGN_CENTER, { 0.70, 0.70, 0.70 })
RemoveAllAnchorsSafe(histPageLabel)
AddAnchorSafe(histPageLabel, "BOTTOM", histWin, 0, -36)

histNextBtn = MakeBtn(histWin, "hw_next", "Next >",
    0, 0, 70, 24, function()
        local sessions = LoadSessions()
        local totalPages = math.max(1, math.ceil(#sessions / sessionsPerPage))
        if histPage < totalPages then
            histPage = histPage + 1
            RefreshHistory()
        end
    end)
RemoveAllAnchorsSafe(histNextBtn)
AddAnchorSafe(histNextBtn, "BOTTOMRIGHT", histWin, -HIST_PAD, -34)

-- Row 2 (tools): per-page toggle + clear
histPerPageBtn = MakeBtn(histWin, "hw_perpage", "10 / page",
    HIST_PAD, 0, 80, 20, function()
        sessionsPerPage = (sessionsPerPage == 10) and 20 or 10
        histPage = 1
        histPerPageBtn:SetText(sessionsPerPage .. " / page")
        histListH = ComputeHistListH()
        SetExtentSafe(histWin, HIST_W, histListH)
        RefreshHistory()
    end)
RemoveAllAnchorsSafe(histPerPageBtn)
AddAnchorSafe(histPerPageBtn, "BOTTOMLEFT", histWin, HIST_PAD, -6)

hwClearBtn = MakeBtn(histWin, "hw_clear", "Clear History",
    0, 0, 110, 20, function()
        ADDON:ClearData("sessions")
        histPage = 1
        RefreshHistory()
        Log("Session history cleared.")
    end)
RemoveAllAnchorsSafe(hwClearBtn)
AddAnchorSafe(hwClearBtn, "BOTTOM", histWin, 0, -6)

-- ── Detail panel (embedded in histWin, hidden until a row is clicked) ────
histListH = ComputeHistListH()

local DP2 = HIST_PAD
local DW2 = HIST_W
local DT_QTY_X2    = DW2 - DP2 - 150
local DT_PRICE_X2  = DW2 - DP2 - 80
local DT_ITEM_H2   = 20
local DT_LOOT_TOP2 = 164

dtBackBtn = MakeBtn(histWin, "dt_back", "< Back", DP2, 12, 68, 18, function()
    ShowHistList()
    RefreshHistory()
end)
ShowSafe(dtBackBtn, false)

dtNoteLabel = MakeLabel(histWin, "dt_note", "", DP2, 42, DW2 - DP2 * 2, 24, 17, ALIGN_LEFT, C_HDR)
dtDateLabel = MakeLabel(histWin, "dt_date", "", DP2, 72, DW2 - DP2 * 2, 16, 11, ALIGN_LEFT, { 0.60, 0.58, 0.50 })
dtStatsLabel  = MakeLabel(histWin, "dt_stats",  "", DP2, 96,  DW2 - DP2 * 2, 18, 12, ALIGN_LEFT, C_LABEL)
dtRatesLabel  = MakeLabel(histWin, "dt_rates",  "", DP2, 120, DW2 - DP2 * 2, 14, 11, ALIGN_LEFT, { 0.55, 0.75, 0.55 })
dtLootHdrLabel = MakeLabel(histWin, "dt_loot_hdr", "Item", DP2, 144, 300, 16, 11, ALIGN_LEFT, { 0.70, 0.65, 0.55 })
dtColQtyLabel   = MakeLabel(histWin, "dt_col_qty",   "Qty",   DT_QTY_X2,   144, 60, 16, 11, ALIGN_RIGHT, { 0.70, 0.65, 0.55 })
dtColPriceLabel = MakeLabel(histWin, "dt_col_price", "Value", DT_PRICE_X2, 144, 80, 16, 11, ALIGN_RIGHT, { 0.70, 0.65, 0.55 })
ShowSafe(dtNoteLabel,     false)
ShowSafe(dtDateLabel,     false)
ShowSafe(dtStatsLabel,    false)
ShowSafe(dtRatesLabel,    false)
ShowSafe(dtLootHdrLabel,  false)
ShowSafe(dtColQtyLabel,   false)
ShowSafe(dtColPriceLabel, false)

for i = 1, MAX_DETAIL_LOOT do
    local iy = DT_LOOT_TOP2 + (i - 1) * DT_ITEM_H2
    dtItemNameLbls[i]  = MakeLabel(histWin, "dt_n_" .. i, "", DP2,        iy, 300, DT_ITEM_H2, 13, ALIGN_LEFT,  { 0.90, 0.88, 0.78 })
    dtItemCountLbls[i] = MakeLabel(histWin, "dt_c_" .. i, "", DT_QTY_X2,  iy,  60, DT_ITEM_H2, 13, ALIGN_RIGHT, C_VALUE)
    dtItemPriceLbls[i] = MakeLabel(histWin, "dt_p_" .. i, "", DT_PRICE_X2,iy,  80, DT_ITEM_H2, 13, ALIGN_RIGHT, C_GOLD)
    ShowSafe(dtItemNameLbls[i],  false)
    ShowSafe(dtItemCountLbls[i], false)
    ShowSafe(dtItemPriceLbls[i], false)
end
dtMoreLabel = MakeLabel(histWin, "dt_more", "", DP2, 0, DW2 - DP2 * 2, DT_ITEM_H2, 11, ALIGN_LEFT, { 0.55, 0.55, 0.55 })
ShowSafe(dtMoreLabel, false)

dtExportBtn = MakeBtn(histWin, "dt_export", "Export to File", DP2, 0, 120, 26, function()
    local sessions = LoadSessions()
    ExportSession(sessions[detailCurrentIdx])
end)
dtDeleteBtn = MakeBtn(histWin, "dt_delete", "Delete Session", DW2 - DP2 - 116, 0, 116, 26, function()
    if detailCurrentIdx > 0 then
        local sessions = LoadSessions()
        if sessions[detailCurrentIdx] then
            table.remove(sessions, detailCurrentIdx)
            ADDON:ClearData("sessions")
            ADDON:SaveData("sessions", { list = sessions })
        end
        detailCurrentIdx = 0
        ShowHistList()
        RefreshHistory()
    end
end)
ShowSafe(dtExportBtn, false)
ShowSafe(dtDeleteBtn, false)

MakeDraggable(histWin, function(x, y) SavePanel("history", x, y, histWin:IsVisible()) end)
ShowSafe(histWin, false)  -- always starts hidden

RefreshHistory = function()
    if not histWin then return end
    local sessions = LoadSessions()
    local totalSessions = #sessions
    local totalPages = math.max(1, math.ceil(totalSessions / sessionsPerPage))
    histPage = math.max(1, math.min(histPage, totalPages))

    -- Update page nav label and button states
    if histPageLabel then
        histPageLabel:SetText("Page " .. histPage .. " / " .. totalPages)
    end

    local firstIdx = (histPage - 1) * sessionsPerPage + 1  -- first session index for this page
    for i = 1, MAX_HIST_ROWS do
        local sessionIdx = firstIdx + i - 1
        local s = (i <= sessionsPerPage) and sessions[sessionIdx] or nil
        histSessionIdxFor[i] = sessionIdx  -- update lookup table for click handlers

        if s and histDateLbls[i] then
            local dateStr = "[ -- ]"
            SafePcall("histDate", function()
                local t = os.date("*t", s.ts or 0)
                dateStr = string.format("[%s %02d %02d:%02d]",
                    MONTHS[t.month] or "?", t.day, t.hour, t.min)
            end)
            local note = (s.note and s.note ~= "") and ("  " .. s.note) or ""
            histDateLbls[i]:SetText(dateStr .. note)
            local el  = s.elapsed or 0
            local h   = math.floor(el / 3600)
            local m   = math.floor((el % 3600) / 60)
            local sec = el % 60
            local dur
            if h > 0 then dur = h .. "h " .. m .. "m"
            elseif m > 0 then dur = m .. "m " .. sec .. "s"
            else dur = sec .. "s" end
            local parts = { dur, shortNum2(s.kills or 0) .. " kills", fmtMoneyClean(s.coin or 0) }
            if (s.deaths or 0) > 0 then parts[#parts+1] = (s.deaths) .. " deaths" end
            if (s.value or 0) > 0  then parts[#parts+1] = "~" .. fmtMoneyClean(s.value) end
            local xpb  = tonumber(s.xp_bonus)  or 0
            local drpb = tonumber(s.drop_bonus) or 0
            if xpb > 0 or drpb > 0 then
                parts[#parts+1] = string.format("XP %d%%  D.%d%%", 100+xpb, 100+drpb)
            end
            histStatsLbls[i]:SetText(table.concat(parts, "  |  "))
            ShowSafe(histDateLbls[i], true)
            ShowSafe(histStatsLbls[i], true)
            if histClickBtns[i] then ShowSafe(histClickBtns[i], true) end
        elseif histDateLbls[i] then
            histDateLbls[i]:SetText("")
            histStatsLbls[i]:SetText("")
            ShowSafe(histDateLbls[i], false)
            ShowSafe(histStatsLbls[i], false)
            if histClickBtns[i] then ShowSafe(histClickBtns[i], false) end
        end
    end
end

-- =========================
-- ESC menu button (Shop/Quality of Life tab) -- opens the panel.
-- =========================
local UIC_GRIND = 1551   -- custom UI category (>1000 to avoid conflicts)

SafePcall("EscMenuRegister", function()
    -- Trigger function: explicitly toggle the panel's visibility.
    -- (ADDON:ToggleContent does not directly show custom windows, so we do it here.)
    ADDON:RegisterContentTriggerFunc(UIC_GRIND, function(show)
        if win and win:IsValidUIObject() then
            -- Snap back to default if window is stuck off-screen.
            local x, y = 0, 0
            if type(win.GetEffectiveOffset) == "function" then x, y = win:GetEffectiveOffset() end
            if x < -50 or x > 3840 or y < -50 or y > 2160 then
                RemoveAllAnchorsSafe(win)
                AddAnchorSafe(win, "TOPLEFT", "UIParent", DEFAULT_PANEL_X, DEFAULT_PANEL_Y)
                Log("Window was off-screen, snapped back to default. Use /gt resetpos to reset both windows.")
            end
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
    setRow("kills", shortNum2(S.kills), "(" .. shortNum2(perHour(S.kills)) .. "/h)")
    setRow("xp",    shortNum(S.xp),    "(" .. shortNum(perHour(S.xp))    .. "/h)")

    -- Compute the AH-estimated value of all items looted this session.
    local itemsCp = ahItemTotalCopper()
    local totalCp = S.coin + itemsCp

    -- Gold on main panel: total (looted + items est), with /h based on total.
    setRow("gold", fmtMoneyClean(totalCp), "(" .. fmtMoneyShort(perHour(totalCp)) .. "/h)")

    -- Items count.
    setRow("items", shortNum(S.lootTotal), "(" .. shortNum(perHour(S.lootTotal)) .. "/h)")

    -- Honor row: shows 0 when nothing earned yet so the row isn't just blank.
    local honorRow = valLabels["honor"]
    if honorRow then
        honorRow.total:SetText(commafy(S.honor))
        honorRow.hourly:SetText(S.honor > 0 and ("(" .. shortNum(perHour(S.honor)) .. "/h)") or "")
    end

    -- Note label: show manual note, or auto zone, or placeholder.
    if noteLabel then
        if S.note ~= "" then
            noteLabel:SetText(S.note)
        elseif S.mainZone ~= "" or S.zone ~= "" then
            local z = (S.mainZone ~= "" and S.zone ~= "") and (S.mainZone .. " - " .. S.zone)
                   or (S.mainZone ~= "") and S.mainZone
                   or S.zone
            -- Truncate very long zone names to keep them within the window
            if #z > 42 then z = z:sub(1, 40) .. ".." end
            noteLabel:SetText(z)
        else
            noteLabel:SetText("No note  --  use !gt note <text>")
        end
    end

    -- ---- Loot window breakdown ----
    lwLootedVal:SetText(fmtMoneyClean(S.coin))
    lwItemsVal:SetText(fmtMoneyClean(itemsCp))

    -- Rates: live XP/drop bonus from UnitInfo (shown top-left of main window).
    local xpb, drpb = GetRates()
    if xpRateLabel then
        xpRateLabel:SetText(xpb > 0 and ("XP " .. (100 + xpb) .. "%") or "")
    end
    if dropRateLabel then
        dropRateLabel:SetText(drpb > 0 and ("Drop " .. (100 + drpb) .. "%") or "")
    end

    -- AH status: how many items still queued / priced / blacklisted.
    local priced, queued = 0, #AH.queue
    for nm, _ in pairs(S.lootMeta) do
        if AH.cache[nm] then priced = priced + 1 end
    end
    local statusText
    if not AH.enabled then
        statusText = "AH lookup disabled"
    elseif AH.ahWindowOpen then
        statusText = "AH open - lookups paused"
    elseif queued > 0 or AH.inFlight then
        statusText = string.format("Pricing... %d queued, %d done", queued + (AH.inFlight and 1 or 0), priced)
    elseif priced > 0 then
        statusText = string.format("%d items priced", priced)
    else
        statusText = ""
    end
    lwAhStatus:SetText(statusText)

    -- ---- Loot list: three columns (name | count | price) + hide button ----
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
            local cnt  = S.lootCount[name] or 0
            lootRowItems[i] = name
            lootNameLbls[i]:SetText(name)
            lootCountLbls[i]:SetText("x" .. cnt)
            local priceRow = AH.cache[name]
            if priceRow and priceRow.price and priceRow.price > 0 then
                lootPriceLbls[i]:SetText(fmtPriceEst(priceRow.price * cnt))
            else
                lootPriceLbls[i]:SetText("")
            end
            ShowSafe(lootHideBtns[i], true)
        else
            lootRowItems[i] = nil
            lootNameLbls[i]:SetText("")
            lootCountLbls[i]:SetText("")
            lootPriceLbls[i]:SetText("")
            ShowSafe(lootHideBtns[i], false)
        end
    end
    -- "more" line: overflow + hidden count
    local extra = #sorted - MAX_LOOT_ROWS
    local hiddenCount = 0
    for _ in pairs(S.lootHidden) do hiddenCount = hiddenCount + 1 end
    local moreParts = {}
    if extra > 0       then moreParts[#moreParts+1] = "+" .. extra .. " more" end
    if hiddenCount > 0 then moreParts[#moreParts+1] = hiddenCount .. " hidden" end
    lootMoreLbl:SetText(table.concat(moreParts, "  .  "))
end

-- =========================
-- Game event handlers
-- =========================

-- Extract a clean item name from an ADDON_ITEM link AND, when possible,
-- the full ItemInfo (giving us itemType + grade for AH lookups).
-- The link is a raw token like "|i{itemType},{grade},{kind},{data}", NOT "[Name]".
local function ItemNameAndInfo(link)
    if type(link) ~= "string" or link == "" then return "Item", nil end

    -- Strategy 1: resolve through the item API
    local ok, info = pcall(function() return X2Item:InfoFromLink(link) end)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
        return info.name, info
    end

    -- Strategy 2: classic [Name] form (some links carry it)
    local n = link:match("%[(.-)%]")
    if n and n ~= "" then return n, nil end

    -- Strategy 3: longest readable run as a last resort
    local best = ""
    for chunk in link:gmatch("[%a][%a '%-]+") do
        if #chunk > #best then best = chunk end
    end
    best = best:gsub("^%s+", ""):gsub("%s+$", "")
    if #best >= 3 then return best, nil end

    return "Item", nil
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
        local name, info = ItemNameAndInfo(itemLink)

        if not S.lootCount[name] then
            S.lootCount[name] = 0
            table.insert(S.lootOrder, name)
        end
        S.lootCount[name] = S.lootCount[name] + cnt
        S.lootTotal = S.lootTotal + cnt

        -- Honor gems: add to session honor total.
        local honorPer = ITEM_HONOR[name]
        if honorPer then S.honor = S.honor + honorPer * cnt end

        -- Remember itemType/grade so we can look up AH price.
        if info and info.itemType and not S.lootMeta[name] then
            -- Detect items that can never appear on the AH and skip the lookup
            -- entirely (no point wasting AH rate-limit on guaranteed misses).
            local cantSell = false
            -- `sellable == false` means cannot be sold (to vendor or AH).
            if info.sellable == false then cantSell = true end
            -- `soul_bound` is the bind state (0 = not bound, nonzero = bound).
            local sb = tonumber(info.soul_bound) or 0
            if sb > 0 then cantSell = true end

            S.lootMeta[name] = {
                itemType  = tonumber(info.itemType) or 0,
                grade     = tonumber(info.grade)    or 1,
                cantSell  = cantSell,
            }

            if cantSell then
                -- Mark as known-unsellable so the UI shows "skipped" instead of
                -- "queued". Use a permanent blacklist entry (it'll only clear
                -- when the cache TTL expires, but ItemInfo will re-flag it then).
                AH.blacklist[name] = os.time()
                ahSaveBlacklist()
            else
                ahMaybeEnqueue(name, S.lootMeta[name].itemType, S.lootMeta[name].grade)
            end
        end
    end)
end)

SafePcall("AuctionResultHook", function()
    UIParent:SetEventHandler(UIEVENT_TYPE.AUCTION_ITEM_SEARCHED, function()
        ahOnSearched()
    end)
end)

SafePcall("AuctionToggleHook", function()
    UIParent:SetEventHandler(UIEVENT_TYPE.AUCTION_TOGGLE, function()
        ahOnToggle()
    end)
end)

SafePcall("DeathHook", function()
    -- UNIT_DEAD_NOTICE fires for the player's OWN death only (confirmed in CLAUDE.md).
    UIParent:SetEventHandler(UIEVENT_TYPE.UNIT_DEAD_NOTICE, function(name)
        if not S.running then return end
        S.deaths = S.deaths + 1
    end)
end)

SafePcall("ZoneHook", function()
    -- Update subzone name when entering a named subzone.
    UIParent:SetEventHandler(UIEVENT_TYPE.ENTERED_SUBZONE, function(...)
        local n = select("#", ...)
        for i = 1, n do
            local v = select(i, ...)
            if type(v) == "string" and v ~= "" and not tonumber(v) then
                S.zone = v
                local z = GetCurrentZoneName()
                if z ~= "" then S.mainZone = z end
                break
            end
        end
    end)
    -- Update main zone name when crossing a major zone boundary (teleport / travel).
    UIParent:SetEventHandler(UIEVENT_TYPE.ENTER_ANOTHER_ZONEGROUP, function()
        S.zone = ""   -- subzone is now unknown until ENTERED_SUBZONE fires
        local z = GetCurrentZoneName()
        if z ~= "" then S.mainZone = z end
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
local autoSaveAcc = 0
local AUTO_SAVE_SEC = 120  -- save running session every 2 minutes
updater:SetHandler("OnUpdate", function(self, frameTime)
    local dt = (tonumber(frameTime) or 0) / 1000
    if S.running then
        S.elapsed = S.elapsed + dt
        -- Autosave periodically so a crash doesn't lose the whole session.
        autoSaveAcc = autoSaveAcc + dt
        if autoSaveAcc >= AUTO_SAVE_SEC then
            autoSaveAcc = 0
            SaveSession()
        end
    end

    ahTick(os.time())

    acc = acc + dt
    if acc < UI_REFRESH_SEC then return end
    acc = 0
    Refresh()
end)

-- =========================
-- Chat commands
-- Uses a hidden window + RegisterEvent("CHAT_MESSAGE") -- the correct pattern
-- for ArcheAge addons (slash commands are intercepted by the client).
-- Usage: type  !gt resetpos  in any chat channel.
-- =========================
local chatListener = CreateEmptyWindow("GT_chatListener", "UIParent")
chatListener:Show(false)
chatListener:SetHandler("OnEvent", function(this, event, channel, relation, name, message, info)
    local msg = string.lower(message or "")
    local raw = message or ""
    if msg == "!gt resetpos" or msg == "!gtreset" then
        ResetPositions()
    elseif string.find(msg, "^!gt note") then
        local note = string.match(raw, "^!gt note%s+(.+)")
        if note then
            S.note = note
            if noteLabel then noteLabel:SetText(note) end
            Log("Note set: " .. note)
        else
            Log("Usage: !gt note Farming Levi")
        end
    elseif msg == "!gt help" or msg == "!gthelp" then
        Log("Commands:")
        Log("  !gt note <text>   set session note (e.g. !gt note Farming Levi)")
        Log("  !gt resetpos      snap all windows back to default position")
    end
end)
chatListener:RegisterEvent("CHAT_MESSAGE")

ahLoadCache()
Refresh()
SafePcall("InitZone", function()
    local z = GetCurrentZoneName()
    if z ~= "" then S.mainZone = z end
end)
Log("Loaded v" .. VERSION .. " - ESC menu > Shop. Type !gt resetpos if window is off-screen.")

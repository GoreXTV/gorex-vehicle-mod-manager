-- =============================================================================
--  gui.lua  -  Vehicle Mod Manager (Oberflaeche + Preview-Szene)
--
--  * Komplett per dx gezeichnet (kein CEGUI-Look). Nur die Texteingabe der Suche
--    laeuft ueber ein unsichtbares guiEdit, das dx zeichnet den Text selbst.
--  * Das Grid wird in ein RenderTarget gezeichnet (sauberes Clipping + Scrollen),
--    es werden nur die sichtbaren Karten gezeichnet (Lazy Loading).
--  * Vorschaubilder werden erst geladen, wenn die Karte sichtbar ist, und per LRU wieder freigegeben.
--  * Preview: EIN Fahrzeug in einer Buehne, Orbit-Kamera (Maus ziehen, Mausrad = Zoom).
-- =============================================================================

local sw, sh = guiGetScreenSize()
local S = 1

local G = {
    open = false, anim = 0, cat = "@all", query = "", scroll = 0, scrollT = 0, maxScroll = 0,
    sel = nil, list = {}, listVer = -1, dirty = true, cols = 1, rowH = 100,
    counts = {}, countsVer = -1,
}
local hits, hoverAnim = {}, {}
local mx, my = 0, 0
local gA = 1                                  -- globaler Alpha-Multiplikator (Einblenden)
local rt, rtW, rtH                            -- RenderTarget des Grids
local edit, searchFocus = nil, false
local thumbs, thumbFail, thumbCount = {}, {}, 0
local startPreview, exitPreview               -- Vorwaertsdeklaration

local P = {
    bg = { 11, 12, 17 }, panel = { 18, 20, 28 }, side = { 14, 15, 22 }, card = { 27, 30, 42 },
    cardHi = { 38, 42, 60 }, line = { 42, 46, 64 }, txt = { 234, 237, 246 }, dim = { 138, 145, 168 },
    accent = { 255, 68, 92 }, green = { 52, 211, 118 }, gold = { 255, 198, 40 }, red = { 226, 58, 70 },
    blue = { 84, 150, 255 },
}

-- ============================================================================
--  Zeichen-Helfer
-- ============================================================================
local function C(r, g, b, a)
    a = (a or 255) * gA
    if a < 0 then a = 0 elseif a > 255 then a = 255 end
    return tocolor(r, g, b, math.floor(a))
end
local function col(p, a) return C(p[1], p[2], p[3], a) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function inside(x, y, w, h) return mx >= x and mx <= x + w and my >= y and my <= y + h end

local fontCache = {}
local function fnt(size, bold)
    if Config.UI.fontFile and fileExists(Config.UI.fontFile) then
        local px = math.max(8, math.floor(size * S + 0.5))
        local k = px .. (bold and "b" or "r")
        if fontCache[k] == nil then
            local file = (bold and Config.UI.fontFileBold) or Config.UI.fontFile
            fontCache[k] = dxCreateFont(file, px) or false
        end
        if fontCache[k] then return fontCache[k], 1 end
    end
    return bold and "default-bold" or "clear", size / 13 * S
end

local function txt(s, x, y, w, h, size, color, ax, ay, bold)
    local f, sc = fnt(size, bold)
    dxDrawText(s, x, y, x + w, y + h, color, sc, f, ax or "left", ay or "center", true, false, false)
end

local function drawStar(cx, cy, r, color, filled)
    local pts = {}
    for i = 0, 9 do
        local ang = -math.pi / 2 + i * math.pi / 5
        local rad = (i % 2 == 0) and r or r * 0.42
        pts[#pts + 1] = { cx + math.cos(ang) * rad, cy + math.sin(ang) * rad }
    end
    for i = 1, 10 do
        local a, b = pts[i], pts[i % 10 + 1]
        dxDrawLine(a[1], a[2], b[1], b[2], color, filled and 2 or 1.3)
        if filled then dxDrawLine(cx, cy, a[1], a[2], color, 3) end
    end
end

-- Button + Klickbereich (Hits werden pro Frame neu aufgebaut, zuletzt gezeichnet = oben)
local BTN = { primary = "accent", success = "green", danger = "red", ghost = "cardHi" }
local function button(id, x, y, w, h, label, kind, disabled, fn, size)
    local hov = (not disabled) and inside(x, y, w, h)
    local t = (hoverAnim[id] or 0)
    t = t + ((hov and 1 or 0) - t) * 0.3
    hoverAnim[id] = t
    local base = P[BTN[kind or "ghost"]]
    local a = disabled and 70 or 235
    dxDrawRectangle(x, y, w, h, col(base, a))
    if t > 0.01 then dxDrawRectangle(x, y, w, h, C(255, 255, 255, 38 * t)) end
    if kind == "ghost" and not disabled then dxDrawRectangle(x, y + h - 2 * S, w * t, 2 * S, col(P.accent)) end
    txt(label, x, y, w, h, size or 12, col(P.txt, disabled and 100 or 255), "center", "center", true)
    if not disabled then hits[#hits + 1] = { x = x, y = y, w = w, h = h, fn = fn } end
end

-- ============================================================================
--  Thumbnails (Lazy + LRU)
-- ============================================================================
local function getThumb(m)
    if not m.pvHash then return nil end
    local t = thumbs[m.pvHash]
    if t then
        t.last = getTickCount()
        return t.tex
    end
    if thumbFail[m.pvHash] then return nil end
    local path = VMM.thumbPath(m.cat, m)
    if path then
        local tex = dxCreateTexture(path)
        if tex then
            thumbs[m.pvHash] = { tex = tex, last = getTickCount() }
            thumbCount = thumbCount + 1
            return tex
        end
        thumbFail[m.pvHash] = true
    end
    return nil
end

setTimer(function()                            -- LRU-Aufraeumen: aelteste Thumbnails freigeben
    if thumbCount <= Config.UI.maxThumbs then return end
    local arr, now = {}, getTickCount()
    for h, t in pairs(thumbs) do arr[#arr + 1] = { h = h, last = t.last } end
    table.sort(arr, function(a, b) return a.last < b.last end)
    local keep = math.floor(Config.UI.maxThumbs * 0.7)
    for i = 1, #arr do
        if thumbCount <= keep then break end
        if now - arr[i].last > 600 then
            if isElement(thumbs[arr[i].h].tex) then destroyElement(thumbs[arr[i].h].tex) end
            thumbs[arr[i].h] = nil
            thumbCount = thumbCount - 1
        end
    end
end, 3000, 0)

VMM.onThumbChanged = function() G.dirty = true end

-- ============================================================================
--  Liste / Suche / Zaehler
-- ============================================================================
local function prepMod(m)
    if m._hay then return end
    local c = VMM.catById[m.cat]
    m._hay = (m.name .. " " .. m.author .. " " .. m.id .. " " .. (c and c.label or "") .. " "
        .. table.concat(m.tags, " ") .. " " .. m.desc):lower()
    m._nums = {}
    for d in (m.name .. " " .. m.id):gmatch("%d+") do m._nums[#m._nums + 1] = tostring(tonumber(d) or d) end
end

local function matches(m, tokens)
    prepMod(m)
    for _, tk in ipairs(tokens) do
        if tk:sub(1, 1) == "#" and #tk > 1 then            -- "#042" -> Nummer 42
            local raw = tk:sub(2)
            local want = tostring(tonumber(raw) or raw)
            local found = false
            for _, n in ipairs(m._nums) do
                if n:sub(1, #want) == want then found = true; break end
            end
            if not found then return false end
        elseif not m._hay:find(tk, 1, true) then
            return false
        end
    end
    return true
end

local function rebuildList()
    local tokens = {}
    for w in G.query:lower():gmatch("%S+") do tokens[#tokens + 1] = w end
    local out = {}
    local function add(m) if matches(m, tokens) then out[#out + 1] = m end end

    if G.cat == "@all" then
        for _, c in ipairs(VMM.cats) do for _, m in ipairs(c.mods) do add(m) end end
    elseif G.cat == "@fav" then
        for _, c in ipairs(VMM.cats) do
            for _, m in ipairs(c.mods) do if VMM.isFav(c.id, m.id) then add(m) end end
        end
    elseif G.cat == "@recent" then
        for _, key in ipairs(VMM.user.recent) do
            local m = VMM.modByKey[key]
            if m then add(m) end
        end
    else
        local c = VMM.catById[G.cat]
        if c then for _, m in ipairs(c.mods) do add(m) end end
    end
    G.list, G.listVer, G.dirty = out, VMM.indexVersion, false
end

local function refreshCounts()
    local total, favs, recent = 0, 0, 0
    for _, c in ipairs(VMM.cats) do total = total + #c.mods end
    for key in pairs(VMM.user.fav) do if VMM.modByKey[key] then favs = favs + 1 end end
    for _, key in ipairs(VMM.user.recent) do if VMM.modByKey[key] then recent = recent + 1 end end
    G.counts = { ["@all"] = total, ["@fav"] = favs, ["@recent"] = recent, total = total }
    G.countsVer = VMM.indexVersion
end

-- ============================================================================
--  Suchfeld (unsichtbares guiEdit als Eingabe-Proxy)
-- ============================================================================
local function ensureEdit()
    if edit and isElement(edit) then return end
    edit = guiCreateEdit(sw - 14, sh - 14, 10, 10, "", false)
    guiEditSetMaxLength(edit, 40)
    guiSetAlpha(edit, 0)
    guiSetVisible(edit, false)
    addEventHandler("onClientGUIChanged", edit, function()
        G.query = (guiGetText(edit) or ""):gsub("[\r\n]", "")
        G.dirty, G.scrollT = true, 0
    end, false)
    addEventHandler("onClientGUIAccepted", edit, function()
        if searchFocus then
            searchFocus = false
            if guiBlur then guiBlur(edit) end
        end
    end, false)
end

local function focusSearch()
    ensureEdit()
    searchFocus = true
    guiBringToFront(edit)
end

local function blurSearch()
    if not searchFocus then return end
    searchFocus = false
    if edit and isElement(edit) and guiBlur then guiBlur(edit) end
end

local function setQuery(s)
    G.query = s
    if edit and isElement(edit) then guiSetText(edit, s) end
    G.dirty, G.scrollT = true, 0
end

-- ============================================================================
--  Aktionen
-- ============================================================================
local function selPub() return G.sel and VMM.modByKey[G.sel] or nil end

local function toggleActivate(m)
    if VMM.committed(m.cat) == m.id then VMM.deactivate(m.cat) else VMM.activate(m.cat, m.id) end
end

local function selectMod(m)
    G.sel = m.cat .. "/" .. m.id
    VMM.currentCat = m.cat
end

local lastClickKey, lastClickT = nil, 0
local function onCardClick(m)
    local key = m.cat .. "/" .. m.id
    local now = getTickCount()
    selectMod(m)
    if Config.UI.clickOpensPreview or (lastClickKey == key and now - lastClickT < 350) then startPreview(m) end
    lastClickKey, lastClickT = key, now
end

-- ============================================================================
--  Karten (im RenderTarget)
-- ============================================================================
local function drawCard(m, x, y, w, h, ax, ay, gx, gy, gw, gh)
    local key = m.cat .. "/" .. m.id
    local hov = inside(gx, gy, gw, gh) and inside(ax, ay, w, h)
    local t = hoverAnim[key] or 0
    t = t + ((hov and 1 or 0) - t) * 0.25
    hoverAnim[key] = t

    local pvH = w * 9 / 16
    local selected = (G.sel == key)
    dxDrawRectangle(x, y, w, h, col(hov and P.cardHi or P.card))
    if selected then
        dxDrawRectangle(x, y, w, 2 * S, col(P.accent))
        dxDrawRectangle(x, y + h - 2 * S, w, 2 * S, col(P.accent))
        dxDrawRectangle(x, y, 2 * S, h, col(P.accent))
        dxDrawRectangle(x + w - 2 * S, y, 2 * S, h, col(P.accent))
    end

    -- Vorschau
    local tex = getThumb(m)
    if tex then
        dxDrawImage(x, y, w, pvH, tex, 0, 0, 0, tocolor(255, 255, 255, 255))
    else
        dxDrawRectangle(x, y, w, pvH, C(20, 22, 32))
        local num = (m.name .. " " .. m.id):match("%d+")
        txt(num and ("#" .. num) or m.cat:upper(), x, y, w, pvH, 22, col(P.line), "center", "center", true)
        txt("NO PREVIEW", x, y + pvH - 22 * S, w, 18 * S, 9, col(P.dim, 150), "center", "center")
    end
    if t > 0.01 then dxDrawRectangle(x, y, w, pvH, C(255, 255, 255, 22 * t)) end

    -- Status-Badge
    if VMM.committed(m.cat) == m.id then
        dxDrawRectangle(x + 6 * S, y + 6 * S, 56 * S, 18 * S, col(P.green))
        txt("ACTIVE", x + 6 * S, y + 6 * S, 56 * S, 18 * S, 10, C(10, 30, 18), "center", "center", true)
    end

    -- Favoriten-Stern
    local fav = VMM.isFav(m.cat, m.id)
    local sx, sy, ss = x + w - 30 * S, y + 6 * S, 24 * S
    dxDrawRectangle(sx, sy, ss, ss, C(0, 0, 0, 120))
    drawStar(sx + ss / 2, sy + ss / 2, 8 * S, fav and col(P.gold) or col(P.dim), fav)

    -- Text
    txt(m.name, x + 10 * S, y + pvH + 6 * S, w - 20 * S, 22 * S, 13, col(P.txt), "left", "center", true)
    local c = VMM.catById[m.cat]
    local sub = (m.author ~= "" and (m.author .. "  -  ") or "") .. (c and c.label or m.cat)
    txt(sub, x + 10 * S, y + pvH + 28 * S, w - 20 * S, 18 * S, 10, col(P.dim), "left", "center")

    -- Klickbereiche (auf sichtbaren Bereich des Grids begrenzt)
    local x0, y0 = math.max(ax, gx), math.max(ay, gy)
    local x1, y1 = math.min(ax + w, gx + gw), math.min(ay + h, gy + gh)
    if x1 > x0 and y1 > y0 then
        hits[#hits + 1] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0, fn = function() onCardClick(m) end }
        local fx0, fy0 = math.max(ax + (sx - x), gx), math.max(ay + (sy - y), gy)
        local fx1, fy1 = math.min(ax + (sx - x) + ss, gx + gw), math.min(ay + (sy - y) + ss, gy + gh)
        if fx1 > fx0 and fy1 > fy0 then
            hits[#hits + 1] = { x = fx0, y = fy0, w = fx1 - fx0, h = fy1 - fy0, fn = function() VMM.toggleFav(m.cat, m.id) end }
        end
    end
end

local function ensureRT(w, h)
    w, h = math.floor(w), math.floor(h)
    if rt and (rtW ~= w or rtH ~= h) then
        if isElement(rt) then destroyElement(rt) end
        rt = nil
    end
    if not rt or not isElement(rt) then
        rt = dxCreateRenderTarget(w, h, true)
        rtW, rtH = w, h
    end
    return rt
end

local function drawGrid(gx, gy, gw, gh)
    local list = G.list
    if #list == 0 then
        local msg, sub
        if not VMM.indexLoaded then
            msg, sub = "LOADING LIBRARY ...", ""
        elseif G.counts.total == 0 then
            msg, sub = "NO MODS FOUND", "Copy mod folders into  mods/<category>/<mod>/  and press RESCAN"
        elseif G.cat == "@fav" and G.query == "" then
            msg, sub = "NO FAVORITES YET", "Click the star on a mod card"
        else
            msg, sub = "NO RESULTS", "Try another search term (name, author, #042, tag)"
        end
        txt(msg, gx, gy + gh * 0.36, gw, 30 * S, 18, col(P.dim), "center", "center", true)
        txt(sub, gx, gy + gh * 0.36 + 30 * S, gw, 22 * S, 11, col(P.dim, 160), "center", "center")
        return
    end

    local gap = 14 * S
    local cols = math.max(1, math.floor((gw + gap) / (188 * S + gap)))
    local cw = (gw - gap * (cols - 1)) / cols
    local ch = cw * 9 / 16 + 54 * S
    local rows = math.ceil(#list / cols)
    local contentH = rows * (ch + gap) - gap
    G.maxScroll, G.cols, G.rowH = math.max(0, contentH - gh), cols, ch + gap
    G.scrollT = clamp(G.scrollT, 0, G.maxScroll)
    G.scroll = G.scroll + (G.scrollT - G.scroll) * 0.25

    local target = ensureRT(gw, gh)
    local ox, oy, savedA = 0, 0, gA
    if target then
        dxSetRenderTarget(target, true)
        gA = 1
    else
        ox, oy = gx, gy
    end

    local first = math.max(0, math.floor(G.scroll / (ch + gap)))
    local last = math.min(#list, (first + math.ceil(gh / (ch + gap)) + 1) * cols)
    for i = first * cols + 1, last do
        local r, c = math.floor((i - 1) / cols), (i - 1) % cols
        local x, y = c * (cw + gap), r * (ch + gap) - G.scroll
        if target or (y >= 0 and y + ch <= gh) then
            drawCard(list[i], ox + x, oy + y, cw, ch, gx + x, gy + y, gx, gy, gw, gh)
        end
    end

    if target then
        dxSetRenderTarget()
        gA = savedA
        dxDrawImage(gx, gy, gw, gh, target, 0, 0, 0, tocolor(255, 255, 255, math.floor(255 * gA)))
    end

    if G.maxScroll > 0 then                        -- Scrollbar
        local th = math.max(30 * S, gh * gh / contentH)
        local ty = gy + (gh - th) * (G.scroll / G.maxScroll)
        dxDrawRectangle(gx + gw - 4 * S, gy, 4 * S, gh, col(P.line, 90))
        dxDrawRectangle(gx + gw - 4 * S, ty, 4 * S, th, col(P.accent))
    end
end

-- ============================================================================
--  Hauptpanel
-- ============================================================================
local function renderPanel(now)
    if VMM.denied then return exitPreview() or G.closeRequest() end
    if G.countsVer ~= VMM.indexVersion then refreshCounts() end
    if G.listVer ~= VMM.indexVersion or G.dirty then rebuildList() end
    if not VMM.currentCat and VMM.cats[1] then VMM.currentCat = VMM.cats[1].id end

    G.anim = G.anim + (1 - G.anim) * 0.18
    gA = G.anim

    local pw, ph = 1120 * S, 660 * S
    local px, py = (sw - pw) / 2, (sh - ph) / 2 + (1 - G.anim) * 26 * S
    local titleH, sideW, botH, pad = 54 * S, 212 * S, 84 * S, 18 * S

    dxDrawRectangle(px - 3 * S, py - 3 * S, pw + 6 * S, ph + 6 * S, C(0, 0, 0, 110))
    dxDrawRectangle(px, py, pw, ph, col(P.panel, 250))

    -- Titelleiste
    dxDrawRectangle(px, py, pw, titleH, col(P.bg))
    dxDrawRectangle(px, py + titleH - 2 * S, pw, 2 * S, col(P.accent))
    txt("VEHICLE MOD MANAGER", px + pad, py, 420 * S, titleH, 19, col(P.txt), "left", "center", true)
    local bx = px + pw - 12 * S
    local function tb(id, w, label, kind, fn, disabled)
        bx = bx - w
        button(id, bx, py + 11 * S, w, 32 * S, label, kind, disabled, fn, 11)
        bx = bx - 8 * S
    end
    tb("close", 34 * S, "X", "ghost", function() G.closeRequest() end)
    tb("creator", 128 * S, "CREATOR: " .. (VMM.creatorMode and "ON" or "OFF"), VMM.creatorMode and "success" or "ghost",
        function() VMM.setCreatorMode(not VMM.creatorMode) end)
    if VMM.canGlobal then
        tb("scope", 110 * S, "SCOPE: " .. VMM.scope:upper(), VMM.scope == "global" and "danger" or "ghost",
            function() VMM.scope = (VMM.scope == "local") and "global" or "local" end)
    end
    tb("rescan", 84 * S, "RESCAN", "ghost", function() VMM.requestIndex(true) end)

    -- Seitenleiste
    local sy = py + titleH
    dxDrawRectangle(px, sy, sideW, ph - titleH, col(P.side))
    local rowH, ry = 44 * S, sy + 10 * S
    local function side(id, icon, label, count, accentCol)
        local sel = (G.cat == id)
        local hov = inside(px, ry, sideW, rowH)
        local t = (hoverAnim["side" .. id] or 0)
        t = t + ((hov and 1 or 0) - t) * 0.3
        hoverAnim["side" .. id] = t
        if sel then dxDrawRectangle(px, ry, sideW, rowH, col(P.cardHi, 200)) end
        if t > 0.01 and not sel then dxDrawRectangle(px, ry, sideW, rowH, C(255, 255, 255, 14 * t)) end
        if sel then dxDrawRectangle(px, ry, 3 * S, rowH, col(P.accent)) end
        dxDrawRectangle(px + 16 * S, ry + 9 * S, 26 * S, 26 * S, col(accentCol or P.line))
        txt(icon, px + 16 * S, ry + 9 * S, 26 * S, 26 * S, 12, col(P.txt), "center", "center", true)
        txt(label, px + 52 * S, ry, 110 * S, rowH, 12, col(sel and P.txt or P.dim), "left", "center", true)
        txt(tostring(count or 0), px + sideW - 56 * S, ry, 44 * S, rowH, 10, col(P.dim), "right", "center")
        local rx, ryy = px, ry
        hits[#hits + 1] = { x = rx, y = ryy, w = sideW, h = rowH, fn = function()
            G.cat, G.dirty, G.scrollT = id, true, 0
            if id:sub(1, 1) ~= "@" then VMM.currentCat = id end
        end }
        ry = ry + rowH
    end
    side("@all", "*", "ALL MODS", G.counts["@all"], P.accent)
    side("@fav", "F", "FAVORITES", G.counts["@fav"], P.gold)
    side("@recent", "R", "RECENT", G.counts["@recent"], P.blue)
    dxDrawRectangle(px + 16 * S, ry + 8 * S, sideW - 32 * S, 1, col(P.line))
    ry = ry + 18 * S
    for _, c in ipairs(VMM.cats) do side(c.id, c.icon, c.label, #c.mods, P.line) end

    -- Inhalt: Suche
    local cx, cw = px + sideW + pad, pw - sideW - 2 * pad
    local searchY, searchH = py + titleH + pad, 42 * S
    dxDrawRectangle(cx, searchY, cw, searchH, col(P.bg))
    dxDrawRectangle(cx, searchY + searchH - 2 * S, cw, 2 * S, col(searchFocus and P.accent or P.line))
    if G.query == "" and not searchFocus then
        txt("SEARCH ...   name, author, #042, tag", cx + 14 * S, searchY, cw - 200 * S, searchH, 12, col(P.dim, 170), "left", "center")
    else
        local caret = (searchFocus and getTickCount() % 1000 < 500) and "|" or ""
        txt(G.query .. caret, cx + 14 * S, searchY, cw - 200 * S, searchH, 13, col(P.txt), "left", "center")
    end
    txt(("%d mods"):format(#G.list), cx + cw - 150 * S, searchY, 100 * S, searchH, 11, col(P.dim), "right", "center")
    hits[#hits + 1] = { x = cx, y = searchY, w = cw - 50 * S, h = searchH, fn = focusSearch, search = true }
    if G.query ~= "" then
        button("clearq", cx + cw - 40 * S, searchY + 6 * S, 30 * S, searchH - 12 * S, "X", "ghost", false, function()
            setQuery("")
        end, 11)
        hits[#hits].search = true
    end

    -- Inhalt: Grid
    local gy = searchY + searchH + 14 * S
    local gh = (py + ph - botH) - gy - 12 * S
    drawGrid(cx, gy, cw, gh)

    -- Untere Leiste
    local by = py + ph - botH
    dxDrawRectangle(px + sideW, by, pw - sideW, botH, col(P.bg))
    local m = selPub()
    if m then
        local c = VMM.catById[m.cat]
        local active = VMM.committed(m.cat) == m.id
        txt(m.name, cx, by + 12 * S, 380 * S, 28 * S, 16, col(P.txt), "left", "center", true)
        txt((m.author ~= "" and (m.author .. "  -  ") or "") .. (c and c.label or m.cat) .. "  -  " .. (active and "ACTIVE" or "Not activated"),
            cx, by + 42 * S, 420 * S, 22 * S, 11, col(active and P.green or P.dim), "left", "center")
        local bh, right = 44 * S, px + pw - pad
        button("activate", right - 140 * S, by + 20 * S, 140 * S, bh, active and "DEACTIVATE" or "ACTIVATE",
            active and "danger" or "success", false, function() toggleActivate(m) end, 13)
        button("preview", right - (140 + 8 + 120) * S, by + 20 * S, 120 * S, bh, "PREVIEW", "primary", false,
            function() startPreview(m) end, 13)
        button("favorite", right - (140 + 8 + 120 + 8 + 120) * S, by + 20 * S, 120 * S, bh,
            VMM.isFav(m.cat, m.id) and "UNFAVORITE" or "FAVORITE", "ghost", false,
            function() VMM.toggleFav(m.cat, m.id) end, 12)
    else
        txt("Select a mod - click opens the preview, ACTIVATE happens there.", cx, by, cw, botH, 12, col(P.dim), "left", "center")
    end
    gA = 1
end

-- ============================================================================
--  Preview-Szene
-- ============================================================================
local pv = { active = false, loading = false }
local VIEWS = {
    FRONT = { yaw = 0, pitch = 8, dist = 6.4 }, SIDE = { yaw = 90, pitch = 6, dist = 7.2 },
    REAR = { yaw = 180, pitch = 8, dist = 6.4 }, TOP = { yaw = 0, pitch = 82, dist = 8.5 },
    FREE = { yaw = 36, pitch = 12, dist = 6.8 },
}

local function angleDiff(a, b) return ((a - b + 180) % 360) - 180 end

local function stagePos()
    if Config.Preview.stageMode == "player" then
        local x, y, z = getElementPosition(localPlayer)
        return x, y, z + 60
    end
    local s = Config.Preview.stage
    return s[1], s[2], s[3]
end

local function applyLightMode()
    local lm = Config.Preview.lightModes[pv.lm]
    if not lm then return end
    setTime(lm.hour, 0)
    if lm.sky then setSkyGradient(lm.sky[1], lm.sky[2], lm.sky[3], lm.sky[4], lm.sky[5], lm.sky[6]) else resetSkyGradient() end
    pv.lastTime = getTickCount()
end

local function setView(name)
    local v = VIEWS[name]
    pv.tYaw, pv.tPitch, pv.tDist = v.yaw, v.pitch, v.dist
    pv.auto = (name == "FREE") and Config.Preview.autoRotate or false
end

local function enterPreview(m, info)
    pv.mod, pv.info, pv.hasModel, pv.hasTex = m, info, false, false
    local upgrades, model = {}, VMM.catById[m.cat] and VMM.catById[m.cat].previewModel
    for _, e in ipairs(info.entries) do
        if e.kind == "model" then
            pv.hasModel = true
            for _, id in ipairs(e.models) do
                if id >= 1000 and id <= 1193 then upgrades[#upgrades + 1] = id end
                if not model and id >= 400 and id <= 611 then model = id end
            end
        else
            pv.hasTex = true
        end
    end
    model = model or Config.Preview.defaultModel

    if pv.hasModel and not VMM.loadIntoGame(m.cat, m.id, info, { skipTextures = true }) then
        VMM.revertToCommitted(m.cat)
        return
    end

    pv.sx, pv.sy, pv.sz = stagePos()
    -- Spieler (und sein Fahrzeug) einfrieren, damit nichts passiert, solange die Kamera woanders steht
    pv.frozen = {}
    local pveh = getPedOccupiedVehicle(localPlayer)
    for _, el in ipairs({ localPlayer, pveh }) do
        if el and isElement(el) and not isElementFrozen(el) then
            setElementFrozen(el, true)
            pv.frozen[#pv.frozen + 1] = el
        end
    end
    pv.veh = createVehicle(model, pv.sx, pv.sy, pv.sz, 0, 0, 0)
    if not pv.veh then
        if pv.hasModel then VMM.revertToCommitted(m.cat) end
        for _, el in ipairs(pv.frozen) do if isElement(el) then setElementFrozen(el, false) end end
        pv.frozen = nil
        return VMM.toast("Could not create preview vehicle", "error")
    end
    setElementFrozen(pv.veh, true)
    setElementCollisionsEnabled(pv.veh, false)
    local c = Config.Preview.color
    setVehicleColor(pv.veh, c[1], c[2], c[3], c[1], c[2], c[3], c[1], c[2], c[3], c[1], c[2], c[3])
    for _, up in ipairs(upgrades) do addVehicleUpgrade(pv.veh, up) end
    if pv.hasTex then
        local ok, rec = VMM.loadIntoGame(m.cat, m.id, info, { texTarget = pv.veh, skipModels = true })
        if not ok then
            destroyElement(pv.veh)
            pv.veh = nil
            for _, el in ipairs(pv.frozen) do if isElement(el) then setElementFrozen(el, false) end end
            pv.frozen = nil
            if pv.hasModel then VMM.revertToCommitted(m.cat) end
            return
        end
        pv.texRec = rec
    end

    pv.lights, pv.lm, pv.snap, pv.drag = false, 1, 0, false
    setVehicleOverrideLights(pv.veh, 1)
    pv.h, pv.min = getTime()
    pv.yaw, pv.pitch, pv.dist = 36, 12, 8
    setView("FREE")
    pv.floorZ = nil
    applyLightMode()
    pv.active = true
    blurSearch()
end

startPreview = function(m)
    if pv.active or pv.loading then return end
    pv.loading = true
    VMM.fetchMod(m.cat, m.id, function(ok, info)
        pv.loading = false
        if not ok then return VMM.toast("Could not load " .. m.name, "error") end
        if G.open and not pv.active then enterPreview(m, info) end
    end)
end

exitPreview = function()
    if not pv.active then return end
    pv.active = false
    pv.snapWait, pv.snap = nil, 0
    if pv.veh and isElement(pv.veh) then destroyElement(pv.veh) end
    VMM.destroyRec(pv.texRec)
    pv.veh, pv.texRec = nil, nil
    setCameraTarget(localPlayer)
    for _, el in ipairs(pv.frozen or {}) do if isElement(el) then setElementFrozen(el, false) end end
    pv.frozen = nil
    resetSkyGradient()
    if pv.h then setTime(pv.h, pv.min) end
    if pv.hasModel then VMM.revertToCommitted(pv.mod.cat) end   -- war nur Preview -> alten Zustand laden
    if pv.hid then
        pv.hid = false
        setPlayerHudComponentVisible("all", true)
        showChat(true)
    end
end

-- Kamera (vor dem Rendern)
addEventHandler("onClientPreRender", root, function(dt)
    if not pv.active or not pv.veh or not isElement(pv.veh) then return end
    if pv.snap > 0 or pv.snapWait then return end -- Aufnahme behaelt den gewaehlten Blickwinkel
    if pv.auto and not pv.drag then pv.tYaw = pv.tYaw + dt * 0.012 end
    local k = 1 - math.exp(-dt / 90)
    pv.yaw = pv.yaw + angleDiff(pv.tYaw, pv.yaw) * k
    pv.pitch = pv.pitch + (pv.tPitch - pv.pitch) * k
    pv.dist = pv.dist + (pv.tDist - pv.dist) * k

    local yaw, pitch = math.rad(pv.yaw), math.rad(pv.pitch)
    local tx, ty, tz = pv.sx, pv.sy, pv.sz + 0.35
    setCameraMatrix(tx + math.sin(yaw) * math.cos(pitch) * pv.dist, ty + math.cos(yaw) * math.cos(pitch) * pv.dist,
        tz + math.sin(pitch) * pv.dist, tx, ty, tz, 0, Config.Preview.fov)

    if getTickCount() - (pv.lastTime or 0) > 1000 then applyLightMode() end   -- Tageszeit festhalten
end)

local function drawPlatform()
    if not pv.floorZ then
        local _, _, minZ = getElementBoundingBox(pv.veh)
        pv.floorZ = pv.sz + (minZ or -0.6)
    end
    local z = pv.floorZ
    for _, r in ipairs({ 2.7, 3.3, 3.9 }) do
        local a = (r == 3.3) and 120 or 60
        for i = 0, 47 do
            local a1, a2 = i / 48 * math.pi * 2, (i + 1) / 48 * math.pi * 2
            dxDrawLine3D(pv.sx + math.cos(a1) * r, pv.sy + math.sin(a1) * r, z, pv.sx + math.cos(a2) * r, pv.sy + math.sin(a2) * r, z,
                tocolor(P.accent[1], P.accent[2], P.accent[3], a), 3)
        end
    end
end

local function finishSnapshot()
    pv.snapWait, pv.snap = nil, 0
    if pv.hid then
        pv.hid = false
        setPlayerHudComponentVisible("all", true)
        showChat(true)
    end
end
VMM.onSnapshotDone = function() if pv.active and pv.snapWait then finishSnapshot() end end

local function doSnapshot()
    local size = Config.Preview.snapshotSize
    local src = dxCreateScreenSource(size[1], size[2])
    if not src then return VMM.toast("Snapshot not supported", "error") end
    local captured = dxUpdateScreenSource(src, true)
    local pixels = captured and dxGetTexturePixels(src)
    destroyElement(src)
    local jpg = pixels and dxConvertPixels(pixels, "jpeg", 85)
    if not jpg then return VMM.toast("Snapshot failed", "error") end
    if VMM.uploadPreview(pv.mod.cat, pv.mod.id, jpg) then
        VMM.toast("Snapshot captured - saving in background", "info")
    else
        VMM.toast("Snapshot upload could not be started", "error")
    end
end

local function renderPreview(now)
    if not pv.veh or not isElement(pv.veh) then return exitPreview() end

    -- Ein sauberes Frame ohne Preview-UI aufnehmen; nicht auf den Upload warten.
    if pv.snapWait then                                   -- Modus "server": warten, bis der Server fertig meldet
        if getTickCount() - pv.snapWait > 10000 then finishSnapshot() end
        return
    end
    if pv.snap > 0 then
        pv.snap = pv.snap - 1
        if pv.snap == 0 then
            if Config.Preview.snapshotMode == "server" then
                pv.snapWait = getTickCount()
                VMM.requestSnapshot(pv.mod.cat, pv.mod.id)
            else
                doSnapshot()
                finishSnapshot()
            end
        end
        return
    end

    drawPlatform()

    -- Maus ziehen = Kamera drehen
    if pv.drag then
        if getKeyState("mouse1") then
            local dx, dy = mx - (pv.lmx or mx), my - (pv.lmy or my)
            pv.tYaw, pv.tPitch = pv.tYaw - dx * 0.4, clamp(pv.tPitch + dy * 0.3, -5, 85)
            pv.yaw, pv.pitch = pv.tYaw, pv.tPitch
            pv.auto = false
        else
            pv.drag = false
        end
    end
    pv.lmx, pv.lmy = mx, my

    local m = pv.mod
    local c = VMM.catById[m.cat]
    local active = VMM.committed(m.cat) == m.id

    -- Info-Karte oben links
    local ix, iy, iw, ih = 24 * S, 24 * S, 360 * S, 112 * S
    dxDrawRectangle(ix, iy, iw, ih, col(P.bg, 220))
    dxDrawRectangle(ix, iy, 4 * S, ih, col(P.accent))
    txt(m.name, ix + 18 * S, iy + 8 * S, iw - 30 * S, 30 * S, 18, col(P.txt), "left", "center", true)
    txt((m.author ~= "" and ("by " .. m.author) or "unknown author") .. "   -   " .. (c and c.label or m.cat),
        ix + 18 * S, iy + 40 * S, iw - 30 * S, 20 * S, 11, col(P.dim), "left", "center")
    txt(active and "STATUS: ACTIVE" or "STATUS: PREVIEW ONLY (not activated)", ix + 18 * S, iy + 62 * S, iw - 30 * S, 20 * S, 11,
        col(active and P.green or P.gold), "left", "center", true)
    txt(("Light: %s   -   Drag = rotate   Wheel = zoom"):format(Config.Preview.lightModes[pv.lm].name),
        ix + 18 * S, iy + 84 * S, iw - 30 * S, 20 * S, 10, col(P.dim, 180), "left", "center")

    -- Werkzeugleiste unten
    local function row(y, items)
        local total = 0
        for _, it in ipairs(items) do total = total + it.w * S + 8 * S end
        local x = (sw - total + 8 * S) / 2
        for _, it in ipairs(items) do
            button("pv" .. it.id, x, y, it.w * S, 38 * S, it.label, it.kind, false, it.fn, 11)
            x = x + it.w * S + 8 * S
        end
    end
    local function vbtn(name) return { id = name, w = 74, label = name, kind = "ghost", fn = function() setView(name) end } end
    row(sh - 112 * S, {
        vbtn("FRONT"), vbtn("SIDE"), vbtn("REAR"), vbtn("TOP"), vbtn("FREE"),
        { id = "light", w = 130, label = "LIGHT: " .. Config.Preview.lightModes[pv.lm].name, kind = "ghost", fn = function()
            pv.lm = pv.lm % #Config.Preview.lightModes + 1
            applyLightMode()
        end },
        { id = "hl", w = 120, label = "HEADLIGHTS", kind = pv.lights and "primary" or "ghost", fn = function()
            pv.lights = not pv.lights
            setVehicleOverrideLights(pv.veh, pv.lights and 2 or 1)
        end },
        { id = "rot", w = 90, label = "ROTATE", kind = pv.auto and "primary" or "ghost", fn = function() pv.auto = not pv.auto end },
    })
    row(sh - 66 * S, {
        { id = "back", w = 120, label = "BACK  (Esc)", kind = "ghost", fn = exitPreview },
        { id = "snap", w = 130, label = "SNAPSHOT", kind = "ghost", fn = function()
            if Config.Preview.snapshotMode == "off" then return VMM.toast("Snapshot is disabled in config.lua", "warn") end
            if pv.snap > 0 or pv.snapWait then return end
            pv.snap, pv.hid = 1, true
            showChat(false)
            setPlayerHudComponentVisible("all", false)
        end },
        { id = "fav", w = 130, label = VMM.isFav(m.cat, m.id) and "UNFAVORITE (F)" or "FAVORITE (F)", kind = "ghost", fn = function()
            VMM.toggleFav(m.cat, m.id)
        end },
        { id = "act", w = 190, label = active and "DEACTIVATE" or "ACTIVATE  (Enter)", kind = active and "danger" or "success",
          fn = function() toggleActivate(m) end },
    })
end

-- ============================================================================
--  Toasts / Overlays (auch bei geschlossenem Panel)
-- ============================================================================
local TOAST_COL = { success = "green", error = "red", warn = "gold", info = "accent" }
local function renderToasts(now)
    for i = #VMM.toasts, 1, -1 do
        if now - VMM.toasts[i].t0 > VMM.toasts[i].dur then table.remove(VMM.toasts, i) end
    end
    for i, t in ipairs(VMM.toasts) do
        local age = now - t.t0
        local a = clamp(math.min(age / 200, (t.dur - age) / 300, 1), 0, 1)
        local w, h = 420 * S, 34 * S
        local x, y = (sw - w) / 2, sh - 190 * S - (#VMM.toasts - i) * (h + 6 * S)
        dxDrawRectangle(x, y, w, h, tocolor(11, 12, 17, 225 * a))
        local p = P[TOAST_COL[t.kind] or "accent"]
        dxDrawRectangle(x, y, 4 * S, h, tocolor(p[1], p[2], p[3], 255 * a))
        local f, sc = fnt(12, false)
        dxDrawText(t.text, x + 14 * S, y, x + w - 8 * S, y + h, tocolor(234, 237, 246, 255 * a), sc, f, "left", "center", true)
    end
end

local function renderCreatorOverlay()
    if not VMM.creatorMode or G.open or pv.active then return end
    local cat = VMM.currentCat and VMM.catById[VMM.currentCat]
    local text = ("CREATOR MODE   [%s] %s  -  %s / %s cycle  -  %s off"):format(cat and cat.label or "-",
        cat and VMM.committed(cat.id) and (VMM.getMod(cat.id, VMM.committed(cat.id)) or { name = "?" }).name or "original",
        Config.Hotkeys.prev:upper(), Config.Hotkeys.next:upper(), Config.Hotkeys.off:upper())
    local w, h = 640 * S, 28 * S
    dxDrawRectangle(16 * S, 16 * S, w, h, tocolor(11, 12, 17, 200))
    dxDrawRectangle(16 * S, 16 * S, 4 * S, h, tocolor(P.green[1], P.green[2], P.green[3], 255))
    local f, sc = fnt(11, true)
    dxDrawText(text, 30 * S, 16 * S, 16 * S + w, 16 * S + h, tocolor(234, 237, 246, 255), sc, f, "left", "center", true)
end

local function renderTransfer()
    if VMM.xfer.active <= 0 then return end
    local w, h = 260 * S, 6 * S
    local x, y = (sw - w) / 2, sh - 150 * S
    local pct = VMM.xfer.total > 0 and clamp(VMM.xfer.got / VMM.xfer.total, 0, 1) or 0
    dxDrawRectangle(x, y, w, h, tocolor(42, 46, 64, 230))
    dxDrawRectangle(x, y, w * pct, h, tocolor(P.accent[1], P.accent[2], P.accent[3], 255))
    local f, sc = fnt(10, false)
    dxDrawText(("Downloading mod files ... %d%%"):format(pct * 100), x, y - 20 * S, x + w, y - 2 * S,
        tocolor(138, 145, 168, 255), sc, f, "center", "bottom")
end

-- ============================================================================
--  Render-Loop
-- ============================================================================
addEventHandler("onClientRender", root, function()
    local now = getTickCount()
    if isCursorShowing() then
        local rx, ry = getCursorPosition()
        if rx then mx, my = rx * sw, ry * sh end
    end
    hits = {}
    gA = 1
    if pv.active then renderPreview(now)
    elseif G.open then renderPanel(now) end
    gA = 1
    renderToasts(now)
    renderCreatorOverlay()
    renderTransfer()
end)

-- ============================================================================
--  Eingabe
-- ============================================================================
addEventHandler("onClientClick", root, function(button, state, ax, ay)
    if not (G.open or pv.active) or button ~= "left" then return end
    if state == "up" then pv.drag = false; return end
    for i = #hits, 1, -1 do
        local h = hits[i]
        if ax >= h.x and ax <= h.x + h.w and ay >= h.y and ay <= h.y + h.h then
            if searchFocus and not h.search then blurSearch() end
            h.fn()
            return
        end
    end
    blurSearch()
    if pv.active then pv.drag = true end
end)

local function moveSelection(delta)
    if #G.list == 0 then return end
    local idx = 0
    for i, m in ipairs(G.list) do
        if G.sel == m.cat .. "/" .. m.id then idx = i; break end
    end
    idx = clamp(idx + delta, 1, #G.list)
    selectMod(G.list[idx])
    local row = math.floor((idx - 1) / G.cols)          -- Auswahl in den sichtbaren Bereich scrollen
    local top, bottom = row * G.rowH, row * G.rowH + G.rowH
    local viewH = 400 * S
    if top < G.scrollT then G.scrollT = top elseif bottom > G.scrollT + viewH then G.scrollT = bottom - viewH end
end

addEventHandler("onClientKey", root, function(key, press)
    if not press or not (G.open or pv.active) then return end

    if searchFocus then
        if key == "escape" then blurSearch(); cancelEvent() end
        return
    end

    if pv.active then
        if key == "escape" then cancelEvent(); exitPreview()
        elseif key == "enter" then toggleActivate(pv.mod)
        elseif key == "f" then VMM.toggleFav(pv.mod.cat, pv.mod.id)
        elseif key == "mouse_wheel_up" then pv.tDist = clamp(pv.tDist - 0.6, 2.6, 16)
        elseif key == "mouse_wheel_down" then pv.tDist = clamp(pv.tDist + 0.6, 2.6, 16)
        elseif key == "1" then setView("FRONT") elseif key == "2" then setView("SIDE")
        elseif key == "3" then setView("REAR") elseif key == "4" then setView("TOP") elseif key == "5" then setView("FREE") end
        return
    end

    if key == "escape" then cancelEvent(); G.closeRequest()
    elseif key == "mouse_wheel_up" then G.scrollT = clamp(G.scrollT - 90 * S, 0, G.maxScroll)
    elseif key == "mouse_wheel_down" then G.scrollT = clamp(G.scrollT + 90 * S, 0, G.maxScroll)
    elseif key == "arrow_l" then moveSelection(-1)
    elseif key == "arrow_r" then moveSelection(1)
    elseif key == "arrow_u" then moveSelection(-G.cols)
    elseif key == "arrow_d" then moveSelection(G.cols)
    elseif key == "enter" then
        local m = selPub()
        if m then startPreview(m) end
    end
end)

-- ============================================================================
--  Oeffnen / Schliessen
-- ============================================================================
local function openPanel()
    if G.open then return end
    sw, sh = guiGetScreenSize()
    S = clamp(math.min(sw / 1600, sh / 900), 0.7, 1.5)
    G.open, G.anim = true, 0
    VMM.denied = false
    ensureEdit()
    guiSetText(edit, G.query)
    guiSetVisible(edit, true)
    guiSetInputMode("no_binds_when_editing")           -- Tasten werden nur beim Tippen im Suchfeld gesperrt
    showCursor(true)
    toggleAllControls(false, true, false)              -- GTA-Steuerung waehrend des Panels aus
    VMM.requestIndex()
end

local function closePanel()
    if not G.open then return end
    exitPreview()
    blurSearch()
    G.open = false
    if edit and isElement(edit) then guiSetVisible(edit, false) end
    guiSetInputMode("allow_binds")
    showCursor(false)
    toggleAllControls(true)
    if rt and isElement(rt) then destroyElement(rt) end
    rt = nil
end

G.closeRequest = closePanel
VMM.toggleGUI = function() if G.open then closePanel() else openPanel() end end

addEventHandler("onClientResourceStart", resourceRoot, function()
    sw, sh = guiGetScreenSize()
    S = clamp(math.min(sw / 1600, sh / 900), 0.7, 1.5)
end)

addEventHandler("onClientResourceStop", resourceRoot, function()
    if G.open then
        showCursor(false)
        toggleAllControls(true)
        guiSetInputMode("allow_binds")
    end
    if pv.active then exitPreview() end
end)

-- =============================================================================
--  server.lua  -  Vehicle Mod Manager (Server)
--
--  Aufgaben:
--   * mods/<kategorie>/<mod>/ einlesen (pathListDir) und validieren
--   * ACL-Pruefung fuer JEDE Aktion (der Client wird nie vertraut)
--   * Dateien nur ueber (Kategorie, Mod-ID, Dateiname) aus dem eigenen Index ausliefern
--   * Favoriten / Recently Used / zuletzt aktive Mods persistent speichern (JSON)
--   * Globale Aktivierung fuer alle Spieler (optional, eigenes ACL-Recht)
-- =============================================================================

local index       = {}            -- index[catId] = { id, def, mods = {[modId]=mod}, order = {modId,...} }
local lastScan    = 0
local hashCache   = {}            -- "pfad|groesse" -> MD5 (spart erneutes Einlesen)
local store       = { users = {}, global = {} }
local STORE_FILE  = "userdata.json"
local saveTimer   = false
local PREVIEW_PRIORITY = { "preview_auto.jpg", "preview.png", "preview.jpg", "preview.jpeg" }

-- Events, die der Client ausloesen darf (alle werden mit "client" geprueft)
for _, e in ipairs({ "vmm:clientReady", "vmm:requestIndex", "vmm:requestMod", "vmm:requestFile",
                     "vmm:activate", "vmm:deactivate", "vmm:toggleFav", "vmm:uploadPreview", "vmm:requestSnapshot" }) do
    addEvent(e, true)
end

-- ============================================================================
--  Dateihilfen
-- ============================================================================
local function fileSizeOf(path)
    local f = fileOpen(path, true)
    if not f then return nil end
    local s = fileGetSize(f)
    fileClose(f)
    return s
end

local function readAll(path)
    local f = fileOpen(path, true)
    if not f then return nil end
    local size = fileGetSize(f)
    local data = (size > 0) and fileRead(f, size) or ""
    fileClose(f)
    return data
end

local function fileHash(path, size)
    local key = path .. "|" .. tostring(size)
    if not hashCache[key] then
        local data = readAll(path)
        if not data then return nil end
        hashCache[key] = md5(data)
    end
    return hashCache[key]
end

local function readJSON(path)
    if not fileExists(path) then return nil end
    return vmmParseJSON(readAll(path))
end

-- ============================================================================
--  Berechtigungen
-- ============================================================================
local function inAnyGroup(player, groups)
    local acc = getPlayerAccount(player)
    if not acc or isGuestAccount(acc) then return false end
    local obj = "user." .. getAccountName(acc)
    for _, g in ipairs(groups or {}) do
        local grp = aclGetGroup(g)
        if grp and isObjectInACLGroup(obj, grp) then return true end
    end
    return false
end

local function canUse(player)
    if not isElement(player) or getElementType(player) ~= "player" then return false end
    if Config.Permission.publicUse then return true end
    if hasObjectPermissionTo(player, Config.Permission.use, false) then return true end
    return inAnyGroup(player, Config.Permission.groups)
end

local function canGlobal(player)
    if not canUse(player) then return false end
    if hasObjectPermissionTo(player, Config.Permission.global, false) then return true end
    return inAnyGroup(player, Config.Permission.globalGroups)
end

local function notify(player, text, kind)
    triggerClientEvent(player, "vmm:notify", resourceRoot, text, kind or "info")
end

local function deny(player)
    notify(player, "No permission. ACL right '" .. Config.Permission.use .. "' or group required.", "denied")
end

-- ============================================================================
--  Persistenz (JSON, pro Spieler-Seriennummer)
-- ============================================================================
local function loadStore()
    local t = readJSON(STORE_FILE)
    if type(t) == "table" then
        store.users  = type(t.users) == "table" and t.users or {}
        store.global = type(t.global) == "table" and t.global or {}
    end
end

local function flushStore()
    if saveTimer and isTimer(saveTimer) then killTimer(saveTimer) end
    saveTimer = false
    if fileExists(STORE_FILE) then fileDelete(STORE_FILE) end
    local f = fileCreate(STORE_FILE)
    if f then
        fileWrite(f, toJSON(store))
        fileClose(f)
    end
end

local function markDirty()
    if not saveTimer then saveTimer = setTimer(flushStore, 3000, 1) end
end

local function getUser(player)
    local key = getPlayerSerial(player)
    local u = store.users[key]
    if type(u) ~= "table" then u = {}; store.users[key] = u end
    if type(u.fav) ~= "table"    then u.fav = {}    end
    if type(u.recent) ~= "table" then u.recent = {} end
    if type(u.active) ~= "table" then u.active = {} end
    return u
end

local function pushRecent(u, key)
    for i = #u.recent, 1, -1 do
        if u.recent[i] == key then table.remove(u.recent, i) end
    end
    table.insert(u.recent, 1, key)
    while #u.recent > Config.MaxRecent do table.remove(u.recent) end
end

-- ============================================================================
--  Mods einlesen
-- ============================================================================
local function cleanStr(v, max)
    if type(v) ~= "string" then return "" end
    return (v:sub(1, max))
end

local function cleanModels(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, v in ipairs(list) do
        local n = tonumber(v)
        if n and n == math.floor(n) and n >= 0 and n <= 20000 and #out < 64 then out[#out + 1] = n end
    end
    return out
end

local function cleanNames(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, v in ipairs(list) do
        if type(v) == "string" and #v <= 64 and v:match("^[%w_%*%-%.]+$") and #out < 16 then out[#out + 1] = v end
    end
    return out
end

local function buildCategoryDef(catId)
    local base = Config.Categories[catId] or {}
    local def = {
        label = base.label or catId:upper(), icon = base.icon or catId:sub(1, 1):upper(),
        order = base.order or 100, kind = base.kind or "model",
        models = base.models or {}, textures = base.textures or {}, previewModel = base.previewModel,
    }
    -- Optional: mods/<kategorie>/category.json ueberschreibt/ergaenzt
    local over = readJSON("mods/" .. catId .. "/category.json")
    if over then
        if type(over.label) == "string" then def.label = cleanStr(over.label, 32) end
        if type(over.icon) == "string" and #over.icon > 0 then def.icon = over.icon:sub(1, 1) end
        if tonumber(over.order) then def.order = tonumber(over.order) end
        if over.kind == "model" or over.kind == "texture" then def.kind = over.kind end
        if over.models then def.models = cleanModels(over.models) end
        if over.textures then def.textures = cleanNames(over.textures) end
        if tonumber(over.previewModel) then def.previewModel = tonumber(over.previewModel) end
    end
    return def
end

local function pickFile(files, wanted, exts)
    if type(wanted) == "string" and files[wanted] and exts[files[wanted].ext] then return wanted end
    local names = {}
    for n, f in pairs(files) do
        if exts[f.ext] and not n:lower():match("^preview") then names[#names + 1] = n end
    end
    table.sort(names, function(a, b) return vmmNaturalKey(a) < vmmNaturalKey(b) end)
    return names[1]
end

local MODEL_EXT   = { dff = true }
local TXD_EXT     = { txd = true }
local COL_EXT     = { col = true }
local IMAGE_EXT   = { png = true, jpg = true, jpeg = true, dds = true, tga = true }

-- Wandelt einen (validierten) Eintrag in das Format um, das der Client versteht.
local function makeEntry(def, src, files)
    local kind = (src.kind == "model" or src.kind == "texture") and src.kind or def.kind
    if kind == "model" then
        local models = cleanModels(src.models)
        if #models == 0 then models = cleanModels(def.models) end
        local dff = pickFile(files, src.dff, MODEL_EXT)
        local txd = pickFile(files, src.txd, TXD_EXT)
        local col = pickFile(files, src.col, COL_EXT)
        if #models == 0 or not (dff or txd or col) then return nil end
        return { kind = "model", models = models, dff = dff, txd = txd, col = col, alpha = src.alpha == true }
    else
        local names = cleanNames(src.textures)
        if #names == 0 then names = cleanNames(def.textures) end
        local image = pickFile(files, src.image or src.texture, IMAGE_EXT)
        if #names == 0 or not image then return nil end
        return { kind = "texture", names = names, image = image }
    end
end

local function buildMod(cat, modId, dir)
    local meta = readJSON(dir .. "/mod.json") or {}
    local files = {}
    for _, fname in ipairs(pathListDir(dir) or {}) do
        local ext = vmmExt(fname)
        local path = dir .. "/" .. fname
        if vmmSafeName(fname) and ext and Config.AllowedExt[ext] and pathIsFile(path) then
            local size = fileSizeOf(path)
            if size and size > 0 and size <= Config.MaxFileSize then
                files[fname] = { path = path, size = size, ext = ext }
            end
        end
    end

    -- Eintraege (was wird ersetzt?)
    local entries = {}
    if type(meta.replace) == "table" then
        for _, src in ipairs(meta.replace) do
            if type(src) == "table" then
                local e = makeEntry(cat.def, src, files)
                if e then entries[#entries + 1] = e end
            end
        end
    else
        local e = makeEntry(cat.def, meta, files)   -- Auto-Erkennung: erste .dff/.txd/.col bzw. erstes Bild
        if e then entries[1] = e end
    end
    if #entries == 0 then
        outputServerLog(("[VMM] skipped %s/%s: no usable files (need .dff/.txd/.col or image + target models/textures)"):format(cat.id, modId))
        return nil
    end

    local refFiles = {}
    for _, e in ipairs(entries) do
        for _, k in ipairs({ "dff", "txd", "col", "image" }) do
            if e[k] then refFiles[e[k]] = true end
        end
    end

    -- Preview-Bild
    local pv
    for _, cand in ipairs(PREVIEW_PRIORITY) do
        if files[cand] then pv = cand; break end
    end

    local tags = {}
    if type(meta.tags) == "table" then
        for _, t in ipairs(meta.tags) do
            if type(t) == "string" and #tags < 10 then tags[#tags + 1] = t:sub(1, 24) end
        end
    end

    local mod = {
        id = modId, dir = dir, files = files, entries = entries, refFiles = refFiles, pv = pv,
        public = {
            id = modId, name = cleanStr(meta.name, 80), author = cleanStr(meta.author, 60),
            desc = cleanStr(meta.description, 200), tags = tags,
        },
    }
    if mod.public.name == "" then mod.public.name = modId end
    if pv then
        local h = fileHash(files[pv].path, files[pv].size)
        mod.public.pvHash, mod.public.pvExt = h, files[pv].ext
        mod.public.pvSize, mod.public.pvName = files[pv].size, pv
    end
    return mod
end

local function scanMods()
    hashCache = {}                -- same-size asset repairs must receive a fresh hash
    local newIndex, nCats, nMods = {}, 0, 0
    for _, catId in ipairs(pathListDir("mods") or {}) do
        if vmmSafeName(catId) and pathIsDirectory("mods/" .. catId) and catId:sub(1, 1) ~= "_" then
            local cat = { id = catId, def = buildCategoryDef(catId), mods = {}, order = {} }
            for _, modId in ipairs(pathListDir("mods/" .. catId) or {}) do
                local dir = "mods/" .. catId .. "/" .. modId
                -- Ordner, die mit "_" beginnen, werden ignoriert (z. B. _TEMPLATE)
                if vmmSafeName(modId) and modId:sub(1, 1) ~= "_" and pathIsDirectory(dir) then
                    local mod = buildMod(cat, modId, dir)
                    if mod then
                        cat.mods[modId] = mod
                        cat.order[#cat.order + 1] = modId
                        nMods = nMods + 1
                    end
                end
            end
            table.sort(cat.order, function(a, b) return vmmNaturalKey(a) < vmmNaturalKey(b) end)
            newIndex[catId] = cat
            nCats = nCats + 1
        end
    end
    index = newIndex
    lastScan = getTickCount()
    outputServerLog(("[VMM] scan finished: %d categories, %d mods"):format(nCats, nMods))
end

local function getMod(cat, id)
    if type(cat) ~= "string" or type(id) ~= "string" then return nil end
    local c = index[cat]
    return c and c.mods[id] or nil
end

-- Zugriff auf Mod-Dateien: Berechtigte ODER Mods, die gerade global aktiv sind
local function accessMod(player, cat, id)
    local mod = getMod(cat, id)
    if not mod then return nil end
    if canUse(player) or store.global[cat] == id then return mod end
    return nil
end

-- ============================================================================
--  Index an Client senden
-- ============================================================================
local function sendIndex(player)
    local cats = {}
    for catId, cat in pairs(index) do
        local list = {}
        for _, id in ipairs(cat.order) do list[#list + 1] = cat.mods[id].public end
        cats[#cats + 1] = {
            id = catId, label = cat.def.label, icon = cat.def.icon, order = cat.def.order,
            kind = cat.def.kind, previewModel = cat.def.previewModel, mods = list,
        }
    end
    table.sort(cats, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    local u = getUser(player)
    triggerClientEvent(player, "vmm:index", resourceRoot, cats,
        { fav = u.fav, recent = u.recent, active = u.active },
        { canGlobal = canGlobal(player), global = store.global })
end

addEventHandler("vmm:requestIndex", resourceRoot, function(force)
    local p = client
    if not canUse(p) then return deny(p) end
    local age = getTickCount() - lastScan
    if (force and age > 1000) or (Config.RescanOnOpen and age > Config.RescanMinInterval) then scanMods() end
    sendIndex(p)
end)

-- ============================================================================
--  Datei-Metadaten und Dateiuebertragung
-- ============================================================================
addEventHandler("vmm:requestMod", resourceRoot, function(cat, id)
    local p = client
    local mod = accessMod(p, cat, id)
    if not mod then
        triggerClientEvent(p, "vmm:modFiles", resourceRoot, tostring(cat), tostring(id), false)
        return
    end
    local files = {}
    for name in pairs(mod.refFiles) do
        local f = mod.files[name]
        f.hash = f.hash or fileHash(f.path, f.size)
        files[name] = { hash = f.hash, size = f.size, ext = f.ext }
    end
    triggerClientEvent(p, "vmm:modFiles", resourceRoot, cat, id, mod.entries, files)
end)

addEventHandler("vmm:requestFile", resourceRoot, function(cat, id, name)
    local p = client
    local mod = accessMod(p, cat, id)
    if not mod or type(name) ~= "string" then return end
    local info = mod.files[name]      -- nur Dateien aus dem eigenen Index, nie freie Pfade
    if not info then return end
    local data = readAll(info.path)
    if not data then return end
    info.hash = info.hash or md5(data)
    local cs = Config.Transfer.chunkSize
    local total = math.max(1, math.ceil(#data / cs))
    for i = 1, total do
        triggerLatentClientEvent(p, "vmm:fileChunk", Config.Transfer.bandwidth, false, resourceRoot,
            info.hash, i, total, data:sub((i - 1) * cs + 1, i * cs))
    end
end)

-- ============================================================================
--  Aktivieren / Deaktivieren / Favoriten
-- ============================================================================
addEventHandler("vmm:activate", resourceRoot, function(cat, id, scope)
    local p = client
    if not canUse(p) then return deny(p) end
    if not getMod(cat, id) then return notify(p, "Unknown mod.", "error") end

    local u = getUser(p)
    u.active[cat] = id
    pushRecent(u, cat .. "/" .. id)

    if scope == "global" and canGlobal(p) then
        store.global[cat] = id
        triggerClientEvent(root, "vmm:apply", resourceRoot, cat, id, "global")
    else
        triggerClientEvent(p, "vmm:apply", resourceRoot, cat, id, "local")
    end
    triggerClientEvent(p, "vmm:userData", resourceRoot, { fav = u.fav, recent = u.recent, active = u.active }, store.global)
    markDirty()
end)

addEventHandler("vmm:deactivate", resourceRoot, function(cat, scope)
    local p = client
    if not canUse(p) then return deny(p) end
    if type(cat) ~= "string" then return end
    local u = getUser(p)
    u.active[cat] = nil
    if scope == "global" and canGlobal(p) then
        store.global[cat] = nil
        triggerClientEvent(root, "vmm:unapply", resourceRoot, cat)
    else
        triggerClientEvent(p, "vmm:unapply", resourceRoot, cat)
    end
    triggerClientEvent(p, "vmm:userData", resourceRoot, { fav = u.fav, recent = u.recent, active = u.active }, store.global)
    markDirty()
end)

addEventHandler("vmm:toggleFav", resourceRoot, function(cat, id)
    local p = client
    if not canUse(p) then return deny(p) end
    if not getMod(cat, id) then return end
    local u = getUser(p)
    local key = cat .. "/" .. id
    u.fav[key] = (not u.fav[key]) or nil
    triggerClientEvent(p, "vmm:userData", resourceRoot, { fav = u.fav, recent = u.recent, active = u.active }, store.global)
    markDirty()
end)

-- ============================================================================
--  Neue Spieler / Wiederherstellung
-- ============================================================================
addEventHandler("vmm:clientReady", resourceRoot, function()
    local p = client
    for cat, id in pairs(store.global) do
        if getMod(cat, id) then triggerClientEvent(p, "vmm:apply", resourceRoot, cat, id, "global") end
    end
    if Config.RestoreOnJoin and canUse(p) then
        local u = getUser(p)
        for cat, id in pairs(u.active) do
            if getMod(cat, id) and not store.global[cat] then
                triggerClientEvent(p, "vmm:apply", resourceRoot, cat, id, "local")
            end
        end
    end
end)

-- ============================================================================
--  Automatisch erzeugte Preview (Snapshot aus der Preview-Szene)
-- ============================================================================
local function saveSnapshot(p, cat, id, data)
    local mod = getMod(cat, id)
    if not mod or type(data) ~= "string" then return false end
    if #data < 100 or #data > 600000 then notify(p, "Snapshot has an invalid size.", "error") return false end
    if data:sub(1, 3) ~= string.char(0xFF, 0xD8, 0xFF) then notify(p, "Snapshot is not a JPEG.", "error") return false end

    -- Der Pfad entsteht ausschliesslich aus bereits validierten Ordnernamen + festem Dateinamen.
    local path = mod.dir .. "/preview_auto.jpg"
    if fileExists(path) then fileDelete(path) end
    local f = fileCreate(path)
    if not f then notify(p, "Could not save snapshot.", "error") return false end
    fileWrite(f, data)
    fileClose(f)

    local size = fileSizeOf(path)
    mod.files["preview_auto.jpg"] = { path = path, size = size, ext = "jpg" }
    mod.pv = "preview_auto.jpg"
    mod.public.pvHash, mod.public.pvExt = md5(data), "jpg"
    mod.public.pvSize, mod.public.pvName = size, "preview_auto.jpg"
    triggerClientEvent(p, "vmm:previewUpdated", resourceRoot, cat, mod.public)
    notify(p, "Snapshot saved as preview.", "success")
    return true
end

-- Variante "client": Client schickt fertiges JPEG
addEventHandler("vmm:uploadPreview", resourceRoot, function(cat, id, data)
    local p = client
    if not canUse(p) then return deny(p) end
    saveSnapshot(p, cat, id, data)
end)

-- Variante "server": MTA erzeugt den Screenshot selbst (takePlayerScreenShot -> onPlayerScreenShot)
local snapPending = {}

addEventHandler("vmm:requestSnapshot", resourceRoot, function(cat, id)
    local p = client
    if not canUse(p) then return deny(p) end
    if not getMod(cat, id) then return end
    local pend = snapPending[p]
    if pend and getTickCount() - pend.t < 15000 then return end
    local sz = Config.Preview.snapshotSize
    snapPending[p] = { cat = cat, id = id, t = getTickCount() }
    if not takePlayerScreenShot(p, sz[1], sz[2], "vmm", 85, Config.Preview.snapshotBandwidth, 1400) then
        snapPending[p] = nil
        notify(p, "Snapshot could not be started.", "error")
        triggerClientEvent(p, "vmm:snapshotDone", resourceRoot, false)
    end
end)

addEventHandler("onPlayerScreenShot", root, function(res, status, imageData, timestamp, tag)
    if res ~= getThisResource() or tag ~= "vmm" then return end
    local p = source
    local pend = snapPending[p]
    snapPending[p] = nil
    if not pend then return end
    if status ~= "ok" then
        notify(p, "Snapshot failed (" .. tostring(status) .. "). Screen upload allowed in MTA settings?", "error")
        return triggerClientEvent(p, "vmm:snapshotDone", resourceRoot, false)
    end
    local ok = saveSnapshot(p, pend.cat, pend.id, imageData)
    triggerClientEvent(p, "vmm:snapshotDone", resourceRoot, ok)
end)

addEventHandler("onPlayerQuit", root, function() snapPending[source] = nil end)

-- ============================================================================
--  Start / Stop / Admin-Kommando
-- ============================================================================
addEventHandler("onResourceStart", resourceRoot, function()
    loadStore()
    scanMods()
end)

addEventHandler("onResourceStop", resourceRoot, function()
    if saveTimer then flushStore() end
end)

-- Server-Konsole oder berechtigter Spieler: "vmmrescan"
addCommandHandler("vmmrescan", function(p)
    if isElement(p) and not canUse(p) then return end
    scanMods()
    if isElement(p) then notify(p, "Rescan done.", "success") end
end)

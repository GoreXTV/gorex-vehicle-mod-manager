-- =============================================================================
--  client.lua  -  Vehicle Mod Manager (Client-Kern)
--
--  Ablauf beim Aktivieren eines Mods:
--    Server validiert  ->  "vmm:apply"  ->  Datei-Liste holen (vmm:modFiles)
--    ->  fehlende Dateien streamen und in cache_<MD5>.<ext> ablegen
--    ->  altes Mod der Kategorie sauber entladen  ->  neues Mod laden und ersetzen
--
--  Speicher-Lifecycle (wichtig gegen Leaks):
--    engineRestoreModel/engineRestoreCOL  ->  danach destroyElement(dff/txd/col/shader/texture)
-- =============================================================================

VMM = {
    cats = {}, catById = {}, modByKey = {},
    user = { fav = {}, recent = {}, active = {} },
    canGlobal = false, globalActive = {},
    scope = "local",          -- "local" = nur ich, "global" = alle Spieler
    creatorMode = false,
    indexLoaded = false, denied = false, indexVersion = 0,
    xfer = { active = 0, got = 0, total = 0 },
    toasts = {},
}

for _, e in ipairs({ "vmm:index", "vmm:userData", "vmm:apply", "vmm:unapply", "vmm:modFiles",
                     "vmm:fileChunk", "vmm:notify", "vmm:previewUpdated", "vmm:snapshotDone" }) do
    addEvent(e, true)
end

local committed   = {}   -- cat -> modId   (aktiviert / dauerhaft)
local loaded      = {}   -- cat -> { key, models = {}, elements = {} }   (aktuell in GTA geladen)
local modelOwner  = {}   -- modelID -> cat (verhindert Konflikte zwischen Kategorien)
local modInfo     = {}   -- "cat/id" -> { entries, files }
local pendingMod  = {}   -- "cat/id" -> { callbacks }
local waitFile    = {}   -- hash -> { callbacks }
local incoming    = {}   -- hash -> { parts, got, total, ext }
local seq         = {}   -- cat -> Zaehler (verwirft veraltete Apply-Vorgaenge)
local okCache     = {}   -- hash -> true (Datei im Cache verifiziert)
local pvInflight, pvFailed = 0, {}

-- ============================================================================
--  Toasts (werden in gui.lua gezeichnet)
-- ============================================================================
function VMM.toast(text, kind)
    table.insert(VMM.toasts, { text = tostring(text), kind = kind or "info", t0 = getTickCount(), dur = 3500 })
    while #VMM.toasts > 4 do table.remove(VMM.toasts, 1) end
end

-- ============================================================================
--  Cache
-- ============================================================================
local function cachePath(hash, ext) return Config.CachePrefix .. hash .. "." .. ext end

local function cachedOK(hash, ext, size)
    if okCache[hash] then return true end
    local p = cachePath(hash, ext)
    if not fileExists(p) then return false end
    local f = fileOpen(p, true)
    if not f then return false end
    local s = fileGetSize(f)
    fileClose(f)
    if s == size then okCache[hash] = true; return true end
    return false
end

function VMM.clearCache()
    local n = 0
    for _, name in ipairs(pathListDir(".") or {}) do
        if name:sub(1, #Config.CachePrefix) == Config.CachePrefix and fileDelete(name) then n = n + 1 end
    end
    okCache = {}
    VMM.toast(("Cache cleared (%d files)"):format(n), "success")
end

-- ============================================================================
--  Download
-- ============================================================================
local function finishFile(hash, ok)
    local cbs = waitFile[hash]
    waitFile[hash] = nil
    if not cbs then return end
    for _, cb in ipairs(cbs) do cb(ok) end
end

local function ensureFile(hash, ext, size, name, cat, id, cb)
    if cachedOK(hash, ext, size) then return cb(true) end
    if waitFile[hash] then
        table.insert(waitFile[hash], cb)
        return
    end
    waitFile[hash] = { cb }
    incoming[hash] = { parts = {}, got = 0, total = 0, ext = ext }
    VMM.xfer.active = VMM.xfer.active + 1
    VMM.xfer.total = VMM.xfer.total + size
    triggerServerEvent("vmm:requestFile", resourceRoot, cat, id, name)
    setTimer(function()
        if incoming[hash] then          -- Zeitueberschreitung
            incoming[hash] = nil
            VMM.xfer.active = math.max(0, VMM.xfer.active - 1)
            finishFile(hash, false)
        end
    end, Config.Transfer.timeout, 1)
end

addEventHandler("vmm:fileChunk", resourceRoot, function(hash, i, total, data)
    local inc = incoming[hash]
    if not inc or inc.parts[i] then return end
    inc.parts[i] = data
    inc.got = inc.got + 1
    VMM.xfer.got = VMM.xfer.got + #data
    if inc.got < total then return end

    incoming[hash] = nil
    VMM.xfer.active = math.max(0, VMM.xfer.active - 1)
    if VMM.xfer.active == 0 then VMM.xfer.got, VMM.xfer.total = 0, 0 end

    local full = table.concat(inc.parts)
    local ok = false
    if md5(full) == hash then                    -- Integritaet pruefen
        local p = cachePath(hash, inc.ext)
        if fileExists(p) then fileDelete(p) end
        local f = fileCreate(p)
        if f then
            fileWrite(f, full)
            fileClose(f)
            okCache[hash] = true
            ok = true
        end
    end
    finishFile(hash, ok)
end)

-- Datei-Liste eines Mods holen und alle fehlenden Dateien laden
local function prepare(cat, id, info, cb)
    local remaining, failed = 0, false
    for _ in pairs(info.files) do remaining = remaining + 1 end
    if remaining == 0 then return cb(true, info) end
    for name, f in pairs(info.files) do
        ensureFile(f.hash, f.ext, f.size, name, cat, id, function(ok)
            if not ok then failed = true end
            remaining = remaining - 1
            if remaining == 0 then cb(not failed, info) end
        end)
    end
end

function VMM.fetchMod(cat, id, cb)
    local key = cat .. "/" .. id
    if modInfo[key] then return prepare(cat, id, modInfo[key], cb) end
    if pendingMod[key] then
        table.insert(pendingMod[key], cb)
        return
    end
    pendingMod[key] = { cb }
    triggerServerEvent("vmm:requestMod", resourceRoot, cat, id)
end

addEventHandler("vmm:modFiles", resourceRoot, function(cat, id, entries, files)
    local key = cat .. "/" .. id
    local cbs = pendingMod[key] or {}
    pendingMod[key] = nil
    if not entries then
        for _, cb in ipairs(cbs) do cb(false) end
        return
    end
    modInfo[key] = { entries = entries, files = files }
    for _, cb in ipairs(cbs) do prepare(cat, id, modInfo[key], cb) end
end)

-- Vorschaubild (Thumbnail): gibt den Pfad zurueck, sobald es im Cache liegt
function VMM.thumbPath(cat, pub)
    if not pub.pvHash or pvFailed[pub.pvHash] then return nil end
    if cachedOK(pub.pvHash, pub.pvExt, pub.pvSize) then return cachePath(pub.pvHash, pub.pvExt) end
    if not incoming[pub.pvHash] and not waitFile[pub.pvHash] and pvInflight < 3 then
        pvInflight = pvInflight + 1
        ensureFile(pub.pvHash, pub.pvExt, pub.pvSize, pub.pvName, cat, pub.id, function(ok)
            pvInflight = pvInflight - 1
            if not ok then pvFailed[pub.pvHash] = true end
        end)
    end
    return nil
end

-- Pfad einer bereits geladenen Datei (fuer Textur/Modell)
local function pathOf(info, name)
    local f = info.files[name]
    return f and cachePath(f.hash, f.ext) or nil
end

-- ============================================================================
--  Modelle/Texturen in GTA laden bzw. entladen
-- ============================================================================
local function unloadCategory(cat)
    local rec = loaded[cat]
    if not rec then return end
    for _, mid in ipairs(rec.models) do
        if modelOwner[mid] == cat then          -- nur wiederherstellen, was diese Kategorie besitzt
            engineRestoreModel(mid)
            if rec.cols and rec.cols[mid] then engineRestoreCOL(mid) end
            modelOwner[mid] = nil
        end
    end
    for i = #rec.elements, 1, -1 do             -- DFF/Shader vor TXD/Textur freigeben
        local el = rec.elements[i]
        if isElement(el) then destroyElement(el) end
    end
    loaded[cat] = nil
end

local function claimModel(mid, cat)
    local owner = modelOwner[mid]
    if owner and owner ~= cat then
        -- Konflikt: Modell gehoert einer anderen Kategorie -> die andere verliert es
        engineRestoreModel(mid)
        local orec = loaded[owner]
        if orec then
            if orec.cols and orec.cols[mid] then engineRestoreCOL(mid); orec.cols[mid] = nil end
            for i = #orec.models, 1, -1 do
                if orec.models[i] == mid then table.remove(orec.models, i) end
            end
        end
        VMM.toast(("Model %d was taken over from '%s'"):format(mid, owner), "warn")
    end
    modelOwner[mid] = cat
end

-- opts.texTarget    : Fahrzeug-Element, auf das Textur-Shader beschraenkt werden (Preview)
-- opts.skipModels   : DFF/TXD/COL nicht laden
-- opts.skipTextures : Shader nicht laden
-- Rueckgabe: ok, texRec  (texRec nur wenn opts.texTarget gesetzt: eigene Elementliste zum Zerstoeren)
function VMM.loadIntoGame(cat, id, info, opts)
    opts = opts or {}
    local key = cat .. "/" .. id
    local hasModel, hasTex = false, false
    for _, e in ipairs(info.entries) do
        if e.kind == "model" then hasModel = true else hasTex = true end
    end

    local rec
    if not opts.skipModels and hasModel then
        unloadCategory(cat)
        rec = { models = {}, cols = {}, elements = {} }
        loaded[cat] = rec
    elseif not opts.texTarget and not opts.skipTextures and hasTex then
        unloadCategory(cat)
        rec = { models = {}, cols = {}, elements = {} }
        loaded[cat] = rec
    else
        rec = loaded[cat] or { models = {}, cols = {}, elements = {} }
        if not loaded[cat] and not opts.texTarget then loaded[cat] = rec end
    end
    local texRec = opts.texTarget and { elements = {} } or nil
    local function fail(step, filename, mid)
        local detail = key .. ": " .. step .. " failed"
            .. (filename and (" [" .. filename .. "]") or "")
            .. (mid and (" model=" .. mid) or "")
        outputDebugString("[VMM] " .. detail, 1)
        local pub = VMM.modByKey[key]
        VMM.toast((pub and pub.name or key) .. ": " .. step .. " failed", "error")
        if texRec then VMM.destroyRec(texRec) else unloadCategory(cat) end
        return false, nil
    end

    local txdByFile = {}                                   -- gleiche TXD (z. B. Felgen-Pack) nur einmal laden
    for _, e in ipairs(info.entries) do
        if e.kind == "model" and not opts.skipModels then
            -- Separate COL replacements support objects only. Vehicle collisions
            -- come from the embedded collision in the vehicle DFF.
            local col
            if e.col then
                for _, mid in ipairs(e.models) do
                    if mid > 611 or (mid >= 321 and mid <= 399) then
                        col = engineLoadCOL(pathOf(info, e.col))
                        if not col then return fail("COL load", e.col, mid) end
                        rec.elements[#rec.elements + 1] = col
                        break
                    end
                end
            end
            local txd
            if e.txd then
                txd = txdByFile[e.txd]
                if txd == nil then
                    txd = engineLoadTXD(pathOf(info, e.txd)) or false
                    txdByFile[e.txd] = txd
                    if txd then rec.elements[#rec.elements + 1] = txd end
                end
                txd = txd or nil
                if not txd then return fail("TXD load", e.txd) end
            end
            for _, mid in ipairs(e.models) do
                claimModel(mid, cat)
                -- Track ownership before changing the engine, including failures.
                rec.models[#rec.models + 1] = mid
                if col and (mid > 611 or (mid >= 321 and mid <= 399)) then
                    rec.cols[mid] = true
                    if not engineReplaceCOL(col, mid) then return fail("COL replace", e.col, mid) end
                end
                if txd and not engineImportTXD(txd, mid) then return fail("TXD import", e.txd, mid) end
            end
            -- Import every target's texture dictionary BEFORE loading the DFF.
            if e.dff then
                local dff = engineLoadDFF(pathOf(info, e.dff))
                if not dff then return fail("DFF load", e.dff) end
                rec.elements[#rec.elements + 1] = dff
                for _, mid in ipairs(e.models) do
                    if not engineReplaceModel(dff, mid, e.alpha == true) then
                        return fail("DFF replace", e.dff, mid)
                    end
                end
            end
        elseif e.kind == "texture" and not opts.skipTextures then
            local tex = dxCreateTexture(pathOf(info, e.image), "argb", true, "clamp")
            local shader = dxCreateShader("shaders/replace.fx")
            if tex and shader then
                local list = texRec and texRec.elements or rec.elements
                list[#list + 1] = tex
                list[#list + 1] = shader
                if not dxSetShaderValue(shader, "gTexture", tex) then return fail("Shader setup", e.image) end
                for _, n in ipairs(e.names) do
                    local applied
                    if opts.texTarget then
                        applied = engineApplyShaderToWorldTexture(shader, n, opts.texTarget)
                    else
                        applied = engineApplyShaderToWorldTexture(shader, n)
                    end
                    if not applied then return fail("Shader apply", n) end
                end
            else
                if tex then destroyElement(tex) end
                if shader then destroyElement(shader) end
                return fail("Texture/shader creation", e.image)
            end
        end
    end
    -- A partial model-only preview must not count as a fully activated mixed mod.
    if not opts.texTarget and not (opts.skipTextures and hasTex) then rec.key = key end
    return true, texRec
end

function VMM.destroyRec(texRec)
    if not texRec then return end
    for i = #texRec.elements, 1, -1 do
        local el = texRec.elements[i]
        if isElement(el) then destroyElement(el) end
    end
    texRec.elements = {}
end

function VMM.unloadCategory(cat) unloadCategory(cat) end
function VMM.loadedKey(cat) return loaded[cat] and loaded[cat].key or nil end
function VMM.committed(cat) return committed[cat] end

-- Nach einer Preview: GTA-Zustand wieder auf den aktivierten Mod zuruecksetzen
function VMM.revertToCommitted(cat)
    local want = committed[cat]
    if not want then
        unloadCategory(cat)
        return
    end
    if VMM.loadedKey(cat) == cat .. "/" .. want then return end
    seq[cat] = (seq[cat] or 0) + 1
    local my = seq[cat]
    VMM.fetchMod(cat, want, function(ok, info)
        if seq[cat] ~= my then return end
        if not ok or not VMM.loadIntoGame(cat, want, info) then
            committed[cat] = nil
            unloadCategory(cat)
        end
    end)
end

-- ============================================================================
--  Server-Events: apply / unapply / userData / index
-- ============================================================================
addEventHandler("vmm:apply", resourceRoot, function(cat, id, scope)
    seq[cat] = (seq[cat] or 0) + 1
    local my = seq[cat]
    local key = cat .. "/" .. id
    if VMM.loadedKey(cat) == key and modInfo[key] then       -- schon geladen (z. B. aus der Preview)
        committed[cat] = id
        VMM.toast("Activated: " .. (VMM.modByKey[key] and VMM.modByKey[key].name or key), "success")
        return
    end
    VMM.fetchMod(cat, id, function(ok, info)
        if seq[cat] ~= my then return end
        if not ok then return VMM.toast("Download failed: " .. key, "error") end
        if VMM.loadIntoGame(cat, id, info) then
            committed[cat] = id
            local pub = VMM.modByKey[key]
            VMM.toast((scope == "global" and "[GLOBAL] " or "") .. "Activated: " .. (pub and pub.name or key), "success")
        else
            VMM.revertToCommitted(cat)
        end
    end)
end)

addEventHandler("vmm:unapply", resourceRoot, function(cat)
    seq[cat] = (seq[cat] or 0) + 1
    unloadCategory(cat)
    committed[cat] = nil
    VMM.toast("Restored original: " .. cat, "info")
end)

addEventHandler("vmm:userData", resourceRoot, function(user, global)
    VMM.user = user
    VMM.globalActive = global or {}
    VMM.indexVersion = VMM.indexVersion + 1
end)

addEventHandler("vmm:index", resourceRoot, function(cats, user, flags)
    VMM.cats, VMM.catById, VMM.modByKey = cats, {}, {}
    for _, c in ipairs(cats) do
        VMM.catById[c.id] = c
        for _, m in ipairs(c.mods) do
            m.cat = c.id
            VMM.modByKey[c.id .. "/" .. m.id] = m
        end
    end
    VMM.user, VMM.canGlobal, VMM.globalActive = user, flags.canGlobal, flags.global or {}
    if not VMM.canGlobal then VMM.scope = "local" end
    modInfo = {}                       -- Dateilisten neu holen (Mods koennen sich geaendert haben)
    VMM.indexLoaded, VMM.denied = true, false
    VMM.indexVersion = VMM.indexVersion + 1
end)

addEventHandler("vmm:previewUpdated", resourceRoot, function(cat, pub)
    local old = VMM.modByKey[cat .. "/" .. pub.id]
    if old then
        old.pvHash, old.pvExt, old.pvSize, old.pvName = pub.pvHash, pub.pvExt, pub.pvSize, pub.pvName
        VMM.indexVersion = VMM.indexVersion + 1
        if VMM.onThumbChanged then VMM.onThumbChanged(cat, pub.id) end
    end
end)

addEventHandler("vmm:notify", resourceRoot, function(text, kind)
    if kind == "denied" then VMM.denied = true end
    VMM.toast(text, kind == "denied" and "error" or kind)
end)

-- ============================================================================
--  API fuer die GUI
-- ============================================================================
function VMM.requestIndex(force) triggerServerEvent("vmm:requestIndex", resourceRoot, force and true or false) end
function VMM.activate(cat, id)   triggerServerEvent("vmm:activate", resourceRoot, cat, id, VMM.scope) end
function VMM.deactivate(cat)     triggerServerEvent("vmm:deactivate", resourceRoot, cat, VMM.scope) end
function VMM.isFav(cat, id)      return VMM.user.fav[cat .. "/" .. id] and true or false end

function VMM.toggleFav(cat, id)
    local key = cat .. "/" .. id
    VMM.user.fav[key] = (not VMM.user.fav[key]) or nil       -- sofort anzeigen (optimistisch)
    VMM.indexVersion = VMM.indexVersion + 1
    triggerServerEvent("vmm:toggleFav", resourceRoot, cat, id)
end

function VMM.getMod(cat, id) return VMM.modByKey[cat .. "/" .. id] end

addEventHandler("vmm:snapshotDone", resourceRoot, function(ok)
    if VMM.onSnapshotDone then VMM.onSnapshotDone(ok) end
end)

function VMM.requestSnapshot(cat, id)
    triggerServerEvent("vmm:requestSnapshot", resourceRoot, cat, id)
end

function VMM.uploadPreview(cat, id, jpegData)
    return triggerLatentServerEvent("vmm:uploadPreview", Config.Preview.snapshotBandwidth, false, resourceRoot, cat, id, jpegData)
end

-- ============================================================================
--  Creator Mode: Schnellwechsel per Tasten (ohne Panel)
-- ============================================================================
VMM.currentCat = nil      -- wird von der GUI gesetzt (zuletzt gewaehlte Kategorie)

local function cycle(dir)
    if not VMM.creatorMode then return end
    if not VMM.indexLoaded then
        VMM.requestIndex()
        return VMM.toast("Loading library ... try again", "info")
    end
    local cat = VMM.currentCat
    if not cat or not VMM.catById[cat] then cat = VMM.cats[1] and VMM.cats[1].id end
    if not cat then return end

    local list = {}
    for _, m in ipairs(VMM.catById[cat].mods) do list[#list + 1] = m end
    if Config.Hotkeys.cycleFavoritesOnly then
        local favs = {}
        for _, m in ipairs(list) do
            if VMM.isFav(cat, m.id) then favs[#favs + 1] = m end
        end
        if #favs > 0 then list = favs end
    end
    if #list == 0 then return end

    local cur, pos = committed[cat], 0
    for i, m in ipairs(list) do
        if m.id == cur then pos = i end
    end
    pos = ((pos - 1 + dir) % #list) + 1
    local m = list[pos]
    VMM.activate(cat, m.id)
    VMM.toast(("%s  %s  (%d/%d)"):format(VMM.catById[cat].label, m.name, pos, #list), "info")
end

function VMM.setCreatorMode(state)
    VMM.creatorMode = state and true or false
    VMM.toast("Creator Mode " .. (VMM.creatorMode and "ON" or "OFF"), "info")
    if VMM.creatorMode and not VMM.indexLoaded then VMM.requestIndex() end
end

-- ============================================================================
--  Start / Stop / Kommandos
-- ============================================================================
addEventHandler("onClientResourceStart", resourceRoot, function()
    triggerServerEvent("vmm:clientReady", resourceRoot)

    bindKey(Config.Hotkeys.next, "down", function() cycle(1) end)
    bindKey(Config.Hotkeys.prev, "down", function() cycle(-1) end)
    bindKey(Config.Hotkeys.off, "down", function()
        if VMM.creatorMode and VMM.currentCat then VMM.deactivate(VMM.currentCat) end
    end)

    addCommandHandler(Config.Command, function(_, sub)
        sub = sub and sub:lower() or ""
        if sub == "creator" then VMM.setCreatorMode(not VMM.creatorMode)
        elseif sub == "rescan" then VMM.requestIndex(true)
        elseif sub == "clearcache" then VMM.clearCache()
        else if VMM.toggleGUI then VMM.toggleGUI() end end
    end)
    if Config.OpenKey then
        bindKey(Config.OpenKey, "down", function() if VMM.toggleGUI then VMM.toggleGUI() end end)
    end
end)

-- Beim Stoppen der Resource raeumt MTA alle Engine-Elemente automatisch auf und stellt die Modelle wieder her.
addEventHandler("onClientResourceStop", resourceRoot, function()
    for cat in pairs(loaded) do unloadCategory(cat) end
end)

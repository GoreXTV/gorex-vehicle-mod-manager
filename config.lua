-- =============================================================================
--  config.lua  (shared)  -  alle Einstellungen des Vehicle Mod Managers
-- =============================================================================
Config = {}

Config.Command = "vmm"      -- /vmm  (Panel), /vmm creator, /vmm rescan, /vmm clearcache
Config.OpenKey = "F5"       -- Taste zum Oeffnen; false = keine Taste

-- ---------------------------------------------------------------------------
--  Berechtigungen (werden NUR serverseitig ausgewertet)
--  publicUse = true: lokales Panel fuer alle Spieler, auch ohne Login/ACL.
--  Globale Aenderungen bleiben separat per ACL geschuetzt.
--  Rechte muessen das Format "command.<name>" haben, damit MTA sie kennt.
-- ---------------------------------------------------------------------------
Config.Permission = {
    publicUse    = true,                         -- false = Panel wieder per ACL einschraenken
    use          = "command.vehiclemod",         -- Panel benutzen (lokal wechseln)
    global       = "command.vehiclemod_global",  -- Mod fuer ALLE Spieler aktivieren
    groups       = { "Admin", "Mapper", "Creator" },
    globalGroups = { "Admin" },
}

Config.RestoreOnJoin     = true    -- zuletzt genutzte Mods beim Verbinden wieder anwenden
Config.RescanOnOpen      = true    -- mods/ beim Oeffnen des Panels neu einlesen
Config.RescanMinInterval = 3000    -- ms, minimaler Abstand zwischen zwei Scans
Config.MaxRecent         = 20
Config.MaxFileSize       = 48 * 1024 * 1024
Config.CachePrefix       = "cache_" -- Dateien im Client-Cache: cache_<MD5>.<ext>

-- erlaubte Dateiendungen in Mod-Ordnern (alles andere wird ignoriert)
Config.AllowedExt = { dff = true, txd = true, col = true, png = true, jpg = true, jpeg = true, dds = true, tga = true }

-- Dateiuebertragung Server -> Client (Latent Events)
Config.Transfer = {
    chunkSize = 262144,    -- Bytes pro Paket
    bandwidth = 1500000,   -- Bytes/Sekunde pro Spieler
    timeout   = 180000,    -- ms bis ein Download als fehlgeschlagen gilt
}

-- ---------------------------------------------------------------------------
--  Preview-Szene
-- ---------------------------------------------------------------------------
Config.Preview = {
    stageMode    = "player",           -- "player" = 60 m ueber dir (sicher: Welt bleibt geladen, Ped faellt nicht); "sky" = weit weg (0,0,900) - RISKANT, Ped kann durch die Welt fallen
    stage        = { 0, 0, 900 },
    defaultModel = 411,                -- Infernus
    color        = { 235, 235, 235 },  -- Lackfarbe des Preview-Fahrzeugs
    fov          = 55,
    autoRotate   = true,
    snapshotSize = { 480, 270 },       -- Groesse des automatisch erzeugten Thumbnails
    snapshotMode = "client",           -- naechstes sauberes Frame lokal aufnehmen, Upload im Hintergrund
                                       -- "server" = alternativer MTA-Screenshot, "off" = deaktiviert
    snapshotBandwidth = 1500000,        -- Bytes/Sekunde fuer Snapshot-Uploads (beide Modi)
    lightModes = {
        { name = "STUDIO", hour = 12, sky = { 34, 36, 46, 8, 9, 12 } },
        { name = "NIGHT",  hour = 0,  sky = { 6, 7, 16, 0, 0, 3 } },
        { name = "DAY",    hour = 13 },
        { name = "SUNSET", hour = 19 },
    },
}

-- ---------------------------------------------------------------------------
--  Creator Mode (Schnellwechsel ohne Panel)
-- ---------------------------------------------------------------------------
Config.Hotkeys = {
    next = "pgdn",     -- naechster Mod der aktuellen Kategorie
    prev = "pgup",     -- vorheriger Mod
    off  = "end",      -- Kategorie deaktivieren (Original wiederherstellen)
    cycleFavoritesOnly = true, -- wenn Favoriten vorhanden: nur durch Favoriten wechseln
}

Config.UI = {
    clickOpensPreview = true,   -- Klick auf Karte oeffnet direkt die Preview (Aktivieren erst dort)
    maxThumbs         = 60,     -- max. gleichzeitig geladene Vorschaubilder
    fontFile          = false,  -- z. B. "fonts/ui.ttf" (muss in meta.xml stehen)
    fontFileBold      = false,
}

-- ---------------------------------------------------------------------------
--  Kategorien
--  Jeder Unterordner von mods/ ist automatisch eine Kategorie. Eintraege hier
--  sind nur Voreinstellungen; zusaetzlich kann mods/<kategorie>/category.json
--  Werte ueberschreiben. Neue Kategorie = neuen Ordner anlegen (+ ggf. category.json).
--
--  kind = "model"   -> DFF/TXD/COL ersetzen (engineReplaceModel)  -> models = { Modell-IDs }
--  kind = "texture" -> Textur per Shader ersetzen                 -> textures = { Texturnamen }
--  previewModel     -> Fahrzeug, das in der Preview gezeigt wird
-- ---------------------------------------------------------------------------
local WHEELS = { 1025, 1073, 1074, 1075, 1076, 1077, 1078, 1079, 1080, 1081, 1082, 1083, 1084, 1085, 1096, 1097, 1098 }

Config.Categories = {
    infernus   = { label = "INFERNUS",   icon = "I", order = 1, kind = "model",   models = { 411 }, previewModel = 411 },
    backlights = { label = "BACKLIGHTS", icon = "B", order = 2, kind = "texture", textures = { "vehiclelights128", "vehiclelightson128" }, previewModel = 411 },
    wheels     = { label = "WHEELS",     icon = "W", order = 3, kind = "model",   models = WHEELS, previewModel = 411 },
    -- Beispiele fuer spaeter (einfach Ordner mods/spoilers/ anlegen):
    spoilers   = { label = "SPOILERS",   icon = "S", order = 4, kind = "model",   models = {},     previewModel = 411 },
    exhausts   = { label = "EXHAUSTS",   icon = "E", order = 5, kind = "model",   models = {},     previewModel = 411 },
}

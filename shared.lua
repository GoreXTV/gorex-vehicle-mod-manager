-- =============================================================================
--  shared.lua  -  Hilfsfunktionen fuer Server UND Client
-- =============================================================================

-- Erlaubt nur harmlose Namen (Ordner-/Dateinamen). Verhindert Pfad-Tricks wie "../" oder "/".
function vmmSafeName(s)
    if type(s) ~= "string" then return false end
    if #s < 1 or #s > 64 then return false end
    if not s:match("^[%w_%-%.]+$") then return false end
    if s:find("..", 1, true) or s:sub(1, 1) == "." then return false end
    return true
end

-- Dateiendung in Kleinbuchstaben ("Infernus.DFF" -> "dff")
function vmmExt(name)
    local e = type(name) == "string" and name:match("%.(%w+)$")
    return e and e:lower() or nil
end

-- JSON tolerant lesen (mit/ohne aeusseren Array-Wrapper, den toJSON erzeugt)
function vmmParseJSON(str)
    if type(str) ~= "string" or str == "" then return nil end
    local ok, t = pcall(fromJSON, str)
    if not (ok and type(t) == "table") then
        ok, t = pcall(fromJSON, "[" .. str .. "]")
    end
    if not (ok and type(t) == "table") then return nil end
    if type(t[1]) == "table" and next(t, 1) == nil then t = t[1] end
    return t
end

-- Natuerliche Sortierung: "Infernus 2" < "Infernus 10"
function vmmNaturalKey(s)
    return (tostring(s):lower():gsub("%d+", function(d)
        return ("0"):rep(math.max(0, 9 - #d)) .. d
    end))
end

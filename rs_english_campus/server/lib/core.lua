--[[
    English Campus — noyau serveur : erreurs, logs, verrous, cache mémoire, JSON.
]]

EC = EC or {}

-- ─────────────────────────────────────────────────────────────────────────────
--  Erreurs métier
--  EC.Fail('forbidden') interrompt le traitement d'une requête ; le code est renvoyé
--  tel quel à l'interface (qui affiche un message traduit). Toute autre erreur Lua
--  est journalisée côté serveur et renvoyée comme 'internal_error' (aucun détail
--  technique n'est exposé au client).
-- ─────────────────────────────────────────────────────────────────────────────

local FailMeta = { __tostring = function(e) return ('EC.Fail(%s)'):format(tostring(e.code)) end }

---@param code string
---@param detail any|nil information complémentaire (champ invalide...) renvoyée à l'UI
function EC.Fail(code, detail)
    error(setmetatable({ code = code, detail = detail }, FailMeta), 2)
end

function EC.IsFail(err)
    return getmetatable(err) == FailMeta
end

--- Lève une erreur métier si la condition est fausse.
function EC.Assert(cond, code, detail)
    if not cond then EC.Fail(code, detail) end
    return cond
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Logs console
-- ─────────────────────────────────────────────────────────────────────────────

local PREFIX = '^4[English Campus]^7 '

function EC.Info(msg, ...)  print(PREFIX .. (select('#', ...) > 0 and msg:format(...) or msg)) end
function EC.Warn(msg, ...)  print(PREFIX .. '^3' .. (select('#', ...) > 0 and msg:format(...) or msg) .. '^7') end
function EC.Error(msg, ...) print(PREFIX .. '^1' .. (select('#', ...) > 0 and msg:format(...) or msg) .. '^7') end
function EC.Debug(msg, ...)
    if Config.Debug then print(PREFIX .. '^5' .. (select('#', ...) > 0 and msg:format(...) or msg) .. '^7') end
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Temps (toujours en secondes UNIX, UTC)
-- ─────────────────────────────────────────────────────────────────────────────

function EC.Now()
    return os.time()
end

-- ─────────────────────────────────────────────────────────────────────────────
--  JSON sûr
-- ─────────────────────────────────────────────────────────────────────────────

function EC.JsonDecode(s, default)
    if type(s) ~= 'string' or s == '' then return default end
    local ok, value = pcall(json.decode, s)
    if ok and value ~= nil then return value end
    return default
end

function EC.JsonEncode(value)
    local ok, out = pcall(json.encode, value)
    if ok then return out end
    EC.Error('JSON encode failed: %s', tostring(out))
    return 'null'
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Verrous coopératifs (évitent les doubles soumissions concurrentes)
-- ─────────────────────────────────────────────────────────────────────────────

local locks = {}

---Exécute fn(...) en exclusivité pour `key`. Les autres appels attendent (max 5 s).
function EC.WithLock(key, fn, ...)
    local waited = 0
    while locks[key] do
        Wait(20)
        waited = waited + 20
        if waited >= 5000 then EC.Fail('busy') end
    end
    locks[key] = true
    local results = table.pack(pcall(fn, ...))
    locks[key] = nil
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Cache mémoire à durée de vie (structure des cours, classes...)
-- ─────────────────────────────────────────────────────────────────────────────

local cache = {}

function EC.CacheGet(key)
    local entry = cache[key]
    if not entry then return nil end
    if entry.expires < GetGameTimer() then
        cache[key] = nil
        return nil
    end
    return entry.value
end

function EC.CacheSet(key, value, ttlSeconds)
    cache[key] = { value = value, expires = GetGameTimer() + math.floor((ttlSeconds or 60) * 1000) }
    return value
end

--- Supprime toutes les entrées dont la clé commence par `prefix`.
function EC.CacheForget(prefix)
    local n = #prefix
    for key in pairs(cache) do
        if key:sub(1, n) == prefix then cache[key] = nil end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Nom complet d'un membre (affichage)
-- ─────────────────────────────────────────────────────────────────────────────

function EC.FullName(first, last)
    first = first or ''
    last = last or ''
    local name = EC.U.trim(first .. ' ' .. last)
    return name ~= '' and name or '—'
end

--- Nom d'affichage d'un professeur : « Mr. Anderson », sinon « Prénom Nom ».
function EC.TeacherName(title, first, last)
    if title and title ~= '' and last and last ~= '' then
        return ('%s %s'):format(title, last)
    end
    return EC.FullName(first, last)
end

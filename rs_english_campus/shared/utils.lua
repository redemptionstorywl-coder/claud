--[[
    English Campus — utilitaires partagés (client + serveur).
    Aucune dépendance FiveM ici : ce fichier est aussi chargé par les tests unitaires (tests/).
]]

EC = EC or {}

---@class ECUtils
local U = {}
EC.U = U

-- ─────────────────────────────────────────────────────────────────────────────
--  Tables
-- ─────────────────────────────────────────────────────────────────────────────

function U.copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function U.deepCopy(t, seen)
    if type(t) ~= 'table' then return t end
    seen = seen or {}
    if seen[t] then return seen[t] end
    local out = {}
    seen[t] = out
    for k, v in pairs(t) do out[U.deepCopy(k, seen)] = U.deepCopy(v, seen) end
    return out
end

function U.map(list, fn)
    local out = {}
    for i = 1, #list do out[i] = fn(list[i], i) end
    return out
end

function U.filter(list, fn)
    local out = {}
    for i = 1, #list do
        if fn(list[i], i) then out[#out + 1] = list[i] end
    end
    return out
end

function U.find(list, fn)
    for i = 1, #list do
        if fn(list[i], i) then return list[i], i end
    end
    return nil
end

function U.toSet(list)
    local set = {}
    for i = 1, #list do set[list[i]] = true end
    return set
end

function U.keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    return out
end

function U.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function U.isArray(t)
    if type(t) ~= 'table' then return false end
    local n = #t
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then return false end
    end
    return true
end

--- Mélange de Fisher–Yates (retourne une copie).
function U.shuffle(list)
    local out = U.copy(list)
    for i = #out, 2, -1 do
        local j = math.random(i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

--- Lit un chemin « a.b.c » dans une table.
function U.getPath(t, path)
    if type(t) ~= 'table' or type(path) ~= 'string' or path == '' then return nil end
    local cur = t
    for part in path:gmatch('[^%.]+') do
        if type(cur) ~= 'table' then return nil end
        cur = cur[part]
        if cur == nil then return nil end
    end
    return cur
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Nombres
-- ─────────────────────────────────────────────────────────────────────────────

function U.clamp(n, min, max)
    if n < min then return min end
    if n > max then return max end
    return n
end

function U.isInt(n)
    return type(n) == 'number' and n == n and n % 1 == 0 and n > -2^53 and n < 2^53
end

--- Arrondit à un pas (0.5 → 15.5, 0.25 → 15.75).
function U.roundTo(n, step)
    step = step or 1
    if step <= 0 then return n end
    return math.floor(n / step + 0.5) * step
end

--- Arrondi décimal propre (évite 14.999999).
function U.round(n, decimals)
    local m = 10 ^ (decimals or 0)
    return math.floor(n * m + 0.5) / m
end

--- oxmysql renvoie les TINYINT(1) en booléen ; certaines configs renvoient 0/1.
function U.bool(v)
    return v == true or v == 1 or v == '1'
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Chaînes UTF-8
-- ─────────────────────────────────────────────────────────────────────────────

function U.trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function U.utf8len(s)
    return utf8.len(s)
end

--- Tronque proprement une chaîne UTF-8 à `max` caractères.
function U.utf8sub(s, max)
    local len = utf8.len(s)
    if not len or len <= max then return s end
    local bytePos = utf8.offset(s, max + 1)
    return s:sub(1, bytePos - 1)
end

-- Caractères accentués courants (latin-1 + œ/æ) : majuscule → minuscule, minuscule → lettre de base.
local LOWER_MAP, BASE_MAP = {}, {}
do
    local pairsList = {
        { 'À', 'à', 'a' }, { 'Á', 'á', 'a' }, { 'Â', 'â', 'a' }, { 'Ã', 'ã', 'a' }, { 'Ä', 'ä', 'a' }, { 'Å', 'å', 'a' },
        { 'Æ', 'æ', 'ae' }, { 'Ç', 'ç', 'c' }, { 'È', 'è', 'e' }, { 'É', 'é', 'e' }, { 'Ê', 'ê', 'e' }, { 'Ë', 'ë', 'e' },
        { 'Ì', 'ì', 'i' }, { 'Í', 'í', 'i' }, { 'Î', 'î', 'i' }, { 'Ï', 'ï', 'i' }, { 'Ñ', 'ñ', 'n' }, { 'Ò', 'ò', 'o' },
        { 'Ó', 'ó', 'o' }, { 'Ô', 'ô', 'o' }, { 'Õ', 'õ', 'o' }, { 'Ö', 'ö', 'o' }, { 'Ø', 'ø', 'o' }, { 'Œ', 'œ', 'oe' },
        { 'Ù', 'ù', 'u' }, { 'Ú', 'ú', 'u' }, { 'Û', 'û', 'u' }, { 'Ü', 'ü', 'u' }, { 'Ý', 'ý', 'y' }, { 'Ÿ', 'ÿ', 'y' },
    }
    for _, p in ipairs(pairsList) do
        LOWER_MAP[p[1]] = p[2]
        BASE_MAP[p[1]] = p[3]
        BASE_MAP[p[2]] = p[3]
    end
    BASE_MAP['ß'] = 'ss'
end

-- Ponctuation typographique → équivalent ASCII.
local TYPO_MAP = {
    ['’'] = "'", ['‘'] = "'", ['‛'] = "'", ['´'] = "'", ['`'] = "'", ['ʼ'] = "'",
    ['“'] = '"', ['”'] = '"', ['«'] = '"', ['»'] = '"', ['„'] = '"',
    ['–'] = '-', ['—'] = '-', ['‐'] = '-', ['−'] = '-',
    ['…'] = '...',
    ['\194\160'] = ' ',     -- espace insécable
    ['\226\128\175'] = ' ', -- espace fine insécable
}

--- Minuscules UTF-8 (gère les lettres accentuées françaises).
function U.lower(s)
    local ok, res = pcall(function()
        local out = {}
        for _, cp in utf8.codes(s) do
            local ch = utf8.char(cp)
            if cp < 128 then
                out[#out + 1] = ch:lower()
            else
                out[#out + 1] = LOWER_MAP[ch] or ch
            end
        end
        return table.concat(out)
    end)
    return ok and res or s:lower()
end

--- Retire les accents (après passage en minuscules).
function U.stripAccents(s)
    local ok, res = pcall(function()
        local out = {}
        for _, cp in utf8.codes(s) do
            local ch = utf8.char(cp)
            out[#out + 1] = (cp >= 128 and BASE_MAP[ch]) or ch
        end
        return table.concat(out)
    end)
    return ok and res or s
end

function U.normalizeTypography(s)
    local ok, res = pcall(function()
        local out = {}
        for _, cp in utf8.codes(s) do
            local ch = utf8.char(cp)
            out[#out + 1] = (cp >= 128 and TYPO_MAP[ch]) or ch
        end
        return table.concat(out)
    end)
    return ok and res or s
end

--- Clé de comparaison souple (classes, rôles) : minuscules, sans accents, sans espaces superflus.
function U.normKey(s)
    if type(s) ~= 'string' then s = tostring(s or '') end
    s = U.stripAccents(U.lower(U.normalizeTypography(s)))
    s = s:gsub('[%s%-_%.]+', ' ')
    return U.trim(s)
end

-- Contractions anglaises non ambiguës (« 's » et « 'd » sont volontairement ignorés).
local CONTRACTIONS = {
    { "can't", 'cannot' }, { "won't", 'will not' }, { "shan't", 'shall not' },
    { "n't", ' not' }, { "'re", ' are' }, { "'ve", ' have' }, { "'ll", ' will' }, { "i'm", 'i am' },
}

--- Normalise une réponse écrite pour la comparaison.
---@param s string
---@param opts table|nil { ignoreAccents, ignorePunctuation, expandContractions, caseSensitive }
function U.normalizeAnswer(s, opts)
    if type(s) ~= 'string' then return '' end
    opts = opts or {}
    s = U.normalizeTypography(s)
    if not opts.caseSensitive then s = U.lower(s) end
    if opts.ignoreAccents then s = U.stripAccents(s) end
    if opts.expandContractions then
        for _, c in ipairs(CONTRACTIONS) do
            s = s:gsub(c[1]:gsub('%p', '%%%0'), c[2])
        end
        s = s:gsub('can not', 'cannot')
    end
    if opts.ignorePunctuation then
        -- On garde les apostrophes (possessifs) et on transforme les tirets en espaces.
        s = s:gsub('%-', ' ')
        s = s:gsub("[^%w%s'\128-\255]", ' ')
    end
    s = s:gsub('%s+', ' ')
    return U.trim(s)
end

--- Distance d'édition (Damerau–Levenshtein restreinte) avec arrêt anticipé.
function U.editDistance(a, b, limit)
    if a == b then return 0 end
    local la, lb = #a, #b
    limit = limit or math.huge
    if math.abs(la - lb) > limit then return limit + 1 end
    if la == 0 then return lb end
    if lb == 0 then return la end
    local prevprev, prev, cur = {}, {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur = { [0] = i }
        local rowMin = cur[0]
        local ca = a:byte(i)
        for j = 1, lb do
            local cb = b:byte(j)
            local cost = (ca == cb) and 0 or 1
            local v = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if i > 1 and j > 1 and ca == b:byte(j - 1) and a:byte(i - 1) == cb then
                v = math.min(v, prevprev[j - 2] + 1)
            end
            cur[j] = v
            if v < rowMin then rowMin = v end
        end
        if rowMin > limit then return limit + 1 end
        prevprev, prev = prev, cur
    end
    return prev[lb]
end

--- Nettoie un texte saisi : UTF-8 valide, sans caractères de contrôle, longueur bornée.
---@return string|nil cleaned, string|nil err
function U.cleanText(s, maxLen, multiline)
    if type(s) ~= 'string' then return nil, 'type' end
    if not utf8.len(s) then return nil, 'encoding' end
    s = s:gsub('\r\n', '\n'):gsub('\r', '\n')
    if multiline then
        s = s:gsub('[\0-\8\11\12\14-\31\127]', '')
        s = s:gsub('\n\n\n+', '\n\n')
    else
        s = s:gsub('[\0-\31\127]', ' ')
    end
    s = U.trim(s)
    if maxLen and utf8.len(s) > maxLen then return nil, 'too_long' end
    return s
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Identifiants
-- ─────────────────────────────────────────────────────────────────────────────

local UID_CHARS = 'abcdefghijklmnopqrstuvwxyz0123456789'

--- Identifiant aléatoire (base 36). 16 caractères ≈ 82 bits d'entropie.
function U.uid(len)
    len = len or 16
    local out = {}
    for i = 1, len do
        local r = math.random(1, #UID_CHARS)
        out[i] = UID_CHARS:sub(r, r)
    end
    return table.concat(out)
end

function U.isUid(s, len)
    return type(s) == 'string' and #s == (len or 16) and s:match('^[a-z0-9]+$') ~= nil
end

return U

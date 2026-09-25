--[[
    English Campus — validation des données reçues de l'interface.

    Règle absolue : tout ce qui vient de la NUI est considéré comme hostile.
    Chaque champ est typé, borné et nettoyé ici avant d'atteindre la base de données.
    En cas de problème, EC.Fail('bad_request', 'nom_du_champ') interrompt la requête.
]]

local U = EC.U

V = {}

local function bad(field, reason)
    EC.Fail('bad_request', reason and (field .. ':' .. reason) or field)
end

--- Identifiant SQL (entier positif).
function V.id(value, field)
    if not U.isInt(value) or value < 1 or value > 4294967295 then bad(field or 'id') end
    return value
end

function V.optId(value, field)
    if value == nil then return nil end
    return V.id(value, field)
end

--- Entier borné.
function V.int(value, min, max, field, default)
    if value == nil and default ~= nil then return default end
    if not U.isInt(value) or value < min or value > max then bad(field or 'int') end
    return value
end

--- Nombre (décimal autorisé) borné.
function V.num(value, min, max, field, default)
    if value == nil and default ~= nil then return default end
    if type(value) ~= 'number' or value ~= value or value < min or value > max then bad(field or 'number') end
    return value
end

function V.bool(value, default)
    if value == nil then return default == true end
    return value == true
end

--- Chaîne nettoyée (UTF-8 valide, sans caractères de contrôle, longueur max en caractères).
---@param opts table|nil { min, multiline, optional, default }
function V.str(value, max, field, opts)
    opts = opts or {}
    if value == nil or value == '' then
        if opts.optional then return opts.default end
        if (opts.min or 1) > 0 then bad(field or 'string', 'required') end
        return ''
    end
    local cleaned, err = U.cleanText(value, max, opts.multiline)
    if not cleaned then bad(field or 'string', err) end
    if opts.min and utf8.len(cleaned) < opts.min then bad(field or 'string', 'too_short') end
    if cleaned == '' and not opts.optional and (opts.min or 1) > 0 then bad(field or 'string', 'required') end
    return cleaned
end

--- Valeur appartenant à un ensemble { valeur = true }.
function V.enum(value, set, field, default)
    if value == nil and default ~= nil then return default end
    if type(value) ~= 'string' or not set[value] then bad(field or 'enum') end
    return value
end

--- Tableau (séquence) de taille bornée.
function V.list(value, max, field, optional)
    if value == nil and optional then return {} end
    if type(value) ~= 'table' then bad(field or 'list') end
    if next(value) ~= nil and not U.isArray(value) then bad(field or 'list', 'not_array') end
    if #value > max then bad(field or 'list', 'too_many') end
    return value
end

--- Liste d'identifiants uniques.
function V.idList(value, max, field, optional)
    local list = V.list(value, max, field, optional)
    local out, seen = {}, {}
    for i = 1, #list do
        local id = V.id(list[i], field)
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

--- Table (objet) obligatoire.
function V.table(value, field)
    if type(value) ~= 'table' then bad(field or 'object') end
    return value
end

--- Identifiant Campus (chaîne courte, caractères sûrs).
function V.campusId(value, field)
    if type(value) == 'number' and U.isInt(value) then value = tostring(value) end
    if type(value) ~= 'string' or #value < 1 or #value > 64 or not value:match('^[%w%-_:%.@]+$') then
        bad(field or 'campus_id')
    end
    return value
end

--- Timestamp UNIX raisonnable (2020 → 2100).
function V.timestamp(value, field, optional)
    if value == nil and optional then return nil end
    if not U.isInt(value) or value < 1577836800 or value > 4102444800 then bad(field or 'timestamp') end
    return value
end

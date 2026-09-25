--[[
    English Campus — adaptateur « compte Campus » (serveur).

    C'est LE point d'intégration avec votre ressource campus :
    English Campus ne crée aucun compte, il lit le compte Campus du joueur.

    Modes disponibles (Config.Campus.Mode) :
      export    exports[Resource][Export](source) → table du compte
      statebag  Player(source).state[StateBagKey] → table du compte
      sql       lecture directe de la table des comptes Campus
      push      votre Campus envoie le compte : exports.rs_english_campus:SetCampusAccount(source, compte)
      framework identité = personnage ESX / QBCore / Qbox (sans Campus)
      custom    Config.Campus.Custom(source)

    Toutes les sources sont normalisées au format :
      { id, characterId, firstName, lastName, class, role, studentNumber, title }
]]

local U = EC.U
local FW = Bridge.Framework

local Campus = {}
Bridge.Campus = Campus

-- Comptes poussés par la ressource Campus (mode 'push').
local pushed = {}

local function config()
    return Config.Campus
end

--- Applique la correspondance de champs Config.Campus.Fields.
local function mapFields(raw)
    local fields = config().Fields or {}
    local function get(key)
        local path = fields[key]
        if not path then return nil end
        local value = U.getPath(raw, path)
        if value == nil then value = raw[key] end -- repli sur le nom canonique
        return value
    end
    return {
        id            = get('id'),
        characterId   = get('characterId'),
        firstName     = get('firstName'),
        lastName      = get('lastName'),
        class         = get('class'),
        role          = get('role'),
        studentNumber = get('studentNumber'),
        title         = get('title'),
    }
end

local readers = {}

function readers.export(src)
    local c = config()
    if GetResourceState(c.Resource) ~= 'started' then return nil, ('resource %s not started'):format(c.Resource) end
    local ok, raw = pcall(function()
        local proxy = exports[c.Resource]
        return proxy[c.Export](proxy, src)
    end)
    if not ok then return nil, ('export %s:%s failed: %s'):format(c.Resource, c.Export, tostring(raw)) end
    if type(raw) ~= 'table' then return nil, 'no account returned by export' end
    return mapFields(raw)
end

function readers.statebag(src)
    local state = Player(src).state[config().StateBagKey]
    if type(state) ~= 'table' then return nil, 'no campus state bag' end
    return mapFields(state)
end

function readers.sql(src)
    local s = config().Sql
    -- Les noms de table/colonne ne peuvent pas être paramétrés : on les valide strictement.
    if not tostring(s.Table):match('^[%w_]+$') or not tostring(s.IdentifierColumn):match('^[%w_]+$') then
        return nil, 'invalid Config.Campus.Sql table/column name'
    end
    local identifier = FW.GetIdentifier(src, s.IdentifierType or 'character')
    if not identifier then return nil, 'no identifier for sql lookup' end
    local row = DB.single(('SELECT * FROM `%s` WHERE `%s` = ? LIMIT 1'):format(s.Table, s.IdentifierColumn), identifier)
    if not row then return nil, 'no campus row for ' .. identifier end
    return mapFields(row)
end

function readers.push(src)
    local account = pushed[src]
    if not account then return nil, 'no account pushed yet' end
    return account
end

function readers.framework(src)
    local character = FW.GetCharacter(src)
    if not character or not character.id then return nil, 'no framework character' end
    return {
        id          = character.id,
        characterId = character.id,
        firstName   = character.firstName,
        lastName    = character.lastName,
    }
end

function readers.custom(src)
    local fn = config().Custom
    if type(fn) ~= 'function' then return nil, 'Config.Campus.Custom is not a function' end
    local ok, raw = pcall(fn, src)
    if not ok then return nil, 'custom reader failed: ' .. tostring(raw) end
    if type(raw) ~= 'table' then return nil, 'custom reader returned no account' end
    return raw
end

local function read(mode, src)
    local reader = readers[mode]
    if not reader then return nil, 'unknown campus mode ' .. tostring(mode) end
    return reader(src)
end

local function str(value, max)
    if value == nil then return nil end
    value = U.cleanText(tostring(value), nil, false)
    if not value or value == '' then return nil end
    return U.utf8sub(value, max or 64)
end

--- Lit et normalise le compte Campus d'un joueur.
---@return table|nil account, string|nil error
function Campus.Fetch(src)
    local c = config()
    local account, err = read(c.Mode, src)
    local usedFallback = false
    if not account and c.Fallback and c.Fallback ~= c.Mode then
        local fallbackErr
        account, fallbackErr = read(c.Fallback, src)
        if account then
            usedFallback = true
            EC.Debug('Campus fallback (%s) used for %s: %s', c.Fallback, GetPlayerName(src) or src, tostring(err))
        else
            err = ('%s | fallback: %s'):format(tostring(err), tostring(fallbackErr))
        end
    end
    if not account then return nil, err end

    local out = {
        id            = str(account.id),
        characterId   = str(account.characterId),
        firstName     = str(account.firstName) or '',
        lastName      = str(account.lastName) or '',
        class         = account.class,
        role          = str(account.role, 32),
        studentNumber = str(account.studentNumber),
        title         = str(account.title, 24),
        fallback      = usedFallback,
    }
    if not out.id then return nil, 'campus account has no id' end
    if not out.id:match('^[%w%-_:%.@]+$') then
        -- Identifiant exotique : on le rend sûr pour l'utiliser comme clé.
        out.id = out.id:gsub('[^%w%-_:%.@]', '_')
    end

    if not out.characterId or out.firstName == '' then
        local character = FW.GetCharacter(src)
        if character then
            out.characterId = out.characterId or (character.id and tostring(character.id))
            if out.firstName == '' then
                out.firstName = str(character.firstName) or ''
                out.lastName = out.lastName ~= '' and out.lastName or (str(character.lastName) or '')
            end
        end
    end
    if out.firstName == '' and out.lastName == '' then out.firstName = GetPlayerName(src) or 'Élève' end
    return out
end

--- Convertit le rôle Campus en rôle English Campus (nil si inconnu).
function Campus.MapRole(value)
    if value == nil then return nil end
    local key = U.normKey(value)
    for campusRole, role in pairs(config().RoleMap or {}) do
        if U.normKey(campusRole) == key then return role end
    end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Mode « push » : votre ressource Campus appelle ces exports.
--    exports.rs_english_campus:SetCampusAccount(source, { id = ..., firstname = ..., class = ..., role = ... })
--    exports.rs_english_campus:ClearCampusAccount(source)
--  Les champs sont lus avec Config.Campus.Fields (comme le mode export).
-- ─────────────────────────────────────────────────────────────────────────────

exports('SetCampusAccount', function(src, account)
    src = tonumber(src)
    if not src or type(account) ~= 'table' then return false end
    pushed[src] = mapFields(account)
    if Campus.OnChanged then Campus.OnChanged(src) end
    return true
end)

exports('ClearCampusAccount', function(src)
    src = tonumber(src)
    if not src then return false end
    pushed[src] = nil
    if Campus.OnChanged then Campus.OnChanged(src) end
    return true
end)

AddEventHandler('playerDropped', function()
    pushed[source] = nil
end)

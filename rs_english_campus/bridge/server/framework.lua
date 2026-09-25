--[[
    English Campus — adaptateur framework (serveur).

    Le script n'exige AUCUN framework. Si ESX, QBCore ou Qbox est démarré, il est utilisé
    pour : l'identifiant du personnage, le nom RP, le job et les groupes admin.
    Sinon, tout repose sur les identifiants FiveM et les permissions ACE.
]]

Bridge = Bridge or {}

local FW = {}
Bridge.Framework = FW

local kind, QBCore, ESX
local detectedAt = 0

local function detect()
    local now = GetGameTimer()
    if kind and (kind ~= 'standalone' or now - detectedAt < 10000) then return kind end
    detectedAt = now
    if GetResourceState('qbx_core') == 'started' then
        kind = 'qbx'
    elseif GetResourceState('qb-core') == 'started' then
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        kind, QBCore = ok and 'qb' or 'standalone', ok and core or nil
    elseif GetResourceState('es_extended') == 'started' then
        local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
        kind, ESX = ok and 'esx' or 'standalone', ok and obj or nil
    else
        kind = 'standalone'
    end
    return kind
end

function FW.Name()
    return detect()
end

--- Identifiant FiveM d'un type donné (license, discord, steam, fivem...).
function FW.GetFiveMIdentifier(src, idType)
    local id = GetPlayerIdentifierByType(src, idType)
    if id and id ~= '' then return id end
    for _, identifier in ipairs(GetPlayerIdentifiers(src) or {}) do
        if identifier:sub(1, #idType + 1) == idType .. ':' then return identifier end
    end
    return nil
end

--- Personnage actif : { id, firstName, lastName, job = { name, grade } } ou nil.
function FW.GetCharacter(src)
    local k = detect()
    if k == 'qbx' or k == 'qb' then
        local ok, player = pcall(function()
            if k == 'qbx' then return exports.qbx_core:GetPlayer(src) end
            return QBCore.Functions.GetPlayer(src)
        end)
        if not ok or not player or not player.PlayerData then return nil end
        local pd = player.PlayerData
        local charinfo = pd.charinfo or {}
        local grade = pd.job and pd.job.grade
        return {
            id        = pd.citizenid,
            firstName = charinfo.firstname,
            lastName  = charinfo.lastname,
            job       = pd.job and { name = pd.job.name, grade = type(grade) == 'table' and grade.level or tonumber(grade) or 0 } or nil,
        }
    elseif k == 'esx' then
        local ok, xPlayer = pcall(function() return ESX.GetPlayerFromId(src) end)
        if not ok or not xPlayer then return nil end
        local first = xPlayer.get and xPlayer.get('firstName') or nil
        local last = xPlayer.get and xPlayer.get('lastName') or nil
        if not first and xPlayer.getName then
            local full = xPlayer.getName() or ''
            first, last = full:match('^(%S+)%s*(.*)$')
        end
        local job = (xPlayer.getJob and xPlayer.getJob()) or xPlayer.job
        return {
            id        = xPlayer.identifier,
            firstName = first,
            lastName  = last,
            job       = job and { name = job.name, grade = tonumber(job.grade) or 0 } or nil,
        }
    end
    local license = FW.GetFiveMIdentifier(src, 'license')
    if not license then return nil end
    return { id = license, firstName = GetPlayerName(src), lastName = '' }
end

--- Identifiant utilisé pour relier le joueur à une table externe (mode SQL du Campus).
---@param idType string 'character' | 'license' | 'discord' | 'steam' | 'fivem'
function FW.GetIdentifier(src, idType)
    if idType == 'character' then
        local character = FW.GetCharacter(src)
        return character and character.id or nil
    end
    return FW.GetFiveMIdentifier(src, idType)
end

--- Job actuel { name, grade } ou nil.
function FW.GetJob(src)
    local character = FW.GetCharacter(src)
    return character and character.job or nil
end

--- Le joueur appartient-il au groupe ? (ACE, groupe ESX, permission QBCore)
function FW.HasGroup(src, group)
    if IsPlayerAceAllowed(src, group) or IsPlayerAceAllowed(src, 'group.' .. group) then return true end
    local k = detect()
    if k == 'esx' then
        local ok, xPlayer = pcall(function() return ESX.GetPlayerFromId(src) end)
        if ok and xPlayer and xPlayer.getGroup and xPlayer.getGroup() == group then return true end
    elseif k == 'qb' then
        local ok, allowed = pcall(function() return QBCore.Functions.HasPermission(src, group) end)
        if ok and allowed then return true end
    end
    return false
end

AddEventHandler('onResourceStart', function(resource)
    if resource == 'qbx_core' or resource == 'qb-core' or resource == 'es_extended' then
        kind = nil
    end
end)

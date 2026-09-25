--[[
    English Campus — pont NUI (client).

    L'interface (téléphone, PC ou fenêtre autonome) appelle :
        fetch('https://rs_english_campus/ec:rpc', { a = action, p = JSON })
    Ce fichier relaie la requête au serveur SANS la modifier ni l'interpréter : le client n'est
    jamais une source de confiance, toutes les vérifications sont faites côté serveur.

    Les évènements temps réel du serveur sont renvoyés vers toutes les instances ouvertes de l'app :
      • SendNUIMessage → page pont (web/bridge.html) → BroadcastChannel → app (téléphone / PC / autonome)
      • canal officiel du téléphone (sendCustomAppMessage) en complément
]]

NUI = {}

local EVENTS = EC.Const.ResourceEvents
local RESOURCE = GetCurrentResourceName()

local pending = {}
local nextId = 0
local messageId = 0

local function reply(cb, body)
    cb(body)
end

-- ─── Requêtes NUI → serveur ─────────────────────────────────────────────────

RegisterNUICallback('ec:rpc', function(data, cb)
    if type(data) ~= 'table' or type(data.a) ~= 'string' or #data.a > 48 then
        return reply(cb, '{"ok":false,"error":"bad_request"}')
    end
    local payload = type(data.p) == 'string' and data.p or '{}'
    if #payload > Config.Security.MaxPayload then
        return reply(cb, '{"ok":false,"error":"payload_too_large"}')
    end

    nextId = nextId + 1
    local id = nextId
    pending[id] = cb
    if #payload > 16000 then
        -- Gros contenu (cours complet) : évènement « latent » qui ne sature pas le réseau.
        TriggerLatentServerEvent(EVENTS.Rpc, 100000, id, data.a, payload)
    else
        TriggerServerEvent(EVENTS.Rpc, id, data.a, payload)
    end

    SetTimeout((Config.Security.RequestTimeout or 15) * 1000, function()
        local waiting = pending[id]
        if waiting then
            pending[id] = nil
            waiting('{"ok":false,"error":"timeout"}')
        end
    end)
end)

RegisterNetEvent(EVENTS.RpcResponse, function(id, body)
    local cb = pending[id]
    if not cb then return end
    pending[id] = nil
    cb(body)
end)

-- ─── Évènements temps réel serveur → interface ──────────────────────────────

--- Diffuse un évènement à toutes les instances de l'app (dédoublonné côté interface par `mid`).
function NUI.Broadcast(kind, data)
    messageId = messageId + 1
    local message = {
        action = 'ec:push',
        mid = ('%d:%d'):format(GetGameTimer(), messageId),
        kind = kind,
        data = data or {},
    }
    SendNUIMessage(message)
    Bridge.Phone.SendMessage(message)
end

RegisterNetEvent(EVENTS.Push, function(kind, data)
    if type(kind) ~= 'string' then return end
    NUI.Broadcast(kind, data)
    if NUI.OnPush then NUI.OnPush(kind, data) end
end)

-- ─── Informations de démarrage de l'interface (aucune donnée sensible) ───────

RegisterNUICallback('ec:boot', function(_, cb)
    cb({
        resource   = RESOURCE,
        appName    = Config.AppName,
        schoolName = Config.SchoolName,
        locale     = Config.Locale,
        theme      = Config.Theme,
        phone      = { adapter = Config.Phone.Adapter, identifier = Config.Phone.Identifier },
        debug      = Config.Debug == true,
    })
end)

--- Présence : l'app signale qu'elle est ouverte / fermée (évite les bannières en double).
RegisterNUICallback('ec:presence', function(data, cb)
    if type(data) == 'table' and type(data.host) == 'string' and NUI.OnPresence then
        NUI.OnPresence(data.host, data.open == true)
    end
    cb(true)
end)

--- Deep-link en attente (notification touchée → ouverture de l'app sur le bon écran).
RegisterNUICallback('ec:link', function(_, cb)
    cb(NUI.ConsumeLink and NUI.ConsumeLink() or false)
end)

RegisterNUICallback('ec:close', function(_, cb)
    if NUI.OnClose then NUI.OnClose() end
    cb(true)
end)

--[[
    English Campus — adaptateur téléphone (client).

    Pour brancher un autre téléphone : ajoutez une entrée dans `adapters` avec les fonctions
      register()      enregistre l'application (icône, nom, page)
      message(msg)    envoie un évènement temps réel à la page de l'app (facultatif)
      notify(n)       affiche une bannière { title, body }
      open()          ouvre l'app (deep-link, facultatif)
    puis mettez Config.Phone.Adapter = 'nom'.

    La page de l'app est web/index.html?host=phone : elle s'exécute dans l'iframe du téléphone et
    parle directement au client de cette ressource (fetch https://<ressource>/ec:rpc).
]]

Bridge = Bridge or {}

local Phone = {}
Bridge.Phone = Phone

local cfg = Config.Phone
local RESOURCE = GetCurrentResourceName()
local UI = ('%s/web/index.html?host=phone'):format(RESOURCE)
local ICON = ('https://cfx-nui-%s/web/assets/icon.png'):format(RESOURCE)

Phone.appOpen = false
Phone.registered = false

local function onOpen()
    Phone.appOpen = true
    if Phone.OnOpen then Phone.OnOpen() end
end

local function onClose()
    Phone.appOpen = false
    if Phone.OnClose then Phone.OnClose() end
end

--- Bannière native GTA (repli quand aucun téléphone n'est utilisé).
local function feedNotification(n)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(('~b~%s~s~\n%s'):format(n.title or Config.AppName, n.body or ''))
    EndTextCommandThefeedPostTicker(false, true)
end

local adapters = {}

-- ─── sd-phone (Samuels-Development) : exports addCustomApp / sendCustomAppMessage / showNotification ───
adapters['sd-phone'] = {
    register = function()
        return exports[cfg.Resource]:addCustomApp({
            identifier  = cfg.Identifier,
            name        = Config.AppName,
            description = Config.AppDescription,
            developer   = Config.Developer,
            defaultApp  = cfg.DefaultApp,
            size        = cfg.Size,
            ui          = UI,
            icon        = ICON,
            fixBlur     = true,
            onOpen      = onOpen,
            onClose     = onClose,
        })
    end,
    message = function(msg)
        return exports[cfg.Resource]:sendCustomAppMessage(cfg.Identifier, msg)
    end,
    notify = function(n)
        exports[cfg.Resource]:showNotification({
            app   = Config.AppName,
            appId = cfg.Identifier,
            image = ICON,
            title = n.title,
            body  = n.body,
            time  = 'now',
        })
    end,
    open = function()
        return exports[cfg.Resource]:openApp(cfg.Identifier)
    end,
}

-- ─── lb-phone (et tout téléphone compatible lb-phone) ───
adapters['lb-phone'] = {
    register = function()
        return exports[cfg.Resource]:AddCustomApp({
            identifier  = cfg.Identifier,
            name        = Config.AppName,
            description = Config.AppDescription,
            developer   = Config.Developer,
            defaultApp  = cfg.DefaultApp,
            size        = cfg.Size,
            images      = {},
            ui          = UI,
            icon        = ICON,
            fixBlur     = true,
            onUse       = onOpen,
            onClose     = onClose,
        })
    end,
    message = function(msg)
        return exports[cfg.Resource]:SendCustomAppMessage(cfg.Identifier, msg)
    end,
    notify = function(n)
        exports[cfg.Resource]:SendNotification({ app = cfg.Identifier, title = n.title, content = n.body })
    end,
}

-- ─── Sans téléphone : l'app s'ouvre dans son propre cadre (commande /english) ───
adapters['standalone'] = {
    register = function() return true end,
    notify = feedNotification,
    open = function()
        if Phone.OpenStandalone then Phone.OpenStandalone() end
        return true
    end,
}

local function adapter()
    return adapters[cfg.Adapter]
end

--- Le téléphone configuré est-il utilisable ?
function Phone.Available()
    if cfg.Adapter == 'standalone' then return true end
    return adapter() ~= nil and GetResourceState(cfg.Resource) == 'started'
end

function Phone.IsStandalone()
    return cfg.Adapter == 'standalone' or not adapter()
end

local function register()
    local a = adapter()
    if not a then
        print(('^3[English Campus] Adaptateur téléphone inconnu : %s (mode autonome utilisé)^7'):format(tostring(cfg.Adapter)))
        return
    end
    local ok, result, err = pcall(a.register)
    if ok and result ~= false then
        Phone.registered = true
        if Config.Debug then print(('[English Campus] Application enregistrée dans %s'):format(cfg.Resource)) end
    else
        Phone.registered = false
        print(('^1[English Campus] Enregistrement dans %s impossible : %s^7'):format(cfg.Resource, tostring(err or result)))
    end
end

--- Envoie un évènement temps réel à la page ouverte dans le téléphone.
function Phone.SendMessage(msg)
    local a = adapter()
    if not a or not a.message or not Phone.registered then return false end
    local ok = pcall(a.message, msg)
    return ok
end

--- Bannière de notification du téléphone (ou notification GTA en repli).
function Phone.Notify(n)
    local a = adapter()
    if a and a.notify and (cfg.Adapter == 'standalone' or Phone.Available()) then
        local ok = pcall(a.notify, n)
        if ok then return end
    end
    feedNotification(n)
end

--- Ouvre l'application (deep-link depuis une notification, un autre script...).
function Phone.Open()
    local a = adapter()
    if a and a.open then
        local ok, result = pcall(a.open)
        return ok and result ~= false
    end
    return false
end

-- Enregistrement au démarrage + ré-enregistrement si le téléphone redémarre
-- (les apps personnalisées ne sont gardées qu'en mémoire par le téléphone).
CreateThread(function()
    if cfg.Adapter == 'standalone' or not adapter() then return end
    local waited = 0
    while GetResourceState(cfg.Resource) ~= 'started' do
        Wait(500)
        waited = waited + 500
        if waited == 30000 then
            print(('^3[English Campus] %s n\'est pas démarré : vérifiez l\'ordre des ensure (le téléphone AVANT English Campus).^7'):format(cfg.Resource))
        end
    end
    Wait(1000)
    register()
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= cfg.Resource or cfg.Adapter == 'standalone' then return end
    Wait(1000)
    register()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == cfg.Resource then
        Phone.registered = false
        Phone.appOpen = false
    end
end)

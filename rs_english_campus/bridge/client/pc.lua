--[[
    English Campus — adaptateur ordinateur (client).

    Deux façons d'avoir English Campus sur l'ordinateur :

    1. Intégré à rs_pc (Config.PC.Adapter = 'rs_pc')
       Au démarrage, English Campus appelle exports[Config.PC.Resource][Config.PC.RegisterExport](app)
       avec app = { id, name, description, icon, url, width, height, resource }.
       rs_pc n'a qu'à afficher `url` dans une fenêtre (iframe). Voir README > Intégration rs_pc
       pour le code exact à ajouter dans rs_pc si l'export n'existe pas encore.
       rs_pc peut aussi simplement appeler exports.rs_english_campus:OpenPC() quand on clique l'icône.

    2. Fenêtre autonome (Config.PC.Adapter = 'standalone', ou repli automatique)
       /englishpc ou [E] près des postes informatiques définis dans Config.PC.Locations.
]]

Bridge = Bridge or {}

local PC = {}
Bridge.PC = PC

local cfg = Config.PC
local RESOURCE = GetCurrentResourceName()

PC.url = ('https://cfx-nui-%s/web/index.html?host=pc'):format(RESOURCE)
PC.icon = ('https://cfx-nui-%s/web/assets/icon.png'):format(RESOURCE)
PC.registered = false
PC.standalone = cfg.Adapter == 'standalone'

local function register()
    if cfg.Adapter ~= 'rs_pc' then return end
    local ok, err = pcall(function()
        local proxy = exports[cfg.Resource]
        local result = proxy[cfg.RegisterExport](proxy, {
            id          = cfg.AppId,
            name        = Config.AppName,
            description = Config.AppDescription,
            icon        = PC.icon,
            url         = PC.url,
            width       = 1180,
            height      = 760,
            resource    = RESOURCE,
        })
        if result == false then error('registration refused') end
    end)
    PC.registered = ok
    if ok then
        PC.standalone = false
        if Config.Debug then print(('[English Campus] Application enregistrée dans %s'):format(cfg.Resource)) end
    else
        PC.standalone = cfg.FallbackToStandalone == true
        print(('^3[English Campus] Intégration %s indisponible (%s). %s^7'):format(cfg.Resource, tostring(err),
            PC.standalone and 'Fenêtre PC autonome activée.' or 'Version PC désactivée.'))
    end
end

CreateThread(function()
    if cfg.Adapter ~= 'rs_pc' then return end
    local waited = 0
    while GetResourceState(cfg.Resource) ~= 'started' and waited < 30000 do
        Wait(500)
        waited = waited + 500
    end
    Wait(1000)
    register()
end)

AddEventHandler('onResourceStart', function(resource)
    if resource == cfg.Resource and cfg.Adapter == 'rs_pc' then
        Wait(1000)
        register()
    end
end)

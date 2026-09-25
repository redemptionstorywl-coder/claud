--[[
    English Campus — client : ouverture de l'app (téléphone / PC / autonome), notifications, deep-links.
    Aucune boucle permanente : seul le repérage des postes informatiques (si configuré) tourne,
    avec une attente adaptative (1,5 s loin des postes).
]]

local Phone, PC = Bridge.Phone, Bridge.PC

local state = {
    standalone = nil,   -- 'phone' | 'pc' | nil : fenêtre autonome ouverte
    hosts = {},         -- host → true quand une instance de l'app signale être ouverte
    pendingLink = nil,  -- { type, id, at }
}

local function appVisible()
    if state.standalone or Phone.appOpen then return true end
    for _, open in pairs(state.hosts) do
        if open then return true end
    end
    return false
end

-- ─── Fenêtre autonome (sans téléphone, ou PC autonome) ───────────────────────

local function openStandalone(layout)
    if state.standalone == layout then return end
    state.standalone = layout
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'ec:standalone:open', layout = layout })
end

local function closeStandalone()
    if not state.standalone then return end
    state.standalone = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'ec:standalone:close' })
end

Phone.OpenStandalone = function() openStandalone('phone') end

NUI.OnClose = closeStandalone

NUI.OnPresence = function(host, open)
    state.hosts[host] = open
end

-- ─── Notifications & deep-links ──────────────────────────────────────────────

NUI.OnPush = function(kind, data)
    if kind == 'notification' and type(data) == 'table' then
        if data.linkType and data.linkId and Config.Phone.DeepLinks then
            state.pendingLink = { type = data.linkType, id = data.linkId, at = GetGameTimer() }
        end
        -- App déjà à l'écran : l'interface affiche sa propre bannière. Sinon : bannière du téléphone.
        if not appVisible() and Config.Phone.Notifications then
            Phone.Notify({ title = data.title, body = data.body })
        end
    elseif kind == 'profile:changed' then
        state.pendingLink = nil
    end
end

NUI.ConsumeLink = function()
    local link = state.pendingLink
    state.pendingLink = nil
    if link and GetGameTimer() - link.at < 180000 then
        return { type = link.type, id = link.id }
    end
    return false
end

-- ─── Commandes & touches ─────────────────────────────────────────────────────

local function openPhoneApp()
    if not Phone.IsStandalone() and Phone.Available() and Phone.Open() then return end
    openStandalone('phone')
end

if Config.Standalone.Command then
    RegisterCommand(Config.Standalone.Command, function()
        if Phone.IsStandalone() or Config.Standalone.AllowWithPhone then
            if state.standalone then closeStandalone() else openStandalone('phone') end
        else
            openPhoneApp()
        end
    end, false)
    if Config.Standalone.Keybind then
        RegisterKeyMapping(Config.Standalone.Command, Config.AppName, 'keyboard', Config.Standalone.Keybind)
    end
end

if Config.PC.Command and Config.PC.Adapter ~= 'none' then
    RegisterCommand(Config.PC.Command, function()
        if state.standalone == 'pc' then closeStandalone() else openStandalone('pc') end
    end, false)
end

-- ─── Postes informatiques (fenêtre PC autonome) ──────────────────────────────

local function helpText(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, false, -1)
end

CreateThread(function()
    local locations = Config.PC.Locations or {}
    if #locations == 0 or Config.PC.Adapter == 'none' then return end
    Wait(2000)
    while true do
        local sleep = 1500
        if PC.standalone and not state.standalone then
            local coords = GetEntityCoords(PlayerPedId())
            for _, spot in ipairs(locations) do
                local distance = #(coords - spot.coords)
                if distance < 8.0 then sleep = 250 end
                if distance <= (Config.PC.InteractDistance or 1.6) then
                    sleep = 0
                    helpText(('~INPUT_CONTEXT~ %s'):format(Config.AppName))
                    if IsControlJustReleased(0, Config.PC.InteractKey or 38) then openStandalone('pc') end
                    break
                end
            end
        end
        Wait(sleep)
    end
end)

-- ─── Exports client ──────────────────────────────────────────────────────────

--- Ouvre English Campus dans le téléphone (ou en autonome si aucun téléphone).
exports('OpenApp', openPhoneApp)

--- Ouvre la version ordinateur (pour rs_pc ou un autre script d'ordinateur).
exports('OpenPC', function() openStandalone('pc') end)

exports('Close', closeStandalone)

exports('IsOpen', appVisible)

--- URL de la version PC à afficher dans une fenêtre (iframe) de rs_pc.
exports('GetPCUrl', function() return PC.url end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and state.standalone then
        SetNuiFocus(false, false)
    end
end)

--[[
    English Campus — suivi en direct (mode classe).

    Pendant une scène de cours, le professeur ouvre « Suivi en direct » sur un cours ou une
    évaluation : il voit chaque élève avancer en temps réel (parties terminées, score, copie rendue).
    Aucune boucle ni sondage : les mises à jour sont poussées uniquement quand un élève agit.
]]

Live = {}

local subscribers = {} -- clé ('course:12' | 'assessment:4') → { [src] = true }
local keyOf = {}       -- src → clé suivie

function Live.Subscribe(src, key)
    Live.Unsubscribe(src)
    subscribers[key] = subscribers[key] or {}
    subscribers[key][src] = true
    keyOf[src] = key
end

function Live.Unsubscribe(src)
    local key = keyOf[src]
    if key and subscribers[key] then
        subscribers[key][src] = nil
        if next(subscribers[key]) == nil then subscribers[key] = nil end
    end
    keyOf[src] = nil
end

function Live.HasSubscribers(key)
    return subscribers[key] ~= nil
end

--- Envoie la mise à jour d'un élève aux professeurs qui suivent `key`.
---@param entry table { studentId, name, ... }
function Live.Emit(key, entry)
    local subs = subscribers[key]
    if not subs then return end
    entry.at = EC.Now()
    for src in pairs(subs) do
        Rpc.Push(src, 'live', { key = key, entry = entry })
    end
end

AddEventHandler('playerDropped', function()
    Live.Unsubscribe(source)
end)

Rpc.Register('live:unsubscribe', { role = 'teacher' }, function(ctx)
    Live.Unsubscribe(ctx.src)
    return true
end)

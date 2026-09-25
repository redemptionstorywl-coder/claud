--[[
    English Campus — point d'entrée unique des requêtes de l'interface.

    NUI → client (fetch) → serveur (évènement réseau unique) → handler → réponse.

    Protections appliquées à CHAQUE requête, avant tout traitement :
      • format strict (identifiant de requête numérique, action connue, charge utile JSON bornée)
      • limitation de débit par joueur (seau à jetons) + requêtes simultanées plafonnées
      • résolution serveur du profil (identité Campus, rôle, classe) — jamais lue depuis la NUI
      • contrôle du rôle minimum et de la capacité requise par l'action
      • erreurs internes masquées (seul un code générique est renvoyé au client)
    Les abus répétés sont journalisés (et le joueur peut être expulsé : Config.Security.KickOnAbuse).
]]

Rpc = {}

local EVENTS = EC.Const.ResourceEvents
local RANK = EC.Const.RoleRank
local security = Config.Security

local handlers = {}
local buckets = {}

---@param name string nom de l'action (ex. 'course:get')
---@param opts table { role = 'student'|'teacher'|'admin'|nil, cap = string|nil, cost = number|nil }
---@param fn fun(ctx: table, data: table): any
function Rpc.Register(name, opts, fn)
    assert(type(name) == 'string' and #name <= 48, 'invalid rpc name')
    assert(not handlers[name], 'rpc already registered: ' .. name)
    handlers[name] = { opts = opts or {}, fn = fn }
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Limitation de débit
-- ─────────────────────────────────────────────────────────────────────────────

local function bucketOf(src)
    local bucket = buckets[src]
    if not bucket then
        bucket = {
            tokens = security.RateLimit.Capacity,
            updated = GetGameTimer(),
            inflight = 0,
            strikes = 0,
            strikeWindow = GetGameTimer(),
        }
        buckets[src] = bucket
    end
    return bucket
end

local function strike(src, reason)
    local bucket = bucketOf(src)
    local t = GetGameTimer()
    if t - bucket.strikeWindow > security.StrikeWindow * 1000 then
        bucket.strikeWindow, bucket.strikes = t, 0
    end
    bucket.strikes = bucket.strikes + 1
    if bucket.strikes == security.StrikeLimit then
        local name = GetPlayerName(src) or '?'
        EC.Warn('Abusive calls from %s (%d): %s', name, src, reason)
        local profile = Sessions.Peek(src)
        DB.fire('INSERT INTO campus_english_logs (campus_id, action, target, details, created_at) VALUES (?, ?, ?, ?, ?)',
            profile and profile.campusId, 'security.abuse', tostring(src),
            EC.JsonEncode({ reason = reason, name = name }), EC.Now())
        if security.KickOnAbuse then DropPlayer(src, security.KickMessage) end
    end
end

local function take(src, cost)
    local bucket = bucketOf(src)
    local t = GetGameTimer()
    local elapsed = (t - bucket.updated) / 1000
    bucket.updated = t
    bucket.tokens = math.min(security.RateLimit.Capacity, bucket.tokens + elapsed * security.RateLimit.RefillPerSecond)
    if bucket.tokens < cost then return false end
    bucket.tokens = bucket.tokens - cost
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Réponse
-- ─────────────────────────────────────────────────────────────────────────────

local function respond(src, reqId, ok, value, detail)
    local body
    if ok then
        body = EC.JsonEncode({ ok = true, data = value })
    else
        body = EC.JsonEncode({ ok = false, error = value, detail = detail })
    end
    if #body > 32000 then
        -- Gros volume (cours complet, carnet de notes...) : envoi « latent » sans bloquer le réseau.
        TriggerLatentClientEvent(EVENTS.RpcResponse, src, 250000, reqId, body)
    else
        TriggerClientEvent(EVENTS.RpcResponse, src, reqId, body)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Réception
-- ─────────────────────────────────────────────────────────────────────────────

RegisterNetEvent(EVENTS.Rpc, function(reqId, action, payload)
    local src = source
    if type(reqId) ~= 'number' or reqId % 1 ~= 0 or type(action) ~= 'string' or #action > 48 then
        return strike(src, 'malformed request')
    end

    local handler = handlers[action]
    if not handler then
        strike(src, 'unknown action ' .. action:sub(1, 48))
        return respond(src, reqId, false, 'unknown_action')
    end

    if payload ~= nil and type(payload) ~= 'string' then
        strike(src, 'invalid payload type')
        return respond(src, reqId, false, 'bad_request')
    end
    if payload and #payload > security.MaxPayload then
        strike(src, 'payload too large')
        return respond(src, reqId, false, 'payload_too_large')
    end

    if not take(src, handler.opts.cost or 1) then
        strike(src, 'rate limit')
        return respond(src, reqId, false, 'rate_limited')
    end

    local bucket = bucketOf(src)
    if bucket.inflight >= security.MaxInFlight then
        strike(src, 'too many concurrent requests')
        return respond(src, reqId, false, 'busy')
    end
    bucket.inflight = bucket.inflight + 1

    CreateThread(function()
        local ok, result = xpcall(function()
            if not EC.Ready then EC.Fail('not_ready') end
            local data = {}
            if payload and payload ~= '' then
                data = EC.JsonDecode(payload, nil)
                if type(data) ~= 'table' then EC.Fail('bad_request', 'payload') end
            end

            local profile = Sessions.Resolve(src)
            Sessions.Touch(src)

            local opts = handler.opts
            if opts.role and (RANK[profile.role] or 0) < RANK[opts.role] then EC.Fail('forbidden') end
            if opts.cap and not Permissions.Can(profile, opts.cap) then EC.Fail('forbidden') end

            local ctx = { src = src, profile = profile, action = action }
            return handler.fn(ctx, data)
        end, function(err)
            -- Les erreurs métier sont renvoyées telles quelles ; les autres avec leur pile d'appels.
            if EC.IsFail(err) then return err end
            return debug and debug.traceback and debug.traceback(tostring(err), 2) or tostring(err)
        end)

        bucket.inflight = math.max(0, bucket.inflight - 1)

        if ok then
            respond(src, reqId, true, result)
        elseif EC.IsFail(result) then
            if result.code == 'forbidden' or result.code == 'forbidden_class' then
                strike(src, 'forbidden ' .. action)
                local profile = Sessions.Peek(src)
                EC.Debug('Forbidden %s for %s', action, profile and profile.campusId or src)
            end
            respond(src, reqId, false, result.code, result.detail)
        else
            EC.Error('RPC "%s" failed for %s: %s', action, GetPlayerName(src) or src, tostring(result))
            respond(src, reqId, false, 'internal_error')
        end
    end)
end)

AddEventHandler('playerDropped', function()
    buckets[source] = nil
end)

--- Évènement temps réel vers un joueur.
function Rpc.Push(src, kind, data)
    TriggerClientEvent(EVENTS.Push, src, kind, data or {})
end

--- Évènement temps réel vers un identifiant Campus s'il est connecté.
function Rpc.PushCampus(campusId, kind, data)
    local src = Sessions.SrcOf(campusId)
    if src then Rpc.Push(src, kind, data) end
end

--- Journal d'activité (asynchrone).
function Rpc.Audit(ctx, action, target, details)
    DB.fire('INSERT INTO campus_english_logs (campus_id, action, target, details, created_at) VALUES (?, ?, ?, ?, ?)',
        ctx and ctx.profile and ctx.profile.campusId, action, target and tostring(target) or nil,
        details and EC.JsonEncode(details) or nil, EC.Now())
end

--[[
    Bouchons FiveM pour exécuter le code serveur d'English Campus hors du jeu (banc de test).
    Le pont Python (runtime.py) fournit : HOST.db_* (MariaDB), HOST.now_ms(), HOST.outbox(...)
]]

local HOST = ...

json = require('json')

-- ─── Horloge simulée ─────────────────────────────────────────────────────────
local realTime = os.time
os.time = function(t)
    if t then return realTime(t) end
    return HOST.epoch()
end

function GetGameTimer()
    return HOST.now_ms()
end

-- ─── Threads (coroutines) ────────────────────────────────────────────────────
local threads = {}

local function spawn(fn, ...)
    local args = table.pack(...)
    local co = coroutine.create(function() return fn(table.unpack(args, 1, args.n)) end)
    threads[#threads + 1] = { co = co, wake = 0 }
end

function CreateThread(fn) spawn(fn) end
Citizen = { CreateThread = CreateThread, Wait = function(ms) return Wait(ms) end }

function Wait(ms)
    local co, main = coroutine.running()
    if main then error('Wait() called outside of a thread') end
    coroutine.yield(HOST.now_ms() + (ms or 0))
end

function SetTimeout(ms, fn)
    spawn(function() Wait(ms); fn() end)
end

--- Exécute les threads prêts. Retourne le nombre de threads encore en vie.
function __tick()
    local now = HOST.now_ms()
    local i = 1
    while i <= #threads do
        local t = threads[i]
        if t.wake <= now then
            local ok, wake = coroutine.resume(t.co)
            if not ok then
                HOST.error(debug.traceback(t.co, tostring(wake)))
                table.remove(threads, i)
            elseif coroutine.status(t.co) == 'dead' then
                table.remove(threads, i)
            else
                t.wake = wake or now
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return #threads
end

function __nextWake()
    local best
    for _, t in ipairs(threads) do
        if not best or t.wake < best then best = t.wake end
    end
    return best
end

-- ─── Évènements ──────────────────────────────────────────────────────────────
local handlers = {}

function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
    return { name = name, fn = fn }
end

function RegisterNetEvent(name, fn)
    if fn then return AddEventHandler(name, fn) end
end
RegisterServerEvent = RegisterNetEvent

--- Déclenche un évènement comme le ferait FiveM (dans un thread, `source` positionné).
function __trigger(name, src, ...)
    local list = handlers[name]
    if not list then return false end
    local args = table.pack(...)
    for _, fn in ipairs(list) do
        spawn(function()
            source = src
            fn(table.unpack(args, 1, args.n))
        end)
    end
    return true
end

function TriggerEvent(name, ...)
    return __trigger(name, '', ...)
end

local function encodeArgs(...)
    local args, out = table.pack(...), {}
    for i = 1, args.n do out[i] = json.encode(args[i]) end
    return out
end

function TriggerClientEvent(name, target, ...)
    HOST.outbox(name, target, encodeArgs(...))
end

function TriggerLatentClientEvent(name, target, bps, ...)
    HOST.outbox(name, target, encodeArgs(...))
end

-- ─── Joueurs ─────────────────────────────────────────────────────────────────
function GetPlayers()
    local out = {}
    for _, id in ipairs(HOST.players()) do out[#out + 1] = tostring(id) end
    return out
end

function GetPlayerName(src) return HOST.player_name(tonumber(src) or -1) end
function GetPlayerIdentifiers(src) return { HOST.player_license(tonumber(src) or -1) } end
function GetPlayerIdentifierByType(src, idType)
    if idType == 'license' then return HOST.player_license(tonumber(src) or -1) end
    return nil
end
function IsPlayerAceAllowed(src, ace) return HOST.has_ace(tonumber(src) or -1, ace) end
function DropPlayer(src, reason) HOST.drop(tonumber(src), reason) end

local states = {}
function Player(src)
    states[src] = states[src] or { state = {} }
    return states[src]
end

-- ─── Ressources / exports ────────────────────────────────────────────────────
function GetCurrentResourceName() return 'rs_english_campus' end
function GetInvokingResource() return nil end
function GetResourceState(name) return HOST.resource_state(name) end
function LoadResourceFile(_, path) return HOST.load_file(path) end
function GetResourceMetadata() return nil end

local ownExports = {}
local externalExports = {}

exports = setmetatable({}, {
    __call = function(_, name, fn) ownExports[name] = fn end,
    __index = function(_, resource)
        if resource == 'rs_english_campus' then
            return setmetatable({}, { __index = function(_, fn)
                return function(_, ...) return ownExports[fn](...) end
            end })
        end
        local res = externalExports[resource]
        if not res then error(('No such export resource %s'):format(resource)) end
        return setmetatable({}, { __index = function(_, fn)
            local f = res[fn]
            if not f then error(('No such export %s in resource %s'):format(fn, resource)) end
            -- Appel « exports.res:Fn(...) » : le premier argument (self) est ignoré, comme dans FiveM.
            return function(_, ...) return f(...) end
        end })
    end,
})

function __defineExternalExport(resource, name, fn)
    externalExports[resource] = externalExports[resource] or {}
    externalExports[resource][name] = fn
end

function __callOwnExport(name, ...)
    return ownExports[name](...)
end

function vector3(x, y, z) return { x = x, y = y, z = z } end

-- ─── oxmysql ─────────────────────────────────────────────────────────────────
local readyCallbacks = {}

local function awaitable(kind)
    return {
        await = function(query, params)
            local result = HOST.db(kind, query, params or {})
            return result
        end,
    }
end

MySQL = {
    query = awaitable('query'),
    single = awaitable('single'),
    scalar = awaitable('scalar'),
    insert = setmetatable(awaitable('insert'), { __call = function(_, query, params) HOST.db('insert', query, params or {}) end }),
    update = awaitable('update'),
    prepare = awaitable('query'),
    transaction = { await = function(queries) return HOST.db_transaction(queries) end },
    ready = function(cb) readyCallbacks[#readyCallbacks + 1] = cb end,
}

function __mysqlReady()
    for _, cb in ipairs(readyCallbacks) do cb() end
end

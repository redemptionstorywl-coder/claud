--[[
    English Campus — sessions & profils.

    À la première requête d'un joueur (ou quand son compte change), on :
      1. récupère son compte Campus (Bridge.Campus)          → identité
      2. récupère son personnage (Bridge.Framework)          → characterId
      3. détermine son rôle (ACE / groupes / Campus / admin) → student | teacher | admin
      4. détermine sa classe (compte Campus ou forçage admin)
      5. met à jour le cache d'affichage campus_english_members
    Le profil résolu est gardé en mémoire (Config.Campus.CacheSeconds).
    L'interface ne transmet JAMAIS l'identité, le rôle ou la classe : tout vient d'ici.
]]

local U = EC.U

Sessions = {}

local bySrc = {}     -- src → { profile, expires, lastActivity }
local byCampus = {}  -- campusId → src

local function now() return EC.Now() end

--- Rôle issu des permissions serveur (ACE, groupes, jobs) — prioritaire sur le Campus.
local function serverRole(src)
    if Permissions.IsAdminSource(src) then return 'admin' end
    if Permissions.IsTeacherSource(src) then return 'teacher' end
    return nil
end

local function buildProfile(src, account)
    local member = DB.single([[
        SELECT campus_id, first_name, last_name, student_number, role, class_id, role_override,
               class_override, title, title_override, prefs, created_at
        FROM campus_english_members WHERE campus_id = ?
    ]], account.id)

    -- Rôle : admin serveur > rôle forcé dans l'app > professeur serveur > Campus > élève
    local role
    local fromServer = serverRole(src)
    if fromServer == 'admin' then
        role = 'admin'
    elseif member and member.role_override and EC.Const.RoleRank[member.role_override] then
        role = member.role_override
    elseif fromServer == 'teacher' then
        role = 'teacher'
    else
        role = Bridge.Campus.MapRole(account.role) or 'student'
    end

    -- Classe : forçage admin > compte Campus
    local classId
    if member and member.class_override then
        classId = member.class_override
    elseif account.class ~= nil and account.class ~= '' then
        classId = Classes.Resolve(account.class)
    end
    local class = classId and Classes.Get(classId) or nil

    local title = (member and member.title_override) or account.title
    local profile = {
        src           = src,
        campusId      = account.id,
        characterId   = account.characterId,
        firstName     = account.firstName,
        lastName      = account.lastName,
        displayName   = EC.FullName(account.firstName, account.lastName),
        title         = title,
        role          = role,
        classId       = class and class.id or nil,
        className     = class and class.label or nil,
        studentNumber = account.studentNumber,
        prefs         = member and EC.JsonDecode(member.prefs, {}) or {},
        fallback      = account.fallback,
    }
    profile.teacherName = EC.TeacherName(title, account.firstName, account.lastName)

    -- Classes enseignées (professeur / admin)
    if role == 'teacher' or role == 'admin' then
        profile.teachingClassIds = Classes.TeacherClassIds(profile.campusId)
        profile.allClasses = role == 'admin'
            or (#profile.teachingClassIds == 0 and Config.Classes.TeacherSeesAllClassesIfNone == true)
    else
        profile.teachingClassIds = {}
        profile.allClasses = false
    end

    -- Mise à jour du cache d'affichage (uniquement si quelque chose a changé).
    local t = now()
    if not member then
        DB.update([[
            INSERT INTO campus_english_members
                (campus_id, character_id, first_name, last_name, student_number, role, class_id, title, last_seen_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE character_id = VALUES(character_id), first_name = VALUES(first_name),
                last_name = VALUES(last_name), student_number = VALUES(student_number), role = VALUES(role),
                class_id = VALUES(class_id), title = VALUES(title), last_seen_at = VALUES(last_seen_at)
        ]], profile.campusId, profile.characterId, U.utf8sub(profile.firstName, 64), U.utf8sub(profile.lastName, 64),
            profile.studentNumber, role, profile.classId, title, t, t)
    elseif member.first_name ~= profile.firstName or member.last_name ~= profile.lastName
        or member.role ~= role or member.class_id ~= profile.classId
        or member.student_number ~= profile.studentNumber or member.title ~= title then
        DB.update([[
            UPDATE campus_english_members
            SET character_id = ?, first_name = ?, last_name = ?, student_number = ?, role = ?, class_id = ?, title = ?, last_seen_at = ?
            WHERE campus_id = ?
        ]], profile.characterId, U.utf8sub(profile.firstName, 64), U.utf8sub(profile.lastName, 64),
            profile.studentNumber, role, profile.classId, title, t, profile.campusId)
    else
        DB.update('UPDATE campus_english_members SET last_seen_at = ? WHERE campus_id = ?', t, profile.campusId)
    end

    return profile
end

--- Profil du joueur (résolu et mis en cache). Lève 'no_campus_account' si aucun compte.
---@param force boolean|nil ignorer le cache
function Sessions.Resolve(src, force)
    src = tonumber(src)
    if not src or src <= 0 or not GetPlayerName(src) then EC.Fail('no_player') end
    local session = bySrc[src]
    if session and not force and session.expires > now() then
        return session.profile
    end

    return EC.WithLock('session:' .. src, function()
        local current = bySrc[src]
        if current and not force and current.expires > now() then return current.profile end

        local account, err = Bridge.Campus.Fetch(src)
        if not account then
            EC.Debug('No Campus account for %s (%d): %s', GetPlayerName(src) or '?', src, tostring(err))
            EC.Fail('no_campus_account')
        end
        local profile = buildProfile(src, account)

        if current and current.profile.campusId ~= profile.campusId then
            if byCampus[current.profile.campusId] == src then byCampus[current.profile.campusId] = nil end
        end
        bySrc[src] = {
            profile      = profile,
            expires      = now() + (Config.Campus.CacheSeconds or 300),
            lastActivity = current and current.lastActivity or now(),
        }
        byCampus[profile.campusId] = src
        return profile
    end)
end

--- Profil en cache uniquement (aucune requête), ou nil.
function Sessions.Peek(src)
    local session = bySrc[src]
    return session and session.profile or nil
end

--- Source du joueur connecté pour un identifiant Campus (ou nil).
function Sessions.SrcOf(campusId)
    local src = byCampus[campusId]
    if src and bySrc[src] and GetPlayerName(src) then return src end
    return nil
end

function Sessions.IsOnline(campusId)
    return Sessions.SrcOf(campusId) ~= nil
end

--- Dernière activité (secondes) — utilisé par le suivi en direct.
function Sessions.LastActivity(campusId)
    local src = Sessions.SrcOf(campusId)
    return src and bySrc[src].lastActivity or nil
end

function Sessions.Touch(src)
    local session = bySrc[src]
    if session then session.lastActivity = now() end
end

--- Oublie le profil en cache (il sera relu à la prochaine requête).
function Sessions.Invalidate(src)
    local session = bySrc[src]
    if session then session.expires = 0 end
end

function Sessions.InvalidateCampus(campusId)
    local src = byCampus[campusId]
    if src then
        Sessions.Invalidate(src)
        TriggerClientEvent(EC.Const.ResourceEvents.Push, src, 'profile:changed', {})
    end
end

function Sessions.Remove(src)
    local session = bySrc[src]
    if session and byCampus[session.profile.campusId] == src then
        byCampus[session.profile.campusId] = nil
    end
    bySrc[src] = nil
end

--- Profils de tous les joueurs connectés, en résolvant ceux qui ne l'ont jamais été.
--- Utilisé pour les notifications de classe (rare) : une requête par joueur non résolu.
function Sessions.AllOnline()
    local list = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local profile = Sessions.Peek(src)
        if not profile then
            local ok, resolved = pcall(Sessions.Resolve, src)
            profile = ok and resolved or nil
            Wait(0)
        end
        if profile then list[#list + 1] = profile end
    end
    return list
end

-- Changement de compte signalé par le Campus (mode push) ou le framework.
Bridge.Campus.OnChanged = function(src)
    Sessions.Invalidate(src)
    TriggerClientEvent(EC.Const.ResourceEvents.Push, src, 'profile:changed', {})
end

for _, eventName in ipairs(Config.Campus.RefreshEvents or {}) do
    AddEventHandler(eventName, function(arg)
        local src = tonumber(arg) or tonumber(source)
        if src and src > 0 then Bridge.Campus.OnChanged(src) end
    end)
end

AddEventHandler('playerDropped', function()
    Sessions.Remove(source)
end)

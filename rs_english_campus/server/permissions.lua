--[[
    English Campus — permissions.

    Deux niveaux de contrôle, TOUJOURS côté serveur :
      1. Capacités par rôle (Config.Permissions) : « peut créer un cours », « peut voir les résultats »...
      2. Portée : un professeur n'agit que sur SES cours / évaluations et SES classes ;
         un élève ne voit que les contenus publiés pour SA classe. L'admin voit tout.
]]

Permissions = {}

local FW = Bridge.Framework

--- Le rôle possède-t-il la capacité ?
function Permissions.Can(profile, capability)
    local set = Config.Permissions[profile.role]
    if not set then return false end
    return set['*'] == true or set[capability] == true
end

--- Lève 'forbidden' si la capacité manque.
function Permissions.Require(profile, capability)
    if not Permissions.Can(profile, capability) then EC.Fail('forbidden') end
end

function Permissions.IsStaff(profile)
    return profile.role == 'teacher' or profile.role == 'admin'
end

function Permissions.IsAdmin(profile)
    return profile.role == 'admin'
end

--- Admin via ACE ou groupes (évalué à chaque résolution de profil).
function Permissions.IsAdminSource(src)
    if Config.AdminAce and IsPlayerAceAllowed(src, Config.AdminAce) then return true end
    for _, group in ipairs(Config.AdminGroups or {}) do
        if FW.HasGroup(src, group) then return true end
    end
    return false
end

--- Professeur via ACE, groupes ou job du framework.
function Permissions.IsTeacherSource(src)
    if Config.TeacherAce and IsPlayerAceAllowed(src, Config.TeacherAce) then return true end
    for _, group in ipairs(Config.TeacherGroups or {}) do
        if FW.HasGroup(src, group) then return true end
    end
    if next(Config.TeacherJobs or {}) then
        local job = FW.GetJob(src)
        local minGrade = job and Config.TeacherJobs[job.name]
        if minGrade and (job.grade or 0) >= minGrade then return true end
    end
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Portée (classes, propriété)
-- ─────────────────────────────────────────────────────────────────────────────

--- Le membre du personnel peut-il agir sur cette classe ?
function Permissions.CanAccessClass(profile, classId)
    if not classId then return false end
    if profile.role == 'admin' or profile.allClasses then return true end
    if profile.role ~= 'teacher' then return false end
    for _, id in ipairs(profile.teachingClassIds or {}) do
        if id == classId then return true end
    end
    return false
end

--- Classes accessibles par le membre du personnel (nil = toutes).
function Permissions.ClassScope(profile)
    if profile.role == 'admin' or profile.allClasses then return nil end
    return profile.teachingClassIds or {}
end

--- Vérifie que toutes les classes demandées sont accessibles ; retourne la liste validée.
function Permissions.FilterClasses(profile, classIds)
    for _, id in ipairs(classIds) do
        if not Classes.Get(id) then EC.Fail('bad_request', 'classIds') end
        if not Permissions.CanAccessClass(profile, id) then EC.Fail('forbidden_class') end
    end
    return classIds
end

--- Propriétaire (ou admin) d'un contenu ?
function Permissions.Owns(profile, teacherId)
    return profile.role == 'admin' or teacherId == profile.campusId
end

function Permissions.RequireOwner(profile, teacherId)
    if not Permissions.Owns(profile, teacherId) then EC.Fail('forbidden') end
end

--- Liste des capacités (envoyée à l'interface uniquement pour adapter l'affichage).
function Permissions.List(profile)
    local set = Config.Permissions[profile.role] or {}
    local out = {}
    if set['*'] then
        for _, role in ipairs({ 'student', 'teacher' }) do
            for capability, allowed in pairs(Config.Permissions[role] or {}) do
                if allowed then out[#out + 1] = capability end
            end
        end
        out[#out + 1] = 'admin'
        return out
    end
    for capability, allowed in pairs(set) do
        if allowed then out[#out + 1] = capability end
    end
    return out
end

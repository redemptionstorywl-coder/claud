--[[
    English Campus — administration (rôle admin uniquement).

    • classes : créer / renommer / réordonner / désactiver
    • membres : forcer un rôle (professeur, admin, élève) ou une classe
    • professeurs : classes enseignées
    • statistiques et journal d'activité
]]

local U = EC.U

local ADMIN = { role = 'admin' }

-- ─────────────────────────────────────────────────────────────────────────────
--  Vue d'ensemble
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('admin:overview', ADMIN, function(ctx)
    local t = EC.Now()
    local week = t - 7 * 86400
    local count = function(sql, ...) return DB.scalar(sql, ...) or 0 end

    local roles = {}
    for _, row in ipairs(DB.query('SELECT role, COUNT(*) AS n FROM campus_english_members GROUP BY role')) do
        roles[row.role] = row.n
    end

    local classes = {}
    for _, row in ipairs(DB.query([[
        SELECT c.id, c.label,
               (SELECT COUNT(*) FROM campus_english_members m WHERE m.class_id = c.id AND m.role = 'student') AS students,
               (SELECT AVG(r.grade / r.grade_max * ?) FROM campus_english_results r
                 WHERE r.class_id = c.id AND r.status = 'released' AND r.grade_max > 0) AS average
        FROM campus_english_classes c WHERE c.active = 1
        ORDER BY c.position, c.label
    ]], Config.Pedagogy.Grading.Scale or 20)) do
        classes[#classes + 1] = {
            id = row.id, label = row.label, students = row.students,
            average = row.average and U.round(tonumber(row.average), 2) or nil,
        }
    end

    local logs = {}
    for _, row in ipairs(DB.query([[
        SELECT l.id, l.action, l.target, l.created_at, m.first_name, m.last_name
        FROM campus_english_logs l LEFT JOIN campus_english_members m ON m.campus_id = l.campus_id
        ORDER BY l.id DESC LIMIT 12
    ]])) do
        logs[#logs + 1] = { id = row.id, action = row.action, target = row.target, at = row.created_at, who = EC.FullName(row.first_name, row.last_name) }
    end

    return {
        members = {
            students = roles.student or 0, teachers = roles.teacher or 0, admins = roles.admin or 0,
            activeWeek = count('SELECT COUNT(*) FROM campus_english_members WHERE last_seen_at >= ?', week),
            online = #GetPlayers(),
        },
        courses = {
            published = count("SELECT COUNT(*) FROM campus_english_courses WHERE status = 'published'"),
            draft = count("SELECT COUNT(*) FROM campus_english_courses WHERE status = 'draft'"),
        },
        assessments = {
            published = count("SELECT COUNT(*) FROM campus_english_assignments WHERE status = 'published'"),
            attemptsWeek = count("SELECT COUNT(*) FROM campus_english_results WHERE kind = 'assessment' AND started_at >= ?", week),
            toReview = count("SELECT COUNT(*) FROM campus_english_results WHERE status = 'submitted'"),
        },
        practice = {
            answersWeek = count('SELECT COUNT(*) FROM campus_english_answers WHERE answered_at >= ?', week),
        },
        classes = classes,
        logs = logs,
        campusMode = Config.Campus.Mode,
        framework = Bridge.Framework.Name(),
    }
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  Classes
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('admin:classes', ADMIN, function()
    local counts = {}
    for _, row in ipairs(DB.query("SELECT class_id, COUNT(*) AS n FROM campus_english_members WHERE role = 'student' AND class_id IS NOT NULL GROUP BY class_id")) do
        counts[row.class_id] = row.n
    end
    local list = Classes.List(true)
    for _, class in ipairs(list) do class.students = counts[class.id] or 0 end
    return list
end)

Rpc.Register('admin:class:save', ADMIN, function(ctx, data)
    local id = V.optId(data.id, 'id')
    local label = V.str(data.label, 64, 'label', { min = 2 })
    local code = V.str(data.code, 32, 'code', { min = 1 }):upper():gsub('[^%w%-_]', '')
    if code == '' then EC.Fail('bad_request', 'code') end
    local level = V.str(data.level, 32, 'level', { optional = true })
    local active = V.bool(data.active, true)
    local clash = DB.scalar('SELECT id FROM campus_english_classes WHERE code = ?', code)
    if clash and clash ~= id then EC.Fail('class_code_taken') end
    if id then
        if not Classes.Get(id) then EC.Fail('not_found') end
        DB.update('UPDATE campus_english_classes SET code = ?, label = ?, level = ?, active = ? WHERE id = ?', code, label, level, active and 1 or 0, id)
    else
        local position = (DB.scalar('SELECT COALESCE(MAX(position), 0) FROM campus_english_classes') or 0) + 1
        id = DB.insert('INSERT INTO campus_english_classes (code, label, level, position, active, created_at) VALUES (?, ?, ?, ?, ?, ?)',
            code, label, level, position, active and 1 or 0, EC.Now())
    end
    Classes.Load()
    Rpc.Audit(ctx, 'admin.class.save', id, { label = label, code = code, active = active })
    return Classes.List(true)
end)

Rpc.Register('admin:class:order', ADMIN, function(ctx, data)
    local ids = V.idList(data.ids, 200, 'ids')
    local tx = DB.transaction()
    for i, id in ipairs(ids) do tx:add('UPDATE campus_english_classes SET position = ? WHERE id = ?', i, id) end
    tx:commit()
    Classes.Load()
    return Classes.List(true)
end)

Rpc.Register('admin:class:delete', ADMIN, function(ctx, data)
    local id = V.id(data.id, 'id')
    local class = Classes.Get(id)
    if not class then EC.Fail('not_found') end
    local used = DB.scalar('SELECT COUNT(*) FROM campus_english_members WHERE class_id = ? OR class_override = ?', id, id) or 0
    if used > 0 then EC.Fail('class_not_empty') end
    DB.update('DELETE FROM campus_english_classes WHERE id = ?', id)
    Classes.Load()
    EC.CacheForget('course:')
    EC.CacheForget('assessment:')
    Rpc.Audit(ctx, 'admin.class.delete', id, { label = class.label })
    return Classes.List(true)
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  Membres, rôles, professeurs
-- ─────────────────────────────────────────────────────────────────────────────

local function memberView(row)
    return {
        campusId = row.campus_id, name = EC.FullName(row.first_name, row.last_name), studentNumber = row.student_number,
        role = row.role, roleOverride = row.role_override, classId = row.class_id, classLabel = Classes.Label(row.class_id),
        classOverride = row.class_override, title = row.title, titleOverride = row.title_override,
        lastSeenAt = row.last_seen_at, online = Sessions.IsOnline(row.campus_id),
    }
end

Rpc.Register('admin:members', ADMIN, function(ctx, data)
    local query = V.str(data.query, 64, 'query', { optional = true, default = '' })
    local role = data.role ~= nil and V.enum(data.role, { student = true, teacher = true, admin = true }, 'role') or nil
    local classId = V.optId(data.classId, 'classId')
    local where, params = {}, {}
    if query ~= '' then
        local like = '%' .. query:gsub('[%%_\\]', '\\%0') .. '%'
        where[#where + 1] = "(CONCAT(first_name, ' ', last_name) LIKE ? OR campus_id LIKE ? OR student_number LIKE ?)"
        params[#params + 1], params[#params + 2], params[#params + 3] = like, like, like
    end
    if role then
        where[#where + 1] = 'role = ?'
        params[#params + 1] = role
    end
    if classId then
        where[#where + 1] = 'class_id = ?'
        params[#params + 1] = classId
    end
    local rows = DB.query(([[
        SELECT campus_id, first_name, last_name, student_number, role, role_override, class_id, class_override, title,
               title_override, last_seen_at
        FROM campus_english_members %s
        ORDER BY last_seen_at DESC LIMIT 60
    ]]):format(#where > 0 and ('WHERE ' .. table.concat(where, ' AND ')) or ''), table.unpack(params))
    local out = {}
    for i, row in ipairs(rows) do out[i] = memberView(row) end
    return out
end)

Rpc.Register('admin:member:get', ADMIN, function(ctx, data)
    local campusId = V.campusId(data.campusId, 'campusId')
    local row = DB.single('SELECT * FROM campus_english_members WHERE campus_id = ?', campusId)
    if not row then EC.Fail('not_found') end
    local view = memberView(row)
    view.teachingClassIds = Classes.TeacherClassIds(campusId)
    return view
end)

Rpc.Register('admin:member:set', ADMIN, function(ctx, data)
    local campusId = V.campusId(data.campusId, 'campusId')
    local row = DB.single('SELECT campus_id FROM campus_english_members WHERE campus_id = ?', campusId)
    if not row then EC.Fail('not_found') end
    local roleOverride
    if data.roleOverride ~= nil and data.roleOverride ~= '' then
        roleOverride = V.enum(data.roleOverride, { student = true, teacher = true, admin = true }, 'roleOverride')
    end
    local classOverride = V.optId(data.classOverride, 'classOverride')
    if classOverride and not Classes.Get(classOverride) then EC.Fail('bad_request', 'classOverride') end
    local title = V.str(data.title, 24, 'title', { optional = true })
    DB.update('UPDATE campus_english_members SET role_override = ?, class_override = ?, title_override = ?, title = COALESCE(?, title) WHERE campus_id = ?',
        roleOverride, classOverride, title, title, campusId)

    if data.teachingClassIds ~= nil then
        local ids = V.idList(data.teachingClassIds, 50, 'teachingClassIds', true)
        for _, id in ipairs(ids) do
            if not Classes.Get(id) then EC.Fail('bad_request', 'teachingClassIds') end
        end
        Classes.SetTeacherClasses(campusId, ids)
    end
    Sessions.InvalidateCampus(campusId)
    Rpc.Audit(ctx, 'admin.member.set', campusId, { role = roleOverride, class = classOverride })
    local fresh = DB.single('SELECT * FROM campus_english_members WHERE campus_id = ?', campusId)
    local view = memberView(fresh)
    view.teachingClassIds = Classes.TeacherClassIds(campusId)
    return view
end)

--- Donne un rôle à un joueur connecté à partir de son ID serveur (pratique en jeu).
Rpc.Register('admin:grant:online', ADMIN, function(ctx, data)
    local target = V.int(data.serverId, 1, 65535, 'serverId')
    local role = V.enum(data.role, { student = true, teacher = true, admin = true }, 'role')
    if not GetPlayerName(target) then EC.Fail('player_offline') end
    local profile = Sessions.Resolve(target, true)
    DB.update('UPDATE campus_english_members SET role_override = ? WHERE campus_id = ?', role, profile.campusId)
    Sessions.InvalidateCampus(profile.campusId)
    Rpc.Audit(ctx, 'admin.grant', profile.campusId, { role = role })
    return { campusId = profile.campusId, name = profile.displayName, role = role }
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  Journal
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('admin:logs', ADMIN, function(ctx, data)
    local before = V.optId(data.before, 'before') or 4294967295
    local rows = DB.query([[
        SELECT l.id, l.campus_id, l.action, l.target, l.details, l.created_at, m.first_name, m.last_name
        FROM campus_english_logs l LEFT JOIN campus_english_members m ON m.campus_id = l.campus_id
        WHERE l.id < ? ORDER BY l.id DESC LIMIT 50
    ]], before)
    local out = {}
    for i, row in ipairs(rows) do
        out[i] = {
            id = row.id, campusId = row.campus_id, who = EC.FullName(row.first_name, row.last_name),
            action = row.action, target = row.target, details = EC.JsonDecode(row.details, nil), at = row.created_at,
        }
    end
    return out
end)

--[[
    English Campus — notifications.

    Une notification cible un élève, une classe, un rôle ou tout le monde.
    Elle est stockée une seule fois (pas une ligne par élève) ; l'état « lu » est
    enregistré par élève dans campus_english_notification_reads.
    Les joueurs connectés reçoivent immédiatement :
      • une bannière dans leur téléphone (si l'app n'est pas ouverte)
      • une mise à jour en direct dans l'app (badge, toast)
]]

Notifications = {}

local function retentionFrom()
    return EC.Now() - (Config.Notifications.RetentionDays or 30) * 86400
end

--- Clause WHERE des notifications visibles par un profil (+ paramètres).
local function visibility(profile)
    local sql = [[
        n.created_at >= ? AND (
            (n.target_type = 'user' AND n.target_id = ?)
            OR (n.target_type = 'role' AND n.target_id = ?)
            OR n.target_type = 'all'
    ]]
    local params = { retentionFrom(), profile.campusId, profile.role }
    if profile.classId and profile.role == 'student' then
        sql = sql .. " OR (n.target_type = 'class' AND n.target_id = ?)"
        params[#params + 1] = tostring(profile.classId)
    end
    return sql .. ')', params
end

local function view(row)
    return {
        id         = row.id,
        kind       = row.kind,
        title      = row.title,
        body       = row.body,
        sender     = row.sender_name,
        linkType   = row.link_type,
        linkId     = row.link_id,
        createdAt  = row.created_at,
        read       = row.read_at ~= nil,
    }
end

function Notifications.List(profile, limit)
    local where, params = visibility(profile)
    local sql = ([[
        SELECT n.id, n.kind, n.title, n.body, n.sender_name, n.link_type, n.link_id, n.created_at, r.read_at
        FROM campus_english_notifications n
        LEFT JOIN campus_english_notification_reads r ON r.notification_id = n.id AND r.campus_id = ?
        WHERE %s
        ORDER BY n.id DESC LIMIT %d
    ]]):format(where, math.floor(limit or 50))
    local rows = DB.query(sql, profile.campusId, table.unpack(params))
    local out = {}
    for i, row in ipairs(rows) do out[i] = view(row) end
    return out
end

function Notifications.UnreadCount(profile)
    local where, params = visibility(profile)
    local sql = ([[
        SELECT COUNT(*) FROM campus_english_notifications n
        LEFT JOIN campus_english_notification_reads r ON r.notification_id = n.id AND r.campus_id = ?
        WHERE r.read_at IS NULL AND %s
    ]]):format(where)
    return DB.scalar(sql, profile.campusId, table.unpack(params)) or 0
end

--- Marque comme lues (toutes, ou la liste d'identifiants fournie).
function Notifications.MarkRead(profile, ids)
    local where, params = visibility(profile)
    local sql = ([[
        INSERT IGNORE INTO campus_english_notification_reads (notification_id, campus_id, read_at)
        SELECT n.id, ?, ? FROM campus_english_notifications n WHERE %s
    ]]):format(where)
    local args = { profile.campusId, EC.Now() }
    for _, p in ipairs(params) do args[#args + 1] = p end
    if ids and #ids > 0 then
        sql = sql .. (' AND n.id IN (%s)'):format(DB.placeholders(#ids))
        for _, id in ipairs(ids) do args[#args + 1] = id end
    end
    DB.update(sql, table.unpack(args))
end

--- Joueurs connectés concernés par une notification.
local function recipients(n)
    if n.targetType == 'user' then
        local src = Sessions.SrcOf(n.targetId)
        return src and { src } or {}
    end
    local out = {}
    for _, profile in ipairs(Sessions.AllOnline()) do
        local match = n.targetType == 'all'
            or (n.targetType == 'role' and profile.role == n.targetId)
            or (n.targetType == 'class' and profile.role == 'student' and tostring(profile.classId) == n.targetId)
        if match then out[#out + 1] = profile.src end
    end
    return out
end

--- Crée et distribue une notification.
---@param n table { targetType, targetId, kind, title, body, linkType, linkId, senderId, senderName }
function Notifications.Send(n)
    n.targetId = tostring(n.targetId or '')
    n.title = EC.U.utf8sub(n.title or '', 120)
    n.body = EC.U.utf8sub(n.body or '', 500)
    local now = EC.Now()
    local id = DB.insert([[
        INSERT INTO campus_english_notifications
            (target_type, target_id, sender_id, sender_name, kind, title, body, link_type, link_id, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], n.targetType, n.targetId, n.senderId, n.senderName, n.kind, n.title, n.body, n.linkType, n.linkId, now)

    local payload = {
        id = id, kind = n.kind, title = n.title, body = n.body, sender = n.senderName,
        linkType = n.linkType, linkId = n.linkId, createdAt = now, read = false,
    }
    CreateThread(function()
        for _, src in ipairs(recipients(n)) do
            Rpc.Push(src, 'notification', payload)
        end
    end)
    return id
end

--- Envoie la même notification à plusieurs classes.
function Notifications.SendToClasses(classIds, n)
    for _, classId in ipairs(classIds) do
        local copy = EC.U.copy(n)
        copy.targetType, copy.targetId = 'class', classId
        Notifications.Send(copy)
    end
end

--- Suppression des notifications trop anciennes (au démarrage).
function Notifications.Purge()
    local removed = DB.update('DELETE FROM campus_english_notifications WHERE created_at < ?', retentionFrom())
    if removed > 0 then EC.Debug('%d old notifications purged', removed) end
end

-- ─────────────────────────────────────────────────────────────────────────────
--  RPC
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('notifications:list', {}, function(ctx)
    return { items = Notifications.List(ctx.profile, 60), unread = Notifications.UnreadCount(ctx.profile) }
end)

Rpc.Register('notifications:read', {}, function(ctx, data)
    local ids = data.all and {} or V.idList(data.ids, 100, 'ids')
    if not data.all and #ids == 0 then return { unread = Notifications.UnreadCount(ctx.profile) } end
    Notifications.MarkRead(ctx.profile, ids)
    return { unread = Notifications.UnreadCount(ctx.profile) }
end)

--- Message d'un professeur à une ou plusieurs de ses classes.
Rpc.Register('notifications:send', { role = 'teacher', cap = 'notify.send', cost = 4 }, function(ctx, data)
    local p = ctx.profile
    local L = Config.Pedagogy.Limits
    local classIds = Permissions.FilterClasses(p, V.idList(data.classIds, 30, 'classIds'))
    if #classIds == 0 then EC.Fail('bad_request', 'classIds:required') end
    local title = V.str(data.title, L.NotificationTitle, 'title', { min = 2 })
    local body = V.str(data.body, L.NotificationBody, 'body', { multiline = true, optional = true, default = '' })

    local linkType, linkId
    if data.linkType ~= nil then
        linkType = V.enum(data.linkType, { course = true, assessment = true }, 'linkType')
        linkId = V.id(data.linkId, 'linkId')
        local owner = DB.scalar(linkType == 'course'
            and 'SELECT teacher_id FROM campus_english_courses WHERE id = ?'
            or 'SELECT teacher_id FROM campus_english_assignments WHERE id = ?', linkId)
        if not owner then EC.Fail('not_found') end
        Permissions.RequireOwner(p, owner)
    end

    if p.role ~= 'admin' then
        local sent = DB.scalar([[
            SELECT COUNT(*) FROM campus_english_notifications
            WHERE sender_id = ? AND kind = 'message' AND created_at > ?
        ]], p.campusId, EC.Now() - 3600) or 0
        if sent + #classIds > (Config.Notifications.TeacherMessagesPerHour or 20) then EC.Fail('notify_quota') end
    end

    Notifications.SendToClasses(classIds, {
        kind = 'message', title = title, body = body, linkType = linkType, linkId = linkId,
        senderId = p.campusId, senderName = p.teacherName,
    })
    Rpc.Audit(ctx, 'notify.send', nil, { classes = classIds, title = title })
    return { sent = #classIds }
end)

--- Historique des messages envoyés par le professeur.
Rpc.Register('notifications:sent', { role = 'teacher', cap = 'notify.send' }, function(ctx)
    local rows = DB.query([[
        SELECT n.id, n.target_id, n.title, n.body, n.created_at,
               (SELECT COUNT(*) FROM campus_english_notification_reads r WHERE r.notification_id = n.id) AS read_count
        FROM campus_english_notifications n
        WHERE n.sender_id = ? AND n.kind = 'message' AND n.target_type = 'class'
        ORDER BY n.id DESC LIMIT 40
    ]], ctx.profile.campusId)
    local out = {}
    for i, row in ipairs(rows) do
        out[i] = {
            id = row.id, title = row.title, body = row.body, createdAt = row.created_at,
            classLabel = Classes.Label(tonumber(row.target_id)), reads = row.read_count,
        }
    end
    return out
end)

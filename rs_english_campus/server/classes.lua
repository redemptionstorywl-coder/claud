--[[
    English Campus — classes.

    Les classes sont le lien entre les contenus et les élèves :
    un cours / une évaluation est publié(e) pour une ou plusieurs classes,
    un élève ne voit que ce qui est destiné à SA classe (vérifié côté serveur).
]]

local U = EC.U

Classes = {}

local state = nil -- { list = {}, byId = {}, byKey = {} }

local function buildIndex(rows)
    local s = { list = rows, byId = {}, byKey = {} }
    for _, row in ipairs(rows) do
        row.active = U.bool(row.active)
        s.byId[row.id] = row
        s.byKey[U.normKey(row.label)] = row
        s.byKey[U.normKey(row.code)] = row
    end
    for alias, code in pairs(Config.Classes.Aliases or {}) do
        local target = s.byKey[U.normKey(code)]
        if target then s.byKey[U.normKey(alias)] = target end
    end
    return s
end

function Classes.Load()
    local rows = DB.query('SELECT id, code, label, level, position, active FROM campus_english_classes ORDER BY position, label')
    state = buildIndex(rows)
    return state
end

local function ensure()
    return state or Classes.Load()
end

function Classes.Invalidate()
    state = nil
end

function Classes.Get(id)
    return ensure().byId[id]
end

function Classes.Label(id)
    local class = id and ensure().byId[id]
    return class and class.label or nil
end

--- Liste des classes (actives par défaut) au format interface.
function Classes.List(includeInactive)
    local out = {}
    for _, row in ipairs(ensure().list) do
        if includeInactive or row.active then
            out[#out + 1] = { id = row.id, code = row.code, label = row.label, level = row.level, active = row.active, position = row.position }
        end
    end
    return out
end

--- Code de classe généré à partir d'un libellé (« Terminale B » → « TERMINALEB »).
local function codeFrom(label)
    local code = U.stripAccents(U.lower(label)):upper():gsub('[^%w]', '')
    if code == '' then code = 'CLASS' end
    return code:sub(1, 28)
end

--- Retrouve la classe correspondant à la valeur du compte Campus (libellé, code ou id).
--- Crée la classe si Config.Classes.AutoCreateFromCampus est actif.
---@return integer|nil classId
function Classes.Resolve(raw)
    if raw == nil then return nil end
    if type(raw) == 'table' then raw = raw.label or raw.name or raw.code or raw.id end
    if type(raw) == 'number' then
        local byId = ensure().byId[raw]
        if byId then return byId.id end
        raw = tostring(raw)
    end
    if type(raw) ~= 'string' then return nil end
    local label = U.cleanText(raw, nil, false)
    if not label or label == '' then return nil end
    label = U.utf8sub(label, 64)

    local found = ensure().byKey[U.normKey(label)]
    if found then return found.id end
    if not Config.Classes.AutoCreateFromCampus then return nil end

    return EC.WithLock('classes:create', function()
        local again = ensure().byKey[U.normKey(label)]
        if again then return again.id end
        local base, code, n = codeFrom(label), nil, 1
        code = base
        while DB.scalar('SELECT id FROM campus_english_classes WHERE code = ?', code) do
            n = n + 1
            code = base .. n
        end
        local position = (DB.scalar('SELECT COALESCE(MAX(position), 0) FROM campus_english_classes') or 0) + 1
        local id = DB.insert('INSERT INTO campus_english_classes (code, label, level, position, active, created_at) VALUES (?, ?, ?, ?, 1, ?)',
            code, label, label:match('^(%S+)'), position, EC.Now())
        EC.Info('Classe créée automatiquement depuis le Campus : %s (%s)', label, code)
        Classes.Load()
        return id
    end)
end

--- Crée les classes par défaut au premier démarrage.
function Classes.Seed()
    local count = DB.scalar('SELECT COUNT(*) FROM campus_english_classes') or 0
    if count > 0 then return end
    for i, class in ipairs(Config.Classes.Default or {}) do
        DB.update('INSERT IGNORE INTO campus_english_classes (code, label, level, position, active, created_at) VALUES (?, ?, ?, ?, 1, ?)',
            class.code, class.label, class.level, i, EC.Now())
    end
    EC.Info('%d classes par défaut créées.', #(Config.Classes.Default or {}))
    Classes.Load()
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Professeurs ↔ classes
-- ─────────────────────────────────────────────────────────────────────────────

function Classes.TeacherClassIds(teacherId)
    local rows = DB.query('SELECT class_id FROM campus_english_teacher_classes WHERE teacher_id = ?', teacherId)
    local ids = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = row.class_id end
    return ids
end

function Classes.SetTeacherClasses(teacherId, classIds)
    local tx = DB.transaction()
    tx:add('DELETE FROM campus_english_teacher_classes WHERE teacher_id = ?', teacherId)
    for _, id in ipairs(classIds) do
        tx:add('INSERT INTO campus_english_teacher_classes (teacher_id, class_id) VALUES (?, ?)', teacherId, id)
    end
    tx:commit()
end

--- Professeur(s) d'anglais d'une classe (affiché sur le tableau de bord élève).
function Classes.TeachersOf(classId)
    if not classId then return {} end
    local rows = DB.query([[
        SELECT m.campus_id, m.first_name, m.last_name, m.title
        FROM campus_english_teacher_classes tc
        JOIN campus_english_members m ON m.campus_id = tc.teacher_id
        WHERE tc.class_id = ? AND m.role IN ('teacher', 'admin')
        ORDER BY m.last_name
    ]], classId)
    if #rows == 0 then
        -- Repli : l'auteur du dernier cours publié pour cette classe.
        rows = DB.query([[
            SELECT m.campus_id, m.first_name, m.last_name, m.title
            FROM campus_english_courses c
            JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
            JOIN campus_english_members m ON m.campus_id = c.teacher_id
            WHERE c.status = 'published'
            ORDER BY c.published_at DESC LIMIT 1
        ]], classId)
    end
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = { campusId = row.campus_id, name = EC.TeacherName(row.title, row.first_name, row.last_name) }
    end
    return out
end

--- Libellés d'une liste d'identifiants de classes.
function Classes.Labels(ids)
    local out = {}
    for _, id in ipairs(ids or {}) do
        local class = Classes.Get(id)
        if class then out[#out + 1] = { id = id, label = class.label } end
    end
    return out
end

-- ─────────────────────────────────────────────────────────────────────────────
--  RPC
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('classes:list', {}, function(ctx)
    return Classes.List(false)
end)

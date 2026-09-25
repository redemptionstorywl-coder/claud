--[[
    English Campus — démarrage serveur, tableaux de bord, réglages, exports.
]]

local U = EC.U

EC.Ready = false

Dashboard = {}

-- ─────────────────────────────────────────────────────────────────────────────
--  Installation / démarrage
-- ─────────────────────────────────────────────────────────────────────────────

local function tablesExist()
    local count = DB.scalar([[
        SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = 'campus_english_courses'
    ]])
    return (tonumber(count) or 0) > 0
end

local function install()
    if tablesExist() then return true end
    if not Config.Database.AutoInstall then
        EC.Error('Tables absentes : importez sql/install.sql (ou activez Config.Database.AutoInstall).')
        return false
    end
    local ok, result = DB.runFile('sql/install.sql')
    if not ok then
        EC.Error('Installation SQL échouée : %s', tostring(result))
        return false
    end
    EC.Info('Base de données installée (%d requêtes exécutées).', result)
    return true
end

MySQL.ready(function()
    CreateThread(function()
        math.randomseed(os.time() + GetGameTimer())
        local ok, err = pcall(function()
            if not install() then return end
            Classes.Seed()
            Classes.Load()
            Notifications.Purge()
            DB.update('DELETE FROM campus_english_logs WHERE created_at < ?', EC.Now() - (Config.Database.LogRetentionDays or 60) * 86400)
            EC.Ready = true
            EC.Info('Prêt — Campus : %s | téléphone : %s | PC : %s | framework : %s',
                Config.Campus.Mode, Config.Phone.Adapter, Config.PC.Adapter, Bridge.Framework.Name())
        end)
        if not ok then EC.Error('Initialisation échouée : %s', tostring(err)) end
    end)
end)

-- Surveillance légère : tentatives expirées + évaluations programmées (une requête indexée par tour).
CreateThread(function()
    local interval = math.max(10, Config.Pedagogy.Assessment.SweepInterval or 30) * 1000
    while true do
        Wait(interval)
        if EC.Ready then
            local ok, err = pcall(Assessments.Sweep)
            if not ok then EC.Error('Sweep failed: %s', tostring(err)) end
        end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  Tableaux de bord
-- ─────────────────────────────────────────────────────────────────────────────

function Dashboard.Student(p)
    local courses = Courses.StudentList(p)
    local counts = { available = #courses, started = 0, completed = 0, exercisesTodo = 0, assessmentsTodo = 0 }
    local continueList, newList = {}, {}
    for _, c in ipairs(courses) do
        if c.state == 'completed' then
            counts.completed = counts.completed + 1
        elseif c.state == 'started' then
            counts.started = counts.started + 1
            continueList[#continueList + 1] = c
        else
            newList[#newList + 1] = c
        end
    end
    table.sort(continueList, function(a, b) return (a.activityAt or 0) > (b.activityAt or 0) end)

    local todo, upcoming = {}, {}
    for _, a in ipairs(Assessments.StudentList(p)) do
        if a.window == 'open' and a.canStart and (a.state == 'todo' or a.state == 'in_progress') then
            todo[#todo + 1] = a
        elseif a.window == 'upcoming' then
            upcoming[#upcoming + 1] = a
        end
    end
    table.sort(todo, function(a, b) return (a.closesAt or math.huge) < (b.closesAt or math.huge) end)
    table.sort(upcoming, function(a, b) return (a.opensAt or 0) < (b.opensAt or 0) end)
    counts.assessmentsTodo = #todo

    if p.classId then
        counts.exercisesTodo = DB.scalar([[
            SELECT COUNT(*) FROM campus_english_course_sections s
            JOIN campus_english_progress pr ON pr.course_id = s.course_id AND pr.student_id = ?
            JOIN campus_english_courses c ON c.id = s.course_id AND c.status = 'published'
            JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
            LEFT JOIN campus_english_progress_sections ps ON ps.section_id = s.id AND ps.student_id = ?
            WHERE s.type = 'exercise' AND ps.section_id IS NULL
        ]], p.campusId, p.classId, p.campusId) or 0
    end

    local grades = {}
    for _, row in ipairs(DB.query([[
        SELECT r.id, r.grade, r.grade_max, r.released_at, a.title
        FROM campus_english_results r JOIN campus_english_assignments a ON a.id = r.assignment_id
        WHERE r.student_id = ? AND r.kind = 'assessment' AND r.status = 'released'
        ORDER BY r.released_at DESC LIMIT 3
    ]], p.campusId)) do
        grades[#grades + 1] = { id = row.id, title = row.title, grade = row.grade, gradeMax = row.grade_max, at = row.released_at }
    end

    local teachers = Classes.TeachersOf(p.classId)
    local function first(list, n)
        local out = {}
        for i = 1, math.min(n, #list) do out[i] = list[i] end
        return out
    end
    return {
        counts        = counts,
        overall       = Grades.Summary(p).overall,
        continue      = first(continueList, 3),
        new           = first(newList, 3),
        assessments   = first(todo, 3),
        upcoming      = first(upcoming, 2),
        grades        = grades,
        teacher       = teachers[1] and teachers[1].name or nil,
        notifications = Notifications.List(p, 3),
    }
end

function Dashboard.Teacher(p)
    local count = function(sql, ...) return DB.scalar(sql, ...) or 0 end
    local t = EC.Now()
    local id = p.campusId
    local out = {
        courses = {
            published = count("SELECT COUNT(*) FROM campus_english_courses WHERE teacher_id = ? AND status = 'published'", id),
            draft     = count("SELECT COUNT(*) FROM campus_english_courses WHERE teacher_id = ? AND status = 'draft'", id),
        },
        assessments = {
            open = count([[SELECT COUNT(*) FROM campus_english_assignments WHERE teacher_id = ? AND status = 'published'
                           AND (opens_at IS NULL OR opens_at <= ?) AND (closes_at IS NULL OR closes_at > ?)]], id, t, t),
            scheduled = count("SELECT COUNT(*) FROM campus_english_assignments WHERE teacher_id = ? AND status = 'published' AND opens_at > ?", id, t),
            toReview = count([[SELECT COUNT(*) FROM campus_english_results r JOIN campus_english_assignments a ON a.id = r.assignment_id
                               WHERE a.teacher_id = ? AND r.status = 'submitted']], id),
            toRelease = count([[SELECT COUNT(*) FROM campus_english_results r JOIN campus_english_assignments a ON a.id = r.assignment_id
                                WHERE a.teacher_id = ? AND r.status = 'graded']], id),
        },
    }

    local classIds = Permissions.ClassScope(p)
    local classes = {}
    local list = classIds and Classes.Labels(classIds) or Classes.List(false)
    if #list > 0 then
        local ids = {}
        for i, c in ipairs(list) do ids[i] = c.id end
        local counts = {}
        for _, row in ipairs(DB.query(([[
            SELECT class_id, COUNT(*) AS n,
                   SUM(last_seen_at >= ?) AS active
            FROM campus_english_members WHERE role = 'student' AND class_id IN (%s) GROUP BY class_id
        ]]):format(DB.placeholders(#ids)), t - 7 * 86400, table.unpack(ids))) do
            counts[row.class_id] = { students = row.n, active = tonumber(row.active) or 0 }
        end
        for _, c in ipairs(list) do
            local n = counts[c.id] or { students = 0, active = 0 }
            classes[#classes + 1] = { id = c.id, label = c.label, students = n.students, active = n.active }
        end
    end
    out.classes = classes

    out.submissions = {}
    for _, row in ipairs(DB.query([[
        SELECT r.id, r.status, r.grade, r.grade_max, r.submitted_at, r.auto_submitted, a.title, m.first_name, m.last_name
        FROM campus_english_results r
        JOIN campus_english_assignments a ON a.id = r.assignment_id
        LEFT JOIN campus_english_members m ON m.campus_id = r.student_id
        WHERE a.teacher_id = ? AND r.status IN ('submitted', 'graded', 'released')
        ORDER BY r.submitted_at DESC LIMIT 6
    ]], id)) do
        out.submissions[#out.submissions + 1] = {
            attemptId = row.id, status = row.status, grade = row.grade, gradeMax = row.grade_max, at = row.submitted_at,
            title = row.title, name = EC.FullName(row.first_name, row.last_name), autoSubmitted = U.bool(row.auto_submitted),
        }
    end
    out.notifications = Notifications.List(p, 3)
    return out
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Profil exposé à l'interface
-- ─────────────────────────────────────────────────────────────────────────────

local function profileView(p)
    local teaching
    if p.role ~= 'student' then
        teaching = p.allClasses and Classes.List(false) or Classes.Labels(p.teachingClassIds)
    end
    return {
        campusId        = p.campusId,
        firstName       = p.firstName,
        lastName        = p.lastName,
        displayName     = p.displayName,
        title           = p.title,
        teacherName     = p.teacherName,
        role            = p.role,
        classId         = p.classId,
        className       = p.className,
        studentNumber   = p.studentNumber,
        capabilities    = Permissions.List(p),
        teachingClasses = teaching,
        allClasses      = p.allClasses,
        prefs           = p.prefs,
        fallback        = p.fallback,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
--  RPC
-- ─────────────────────────────────────────────────────────────────────────────

--- Ouverture de l'application : profil + réglages + tableau de bord en une seule requête.
Rpc.Register('app:init', { cost = 2 }, function(ctx)
    local p = ctx.profile
    local L = Config.Pedagogy.Limits
    return {
        serverNow = EC.Now(),
        profile   = profileView(p),
        classes   = Permissions.IsStaff(p) and Classes.List(false) or nil,
        unread    = Notifications.UnreadCount(p),
        settings  = {
            scale                  = Config.Pedagogy.Grading.Scale or 20,
            themes                 = Config.Pedagogy.Themes,
            teachersCanPickClasses = Config.Classes.TeachersCanPickClasses == true,
            vocabularySession      = Config.Pedagogy.Vocabulary.SessionSize or 10,
            defaultDuration        = Config.Pedagogy.DefaultCourseDuration,
            assessment             = {
                defaultDuration = Config.Pedagogy.Assessment.DefaultDuration,
                defaultMaxScore = Config.Pedagogy.Assessment.DefaultMaxScore,
                maxDuration     = Config.Pedagogy.Assessment.MaxDuration,
            },
            limits = {
                courseTitle = L.CourseTitle, courseDescription = L.CourseDescription, sections = L.SectionsPerCourse,
                sectionTitle = L.SectionTitle, textBody = L.TextBody, words = L.WordsPerVocabulary, term = L.VocabularyTerm,
                questions = L.QuestionsPerExercise, prompt = L.QuestionPrompt, explanation = L.Explanation,
                options = L.OptionsPerQuestion, optionText = L.OptionText, accepted = L.AcceptedAnswers,
                answerText = L.AnswerText, openAnswer = L.OpenAnswerText, maxPoints = L.MaxPoints,
                notificationTitle = L.NotificationTitle, notificationBody = L.NotificationBody,
            },
        },
        dashboard = p.role == 'student' and Dashboard.Student(p) or Dashboard.Teacher(p),
    }
end)

Rpc.Register('dashboard:get', {}, function(ctx)
    local p = ctx.profile
    return {
        serverNow = EC.Now(),
        unread = Notifications.UnreadCount(p),
        dashboard = p.role == 'student' and Dashboard.Student(p) or Dashboard.Teacher(p),
    }
end)

Rpc.Register('settings:get', {}, function(ctx)
    local p = ctx.profile
    return {
        prefs = p.prefs,
        title = p.title,
        teachingClassIds = p.teachingClassIds,
        allClasses = p.allClasses,
        canPickClasses = p.role == 'teacher' and Config.Classes.TeachersCanPickClasses == true,
        classes = Permissions.IsStaff(p) and Classes.List(false) or nil,
    }
end)

Rpc.Register('settings:save', { cost = 2 }, function(ctx, data)
    local p = ctx.profile
    local prefs = U.copy(p.prefs or {})
    if data.theme ~= nil then prefs.theme = V.enum(data.theme, { auto = true, light = true, dark = true }, 'theme') end
    if data.sounds ~= nil then prefs.sounds = V.bool(data.sounds) end
    if data.reduceMotion ~= nil then prefs.reduceMotion = V.bool(data.reduceMotion) end

    if Permissions.IsStaff(p) and data.title ~= nil then
        local title = V.str(data.title, 24, 'title', { optional = true })
        DB.update('UPDATE campus_english_members SET title_override = ? WHERE campus_id = ?', title, p.campusId)
    end
    DB.update('UPDATE campus_english_members SET prefs = ? WHERE campus_id = ?', EC.JsonEncode(prefs), p.campusId)

    if data.classIds ~= nil then
        if p.role ~= 'teacher' or not Config.Classes.TeachersCanPickClasses then EC.Fail('forbidden') end
        local ids = V.idList(data.classIds, 30, 'classIds', true)
        for _, id in ipairs(ids) do
            if not Classes.Get(id) then EC.Fail('bad_request', 'classIds') end
        end
        Classes.SetTeacherClasses(p.campusId, ids)
        Rpc.Audit(ctx, 'teacher.classes', p.campusId, { classes = ids })
    end

    local fresh = Sessions.Resolve(ctx.src, true)
    return profileView(fresh)
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  Exports serveur (intégration avec vos autres ressources)
-- ─────────────────────────────────────────────────────────────────────────────

--- Profil English Campus d'un joueur (ou nil) : campusId, role, classId, className...
exports('GetProfile', function(src)
    local ok, profile = pcall(Sessions.Resolve, tonumber(src))
    return ok and profile or nil
end)

--- Force la relecture du compte Campus d'un joueur (après un changement de classe, de rôle...).
exports('RefreshProfile', function(src)
    src = tonumber(src)
    if src then Bridge.Campus.OnChanged(src) end
end)

--- Notification English Campus vers un élève, une classe ou un rôle.
---   exports.rs_english_campus:Notify('class', 3, 'Rappel', 'Cours à 18h !')
exports('Notify', function(targetType, targetId, title, body)
    if not EC.Ready then return false end
    if targetType ~= 'user' and targetType ~= 'class' and targetType ~= 'role' and targetType ~= 'all' then return false end
    CreateThread(function()
        Notifications.Send({
            targetType = targetType, targetId = targetId, kind = 'system',
            title = tostring(title or ''), body = tostring(body or ''),
        })
    end)
    return true
end)

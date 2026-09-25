--[[
    English Campus — notes, carnet de notes, progression.

    • L'élève voit uniquement SES notes publiées et SA progression.
    • Le professeur voit les élèves et résultats de SES classes (et de SES évaluations).
    • Les notes ne sont JAMAIS reçues depuis l'interface : la correction manuelle d'une
      question envoie seulement des points, bornés par le serveur entre 0 et le barème.
]]

local U = EC.U

Grades = {}

local function scale()
    return Config.Pedagogy.Grading.Scale or 20
end

--- Moyenne pondérée (coefficients) ramenée sur le barème. Meilleure tentative par évaluation.
---@param rows table lignes { assignment_id, grade, grade_max, coefficient }
function Grades.Average(rows)
    local best = {}
    for _, r in ipairs(rows) do
        local max = tonumber(r.grade_max) or 0
        if max > 0 and r.grade ~= nil then
            local value = tonumber(r.grade) / max * scale()
            local current = best[r.assignment_id]
            if not current or value > current.value then
                best[r.assignment_id] = { value = value, coefficient = tonumber(r.coefficient) or 1 }
            end
        end
    end
    local sum, weights, count = 0, 0, 0
    for _, entry in pairs(best) do
        sum = sum + entry.value * entry.coefficient
        weights = weights + entry.coefficient
        count = count + 1
    end
    if weights <= 0 then return nil, 0 end
    return U.round(sum / weights, 2), count
end

--- Progression par thème (points obtenus / points possibles), entraînement + évaluations publiées.
function Grades.Themes(studentId)
    local rows = DB.query([[
        SELECT q.theme, SUM(a.points) AS got, SUM(a.max_points) AS total
        FROM campus_english_answers a
        JOIN campus_english_results r ON r.id = a.result_id
        JOIN campus_english_questions q ON q.id = a.question_id
        WHERE r.student_id = ? AND a.graded = 1
          AND (r.kind = 'practice' OR r.kind = 'practice_old' OR (r.kind = 'assessment' AND r.status = 'released'))
        GROUP BY q.theme
    ]], studentId)
    local byTheme = {}
    for _, row in ipairs(rows) do
        local total = tonumber(row.total) or 0
        if total > 0 then byTheme[row.theme] = U.round((tonumber(row.got) or 0) / total * 100, 0) end
    end
    local out = {}
    for _, theme in ipairs(Config.Pedagogy.Themes) do
        out[#out + 1] = { theme = theme, percent = byTheme[theme] }
    end
    return out
end

--- Progression sur les cours publiés pour une classe (un ou plusieurs élèves).
---@return table<string, { percent, completed, total }> par élève, integer nombre de cours
function Grades.CourseProgress(classId, studentIds)
    local out = {}
    if not classId or #studentIds == 0 then return out, 0 end
    local courses = DB.query([[
        SELECT c.id, (SELECT COUNT(*) FROM campus_english_course_sections s WHERE s.course_id = c.id) AS total
        FROM campus_english_courses c
        JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
        WHERE c.status = 'published'
    ]], classId)
    if #courses == 0 then
        for _, id in ipairs(studentIds) do out[id] = { percent = 0, completed = 0, total = 0 } end
        return out, 0
    end
    local courseIds, totals = {}, {}
    for i, c in ipairs(courses) do
        courseIds[i] = c.id
        totals[c.id] = c.total
    end
    local done = {}
    local params = {}
    for _, id in ipairs(courseIds) do params[#params + 1] = id end
    for _, id in ipairs(studentIds) do params[#params + 1] = id end
    for _, row in ipairs(DB.query(([[
        SELECT student_id, course_id, COUNT(*) AS done FROM campus_english_progress_sections
        WHERE course_id IN (%s) AND student_id IN (%s)
        GROUP BY student_id, course_id
    ]]):format(DB.placeholders(#courseIds), DB.placeholders(#studentIds)), table.unpack(params))) do
        done[row.student_id] = done[row.student_id] or {}
        done[row.student_id][row.course_id] = row.done
    end
    for _, studentId in ipairs(studentIds) do
        local sum, completed = 0, 0
        for _, courseId in ipairs(courseIds) do
            local total = totals[courseId]
            local d = (done[studentId] or {})[courseId] or 0
            if total > 0 then
                sum = sum + math.min(1, d / total)
                if d >= total then completed = completed + 1 end
            end
        end
        out[studentId] = { percent = math.floor(sum / #courseIds * 100), completed = completed, total = #courseIds }
    end
    return out, #courseIds
end

--- Notes publiées d'une liste d'élèves.
local function releasedGrades(studentIds)
    if #studentIds == 0 then return {} end
    return DB.query(([[
        SELECT r.id, r.student_id, r.assignment_id, r.grade, r.grade_max, r.percent, r.submitted_at, r.released_at,
               r.duration_sec, a.title, a.coefficient, a.theme
        FROM campus_english_results r
        JOIN campus_english_assignments a ON a.id = r.assignment_id
        WHERE r.kind = 'assessment' AND r.status = 'released' AND r.student_id IN (%s)
        ORDER BY r.submitted_at
    ]]):format(DB.placeholders(#studentIds)), table.unpack(studentIds))
end

--- Le professeur peut-il consulter cet élève ?
local function requireStudentAccess(profile, studentId)
    local member = DB.single('SELECT campus_id, first_name, last_name, student_number, class_id, role, last_seen_at FROM campus_english_members WHERE campus_id = ?', studentId)
    if not member then EC.Fail('not_found') end
    if profile.role ~= 'admin' and not Permissions.CanAccessClass(profile, member.class_id) then EC.Fail('forbidden') end
    return member
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Élève : mes résultats / ma progression
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('results:mine', { cap = 'results.own' }, function(ctx)
    local p = ctx.profile
    local rows = DB.query([[
        SELECT r.id, r.assignment_id, r.attempt_no, r.status, r.grade, r.grade_max, r.percent, r.submitted_at,
               r.duration_sec, r.auto_submitted, a.title, a.coefficient, a.theme
        FROM campus_english_results r
        JOIN campus_english_assignments a ON a.id = r.assignment_id
        WHERE r.student_id = ? AND r.kind = 'assessment' AND r.status IN ('submitted', 'graded', 'released')
        ORDER BY r.submitted_at DESC
        LIMIT 100
    ]], p.campusId)
    local items, released = {}, {}
    for i, row in ipairs(rows) do
        local isReleased = row.status == 'released'
        items[i] = {
            id = row.id, assessmentId = row.assignment_id, title = row.title, attemptNo = row.attempt_no,
            status = row.status, submittedAt = row.submitted_at, durationSec = row.duration_sec,
            coefficient = row.coefficient, theme = row.theme, autoSubmitted = U.bool(row.auto_submitted),
            grade = isReleased and row.grade or nil, gradeMax = isReleased and row.grade_max or nil,
            percent = isReleased and row.percent or nil,
        }
        if isReleased then released[#released + 1] = row end
    end
    local average, counted = Grades.Average(released)
    return { items = items, average = average, counted = counted, scale = scale() }
end)

--- Synthèse de progression d'un élève : cours, exercices, vocabulaire et pourcentage global.
--- Partagée par le tableau de bord et l'écran « Ma progression » pour afficher le même chiffre partout.
function Grades.Summary(p)
    local courses = Grades.CourseProgress(p.classId, { p.campusId })[p.campusId] or { percent = 0, completed = 0, total = 0 }
    local out = { courses = courses, exercises = { total = 0, done = 0 }, vocabulary = { total = 0, mastered = 0 } }

    if p.classId then
        out.exercises = {
            total = DB.scalar([[
                SELECT COUNT(*) FROM campus_english_course_sections s
                JOIN campus_english_courses c ON c.id = s.course_id AND c.status = 'published'
                JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
                WHERE s.type = 'exercise'
            ]], p.classId) or 0,
            done = DB.scalar([[
                SELECT COUNT(*) FROM campus_english_results r
                JOIN campus_english_courses c ON c.id = r.course_id AND c.status = 'published'
                JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
                WHERE r.student_id = ? AND r.kind = 'practice' AND (r.status = 'completed' OR r.best_percent IS NOT NULL)
            ]], p.classId, p.campusId) or 0,
        }
        local vocab = DB.single([[
            SELECT COUNT(*) AS total, COALESCE(SUM(st.box >= ?), 0) AS mastered
            FROM campus_english_vocabulary v
            JOIN campus_english_courses c ON c.id = v.course_id AND c.status = 'published'
            JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
            LEFT JOIN campus_english_vocab_stats st ON st.word_id = v.id AND st.student_id = ?
        ]], Config.Pedagogy.Vocabulary.MasteredBox or 4, p.classId, p.campusId) or {}
        out.vocabulary = { total = tonumber(vocab.total) or 0, mastered = tonumber(vocab.mastered) or 0 }
    end

    -- Progression globale : moyenne des cours, exercices et vocabulaire maîtrisé.
    local parts, sum = 0, 0
    if courses.total > 0 then parts, sum = parts + 1, sum + courses.percent end
    if out.exercises.total > 0 then parts, sum = parts + 1, sum + math.min(100, out.exercises.done / out.exercises.total * 100) end
    if out.vocabulary.total > 0 then parts, sum = parts + 1, sum + out.vocabulary.mastered / out.vocabulary.total * 100 end
    out.overall = parts > 0 and math.floor(sum / parts) or 0
    return out
end

Rpc.Register('progress:mine', { cap = 'progress.own' }, function(ctx)
    local p = ctx.profile
    local out = Grades.Summary(p)
    out.themes, out.scale = Grades.Themes(p.campusId), scale()

    local released = releasedGrades({ p.campusId })
    out.average, out.assessments = Grades.Average(released)
    out.history = {}
    for i = math.max(1, #released - 7), #released do
        local r = released[i]
        if r then
            out.history[#out.history + 1] = {
                title = r.title, value = U.round(r.grade / r.grade_max * scale(), 2), at = r.submitted_at,
            }
        end
    end
    return out
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  Professeur : résultats d'une évaluation
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('tassessment:results', { role = 'teacher', cap = 'results.view' }, function(ctx, data)
    local st = Assessments.ForOwner(ctx.profile, V.id(data.id, 'id'))
    local a = st.a
    local rows = DB.query([[
        SELECT r.*, m.first_name, m.last_name, m.class_id AS member_class
        FROM campus_english_results r
        LEFT JOIN campus_english_members m ON m.campus_id = r.student_id
        WHERE r.assignment_id = ? AND r.kind = 'assessment' AND r.status <> 'void'
        ORDER BY r.attempt_no
    ]], a.id)

    local byStudent = {}
    for _, row in ipairs(rows) do
        local entry = byStudent[row.student_id]
        if not entry then
            entry = {
                studentId = row.student_id, name = EC.FullName(row.first_name, row.last_name),
                classId = row.class_id or row.member_class, attempts = 0,
            }
            byStudent[row.student_id] = entry
        end
        entry.attempts = entry.attempts + 1
        -- Tentative de référence : meilleure note, sinon la plus récente.
        local better = not entry.row
            or (row.grade ~= nil and (entry.row.grade == nil or row.grade > entry.row.grade))
            or (entry.row.grade == nil and row.grade == nil)
        if better then entry.row = row end
    end

    local students, grades = {}, {}
    local stats = { submitted = 0, running = 0, toReview = 0, toRelease = 0 }
    for _, entry in pairs(byStudent) do
        local r = entry.row
        students[#students + 1] = {
            studentId = entry.studentId, name = entry.name, classLabel = Classes.Label(entry.classId),
            attempts = entry.attempts, attemptId = r.id, status = r.status, grade = r.grade, gradeMax = r.grade_max,
            percent = r.percent, durationSec = r.duration_sec, submittedAt = r.submitted_at,
            autoSubmitted = U.bool(r.auto_submitted), needsReview = U.bool(r.needs_review),
            online = Sessions.IsOnline(entry.studentId),
        }
        if r.status == 'in_progress' then stats.running = stats.running + 1 else stats.submitted = stats.submitted + 1 end
        if r.status == 'submitted' then stats.toReview = stats.toReview + 1 end
        if r.status == 'graded' then stats.toRelease = stats.toRelease + 1 end
        if r.grade ~= nil and r.status ~= 'in_progress' and r.status ~= 'submitted' then
            grades[#grades + 1] = r.grade / (r.grade_max > 0 and r.grade_max or 1) * a.max_score
        end
    end

    -- Élèves des classes ciblées n'ayant pas encore commencé.
    if #st.classIds > 0 then
        for _, m in ipairs(DB.query(([[
            SELECT campus_id, first_name, last_name, class_id FROM campus_english_members
            WHERE role = 'student' AND class_id IN (%s)
        ]]):format(DB.placeholders(#st.classIds)), table.unpack(st.classIds))) do
            if not byStudent[m.campus_id] then
                students[#students + 1] = {
                    studentId = m.campus_id, name = EC.FullName(m.first_name, m.last_name),
                    classLabel = Classes.Label(m.class_id), attempts = 0, status = 'not_started',
                    online = Sessions.IsOnline(m.campus_id),
                }
            end
        end
    end
    table.sort(students, function(x, y) return x.name < y.name end)

    if #grades > 0 then
        local sum, min, max = 0, math.huge, -math.huge
        for _, g in ipairs(grades) do
            sum = sum + g
            min, max = math.min(min, g), math.max(max, g)
        end
        stats.average, stats.min, stats.max = U.round(sum / #grades, 2), U.round(min, 2), U.round(max, 2)
    end

    return {
        assessment = {
            id = a.id, title = a.title, maxScore = a.max_score, status = a.status, window = Assessments.Window(a),
            opensAt = a.opens_at, closesAt = a.closes_at, releaseMode = a.release_mode,
            classes = Classes.Labels(st.classIds), questionCount = #st.questions,
        },
        students = students,
        stats = stats,
    }
end)

--- Tentative + ressources de correction (vue professeur).
local function ownedAttempt(profile, attemptId)
    local row = DB.single("SELECT * FROM campus_english_results WHERE id = ? AND kind = 'assessment'", attemptId)
    if not row then EC.Fail('not_found') end
    local st = Assessments.ForOwner(profile, row.assignment_id)
    return row, st
end

Rpc.Register('attempt:get', { role = 'teacher', cap = 'results.view' }, function(ctx, data)
    local row, st = ownedAttempt(ctx.profile, V.id(data.id, 'id'))
    local view = Assessments.ResultView(row, st, false)
    local m = DB.single('SELECT first_name, last_name, student_number, class_id FROM campus_english_members WHERE campus_id = ?', row.student_id)
    view.student = {
        id = row.student_id, name = m and EC.FullName(m.first_name, m.last_name) or row.student_id,
        studentNumber = m and m.student_number, classLabel = Classes.Label(row.class_id or (m and m.class_id)),
    }
    view.expiresAt = row.expires_at
    view.releasedAt = row.released_at
    return view
end)

--- Correction manuelle (questions ouvertes, ajustements) + commentaire + publication éventuelle.
Rpc.Register('attempt:grade', { role = 'teacher', cap = 'results.grade', cost = 3 }, function(ctx, data)
    local attemptId = V.id(data.id, 'id')
    local row, st = ownedAttempt(ctx.profile, attemptId)
    if row.status == 'in_progress' or row.status == 'void' then EC.Fail('attempt_not_submitted') end
    local comment = V.str(data.comment, 1200, 'comment', { multiline = true, optional = true })
    local release = V.bool(data.release, false)
    local allowed = U.toSet(EC.JsonDecode(row.questions, {}))

    return EC.WithLock(('attempt:%s:%d'):format(row.student_id, row.assignment_id), function()
        local t = EC.Now()
        local tx = DB.transaction()
        for i, g in ipairs(V.list(data.grades, 200, 'grades', true)) do
            V.table(g, 'grades')
            local qid = V.id(g.questionId, ('grades[%d].questionId'):format(i))
            local q = allowed[qid] and st.questionById[qid]
            if not q then EC.Fail('bad_request', 'grades.questionId') end
            -- Les points sont bornés par le barème de la question : impossible de gonfler une note.
            local points = U.round(U.clamp(V.num(g.points, 0, q.points, ('grades[%d].points'):format(i)), 0, q.points), 2)
            local feedback = V.str(g.feedback, 600, 'grades.feedback', { multiline = true, optional = true })
            local isCorrect = points >= q.points and 1 or 0
            tx:add([[
                INSERT INTO campus_english_answers (result_id, question_id, answer, is_correct, points, max_points, graded, feedback, answered_at)
                VALUES (?, ?, NULL, ?, ?, ?, 1, ?, ?)
                ON DUPLICATE KEY UPDATE is_correct = VALUES(is_correct), points = VALUES(points), graded = 1, feedback = VALUES(feedback)
            ]], row.id, qid, isCorrect, points, q.points, feedback, t)
        end
        tx:commit()

        local sums = DB.single([[
            SELECT COALESCE(SUM(points), 0) AS score, COALESCE(SUM(graded = 0), 0) AS pending
            FROM campus_english_answers WHERE result_id = ?
        ]], row.id)
        local score = U.round(tonumber(sums.score) or 0, 2)
        local pending = (tonumber(sums.pending) or 0) > 0
        local grade, percent = Grading.toGrade(score, row.max_points, st.a.max_score)

        local status = row.status
        if not pending then
            status = release and 'released' or (row.status == 'released' and 'released' or 'graded')
        elseif release then
            EC.Fail('needs_review')
        end
        DB.update([[
            UPDATE campus_english_results
            SET score = ?, grade = ?, grade_max = ?, percent = ?, needs_review = ?, status = ?, teacher_comment = ?,
                graded_by = ?, graded_at = ?, released_at = CASE WHEN ? = 'released' THEN COALESCE(released_at, ?) ELSE released_at END
            WHERE id = ?
        ]], score, grade, st.a.max_score, percent, pending and 1 or 0, status, comment, ctx.profile.campusId, t, status, t, row.id)

        if status == 'released' and row.status ~= 'released' and Config.Notifications.OnResultReleased then
            Notifications.Send({
                targetType = 'user', targetId = row.student_id, kind = 'result',
                title = EC.L('notif.result.title'),
                body = EC.L('notif.result.body', st.a.title, EC.FormatGrade(grade, st.a.max_score)),
                linkType = 'result', linkId = row.id,
                senderId = ctx.profile.campusId, senderName = ctx.profile.teacherName,
            })
        end
        Rpc.Audit(ctx, 'attempt.grade', row.id, { grade = grade, status = status })
        return { status = status, grade = grade, gradeMax = st.a.max_score, percent = percent, score = score, pending = pending }
    end)
end)

local function releaseRows(ctx, st, rows)
    local t = EC.Now()
    local released = 0
    for _, row in ipairs(rows) do
        local changed = DB.update("UPDATE campus_english_results SET status = 'released', released_at = ? WHERE id = ? AND status = 'graded'", t, row.id)
        if changed > 0 then
            released = released + 1
            if Config.Notifications.OnResultReleased then
                Notifications.Send({
                    targetType = 'user', targetId = row.student_id, kind = 'result',
                    title = EC.L('notif.result.title'),
                    body = EC.L('notif.result.body', st.a.title, EC.FormatGrade(row.grade, st.a.max_score)),
                    linkType = 'result', linkId = row.id,
                    senderId = ctx.profile.campusId, senderName = ctx.profile.teacherName,
                })
            end
        end
    end
    return released
end

Rpc.Register('attempt:release', { role = 'teacher', cap = 'results.grade', cost = 2 }, function(ctx, data)
    local row, st = ownedAttempt(ctx.profile, V.id(data.id, 'id'))
    if row.status == 'submitted' then EC.Fail('needs_review') end
    if row.status ~= 'graded' then EC.Fail('attempt_not_graded') end
    return { released = releaseRows(ctx, st, { row }) }
end)

Rpc.Register('tassessment:releaseAll', { role = 'teacher', cap = 'results.grade', cost = 5 }, function(ctx, data)
    local st = Assessments.ForOwner(ctx.profile, V.id(data.id, 'id'))
    local rows = DB.query("SELECT id, student_id, grade FROM campus_english_results WHERE assignment_id = ? AND status = 'graded'", st.a.id)
    local released = releaseRows(ctx, st, rows)
    Rpc.Audit(ctx, 'assessment.releaseAll', st.a.id, { count = released })
    return { released = released }
end)

--- Annule une tentative (ex. crash du joueur) : elle ne compte plus et l'élève peut recommencer.
Rpc.Register('attempt:void', { role = 'teacher', cap = 'results.grade', cost = 3 }, function(ctx, data)
    local row, st = ownedAttempt(ctx.profile, V.id(data.id, 'id'))
    return EC.WithLock(('attempt:%s:%d'):format(row.student_id, row.assignment_id), function()
        DB.update("UPDATE campus_english_results SET status = 'void' WHERE id = ?", row.id)
        Rpc.PushCampus(row.student_id, 'attempt:closed', { attemptId = row.id, assessmentId = st.a.id, void = true })
        Rpc.Audit(ctx, 'attempt.void', row.id, { student = row.student_id })
        return true
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  Professeur : élèves et carnet de notes
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('students:list', { role = 'teacher', cap = 'students.view' }, function(ctx, data)
    local classId = V.id(data.classId, 'classId')
    if not Permissions.CanAccessClass(ctx.profile, classId) then EC.Fail('forbidden_class') end
    local members = DB.query([[
        SELECT campus_id, first_name, last_name, student_number, last_seen_at
        FROM campus_english_members WHERE class_id = ? AND role = 'student'
        ORDER BY last_name, first_name LIMIT 300
    ]], classId)
    local ids = {}
    for i, m in ipairs(members) do ids[i] = m.campus_id end
    local progress, courseCount = Grades.CourseProgress(classId, ids)

    local gradesBy = {}
    for _, row in ipairs(releasedGrades(ids)) do
        gradesBy[row.student_id] = gradesBy[row.student_id] or {}
        table.insert(gradesBy[row.student_id], row)
    end

    local students, sumAvg, nAvg, sumProgress = {}, 0, 0, 0
    for i, m in ipairs(members) do
        local rows = gradesBy[m.campus_id] or {}
        local average = Grades.Average(rows)
        local last = rows[#rows]
        local prog = progress[m.campus_id] or { percent = 0, completed = 0, total = courseCount }
        students[i] = {
            studentId = m.campus_id, name = EC.FullName(m.first_name, m.last_name), studentNumber = m.student_number,
            average = average, lastGrade = last and { grade = last.grade, gradeMax = last.grade_max, title = last.title } or nil,
            progress = prog.percent, coursesCompleted = prog.completed, lastSeenAt = m.last_seen_at,
            online = Sessions.IsOnline(m.campus_id),
        }
        if average then sumAvg, nAvg = sumAvg + average, nAvg + 1 end
        sumProgress = sumProgress + prog.percent
    end
    return {
        class = { id = classId, label = Classes.Label(classId) },
        students = students,
        summary = {
            count = #students, courses = courseCount,
            average = nAvg > 0 and U.round(sumAvg / nAvg, 2) or nil,
            progress = #students > 0 and math.floor(sumProgress / #students) or 0,
        },
        scale = scale(),
    }
end)

Rpc.Register('student:detail', { role = 'teacher', cap = 'students.view' }, function(ctx, data)
    local member = requireStudentAccess(ctx.profile, V.campusId(data.studentId, 'studentId'))
    local id = member.campus_id
    local rows = DB.query([[
        SELECT r.id, r.assignment_id, r.attempt_no, r.status, r.grade, r.grade_max, r.percent, r.submitted_at,
               r.duration_sec, r.auto_submitted, a.title, a.coefficient, a.teacher_id
        FROM campus_english_results r
        JOIN campus_english_assignments a ON a.id = r.assignment_id
        WHERE r.student_id = ? AND r.kind = 'assessment' AND r.status <> 'void'
        ORDER BY r.submitted_at DESC, r.id DESC
        LIMIT 100
    ]], id)
    local history, released = {}, {}
    for i, row in ipairs(rows) do
        history[i] = {
            attemptId = row.id, assessmentId = row.assignment_id, title = row.title, attemptNo = row.attempt_no,
            status = row.status, grade = row.grade, gradeMax = row.grade_max, percent = row.percent,
            submittedAt = row.submitted_at, durationSec = row.duration_sec, coefficient = row.coefficient,
            autoSubmitted = U.bool(row.auto_submitted), mine = Permissions.Owns(ctx.profile, row.teacher_id),
        }
        if row.status == 'released' then released[#released + 1] = row end
    end
    local average, counted = Grades.Average(released)

    local courses = {}
    if member.class_id then
        for _, row in ipairs(DB.query([[
            SELECT c.id, c.title,
                   (SELECT COUNT(*) FROM campus_english_course_sections s WHERE s.course_id = c.id) AS total,
                   (SELECT COUNT(*) FROM campus_english_progress_sections ps WHERE ps.course_id = c.id AND ps.student_id = ?) AS done,
                   p.updated_at
            FROM campus_english_courses c
            JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
            LEFT JOIN campus_english_progress p ON p.course_id = c.id AND p.student_id = ?
            WHERE c.status = 'published'
            ORDER BY c.published_at DESC
        ]], id, member.class_id, id)) do
            courses[#courses + 1] = {
                id = row.id, title = row.title, activityAt = row.updated_at,
                percent = row.total > 0 and math.floor(row.done / row.total * 100) or 0,
            }
        end
    end

    return {
        student = {
            id = id, name = EC.FullName(member.first_name, member.last_name), studentNumber = member.student_number,
            classLabel = Classes.Label(member.class_id), lastSeenAt = member.last_seen_at, online = Sessions.IsOnline(id),
        },
        history = history,
        average = average,
        counted = counted,
        courses = courses,
        themes = Grades.Themes(id),
        scale = scale(),
    }
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  Suivi en direct (instantané initial + abonnement)
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('live:subscribe', { role = 'teacher', cap = 'live.use' }, function(ctx, data)
    local kind = V.enum(data.type, { course = true, assessment = true }, 'type')
    local id = V.id(data.id, 'id')
    local classIds, entries, title = {}, {}, nil

    if kind == 'course' then
        local st = Courses.ForOwner(ctx.profile, id)
        classIds, title = st.classIds, st.course.title
        if #classIds > 0 then
            local members = DB.query(([[
                SELECT m.campus_id, m.first_name, m.last_name, m.class_id, p.status, p.updated_at,
                       (SELECT COUNT(*) FROM campus_english_progress_sections ps WHERE ps.course_id = ? AND ps.student_id = m.campus_id) AS done
                FROM campus_english_members m
                LEFT JOIN campus_english_progress p ON p.course_id = ? AND p.student_id = m.campus_id
                WHERE m.role = 'student' AND m.class_id IN (%s)
            ]]):format(DB.placeholders(#classIds)), id, id, table.unpack(classIds))
            local total = #st.sections
            for _, m in ipairs(members) do
                entries[#entries + 1] = {
                    studentId = m.campus_id, name = EC.FullName(m.first_name, m.last_name), classId = m.class_id,
                    percent = total > 0 and math.floor(m.done / total * 100) or 0, done = m.done, total = total,
                    completed = total > 0 and m.done >= total, started = m.status ~= nil,
                    at = m.updated_at, online = Sessions.IsOnline(m.campus_id),
                }
            end
        end
    else
        local st = Assessments.ForOwner(ctx.profile, id)
        classIds, title = st.classIds, st.a.title
        local wanted = st.a.question_count or 0
        local effectiveTotal = (wanted > 0 and wanted < #st.questions) and wanted or #st.questions
        if #classIds > 0 then
            local latest = {}
            for _, r in ipairs(DB.query([[
                SELECT r.id, r.student_id, r.status, r.grade, r.grade_max, r.percent, r.started_at, r.expires_at, r.submitted_at,
                       r.auto_submitted, r.questions, (SELECT COUNT(*) FROM campus_english_answers a WHERE a.result_id = r.id) AS answered
                FROM campus_english_results r
                WHERE r.assignment_id = ? AND r.status <> 'void'
                ORDER BY r.attempt_no
            ]], id)) do
                latest[r.student_id] = r
            end
            for _, m in ipairs(DB.query(([[
                SELECT campus_id, first_name, last_name, class_id FROM campus_english_members
                WHERE role = 'student' AND class_id IN (%s)
            ]]):format(DB.placeholders(#classIds)), table.unpack(classIds))) do
                local r = latest[m.campus_id]
                entries[#entries + 1] = {
                    studentId = m.campus_id, name = EC.FullName(m.first_name, m.last_name), classId = m.class_id,
                    status = r and r.status or 'not_started', attemptId = r and r.id or nil,
                    answered = r and r.answered or 0, total = r and #EC.JsonDecode(r.questions, {}) or effectiveTotal,
                    grade = r and r.grade or nil, gradeMax = r and r.grade_max or nil, percent = r and r.percent or nil,
                    expiresAt = r and r.expires_at or nil, at = r and (r.submitted_at or r.started_at) or nil,
                    auto = r and U.bool(r.auto_submitted) or false, online = Sessions.IsOnline(m.campus_id),
                }
            end
        end
    end

    table.sort(entries, function(x, y) return x.name < y.name end)
    Live.Subscribe(ctx.src, kind .. ':' .. id)
    return { key = kind .. ':' .. id, title = title, entries = entries, classes = Classes.Labels(classIds), serverNow = EC.Now() }
end)

--[[
    English Campus — évaluations.

    Sécurité :
      • le chronomètre est tenu par le SERVEUR (expires_at) ; l'affichage client n'est qu'indicatif
      • les questions tirées et leur ordre sont enregistrés au démarrage de la tentative
      • les réponses sont enregistrées au fil de l'eau mais corrigées uniquement au rendu
      • une tentative expirée est rendue automatiquement (thread de surveillance)
      • nombre de tentatives, fenêtre d'ouverture et classe vérifiés à chaque démarrage
      • rendu atomique (verrou + UPDATE ... WHERE status = 'in_progress') : impossible de rendre deux fois
]]

local U = EC.U

Assessments = {}

local CACHE_TTL = 120

local function now() return EC.Now() end

local function grace()
    return Config.Pedagogy.Assessment.GraceSeconds or 20
end

local function lockKey(studentId, assignmentId)
    return ('attempt:%s:%d'):format(studentId, assignmentId)
end

function Assessments.Forget(id)
    EC.CacheForget('assessment:' .. id)
end

--- Évaluation + classes + banque de questions (mise en cache courte).
function Assessments.Get(id)
    local key = 'assessment:' .. id
    local cached = EC.CacheGet(key)
    if cached then return cached end

    local a = DB.single('SELECT * FROM campus_english_assignments WHERE id = ?', id)
    if not a then return nil end
    a.shuffle_questions = U.bool(a.shuffle_questions)
    a.shuffle_options = U.bool(a.shuffle_options)

    local classIds = {}
    for _, row in ipairs(DB.query('SELECT class_id FROM campus_english_assignment_classes WHERE assignment_id = ?', id)) do
        classIds[#classIds + 1] = row.class_id
    end

    local exercise = DB.single('SELECT id, uid FROM campus_english_exercises WHERE assignment_id = ?', id)
    local questions, questionById = {}, {}
    if exercise then
        for _, row in ipairs(DB.query('SELECT * FROM campus_english_questions WHERE exercise_id = ? ORDER BY position, id', exercise.id)) do
            local q = Questions.decode(row)
            questions[#questions + 1] = q
            questionById[q.id] = q
        end
    end

    local teacher = DB.single('SELECT first_name, last_name, title FROM campus_english_members WHERE campus_id = ?', a.teacher_id)
    local course = a.course_id and DB.single('SELECT id, title, status FROM campus_english_courses WHERE id = ?', a.course_id) or nil

    return EC.CacheSet(key, {
        a            = a,
        classIds     = classIds,
        classSet     = U.toSet(classIds),
        exercise     = exercise,
        questions    = questions,
        questionById = questionById,
        teacherName  = teacher and EC.TeacherName(teacher.title, teacher.first_name, teacher.last_name) or '—',
        course       = course,
    }, CACHE_TTL)
end

--- 'upcoming' | 'open' | 'closed'
function Assessments.Window(a, t)
    t = t or now()
    if a.opens_at and t < a.opens_at then return 'upcoming' end
    if a.closes_at and t >= a.closes_at then return 'closed' end
    return 'open'
end

--- Nombre de questions d'une tentative.
local function effectiveCount(st)
    local pool = #st.questions
    local wanted = st.a.question_count or 0
    if wanted > 0 and wanted < pool then return wanted end
    return pool
end

function Assessments.ForStudent(profile, id)
    local st = Assessments.Get(id)
    if not st or st.a.status ~= 'published' or not profile.classId or not st.classSet[profile.classId] then
        EC.Fail('not_found')
    end
    return st
end

function Assessments.ForOwner(profile, id)
    local st = Assessments.Get(id)
    if not st then EC.Fail('not_found') end
    Permissions.RequireOwner(profile, st.a.teacher_id)
    return st
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Vues élève
-- ─────────────────────────────────────────────────────────────────────────────

--- Résumé d'une tentative (la note n'est visible qu'une fois publiée).
function Assessments.AttemptSummary(row)
    local released = row.status == 'released'
    return {
        id            = row.id,
        attemptNo     = row.attempt_no,
        status        = row.status,
        startedAt     = row.started_at,
        expiresAt     = row.expires_at,
        submittedAt   = row.submitted_at,
        durationSec   = row.duration_sec,
        autoSubmitted = U.bool(row.auto_submitted),
        grade         = released and row.grade or nil,
        gradeMax      = released and row.grade_max or nil,
        percent       = released and row.percent or nil,
    }
end

local function card(st, attempts)
    local a = st.a
    local out = {
        id            = a.id,
        title         = a.title,
        description   = a.description,
        theme         = a.theme,
        difficulty    = a.difficulty,
        duration      = a.duration,
        questionCount = effectiveCount(st),
        maxScore      = a.max_score,
        coefficient   = a.coefficient,
        opensAt       = a.opens_at,
        closesAt      = a.closes_at,
        maxAttempts   = a.max_attempts,
        releaseMode   = a.release_mode,
        window        = Assessments.Window(a),
        teacher       = st.teacherName,
        course        = st.course and { id = st.course.id, title = st.course.title } or nil,
    }
    if attempts then
        local used, inProgress, last, best = 0, nil, nil, nil
        for _, row in ipairs(attempts) do
            if row.status ~= 'void' then
                used = used + 1
                last = row
                if row.status == 'in_progress' then inProgress = row end
                if row.status == 'released' and (not best or (row.grade or 0) > (best.grade or 0)) then best = row end
            end
        end
        out.attemptsUsed = used
        out.attemptsLeft = a.max_attempts > 0 and math.max(0, a.max_attempts - used) or -1
        out.inProgress = inProgress and Assessments.AttemptSummary(inProgress) or nil
        out.last = last and Assessments.AttemptSummary(last) or nil
        out.best = best and Assessments.AttemptSummary(best) or nil
        if inProgress then
            out.state = 'in_progress'
        elseif last and last.status == 'released' then
            out.state = 'done'
        elseif last and (last.status == 'submitted' or last.status == 'graded') then
            out.state = 'pending'
        else
            out.state = 'todo'
        end
        out.canStart = out.window == 'open' and (inProgress ~= nil or out.attemptsLeft ~= 0)
    end
    return out
end

local function attemptsOf(studentId, assignmentId)
    return DB.query([[
        SELECT * FROM campus_english_results
        WHERE student_id = ? AND assignment_id = ? AND kind = 'assessment'
        ORDER BY attempt_no
    ]], studentId, assignmentId)
end

--- Carte d'évaluation affichée à l'élève (liste, cours, tableau de bord).
function Assessments.StudentCard(profile, id, preview)
    local st = Assessments.Get(id)
    if not st then return { unavailable = true } end
    if preview then return card(st, nil) end
    if st.a.status ~= 'published' or not profile.classId or not st.classSet[profile.classId] then
        return { unavailable = true }
    end
    return card(st, attemptsOf(profile.campusId, id))
end

--- Toutes les évaluations publiées pour la classe de l'élève.
function Assessments.StudentList(profile)
    if not profile.classId then return {} end
    local rows = DB.query([[
        SELECT a.id FROM campus_english_assignments a
        JOIN campus_english_assignment_classes ac ON ac.assignment_id = a.id AND ac.class_id = ?
        WHERE a.status = 'published'
        ORDER BY COALESCE(a.opens_at, a.published_at) DESC
        LIMIT 100
    ]], profile.classId)
    if #rows == 0 then return {} end

    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.id end
    local attemptsBy = {}
    for _, row in ipairs(DB.query(([[
        SELECT * FROM campus_english_results
        WHERE student_id = ? AND kind = 'assessment' AND assignment_id IN (%s)
        ORDER BY attempt_no
    ]]):format(DB.placeholders(#ids)), profile.campusId, table.unpack(ids))) do
        attemptsBy[row.assignment_id] = attemptsBy[row.assignment_id] or {}
        table.insert(attemptsBy[row.assignment_id], row)
    end

    local out = {}
    for _, id in ipairs(ids) do
        local st = Assessments.Get(id)
        if st then out[#out + 1] = card(st, attemptsBy[id] or {}) end
    end
    return out
end

--- Questions d'une tentative (sans solutions) + réponses déjà enregistrées.
function Assessments.AttemptPayload(st, row)
    local questions = {}
    for _, qid in ipairs(EC.JsonDecode(row.questions, {})) do
        local q = st.questionById[qid]
        if q then questions[#questions + 1] = Questions.toStudent(q, { shuffleOptions = st.a.shuffle_options }) end
    end
    local saved = {}
    for _, ans in ipairs(DB.query('SELECT question_id, answer FROM campus_english_answers WHERE result_id = ?', row.id)) do
        saved[tostring(ans.question_id)] = EC.JsonDecode(ans.answer, {})
    end
    return {
        attempt = {
            id = row.id, attemptNo = row.attempt_no, status = row.status,
            startedAt = row.started_at, expiresAt = row.expires_at, serverNow = now(),
        },
        assessment = {
            id = st.a.id, title = st.a.title, description = st.a.description,
            duration = st.a.duration, maxScore = st.a.max_score, questionCount = #questions,
        },
        questions = questions,
        answers = saved,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Rendu et correction
-- ─────────────────────────────────────────────────────────────────────────────

--- Profil minimal d'un élève (pour la progression / le direct quand il est hors ligne).
local function studentStub(studentId, classId)
    local src = Sessions.SrcOf(studentId)
    local profile = src and Sessions.Peek(src)
    if profile then return profile end
    local m = DB.single('SELECT first_name, last_name, class_id FROM campus_english_members WHERE campus_id = ?', studentId)
    return {
        campusId = studentId,
        displayName = m and EC.FullName(m.first_name, m.last_name) or studentId,
        classId = classId or (m and m.class_id),
    }
end

--- Marque comme terminées les parties de cours qui renvoient vers cette évaluation.
local function completeLinkedSections(student, assignmentId)
    for _, row in ipairs(DB.query("SELECT id, course_id FROM campus_english_course_sections WHERE type = 'assessment' AND ref_id = ?", assignmentId)) do
        local st = Courses.Structure(row.course_id)
        local section = st and st.sectionById[row.id]
        if section and st.course.status == 'published' and student.classId and st.classSet[student.classId] then
            Courses.MarkSectionDone(student, st, section)
        end
    end
end

--- Corrige et clôture une tentative. À appeler sous le verrou de la tentative.
---@param row table ligne de campus_english_results
---@param opts table { auto = bool }
function Assessments.Finalize(row, opts)
    opts = opts or {}
    local fresh = DB.single('SELECT * FROM campus_english_results WHERE id = ?', row.id)
    if not fresh or fresh.status ~= 'in_progress' then return fresh end
    row = fresh

    local st = Assessments.Get(row.assignment_id)
    if not st then return row end
    local a = st.a

    local stored = {}
    for _, ans in ipairs(DB.query('SELECT id, question_id, answer FROM campus_english_answers WHERE result_id = ?', row.id)) do
        stored[ans.question_id] = ans
    end

    local t = now()
    local score, maxPoints, needsReview = 0, 0, false
    local tx = DB.transaction()
    for _, qid in ipairs(EC.JsonDecode(row.questions, {})) do
        local q = st.questionById[qid]
        if q then
            maxPoints = maxPoints + q.points
            local ans = stored[qid]
            local answer = ans and EC.JsonDecode(ans.answer, {}) or {}
            local graded
            if not ans or Grading.isEmpty(q, answer) then
                graded = { correct = false, points = 0, max = q.points }
            else
                graded = Grading.grade(q, answer)
            end
            if graded.pending then needsReview = true end
            score = score + graded.points
            local isCorrect
            if graded.correct ~= nil then isCorrect = graded.correct and 1 or 0 end
            if ans then
                tx:add('UPDATE campus_english_answers SET is_correct = ?, points = ?, max_points = ?, graded = ? WHERE id = ?',
                    isCorrect, graded.points, q.points, graded.pending and 0 or 1, ans.id)
            else
                tx:add([[INSERT INTO campus_english_answers (result_id, question_id, answer, is_correct, points, max_points, graded, answered_at)
                         VALUES (?, ?, NULL, 0, 0, ?, 1, ?)]], row.id, qid, q.points, t)
            end
        end
    end

    score = U.round(score, 2)
    local grade, percent = Grading.toGrade(score, maxPoints, a.max_score)
    local status = needsReview and 'submitted' or (a.release_mode == 'manual' and 'graded' or 'released')
    local finishedAt = row.expires_at and math.min(t, row.expires_at) or t
    local graded = not needsReview
    tx:add([[
        UPDATE campus_english_results
        SET status = ?, submitted_at = ?, graded_at = ?, released_at = ?, score = ?, max_points = ?, grade = ?,
            grade_max = ?, percent = ?, duration_sec = ?, needs_review = ?, auto_submitted = ?
        WHERE id = ? AND status = 'in_progress'
    ]], status, t, graded and t or nil, status == 'released' and t or nil, score, maxPoints, grade,
        a.max_score, percent, math.max(0, finishedAt - row.started_at), needsReview and 1 or 0, opts.auto and 1 or 0, row.id)
    tx:commit()

    local student = studentStub(row.student_id, row.class_id)
    pcall(completeLinkedSections, student, a.id)

    if needsReview and Config.Notifications.OnSubmissionToCorrect then
        Notifications.Send({
            targetType = 'user', targetId = a.teacher_id, kind = 'submission',
            title = EC.L('notif.submission.title'), body = EC.L('notif.submission.body', student.displayName, a.title),
            linkType = 'attempt', linkId = row.id,
        })
    end
    if opts.auto then
        Notifications.Send({
            targetType = 'user', targetId = row.student_id, kind = 'result',
            title = EC.L('notif.auto.title'),
            body = status == 'released'
                and EC.L('notif.result.instant', a.title, EC.FormatGrade(grade, a.max_score))
                or EC.L('notif.auto.body', a.title),
            linkType = 'result', linkId = row.id,
        })
        Rpc.PushCampus(row.student_id, 'attempt:closed', { attemptId = row.id, assessmentId = a.id })
    end

    Live.Emit('assessment:' .. a.id, {
        studentId = row.student_id, name = student.displayName, classId = student.classId,
        status = status, grade = grade, gradeMax = a.max_score, percent = percent,
        submittedAt = t, auto = opts.auto == true, attemptId = row.id,
    })
    return DB.single('SELECT * FROM campus_english_results WHERE id = ?', row.id)
end

--- Résultat d'une tentative (vue élève si forStudent, sinon vue professeur).
function Assessments.ResultView(row, st, forStudent)
    local a = st.a
    local released = row.status == 'released'
    local out = {
        id            = row.id,
        assessment    = { id = a.id, title = a.title, maxScore = a.max_score, reviewMode = a.review_mode },
        attemptNo     = row.attempt_no,
        status        = row.status,
        startedAt     = row.started_at,
        submittedAt   = row.submitted_at,
        durationSec   = row.duration_sec,
        autoSubmitted = U.bool(row.auto_submitted),
        needsReview   = U.bool(row.needs_review),
    }
    if released or not forStudent then
        out.grade, out.gradeMax, out.percent = row.grade, row.grade_max, row.percent
        out.score, out.maxPoints = row.score, row.max_points
        out.teacherComment = row.teacher_comment
    end

    local canReview = not forStudent
    if forStudent and released then
        canReview = a.review_mode == 'after_submit'
            or (a.review_mode == 'after_close' and a.closes_at ~= nil and now() >= a.closes_at)
        if a.review_mode == 'after_close' and not canReview then out.reviewAt = a.closes_at end
    end
    out.canReview = canReview

    if canReview and row.status ~= 'in_progress' then
        local answers = {}
        for _, ans in ipairs(DB.query('SELECT * FROM campus_english_answers WHERE result_id = ?', row.id)) do
            answers[ans.question_id] = ans
        end
        out.review = {}
        for _, qid in ipairs(EC.JsonDecode(row.questions, {})) do
            local q = st.questionById[qid]
            if q then
                local ans = answers[qid]
                local item = Questions.toStudent(q, { shuffleOptions = false })
                item.answer = ans and EC.JsonDecode(ans.answer, {}) or nil
                if ans and ans.is_correct ~= nil then item.correct = U.bool(ans.is_correct) end
                if item.answer then
                    -- Détail par trou / par paire pour colorer la correction (recalculé, jamais stocké côté client).
                    item.detail = Grading.grade(q, item.answer).detail
                end
                item.earned = ans and ans.points or 0
                item.max = q.points
                item.pending = ans ~= nil and not U.bool(ans.graded)
                item.teacherFeedback = ans and ans.feedback or nil
                item.solution = Grading.solutionView(q)
                item.explanation = q.explanation
                out.review[#out.review + 1] = item
            end
        end
    end
    return out
end

--- Démarre (ou reprend) une tentative.
function Assessments.Start(ctx, id)
    local p = ctx.profile
    local st = Assessments.ForStudent(p, id)
    local a = st.a
    return EC.WithLock(lockKey(p.campusId, id), function()
        local t = now()
        local current = DB.single([[
            SELECT * FROM campus_english_results
            WHERE student_id = ? AND assignment_id = ? AND kind = 'assessment' AND status = 'in_progress'
            ORDER BY attempt_no DESC LIMIT 1
        ]], p.campusId, id)
        if current then
            if current.expires_at and t > current.expires_at + grace() then
                Assessments.Finalize(current, { auto = true })
            else
                return Assessments.AttemptPayload(st, current)
            end
        end

        local window = Assessments.Window(a, t)
        if window == 'upcoming' then EC.Fail('assessment_not_open') end
        if window == 'closed' then EC.Fail('assessment_closed') end
        if #st.questions == 0 then EC.Fail('assessment_empty') end

        local used = DB.scalar([[
            SELECT COUNT(*) FROM campus_english_results
            WHERE student_id = ? AND assignment_id = ? AND kind = 'assessment' AND status <> 'void'
        ]], p.campusId, id) or 0
        if a.max_attempts > 0 and used >= a.max_attempts then EC.Fail('no_attempts_left') end

        -- Tirage des questions (sous-ensemble aléatoire si question_count < taille de la banque).
        local count = effectiveCount(st)
        local picked
        if count < #st.questions then
            picked = {}
            local shuffled = U.shuffle(st.questions)
            for i = 1, count do picked[i] = shuffled[i] end
            if not a.shuffle_questions then
                table.sort(picked, function(x, y) return (x.position or 0) < (y.position or 0) end)
            end
        else
            picked = a.shuffle_questions and U.shuffle(st.questions) or U.copy(st.questions)
        end
        local ids, maxPoints = {}, 0
        for i, q in ipairs(picked) do
            ids[i] = q.id
            maxPoints = maxPoints + q.points
        end

        local expires = nil
        if a.duration > 0 then expires = t + a.duration * 60 end
        if a.closes_at and (not expires or a.closes_at < expires) then expires = a.closes_at end

        local attemptNo = (DB.scalar('SELECT COALESCE(MAX(attempt_no), 0) FROM campus_english_results WHERE student_id = ? AND assignment_id = ?', p.campusId, id) or 0) + 1
        local resultId = DB.insert([[
            INSERT INTO campus_english_results
                (kind, student_id, class_id, assignment_id, attempt_no, status, questions, started_at, expires_at, max_points, grade_max)
            VALUES ('assessment', ?, ?, ?, ?, 'in_progress', ?, ?, ?, ?, ?)
        ]], p.campusId, p.classId, id, attemptNo, EC.JsonEncode(ids), t, expires, maxPoints, a.max_score)

        Live.Emit('assessment:' .. id, {
            studentId = p.campusId, name = p.displayName, classId = p.classId,
            status = 'in_progress', answered = 0, total = count, startedAt = t, expiresAt = expires,
        })
        Rpc.Audit(ctx, 'assessment.start', id, { attempt = attemptNo })
        return Assessments.AttemptPayload(st, DB.single('SELECT * FROM campus_english_results WHERE id = ?', resultId))
    end)
end

--- Tentative en cours appartenant à l'élève (sinon erreur).
local function ownAttempt(p, attemptId)
    local row = DB.single("SELECT * FROM campus_english_results WHERE id = ? AND student_id = ? AND kind = 'assessment'", attemptId, p.campusId)
    if not row then EC.Fail('not_found') end
    return row
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Surveillance : tentatives expirées + ouvertures programmées
-- ─────────────────────────────────────────────────────────────────────────────

--- Annonce une évaluation dont l'ouverture est arrivée (une seule fois).
function Assessments.Announce(id)
    local changed = DB.update('UPDATE campus_english_assignments SET announced_at = ? WHERE id = ? AND announced_at IS NULL', now(), id)
    if changed == 0 then return end
    Assessments.Forget(id)
    local st = Assessments.Get(id)
    if not st or st.a.status ~= 'published' then return end
    local a = st.a
    if a.closes_at and a.closes_at <= now() then return end
    if Config.Notifications.OnAssessmentOpened then
        Notifications.SendToClasses(st.classIds, {
            kind = 'assessment',
            title = EC.L('notif.assessment.title'),
            body = a.closes_at and EC.L('notif.assessment.until', a.title, EC.FormatDuration(a.closes_at - now()))
                or EC.L('notif.assessment.body', a.title),
            linkType = 'assessment', linkId = id,
            senderId = a.teacher_id, senderName = st.teacherName,
        })
    end
end

function Assessments.Sweep()
    local t = now()
    local expired = DB.query([[
        SELECT id, student_id, assignment_id FROM campus_english_results
        WHERE status = 'in_progress' AND kind = 'assessment' AND expires_at IS NOT NULL AND expires_at < ?
        LIMIT 50
    ]], t - grace())
    for _, row in ipairs(expired) do
        local ok, err = pcall(EC.WithLock, lockKey(row.student_id, row.assignment_id), Assessments.Finalize, row, { auto = true })
        if not ok then EC.Error('Auto-submit of attempt %d failed: %s', row.id, tostring(err)) end
    end

    local due = DB.query([[
        SELECT id FROM campus_english_assignments
        WHERE status = 'published' AND announced_at IS NULL AND (opens_at IS NULL OR opens_at <= ?)
        LIMIT 20
    ]], t)
    for _, row in ipairs(due) do
        local ok, err = pcall(Assessments.Announce, row.id)
        if not ok then EC.Error('Announcing assessment %d failed: %s', row.id, tostring(err)) end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Éditeur (professeur)
-- ─────────────────────────────────────────────────────────────────────────────

local function hasAttempts(id)
    return (DB.scalar("SELECT COUNT(*) FROM campus_english_results WHERE assignment_id = ? AND status <> 'void'", id) or 0) > 0
end

function Assessments.EditorPayload(id)
    local st = Assessments.Get(id)
    if not st then EC.Fail('not_found') end
    local a = st.a
    local questions = {}
    for i, q in ipairs(st.questions) do questions[i] = Questions.toEditor(q) end
    local attempts = DB.scalar("SELECT COUNT(*) FROM campus_english_results WHERE assignment_id = ? AND status <> 'void'", id) or 0
    return {
        id = a.id, title = a.title, description = a.description or '', courseId = a.course_id,
        courseTitle = st.course and st.course.title or nil, theme = a.theme, difficulty = a.difficulty,
        duration = a.duration, questionCount = a.question_count, maxScore = a.max_score, coefficient = a.coefficient,
        opensAt = a.opens_at, closesAt = a.closes_at, maxAttempts = a.max_attempts,
        shuffleQuestions = a.shuffle_questions, shuffleOptions = a.shuffle_options,
        releaseMode = a.release_mode, reviewMode = a.review_mode, status = a.status,
        teacherId = a.teacher_id, teacher = st.teacherName, classIds = st.classIds,
        questions = questions, attempts = attempts, locked = attempts > 0,
        announcedAt = a.announced_at, publishedAt = a.published_at, updatedAt = a.updated_at,
    }
end

local function parseAssessment(profile, input)
    local L, A = Config.Pedagogy.Limits, Config.Pedagogy.Assessment
    local x = V.table(input, 'assessment')
    local out = {
        id               = V.optId(x.id, 'id'),
        title            = V.str(x.title, L.CourseTitle, 'title', { min = 2 }),
        description      = V.str(x.description, L.CourseDescription, 'description', { multiline = true, optional = true, default = '' }),
        courseId         = V.optId(x.courseId, 'courseId'),
        theme            = V.enum(x.theme, EC.Const.Themes, 'theme', 'grammar'),
        difficulty       = V.int(x.difficulty, 1, 3, 'difficulty', 2),
        duration         = V.int(x.duration, 0, A.MaxDuration, 'duration', A.DefaultDuration),
        questionCount    = V.int(x.questionCount, 0, 200, 'questionCount', 0),
        maxScore         = V.num(x.maxScore, 1, 100, 'maxScore', A.DefaultMaxScore),
        coefficient      = V.num(x.coefficient, 0.25, 20, 'coefficient', 1),
        opensAt          = V.timestamp(x.opensAt, 'opensAt', true),
        closesAt         = V.timestamp(x.closesAt, 'closesAt', true),
        maxAttempts      = V.int(x.maxAttempts, 0, 20, 'maxAttempts', 1),
        shuffleQuestions = V.bool(x.shuffleQuestions, true),
        shuffleOptions   = V.bool(x.shuffleOptions, true),
        releaseMode      = V.enum(x.releaseMode, EC.Const.ReleaseModes, 'releaseMode', 'immediate'),
        reviewMode       = V.enum(x.reviewMode, EC.Const.ReviewModes, 'reviewMode', 'after_submit'),
        classIds         = Permissions.FilterClasses(profile, V.idList(x.classIds, 50, 'classIds', true)),
        questions        = {},
    }
    if out.opensAt and out.closesAt and out.closesAt <= out.opensAt then EC.Fail('bad_request', 'closesAt:before_open') end
    if out.courseId then
        local owner = DB.scalar('SELECT teacher_id FROM campus_english_courses WHERE id = ?', out.courseId)
        if not owner then EC.Fail('bad_request', 'courseId:not_found') end
        Permissions.RequireOwner(profile, owner)
    end
    for i, q in ipairs(V.list(x.questions, 200, 'questions', true)) do
        out.questions[i] = Questions.fromEditor(q, ('questions[%d]'):format(i))
    end
    return out
end

local function persist(id, x, lockQuestions)
    local t = now()
    local json = EC.JsonEncode
    local tx = DB.transaction()
    tx:add([[
        UPDATE campus_english_assignments
        SET title = ?, description = ?, course_id = ?, theme = ?, difficulty = ?, duration = ?, question_count = ?,
            max_score = ?, coefficient = ?, opens_at = ?, closes_at = ?, max_attempts = ?, shuffle_questions = ?,
            shuffle_options = ?, release_mode = ?, review_mode = ?, updated_at = ?
        WHERE id = ?
    ]], x.title, x.description, x.courseId, x.theme, x.difficulty, x.duration, x.questionCount, x.maxScore,
        x.coefficient, x.opensAt, x.closesAt, x.maxAttempts, x.shuffleQuestions and 1 or 0,
        x.shuffleOptions and 1 or 0, x.releaseMode, x.reviewMode, t, id)
    tx:add('DELETE FROM campus_english_assignment_classes WHERE assignment_id = ?', id)
    for _, classId in ipairs(x.classIds) do
        tx:add('INSERT INTO campus_english_assignment_classes (assignment_id, class_id) VALUES (?, ?)', id, classId)
    end

    if not lockQuestions then
        local exercise = DB.single('SELECT id, uid FROM campus_english_exercises WHERE assignment_id = ?', id)
        local exerciseUid
        local existing = {}
        if exercise then
            exerciseUid = exercise.uid
            tx:add('UPDATE campus_english_exercises SET title = ?, updated_at = ? WHERE id = ?', x.title, t, exercise.id)
            for _, r in ipairs(DB.query('SELECT id, uid, type FROM campus_english_questions WHERE exercise_id = ?', exercise.id)) do
                existing[r.uid] = r
            end
        else
            exerciseUid = U.uid()
            tx:add('INSERT INTO campus_english_exercises (uid, assignment_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
                exerciseUid, id, x.title, t, t)
        end
        local kept = {}
        for j, q in ipairs(x.questions) do
            local row = q.uid and existing[q.uid]
            if row and row.type == q.type and not kept[row.id] then
                kept[row.id] = true
                tx:add([[UPDATE campus_english_questions SET position = ?, prompt = ?, data = ?, solution = ?, explanation = ?,
                         points = ?, difficulty = ?, theme = ?, updated_at = ? WHERE id = ?]],
                    j, q.prompt, json(q.data), json(q.solution), q.explanation, q.points, q.difficulty, q.theme, t, row.id)
            else
                tx:add([[INSERT INTO campus_english_questions
                         (uid, exercise_id, position, type, prompt, data, solution, explanation, points, difficulty, theme, created_at, updated_at)
                         SELECT ?, id, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? FROM campus_english_exercises WHERE uid = ?]],
                    U.uid(), j, q.type, q.prompt, json(q.data), json(q.solution), q.explanation, q.points, q.difficulty, q.theme, t, t, exerciseUid)
            end
        end
        local removed = {}
        for _, r in pairs(existing) do
            if not kept[r.id] then removed[#removed + 1] = r.id end
        end
        if #removed > 0 then
            tx:add(('DELETE FROM campus_english_questions WHERE id IN (%s)'):format(DB.placeholders(#removed)), table.unpack(removed))
        end
    end
    tx:commit()
    Assessments.Forget(id)
end

function Assessments.Save(ctx, input)
    local p = ctx.profile
    local x = parseAssessment(p, input)
    if x.id then
        local current = DB.single('SELECT id, teacher_id, status, closes_at FROM campus_english_assignments WHERE id = ?', x.id)
        if not current then EC.Fail('not_found') end
        Permissions.RequireOwner(p, current.teacher_id)
        local locked = hasAttempts(x.id)
        if current.status == 'published' and not locked and #x.questions == 0 then
            EC.Fail('assessment_incomplete', 'no_question')
        end
        EC.WithLock('assessment:save:' .. x.id, persist, x.id, x, locked)
        Rpc.Audit(ctx, 'assessment.save', x.id, { title = x.title, locked = locked })
        return x.id, locked
    end
    Permissions.Require(p, 'assessments.create')
    local t = now()
    local id = DB.insert([[
        INSERT INTO campus_english_assignments (teacher_id, title, status, created_at, updated_at)
        VALUES (?, ?, 'draft', ?, ?)
    ]], p.campusId, x.title, t, t)
    local ok, err = pcall(persist, id, x, false)
    if not ok then
        DB.update('DELETE FROM campus_english_assignments WHERE id = ?', id)
        error(err, 0)
    end
    Rpc.Audit(ctx, 'assessment.create', id, { title = x.title })
    return id, false
end

function Assessments.SetStatus(ctx, id, status)
    local st = Assessments.ForOwner(ctx.profile, id)
    local a = st.a
    if a.status == status then return status end
    local t = now()
    if status == 'published' then
        if #st.classIds == 0 then EC.Fail('assessment_incomplete', 'no_class') end
        if #st.questions == 0 then EC.Fail('assessment_incomplete', 'no_question') end
        if a.closes_at and a.closes_at <= t then EC.Fail('assessment_incomplete', 'closed') end
        DB.update("UPDATE campus_english_assignments SET status = 'published', published_at = COALESCE(published_at, ?), updated_at = ? WHERE id = ?", t, t, id)
        Assessments.Forget(id)
        if not a.announced_at and (not a.opens_at or a.opens_at <= t) then Assessments.Announce(id) end
    else
        DB.update('UPDATE campus_english_assignments SET status = ?, updated_at = ? WHERE id = ?', status, t, id)
        Assessments.Forget(id)
    end
    Rpc.Audit(ctx, 'assessment.status', id, { from = a.status, to = status })
    return status
end

-- ─────────────────────────────────────────────────────────────────────────────
--  RPC élève
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('assessments:list', { cap = 'assessments.take' }, function(ctx)
    return Assessments.StudentList(ctx.profile)
end)

Rpc.Register('assessment:get', { cap = 'assessments.take' }, function(ctx, data)
    local id = V.id(data.id, 'id')
    Assessments.ForStudent(ctx.profile, id)
    return Assessments.StudentCard(ctx.profile, id)
end)

Rpc.Register('assessment:start', { cap = 'assessments.take', cost = 3 }, function(ctx, data)
    return Assessments.Start(ctx, V.id(data.id, 'id'))
end)

--- Enregistrement automatique d'une réponse (non corrigée avant le rendu).
Rpc.Register('assessment:save', { cap = 'assessments.take', cost = 1 }, function(ctx, data)
    local p = ctx.profile
    local attemptId = V.id(data.attemptId, 'attemptId')
    local questionId = V.id(data.questionId, 'questionId')
    local probe = ownAttempt(p, attemptId)
    return EC.WithLock(lockKey(p.campusId, probe.assignment_id), function()
        local row = ownAttempt(p, attemptId)
        if row.status ~= 'in_progress' then EC.Fail('attempt_closed') end
        if row.expires_at and now() > row.expires_at + grace() then
            Assessments.Finalize(row, { auto = true })
            EC.Fail('attempt_expired')
        end
        local st = Assessments.Get(row.assignment_id)
        if not st then EC.Fail('not_found') end
        local allowed = U.toSet(EC.JsonDecode(row.questions, {}))
        local q = allowed[questionId] and st.questionById[questionId]
        if not q then EC.Fail('not_found') end

        local answer = Grading.sanitizeAnswer(q, data.answer)
        DB.update([[
            INSERT INTO campus_english_answers (result_id, question_id, answer, is_correct, points, max_points, graded, answered_at)
            VALUES (?, ?, ?, NULL, 0, ?, 0, ?)
            ON DUPLICATE KEY UPDATE answer = VALUES(answer), answered_at = VALUES(answered_at)
        ]], row.id, q.id, EC.JsonEncode(answer), q.points, now())
        local answered = DB.scalar('SELECT COUNT(*) FROM campus_english_answers WHERE result_id = ?', row.id) or 0
        Live.Emit('assessment:' .. row.assignment_id, {
            studentId = p.campusId, name = p.displayName, classId = p.classId,
            status = 'in_progress', answered = answered, total = #EC.JsonDecode(row.questions, {}),
        })
        return { saved = true, answered = answered, serverNow = now() }
    end)
end)

--- Rendu de la copie : correction complète côté serveur.
Rpc.Register('assessment:submit', { cap = 'assessments.take', cost = 3 }, function(ctx, data)
    local p = ctx.profile
    local attemptId = V.id(data.attemptId, 'attemptId')
    local probe = ownAttempt(p, attemptId)
    local row = EC.WithLock(lockKey(p.campusId, probe.assignment_id), function()
        local current = ownAttempt(p, attemptId)
        if current.status ~= 'in_progress' then return current end
        return Assessments.Finalize(current, { auto = false })
    end)
    local st = Assessments.Get(row.assignment_id)
    if not st then EC.Fail('not_found') end
    Rpc.Audit(ctx, 'assessment.submit', row.assignment_id, { attempt = row.id, grade = row.grade })
    return Assessments.ResultView(row, st, true)
end)

--- Résultat d'une tentative de l'élève.
Rpc.Register('result:get', { cap = 'results.own' }, function(ctx, data)
    local row = ownAttempt(ctx.profile, V.id(data.id, 'id'))
    if row.status == 'in_progress' and row.expires_at and now() > row.expires_at + grace() then
        row = EC.WithLock(lockKey(ctx.profile.campusId, row.assignment_id), Assessments.Finalize, row, { auto = true }) or row
    end
    local st = Assessments.Get(row.assignment_id)
    if not st then EC.Fail('not_found') end
    return Assessments.ResultView(row, st, true)
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  RPC professeur
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('tassessments:list', { role = 'teacher' }, function(ctx, data)
    local p = ctx.profile
    local all = p.role == 'admin' and data.scope == 'all'
    local where, params = {}, { Config.Pedagogy.Grading.Scale or 20 }
    if not all then
        where[#where + 1] = 'a.teacher_id = ?'
        params[#params + 1] = p.campusId
    end
    if data.archived ~= true then where[#where + 1] = "a.status <> 'archived'" end
    local rows = DB.query(([[
        SELECT a.id, a.title, a.theme, a.difficulty, a.duration, a.question_count, a.max_score, a.opens_at, a.closes_at,
               a.status, a.updated_at, a.teacher_id, a.release_mode, m.first_name, m.last_name, m.title AS t_title,
               (SELECT COUNT(*) FROM campus_english_questions q JOIN campus_english_exercises e ON e.id = q.exercise_id
                 WHERE e.assignment_id = a.id) AS pool,
               (SELECT COUNT(*) FROM campus_english_results r WHERE r.assignment_id = a.id AND r.status IN ('submitted', 'graded', 'released')) AS submitted,
               (SELECT COUNT(*) FROM campus_english_results r WHERE r.assignment_id = a.id AND r.status = 'in_progress') AS running,
               (SELECT COUNT(*) FROM campus_english_results r WHERE r.assignment_id = a.id AND r.status = 'submitted') AS to_review,
               (SELECT COUNT(*) FROM campus_english_results r WHERE r.assignment_id = a.id AND r.status = 'graded') AS to_release,
               (SELECT AVG(r.grade / r.grade_max * ?) FROM campus_english_results r
                 WHERE r.assignment_id = a.id AND r.status IN ('graded', 'released') AND r.grade_max > 0) AS average
        FROM campus_english_assignments a
        LEFT JOIN campus_english_members m ON m.campus_id = a.teacher_id
        %s
        ORDER BY a.updated_at DESC LIMIT 300
    ]]):format(#where > 0 and ('WHERE ' .. table.concat(where, ' AND ')) or ''), table.unpack(params))

    local out = {}
    for i, row in ipairs(rows) do
        local count = (row.question_count > 0 and row.question_count < row.pool) and row.question_count or row.pool
        out[i] = {
            id = row.id, title = row.title, theme = row.theme, difficulty = row.difficulty, duration = row.duration,
            questionCount = count, pool = row.pool, maxScore = row.max_score, opensAt = row.opens_at, closesAt = row.closes_at,
            status = row.status, window = Assessments.Window(row), updatedAt = row.updated_at, releaseMode = row.release_mode,
            teacher = EC.TeacherName(row.t_title, row.first_name, row.last_name), mine = row.teacher_id == p.campusId,
            submitted = row.submitted, running = row.running, toReview = row.to_review, toRelease = row.to_release,
            average = row.average and U.round(tonumber(row.average), 2) or nil,
        }
    end
    return out
end)

Rpc.Register('tassessment:get', { role = 'teacher' }, function(ctx, data)
    local st = Assessments.ForOwner(ctx.profile, V.id(data.id, 'id'))
    return Assessments.EditorPayload(st.a.id)
end)

Rpc.Register('tassessment:save', { role = 'teacher', cap = 'assessments.create', cost = 5 }, function(ctx, data)
    local id, locked = Assessments.Save(ctx, data.assessment)
    local status = data.publish == true and Assessments.SetStatus(ctx, id, 'published') or nil
    return { id = id, locked = locked, status = status, assessment = Assessments.EditorPayload(id) }
end)

Rpc.Register('tassessment:status', { role = 'teacher', cap = 'assessments.create', cost = 3 }, function(ctx, data)
    local id = V.id(data.id, 'id')
    local status = V.enum(data.status, EC.Const.AssessmentStatus, 'status')
    return { status = Assessments.SetStatus(ctx, id, status) }
end)

Rpc.Register('tassessment:duplicate', { role = 'teacher', cap = 'assessments.create', cost = 5 }, function(ctx, data)
    local payload = Assessments.EditorPayload(V.id(data.id, 'id'))
    Permissions.RequireOwner(ctx.profile, payload.teacherId)
    payload.id = nil
    local suffix = Config.Locale == 'en' and ' (copy)' or ' (copie)'
    payload.title = U.utf8sub(payload.title, Config.Pedagogy.Limits.CourseTitle - utf8.len(suffix)) .. suffix
    payload.opensAt, payload.closesAt = nil, nil
    for _, q in ipairs(payload.questions) do q.uid, q.id = nil, nil end
    local classIds = {}
    for _, id in ipairs(payload.classIds) do
        if Permissions.CanAccessClass(ctx.profile, id) then classIds[#classIds + 1] = id end
    end
    payload.classIds = classIds
    if payload.courseId and not Permissions.Owns(ctx.profile, DB.scalar('SELECT teacher_id FROM campus_english_courses WHERE id = ?', payload.courseId)) then
        payload.courseId = nil
    end
    local id = Assessments.Save(ctx, payload)
    return { id = id }
end)

Rpc.Register('tassessment:delete', { role = 'teacher', cap = 'assessments.create', cost = 3 }, function(ctx, data)
    local id = V.id(data.id, 'id')
    local st = Assessments.ForOwner(ctx.profile, id)
    if ctx.profile.role ~= 'admin' and hasAttempts(id) then EC.Fail('assessment_has_results') end
    local tx = DB.transaction()
    tx:add("UPDATE campus_english_course_sections SET ref_id = NULL WHERE type = 'assessment' AND ref_id = ?", id)
    tx:add('DELETE FROM campus_english_assignments WHERE id = ?', id)
    tx:commit()
    Assessments.Forget(id)
    EC.CacheForget('course:')
    Rpc.Audit(ctx, 'assessment.delete', id, { title = st.a.title })
    return true
end)

--[[
    English Campus — cours.

    Un cours = des métadonnées + des classes cibles + une suite ordonnée de parties :
      text        titre + texte mis en forme
      vocabulary  liste de mots (anglais → traduction)
      exercise    série de questions corrigées par le serveur
      assessment  lien vers une évaluation (ex. « Évaluation finale »)

    Élève      : ne voit que les cours publiés pour SA classe, sans aucune solution.
    Professeur : crée / modifie / publie / duplique SES cours (l'admin : tous).
]]

local U = EC.U

Courses = {}

local CACHE_TTL = 300

-- ─────────────────────────────────────────────────────────────────────────────
--  Structure d'un cours (mise en cache, partagée par tous les élèves d'une classe)
-- ─────────────────────────────────────────────────────────────────────────────

function Courses.Forget(courseId)
    EC.CacheForget('course:' .. courseId)
end

--- Charge la structure complète d'un cours (ne pas modifier la table retournée).
function Courses.Structure(courseId)
    local key = 'course:' .. courseId
    local cached = EC.CacheGet(key)
    if cached then return cached end

    local course = DB.single('SELECT * FROM campus_english_courses WHERE id = ?', courseId)
    if not course then return nil end

    local classIds = {}
    for _, row in ipairs(DB.query('SELECT class_id FROM campus_english_course_classes WHERE course_id = ?', courseId)) do
        classIds[#classIds + 1] = row.class_id
    end

    local sections, sectionById = {}, {}
    for _, row in ipairs(DB.query('SELECT * FROM campus_english_course_sections WHERE course_id = ? ORDER BY position, id', courseId)) do
        local section = {
            id = row.id, uid = row.uid, type = row.type, title = row.title, position = row.position,
            content = EC.JsonDecode(row.content, {}), refId = row.ref_id,
        }
        sections[#sections + 1] = section
        sectionById[section.id] = section
    end

    local exerciseById = {}
    for _, row in ipairs(DB.query('SELECT id, uid, section_id, title, instructions FROM campus_english_exercises WHERE course_id = ? AND section_id IS NOT NULL', courseId)) do
        local exercise = { id = row.id, uid = row.uid, sectionId = row.section_id, title = row.title, instructions = row.instructions, questions = {} }
        exerciseById[row.id] = exercise
        local section = sectionById[row.section_id]
        if section then section.exercise = exercise end
    end

    local questionById = {}
    if next(exerciseById) then
        for _, row in ipairs(DB.query([[
            SELECT q.* FROM campus_english_questions q
            JOIN campus_english_exercises e ON e.id = q.exercise_id
            WHERE e.course_id = ? AND e.section_id IS NOT NULL
            ORDER BY q.exercise_id, q.position, q.id
        ]], courseId)) do
            local exercise = exerciseById[row.exercise_id]
            if exercise then
                local q = Questions.decode(row)
                q.sectionId = exercise.sectionId
                exercise.questions[#exercise.questions + 1] = q
                questionById[q.id] = q
            end
        end
    end

    for _, row in ipairs(DB.query('SELECT id, uid, section_id, term, translation, example FROM campus_english_vocabulary WHERE course_id = ? ORDER BY section_id, position, id', courseId)) do
        local section = sectionById[row.section_id]
        if section then
            section.words = section.words or {}
            section.words[#section.words + 1] = { id = row.id, uid = row.uid, term = row.term, translation = row.translation, example = row.example }
        end
    end
    for _, section in ipairs(sections) do
        if section.type == 'vocabulary' then section.words = section.words or {} end
    end

    local teacher = DB.single('SELECT first_name, last_name, title FROM campus_english_members WHERE campus_id = ?', course.teacher_id)
    local structure = {
        course       = course,
        classIds     = classIds,
        classSet     = U.toSet(classIds),
        sections     = sections,
        sectionById  = sectionById,
        questionById = questionById,
        teacherName  = teacher and EC.TeacherName(teacher.title, teacher.first_name, teacher.last_name) or '—',
    }
    return EC.CacheSet(key, structure, CACHE_TTL)
end

--- Structure accessible à un élève (publiée + destinée à sa classe), sinon 'not_found'.
function Courses.ForStudent(profile, courseId)
    local st = Courses.Structure(courseId)
    if not st or st.course.status ~= 'published' or not profile.classId or not st.classSet[profile.classId] then
        EC.Fail('not_found')
    end
    return st
end

--- Structure modifiable par le professeur (propriétaire ou admin), sinon 'not_found' / 'forbidden'.
function Courses.ForOwner(profile, courseId)
    local st = Courses.Structure(courseId)
    if not st then EC.Fail('not_found') end
    Permissions.RequireOwner(profile, st.course.teacher_id)
    return st
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Progression
-- ─────────────────────────────────────────────────────────────────────────────

function Courses.DoneSet(studentId, courseId)
    local set = {}
    for _, row in ipairs(DB.query('SELECT section_id FROM campus_english_progress_sections WHERE student_id = ? AND course_id = ?', studentId, courseId)) do
        set[row.section_id] = true
    end
    return set
end

function Courses.ProgressOf(st, doneSet)
    local total, done = #st.sections, 0
    for _, section in ipairs(st.sections) do
        if doneSet[section.id] then done = done + 1 end
    end
    return {
        done      = done,
        total     = total,
        percent   = total > 0 and math.floor(done / total * 100) or 0,
        completed = total > 0 and done >= total,
    }
end

local function liveEntry(profile, extra)
    local entry = {
        studentId = profile.campusId,
        name      = profile.displayName,
        classId   = profile.classId,
    }
    for k, v in pairs(extra or {}) do entry[k] = v end
    return entry
end

--- Recalcule la progression d'un élève sur un cours et met à jour son statut.
function Courses.RefreshProgress(profile, st, lastSectionId)
    local progress = Courses.ProgressOf(st, Courses.DoneSet(profile.campusId, st.course.id))
    local t = EC.Now()
    if progress.completed then
        local changed = DB.update([[
            UPDATE campus_english_progress
            SET status = 'completed', completed_at = COALESCE(completed_at, ?), updated_at = ?, last_section_id = COALESCE(?, last_section_id)
            WHERE student_id = ? AND course_id = ? AND status <> 'completed'
        ]], t, t, lastSectionId, profile.campusId, st.course.id)
        progress.justCompleted = changed > 0
    end
    if not progress.justCompleted then
        DB.update('UPDATE campus_english_progress SET updated_at = ?, last_section_id = COALESCE(?, last_section_id) WHERE student_id = ? AND course_id = ?',
            t, lastSectionId, profile.campusId, st.course.id)
    end
    Live.Emit('course:' .. st.course.id, liveEntry(profile, {
        percent = progress.percent, done = progress.done, total = progress.total, completed = progress.completed,
    }))
    return progress
end

--- Démarre le suivi d'un cours (idempotent).
function Courses.EnsureStarted(profile, courseId, sectionId)
    local t = EC.Now()
    DB.update([[
        INSERT IGNORE INTO campus_english_progress (student_id, course_id, status, last_section_id, started_at, updated_at)
        VALUES (?, ?, 'in_progress', ?, ?, ?)
    ]], profile.campusId, courseId, sectionId, t, t)
end

--- Marque une partie comme terminée pour l'élève.
function Courses.MarkSectionDone(profile, st, section)
    Courses.EnsureStarted(profile, st.course.id, section.id)
    DB.update('INSERT IGNORE INTO campus_english_progress_sections (student_id, section_id, course_id, completed_at) VALUES (?, ?, ?, ?)',
        profile.campusId, section.id, st.course.id, EC.Now())
    return Courses.RefreshProgress(profile, st, section.id)
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Vues élève
-- ─────────────────────────────────────────────────────────────────────────────

--- Retour de correction affiché après une réponse (contient la solution : l'élève a déjà répondu).
function Courses.Feedback(q, answer, graded)
    return {
        correct     = graded.correct,
        points      = graded.points,
        max         = graded.max,
        typo        = graded.typo,
        partial     = graded.partial,
        pending     = graded.pending,
        detail      = graded.detail,
        answer      = answer,
        solution    = Grading.solutionView(q),
        explanation = q.explanation,
    }
end

local function stateOf(total, done, progressStatus)
    if total > 0 and done >= total then return 'completed' end
    if progressStatus then return 'started' end
    return 'new'
end

--- Liste des cours disponibles pour l'élève (avec sa progression).
function Courses.StudentList(profile)
    if not profile.classId then return {} end
    local rows = DB.query([[
        SELECT c.id, c.title, c.description, c.theme, c.level, c.duration, c.emblem, c.published_at, c.updated_at,
               m.first_name AS t_first, m.last_name AS t_last, m.title AS t_title,
               (SELECT COUNT(*) FROM campus_english_course_sections s WHERE s.course_id = c.id) AS total,
               (SELECT COUNT(*) FROM campus_english_progress_sections ps WHERE ps.course_id = c.id AND ps.student_id = ?) AS done,
               p.status AS p_status, p.updated_at AS p_updated, p.last_section_id
        FROM campus_english_courses c
        JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
        LEFT JOIN campus_english_members m ON m.campus_id = c.teacher_id
        LEFT JOIN campus_english_progress p ON p.course_id = c.id AND p.student_id = ?
        WHERE c.status = 'published'
        ORDER BY c.published_at DESC
    ]], profile.campusId, profile.classId, profile.campusId)

    local out = {}
    for i, row in ipairs(rows) do
        local total, done = row.total or 0, row.done or 0
        out[i] = {
            id          = row.id,
            title       = row.title,
            description = row.description,
            theme       = row.theme,
            level       = row.level,
            duration    = row.duration,
            emblem      = row.emblem,
            teacher     = EC.TeacherName(row.t_title, row.t_first, row.t_last),
            publishedAt = row.published_at,
            activityAt  = row.p_updated,
            total       = total,
            done        = done,
            percent     = total > 0 and math.floor(done / total * 100) or 0,
            state       = stateOf(total, done, row.p_status),
        }
    end
    return out
end

--- Contenu complet d'un cours pour l'élève (ou l'aperçu du professeur si opts.preview).
function Courses.StudentPayload(profile, st, opts)
    opts = opts or {}
    local course = st.course
    local doneSet, practice, answers, progressRow = {}, {}, {}, nil

    if not opts.preview then
        doneSet = Courses.DoneSet(profile.campusId, course.id)
        progressRow = DB.single('SELECT status, last_section_id, started_at FROM campus_english_progress WHERE student_id = ? AND course_id = ?',
            profile.campusId, course.id)
        for _, row in ipairs(DB.query([[
            SELECT id, exercise_id, status, score, max_points, percent, best_percent
            FROM campus_english_results WHERE student_id = ? AND course_id = ? AND kind = 'practice'
        ]], profile.campusId, course.id)) do
            practice[row.exercise_id] = row
        end
        for _, row in ipairs(DB.query([[
            SELECT a.question_id, a.answer, a.is_correct, a.points, a.max_points, a.graded
            FROM campus_english_answers a
            JOIN campus_english_results r ON r.id = a.result_id
            WHERE r.student_id = ? AND r.course_id = ? AND r.kind = 'practice'
        ]], profile.campusId, course.id)) do
            answers[row.question_id] = row
        end
    end

    local sections = {}
    for i, s in ipairs(st.sections) do
        local out = { id = s.id, type = s.type, title = s.title, done = doneSet[s.id] == true }
        if s.type == 'text' then
            out.body = s.content.body or ''
        elseif s.type == 'vocabulary' then
            out.words = {}
            for j, w in ipairs(s.words or {}) do
                out.words[j] = { id = w.id, term = w.term, translation = w.translation, example = w.example }
            end
        elseif s.type == 'exercise' then
            local exercise = s.exercise or { questions = {} }
            out.instructions = exercise.instructions
            out.questions = {}
            local answered = 0
            for j, q in ipairs(exercise.questions) do
                local view = Questions.toStudent(q, { shuffleOptions = false })
                local stored = answers[q.id]
                if stored then
                    answered = answered + 1
                    local graded = { points = stored.points, max = stored.max_points, pending = not U.bool(stored.graded) }
                    if stored.is_correct ~= nil then graded.correct = U.bool(stored.is_correct) end
                    view.feedback = Courses.Feedback(q, EC.JsonDecode(stored.answer, {}), graded)
                end
                out.questions[j] = view
            end
            out.answered = answered
            local result = exercise.id and practice[exercise.id]
            if result then
                out.result = {
                    status = result.status, score = result.score, maxPoints = result.max_points,
                    percent = result.percent, bestPercent = result.best_percent,
                }
            end
        elseif s.type == 'assessment' then
            out.assessment = s.refId and Assessments.StudentCard(profile, s.refId, opts.preview) or nil
        end
        sections[i] = out
    end

    local progress = Courses.ProgressOf(st, doneSet)
    progress.status = progressRow and progressRow.status or nil
    progress.lastSectionId = progressRow and progressRow.last_section_id or nil

    return {
        id          = course.id,
        title       = course.title,
        description = course.description,
        theme       = course.theme,
        level       = course.level,
        duration    = course.duration,
        emblem      = course.emblem,
        status      = course.status,
        teacher     = st.teacherName,
        publishedAt = course.published_at,
        classes     = Classes.Labels(st.classIds),
        sections    = sections,
        progress    = progress,
        preview     = opts.preview == true,
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
--  Éditeur (professeur)
-- ─────────────────────────────────────────────────────────────────────────────

function Courses.EditorPayload(courseId)
    local st = Courses.Structure(courseId)
    if not st then EC.Fail('not_found') end
    local c = st.course
    local sections = {}
    for i, s in ipairs(st.sections) do
        local out = { uid = s.uid, type = s.type, title = s.title }
        if s.type == 'text' then
            out.body = s.content.body or ''
        elseif s.type == 'vocabulary' then
            out.words = {}
            for j, w in ipairs(s.words or {}) do
                out.words[j] = { uid = w.uid, term = w.term, translation = w.translation, example = w.example }
            end
        elseif s.type == 'exercise' then
            local exercise = s.exercise or { questions = {} }
            out.instructions = exercise.instructions
            out.questions = {}
            for j, q in ipairs(exercise.questions) do out.questions[j] = Questions.toEditor(q) end
        elseif s.type == 'assessment' then
            out.assessmentId = s.refId
            local a = s.refId and DB.single('SELECT title, status FROM campus_english_assignments WHERE id = ?', s.refId)
            out.assessmentTitle = a and a.title or nil
        end
        sections[i] = out
    end
    local stats = DB.single([[
        SELECT COUNT(*) AS started, COALESCE(SUM(status = 'completed'), 0) AS completed
        FROM campus_english_progress WHERE course_id = ?
    ]], courseId) or {}
    return {
        id          = c.id,
        title       = c.title,
        description = c.description or '',
        theme       = c.theme,
        level       = c.level,
        duration    = c.duration,
        emblem      = c.emblem,
        status      = c.status,
        teacherId   = c.teacher_id,
        teacher     = st.teacherName,
        publishedAt = c.published_at,
        updatedAt   = c.updated_at,
        classIds    = st.classIds,
        sections    = sections,
        stats       = { started = tonumber(stats.started) or 0, completed = tonumber(stats.completed) or 0 },
    }
end

--- Valide le cours envoyé par l'éditeur. Aucune donnée n'est écrite ici.
local function parseCourse(profile, input)
    local L = Config.Pedagogy.Limits
    local c = V.table(input, 'course')
    local out = {
        id          = V.optId(c.id, 'course.id'),
        title       = V.str(c.title, L.CourseTitle, 'course.title', { min = 2 }),
        description = V.str(c.description, L.CourseDescription, 'course.description', { multiline = true, optional = true, default = '' }),
        theme       = V.enum(c.theme, EC.Const.Themes, 'course.theme', 'grammar'),
        level       = V.int(c.level, 1, 3, 'course.level', 1),
        duration    = V.int(c.duration, 1, 600, 'course.duration', Config.Pedagogy.DefaultCourseDuration),
        emblem      = V.enum(c.emblem, EC.Const.Emblems, 'course.emblem', 'book'),
        classIds    = Permissions.FilterClasses(profile, V.idList(c.classIds, 50, 'course.classIds', true)),
        sections    = {},
    }

    local questionCount = 0
    for i, s in ipairs(V.list(c.sections, L.SectionsPerCourse, 'course.sections', true)) do
        local f = ('sections[%d]'):format(i)
        V.table(s, f)
        local section = {
            type  = V.enum(s.type, EC.Const.SectionTypes, f .. '.type'),
            uid   = U.isUid(s.uid) and s.uid or nil,
            title = V.str(s.title, L.SectionTitle, f .. '.title', { optional = true, default = '' }),
        }
        if section.type == 'text' then
            section.content = { body = V.str(s.body, L.TextBody, f .. '.body', { multiline = true, optional = true, default = '' }) }
        elseif section.type == 'vocabulary' then
            section.words = {}
            for j, w in ipairs(V.list(s.words, L.WordsPerVocabulary, f .. '.words', true)) do
                local wf = ('%s.words[%d]'):format(f, j)
                V.table(w, wf)
                section.words[#section.words + 1] = {
                    uid         = U.isUid(w.uid) and w.uid or nil,
                    term        = V.str(w.term, L.VocabularyTerm, wf .. '.term'),
                    translation = V.str(w.translation, L.VocabularyTerm, wf .. '.translation'),
                    example     = V.str(w.example, 255, wf .. '.example', { optional = true }),
                }
            end
        elseif section.type == 'exercise' then
            section.instructions = V.str(s.instructions, L.Explanation, f .. '.instructions', { multiline = true, optional = true })
            section.questions = {}
            for j, q in ipairs(V.list(s.questions, L.QuestionsPerExercise, f .. '.questions', true)) do
                section.questions[j] = Questions.fromEditor(q, ('%s.questions[%d]'):format(f, j))
                questionCount = questionCount + 1
            end
        elseif section.type == 'assessment' then
            section.refId = V.id(s.assessmentId, f .. '.assessmentId')
            local owner = DB.scalar('SELECT teacher_id FROM campus_english_assignments WHERE id = ?', section.refId)
            if not owner then EC.Fail('bad_request', f .. '.assessmentId:not_found') end
            Permissions.RequireOwner(profile, owner)
            section.content = {}
        end
        out.sections[i] = section
    end
    if questionCount > 400 then EC.Fail('bad_request', 'course:too_many_questions') end
    return out
end

--- Conditions pour qu'un cours soit visible par les élèves.
local function publishProblem(parsedOrStructure)
    if #parsedOrStructure.classIds == 0 then return 'no_class' end
    if #parsedOrStructure.sections == 0 then return 'no_section' end
    for i, s in ipairs(parsedOrStructure.sections) do
        if s.type == 'exercise' then
            local questions = s.questions or (s.exercise and s.exercise.questions) or {}
            if #questions == 0 then return 'empty_exercise:' .. i end
        end
    end
    return nil
end

--- Écrit le cours en base (transaction unique). Les éléments existants sont reconnus par leur uid.
local function persist(courseId, c, isNew)
    local now = EC.Now()
    local json = EC.JsonEncode
    local existingSections, existingExercises, existingQuestions, existingWords = {}, {}, {}, {}
    if not isNew then
        for _, r in ipairs(DB.query('SELECT id, uid, type FROM campus_english_course_sections WHERE course_id = ?', courseId)) do
            existingSections[r.uid] = r
        end
        for _, r in ipairs(DB.query('SELECT id, uid, section_id FROM campus_english_exercises WHERE course_id = ? AND section_id IS NOT NULL', courseId)) do
            existingExercises[r.section_id] = r
        end
        for _, r in ipairs(DB.query([[
            SELECT q.id, q.uid, q.type, q.exercise_id FROM campus_english_questions q
            JOIN campus_english_exercises e ON e.id = q.exercise_id
            WHERE e.course_id = ? AND e.section_id IS NOT NULL
        ]], courseId)) do
            existingQuestions[r.uid] = r
        end
        for _, r in ipairs(DB.query('SELECT id, uid, section_id FROM campus_english_vocabulary WHERE course_id = ?', courseId)) do
            existingWords[r.uid] = r
        end
    end

    local tx = DB.transaction()
    tx:add('UPDATE campus_english_courses SET title = ?, description = ?, theme = ?, level = ?, duration = ?, emblem = ?, updated_at = ? WHERE id = ?',
        c.title, c.description, c.theme, c.level, c.duration, c.emblem, now, courseId)
    tx:add('DELETE FROM campus_english_course_classes WHERE course_id = ?', courseId)
    for _, classId in ipairs(c.classIds) do
        tx:add('INSERT INTO campus_english_course_classes (course_id, class_id) VALUES (?, ?)', courseId, classId)
    end

    -- Identité des parties : une partie existante garde son id (et donc la progression des élèves).
    local keptSections = {}
    for _, s in ipairs(c.sections) do
        local existing = s.uid and existingSections[s.uid]
        if existing and existing.type == s.type and not keptSections[existing.id] then
            s.id = existing.id
            keptSections[existing.id] = true
        else
            s.id, s.uid = nil, U.uid()
        end
    end
    local removedSections = {}
    for _, r in pairs(existingSections) do
        if not keptSections[r.id] then removedSections[#removedSections + 1] = r.id end
    end
    if #removedSections > 0 then
        tx:add(('DELETE FROM campus_english_course_sections WHERE id IN (%s)'):format(DB.placeholders(#removedSections)), table.unpack(removedSections))
    end

    local keptQuestions, keptWords = {}, {}
    for i, s in ipairs(c.sections) do
        local content = s.content and json(s.content) or nil
        if s.id then
            tx:add('UPDATE campus_english_course_sections SET position = ?, title = ?, content = ?, ref_id = ?, updated_at = ? WHERE id = ?',
                i, s.title, content, s.refId, now, s.id)
        else
            tx:add('INSERT INTO campus_english_course_sections (uid, course_id, position, type, title, content, ref_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                s.uid, courseId, i, s.type, s.title, content, s.refId, now, now)
        end

        if s.type == 'exercise' then
            local exerciseRow = s.id and existingExercises[s.id]
            local exerciseUid
            if exerciseRow then
                exerciseUid = exerciseRow.uid
                tx:add('UPDATE campus_english_exercises SET title = ?, instructions = ?, updated_at = ? WHERE id = ?',
                    s.title, s.instructions, now, exerciseRow.id)
            else
                exerciseUid = U.uid()
                tx:add([[INSERT INTO campus_english_exercises (uid, course_id, section_id, title, instructions, created_at, updated_at)
                         SELECT ?, ?, id, ?, ?, ?, ? FROM campus_english_course_sections WHERE uid = ?]],
                    exerciseUid, courseId, s.title, s.instructions, now, now, s.uid)
            end
            for j, q in ipairs(s.questions) do
                local existing = q.uid and existingQuestions[q.uid]
                if existing and exerciseRow and existing.exercise_id == exerciseRow.id and existing.type == q.type and not keptQuestions[existing.id] then
                    keptQuestions[existing.id] = true
                    tx:add([[UPDATE campus_english_questions SET position = ?, prompt = ?, data = ?, solution = ?, explanation = ?,
                             points = ?, difficulty = ?, theme = ?, updated_at = ? WHERE id = ?]],
                        j, q.prompt, json(q.data), json(q.solution), q.explanation, q.points, q.difficulty, q.theme, now, existing.id)
                else
                    tx:add([[INSERT INTO campus_english_questions
                             (uid, exercise_id, position, type, prompt, data, solution, explanation, points, difficulty, theme, created_at, updated_at)
                             SELECT ?, id, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? FROM campus_english_exercises WHERE uid = ?]],
                        U.uid(), j, q.type, q.prompt, json(q.data), json(q.solution), q.explanation, q.points, q.difficulty, q.theme, now, now, exerciseUid)
                end
            end
        elseif s.type == 'vocabulary' then
            for j, w in ipairs(s.words) do
                local existing = w.uid and existingWords[w.uid]
                if existing and s.id and existing.section_id == s.id and not keptWords[existing.id] then
                    keptWords[existing.id] = true
                    tx:add('UPDATE campus_english_vocabulary SET position = ?, term = ?, translation = ?, example = ? WHERE id = ?',
                        j, w.term, w.translation, w.example, existing.id)
                else
                    tx:add([[INSERT INTO campus_english_vocabulary (uid, section_id, course_id, position, term, translation, example, created_at)
                             SELECT ?, id, ?, ?, ?, ?, ?, ? FROM campus_english_course_sections WHERE uid = ?]],
                        U.uid(), courseId, j, w.term, w.translation, w.example, now, s.uid)
                end
            end
        end
    end

    local removedQuestions, removedWords = {}, {}
    for _, r in pairs(existingQuestions) do
        if not keptQuestions[r.id] then removedQuestions[#removedQuestions + 1] = r.id end
    end
    for _, r in pairs(existingWords) do
        if not keptWords[r.id] then removedWords[#removedWords + 1] = r.id end
    end
    if #removedQuestions > 0 then
        tx:add(('DELETE FROM campus_english_questions WHERE id IN (%s)'):format(DB.placeholders(#removedQuestions)), table.unpack(removedQuestions))
    end
    if #removedWords > 0 then
        tx:add(('DELETE FROM campus_english_vocabulary WHERE id IN (%s)'):format(DB.placeholders(#removedWords)), table.unpack(removedWords))
    end

    tx:commit()
    Courses.Forget(courseId)
end

--- Crée ou met à jour un cours. Retourne l'id.
function Courses.Save(ctx, input)
    local profile = ctx.profile
    local c = parseCourse(profile, input)
    if c.id then
        local current = DB.single('SELECT id, teacher_id, status FROM campus_english_courses WHERE id = ?', c.id)
        if not current then EC.Fail('not_found') end
        Permissions.RequireOwner(profile, current.teacher_id)
        if current.status == 'published' then
            local problem = publishProblem(c)
            if problem then EC.Fail('course_incomplete', problem) end
        end
        EC.WithLock('course:save:' .. c.id, persist, c.id, c, false)
        Rpc.Audit(ctx, 'course.save', c.id, { title = c.title })
        return c.id
    end

    Permissions.Require(profile, 'courses.create')
    local now = EC.Now()
    local id = DB.insert([[
        INSERT INTO campus_english_courses (teacher_id, title, description, theme, level, duration, emblem, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'draft', ?, ?)
    ]], profile.campusId, c.title, c.description, c.theme, c.level, c.duration, c.emblem, now, now)
    local ok, err = pcall(persist, id, c, true)
    if not ok then
        DB.update('DELETE FROM campus_english_courses WHERE id = ?', id)
        error(err, 0)
    end
    Rpc.Audit(ctx, 'course.create', id, { title = c.title })
    return id
end

--- Duplique un cours (brouillon, nouveaux identifiants).
function Courses.Duplicate(ctx, courseId)
    local payload = Courses.EditorPayload(courseId)
    Permissions.RequireOwner(ctx.profile, payload.teacherId)
    payload.id = nil
    local suffix = Config.Locale == 'en' and ' (copy)' or ' (copie)'
    payload.title = U.utf8sub(payload.title, Config.Pedagogy.Limits.CourseTitle - utf8.len(suffix)) .. suffix
    for _, s in ipairs(payload.sections) do
        s.uid = nil
        for _, q in ipairs(s.questions or {}) do q.uid, q.id = nil, nil end
        for _, w in ipairs(s.words or {}) do w.uid = nil end
    end
    -- Un admin qui duplique le cours d'un collègue n'a pas forcément accès à ses classes : on les garde si possible.
    local classIds = {}
    for _, id in ipairs(payload.classIds) do
        if Permissions.CanAccessClass(ctx.profile, id) then classIds[#classIds + 1] = id end
    end
    payload.classIds = classIds
    return Courses.Save(ctx, payload)
end

--- Publie / dépublie / archive.
function Courses.SetStatus(ctx, courseId, status)
    local st = Courses.ForOwner(ctx.profile, courseId)
    local previous = st.course.status
    if status == previous then return previous end
    local now = EC.Now()
    if status == 'published' then
        Permissions.Require(ctx.profile, 'courses.publish')
        local problem = publishProblem(st)
        if problem then EC.Fail('course_incomplete', problem) end
        DB.update("UPDATE campus_english_courses SET status = 'published', published_at = ?, updated_at = ? WHERE id = ?", now, now, courseId)
    else
        DB.update('UPDATE campus_english_courses SET status = ?, updated_at = ? WHERE id = ?', status, now, courseId)
    end
    Courses.Forget(courseId)

    if status == 'published' and Config.Notifications.OnCoursePublished then
        local teacherName = ctx.profile.role == 'teacher' and ctx.profile.teacherName or st.teacherName
        Notifications.SendToClasses(st.classIds, {
            kind       = 'course',
            title      = EC.L('notif.course.title'),
            body       = EC.L('notif.course.body', teacherName, st.course.title),
            linkType   = 'course',
            linkId     = courseId,
            senderId   = ctx.profile.campusId,
            senderName = teacherName,
        })
    end
    Rpc.Audit(ctx, 'course.status', courseId, { from = previous, to = status })
    return status
end

-- ─────────────────────────────────────────────────────────────────────────────
--  RPC élève
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('courses:list', { cap = 'courses.view' }, function(ctx)
    return Courses.StudentList(ctx.profile)
end)

Rpc.Register('course:get', { cap = 'courses.view' }, function(ctx, data)
    local st = Courses.ForStudent(ctx.profile, V.id(data.id, 'id'))
    return Courses.StudentPayload(ctx.profile, st)
end)

Rpc.Register('course:start', { cap = 'courses.view' }, function(ctx, data)
    local st = Courses.ForStudent(ctx.profile, V.id(data.id, 'id'))
    Courses.EnsureStarted(ctx.profile, st.course.id, st.sections[1] and st.sections[1].id or nil)
    return Courses.RefreshProgress(ctx.profile, st, nil)
end)

--- Partie de lecture (texte / vocabulaire) terminée.
Rpc.Register('course:section:done', { cap = 'courses.view' }, function(ctx, data)
    local st = Courses.ForStudent(ctx.profile, V.id(data.courseId, 'courseId'))
    local section = st.sectionById[V.id(data.sectionId, 'sectionId')]
    if not section then EC.Fail('not_found') end
    if section.type ~= 'text' and section.type ~= 'vocabulary' then EC.Fail('bad_request', 'section_type') end
    return Courses.MarkSectionDone(ctx.profile, st, section)
end)

-- ─────────────────────────────────────────────────────────────────────────────
--  RPC professeur
-- ─────────────────────────────────────────────────────────────────────────────

Rpc.Register('tcourses:list', { role = 'teacher' }, function(ctx, data)
    local p = ctx.profile
    local all = p.role == 'admin' and data.scope == 'all'
    local archived = data.archived == true
    local where, params = {}, {}
    if not all then
        where[#where + 1] = 'c.teacher_id = ?'
        params[#params + 1] = p.campusId
    end
    if not archived then where[#where + 1] = "c.status <> 'archived'" end
    local rows = DB.query(([[
        SELECT c.id, c.title, c.theme, c.level, c.duration, c.emblem, c.status, c.published_at, c.updated_at, c.teacher_id,
               m.first_name, m.last_name, m.title AS t_title,
               (SELECT COUNT(*) FROM campus_english_course_sections s WHERE s.course_id = c.id) AS sections,
               (SELECT COUNT(*) FROM campus_english_progress pr WHERE pr.course_id = c.id) AS started,
               (SELECT COUNT(*) FROM campus_english_progress pr WHERE pr.course_id = c.id AND pr.status = 'completed') AS completed
        FROM campus_english_courses c
        LEFT JOIN campus_english_members m ON m.campus_id = c.teacher_id
        %s
        ORDER BY c.updated_at DESC LIMIT 300
    ]]):format(#where > 0 and ('WHERE ' .. table.concat(where, ' AND ')) or ''), table.unpack(params))

    local ids, byId, out = {}, {}, {}
    for i, row in ipairs(rows) do
        local item = {
            id = row.id, title = row.title, theme = row.theme, level = row.level, duration = row.duration,
            emblem = row.emblem, status = row.status, publishedAt = row.published_at, updatedAt = row.updated_at,
            teacher = EC.TeacherName(row.t_title, row.first_name, row.last_name), mine = row.teacher_id == p.campusId,
            sections = row.sections, started = row.started, completed = row.completed, classes = {},
        }
        out[i], byId[row.id], ids[#ids + 1] = item, item, row.id
    end
    if #ids > 0 then
        for _, row in ipairs(DB.query(('SELECT course_id, class_id FROM campus_english_course_classes WHERE course_id IN (%s)'):format(DB.placeholders(#ids)), table.unpack(ids))) do
            local item = byId[row.course_id]
            local label = Classes.Label(row.class_id)
            if item and label then item.classes[#item.classes + 1] = label end
        end
    end
    return out
end)

Rpc.Register('tcourse:get', { role = 'teacher' }, function(ctx, data)
    local st = Courses.ForOwner(ctx.profile, V.id(data.id, 'id'))
    return Courses.EditorPayload(st.course.id)
end)

Rpc.Register('tcourse:save', { role = 'teacher', cap = 'courses.edit', cost = 5 }, function(ctx, data)
    local id = Courses.Save(ctx, data.course)
    local status = data.publish == true and Courses.SetStatus(ctx, id, 'published') or nil
    return { id = id, status = status, course = Courses.EditorPayload(id) }
end)

Rpc.Register('tcourse:status', { role = 'teacher', cap = 'courses.edit', cost = 3 }, function(ctx, data)
    local id = V.id(data.id, 'id')
    local status = V.enum(data.status, EC.Const.CourseStatus, 'status')
    return { status = Courses.SetStatus(ctx, id, status) }
end)

Rpc.Register('tcourse:duplicate', { role = 'teacher', cap = 'courses.create', cost = 5 }, function(ctx, data)
    local id = Courses.Duplicate(ctx, V.id(data.id, 'id'))
    return { id = id }
end)

Rpc.Register('tcourse:delete', { role = 'teacher', cap = 'courses.delete', cost = 3 }, function(ctx, data)
    local id = V.id(data.id, 'id')
    local course = DB.single('SELECT id, teacher_id, title FROM campus_english_courses WHERE id = ?', id)
    if not course then EC.Fail('not_found') end
    Permissions.RequireOwner(ctx.profile, course.teacher_id)
    if ctx.profile.role ~= 'admin' then
        local used = (DB.scalar('SELECT COUNT(*) FROM campus_english_progress WHERE course_id = ?', id) or 0)
            + (DB.scalar('SELECT COUNT(*) FROM campus_english_results WHERE course_id = ?', id) or 0)
        if used > 0 then EC.Fail('course_has_results') end
    end
    DB.update('DELETE FROM campus_english_courses WHERE id = ?', id)
    Courses.Forget(id)
    Rpc.Audit(ctx, 'course.delete', id, { title = course.title })
    return true
end)

--- Aperçu élève du cours (sans enregistrer de progression).
Rpc.Register('tcourse:preview', { role = 'teacher' }, function(ctx, data)
    local st = Courses.ForOwner(ctx.profile, V.id(data.id, 'id'))
    return Courses.StudentPayload(ctx.profile, st, { preview = true })
end)

--- Correction d'une réponse dans l'aperçu (rien n'est enregistré).
Rpc.Register('tcourse:preview:answer', { role = 'teacher' }, function(ctx, data)
    local st = Courses.ForOwner(ctx.profile, V.id(data.courseId, 'courseId'))
    local q = st.questionById[V.id(data.questionId, 'questionId')]
    if not q then EC.Fail('not_found') end
    local answer = Grading.sanitizeAnswer(q, data.answer)
    return Courses.Feedback(q, answer, Grading.grade(q, answer))
end)

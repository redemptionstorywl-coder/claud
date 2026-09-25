--[[
    English Campus — exercices d'entraînement (dans les cours).

    L'élève répond question par question ; le serveur corrige immédiatement et renvoie
    la correction (bonne réponse + explication). Une question déjà répondue ne peut pas
    être « rejouée » pour améliorer le score : il faut recommencer l'exercice entier.
    Le meilleur score est conservé.
]]

local U = EC.U

Exercises = {}

--- Section « exercice » d'un cours accessible à l'élève.
local function exerciseSection(ctx, data)
    local st = Courses.ForStudent(ctx.profile, V.id(data.courseId, 'courseId'))
    local section = st.sectionById[V.id(data.sectionId, 'sectionId')]
    if not section or section.type ~= 'exercise' or not section.exercise then EC.Fail('not_found') end
    return st, section, section.exercise
end

--- Ligne de résultat d'entraînement de l'élève pour un exercice (créée si besoin).
local function practiceResult(profile, st, exercise)
    local maxPoints = 0
    for _, q in ipairs(exercise.questions) do maxPoints = maxPoints + q.points end
    DB.update([[
        INSERT IGNORE INTO campus_english_results
            (kind, student_id, class_id, course_id, exercise_id, attempt_no, status, started_at, max_points)
        VALUES ('practice', ?, ?, ?, ?, 1, 'in_progress', ?, ?)
    ]], profile.campusId, profile.classId, st.course.id, exercise.id, EC.Now(), maxPoints)
    return DB.single('SELECT * FROM campus_english_results WHERE student_id = ? AND exercise_id = ?', profile.campusId, exercise.id)
end

--- Recalcule le score d'un exercice ; termine l'exercice si toutes les questions sont répondues.
local function refreshPractice(profile, st, section, exercise, result)
    local stats = DB.single([[
        SELECT COUNT(*) AS answered,
               COALESCE(SUM(points), 0) AS score,
               COALESCE(SUM(CASE WHEN graded = 1 THEN max_points ELSE 0 END), 0) AS graded_max
        FROM campus_english_answers WHERE result_id = ?
    ]], result.id)
    local answered = tonumber(stats.answered) or 0
    local score = tonumber(stats.score) or 0
    local gradedMax = tonumber(stats.graded_max) or 0
    local total = #exercise.questions
    local percent = gradedMax > 0 and U.round(score / gradedMax * 100, 1) or nil
    local completed = total > 0 and answered >= total

    local out = {
        answered = answered, total = total, score = U.round(score, 2), percent = percent,
        completed = completed, bestPercent = result.best_percent,
    }

    if completed and result.status ~= 'completed' then
        local best = result.best_percent
        if percent and (not best or percent > best) then best = percent end
        DB.update([[
            UPDATE campus_english_results SET status = 'completed', score = ?, percent = ?, best_percent = ?, submitted_at = ?
            WHERE id = ?
        ]], score, percent, best, EC.Now(), result.id)
        out.bestPercent = best
        out.progress = Courses.MarkSectionDone(profile, st, section)
    else
        DB.update('UPDATE campus_english_results SET score = ?, percent = ? WHERE id = ?', score, percent, result.id)
        Courses.EnsureStarted(profile, st.course.id, section.id)
        out.progress = Courses.RefreshProgress(profile, st, section.id)
    end
    return out
end

-- ─────────────────────────────────────────────────────────────────────────────
--  RPC
-- ─────────────────────────────────────────────────────────────────────────────

--- Réponse à une question d'exercice : correction serveur immédiate.
Rpc.Register('exercise:answer', { cap = 'exercises.do', cost = 1 }, function(ctx, data)
    local profile = ctx.profile
    local st, section, exercise = exerciseSection(ctx, data)
    local questionId = V.id(data.questionId, 'questionId')
    local q = st.questionById[questionId]
    if not q or q.sectionId ~= section.id then EC.Fail('not_found') end

    return EC.WithLock(('practice:%s:%d'):format(profile.campusId, exercise.id), function()
        local result = practiceResult(profile, st, exercise)

        -- Déjà répondu (double clic, rechargement) : on renvoie la correction enregistrée.
        local stored = DB.single('SELECT answer, is_correct, points, max_points, graded FROM campus_english_answers WHERE result_id = ? AND question_id = ?',
            result.id, q.id)
        if stored then
            local graded = { points = stored.points, max = stored.max_points, pending = not U.bool(stored.graded) }
            if stored.is_correct ~= nil then graded.correct = U.bool(stored.is_correct) end
            local feedback = Courses.Feedback(q, EC.JsonDecode(stored.answer, {}), graded)
            feedback.alreadyAnswered = true
            feedback.exercise = refreshPractice(profile, st, section, exercise, result)
            return feedback
        end

        local answer = Grading.sanitizeAnswer(q, data.answer)
        local graded = Grading.grade(q, answer)
        local isCorrect
        if graded.correct ~= nil then isCorrect = graded.correct and 1 or 0 end
        DB.update([[
            INSERT IGNORE INTO campus_english_answers (result_id, question_id, answer, is_correct, points, max_points, graded, answered_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ]], result.id, q.id, EC.JsonEncode(answer), isCorrect, graded.points, graded.max, graded.pending and 0 or 1, EC.Now())

        local feedback = Courses.Feedback(q, answer, graded)
        feedback.exercise = refreshPractice(profile, st, section, exercise, result)
        Live.Emit('course:' .. st.course.id, {
            studentId = profile.campusId, name = profile.displayName, classId = profile.classId,
            percent = feedback.exercise.progress and feedback.exercise.progress.percent or nil,
            lastAnswer = { correct = graded.correct, section = section.title },
        })
        return feedback
    end)
end)

--- Recommencer un exercice. La tentative précédente est archivée (kind = 'practice_old') :
--- ses réponses continuent de compter dans la progression par thème, le meilleur score
--- et la partie terminée sont conservés.
Rpc.Register('exercise:reset', { cap = 'exercises.do', cost = 2 }, function(ctx, data)
    local profile = ctx.profile
    local st, _, exercise = exerciseSection(ctx, data)
    return EC.WithLock(('practice:%s:%d'):format(profile.campusId, exercise.id), function()
        local result = DB.single("SELECT id, attempt_no, best_percent FROM campus_english_results WHERE student_id = ? AND exercise_id = ? AND kind = 'practice'",
            profile.campusId, exercise.id)
        local answered = result and (DB.scalar('SELECT COUNT(*) FROM campus_english_answers WHERE result_id = ?', result.id) or 0) or 0
        if answered > 0 then
            local maxPoints = 0
            for _, q in ipairs(exercise.questions) do maxPoints = maxPoints + q.points end
            local tx = DB.transaction()
            tx:add("UPDATE campus_english_results SET kind = 'practice_old', exercise_id = NULL WHERE id = ?", result.id)
            tx:add([[
                INSERT INTO campus_english_results
                    (kind, student_id, class_id, course_id, exercise_id, attempt_no, status, started_at, max_points, best_percent)
                VALUES ('practice', ?, ?, ?, ?, ?, 'in_progress', ?, ?, ?)
            ]], profile.campusId, profile.classId, st.course.id, exercise.id, result.attempt_no + 1, EC.Now(), maxPoints, result.best_percent)
            tx:commit()
        end
        -- Nouvelles questions mélangées (ordre des mots, associations...).
        local questions = {}
        for i, q in ipairs(exercise.questions) do questions[i] = Questions.toStudent(q) end
        return { questions = questions, courseId = st.course.id }
    end)
end)

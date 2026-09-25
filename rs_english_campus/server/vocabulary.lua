--[[
    English Campus — vocabulaire et mode révision (répétition espacée).

    Les mots proviennent des parties « vocabulaire » des cours publiés pour la classe de l'élève.
    Mode révision : « Quel est le mot anglais pour : Professeur ? » → vérification serveur,
    puis le mot monte (ou redescend) dans les boîtes de Leitner pour être revu au bon moment.
]]

local U = EC.U

Vocabulary = {}

local function settings()
    return Config.Pedagogy.Vocabulary
end

--- Tous les mots accessibles à l'élève (avec sa maîtrise).
local function wordsFor(profile, courseId)
    if not profile.classId then return {} end
    local sql = [[
        SELECT v.id, v.term, v.translation, v.example, v.section_id, v.course_id,
               s.title AS section_title, c.title AS course_title, c.published_at,
               st.box, st.correct, st.wrong, st.due_at, st.last_seen_at
        FROM campus_english_vocabulary v
        JOIN campus_english_course_sections s ON s.id = v.section_id
        JOIN campus_english_courses c ON c.id = v.course_id AND c.status = 'published'
        JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
        LEFT JOIN campus_english_vocab_stats st ON st.word_id = v.id AND st.student_id = ?
    ]]
    if courseId then
        return DB.query(sql .. ' WHERE v.course_id = ? ORDER BY c.published_at DESC, s.position, v.position LIMIT 2000',
            profile.classId, profile.campusId, courseId)
    end
    return DB.query(sql .. ' ORDER BY c.published_at DESC, s.position, v.position LIMIT 2000', profile.classId, profile.campusId)
end

--- Réponses acceptées pour une traduction : « professeur / enseignant » → { professeur, enseignant }.
local function variants(text)
    local out = {}
    for part in tostring(text):gmatch('[^/;,]+') do
        local trimmed = U.trim(part)
        if trimmed ~= '' then out[#out + 1] = trimmed end
    end
    if #out == 0 then out[1] = text end
    return out
end

local function directionFor(mode)
    if mode == 'en_fr' or mode == 'fr_en' then return mode end
    return math.random() < 0.5 and 'en_fr' or 'fr_en'
end

Rpc.Register('vocab:list', { cap = 'vocabulary.use' }, function(ctx)
    local mastered = settings().MasteredBox or 4
    local groups, byKey = {}, {}
    local total, masteredCount = 0, 0
    for _, row in ipairs(wordsFor(ctx.profile)) do
        local key = row.section_id
        local group = byKey[key]
        if not group then
            group = {
                courseId = row.course_id, courseTitle = row.course_title,
                title = row.section_title ~= '' and row.section_title or row.course_title, words = {},
            }
            byKey[key] = group
            groups[#groups + 1] = group
        end
        local box = row.box or 0
        group.words[#group.words + 1] = {
            id = row.id, term = row.term, translation = row.translation, example = row.example,
            box = box, seen = row.last_seen_at ~= nil, mastered = box >= mastered,
        }
        total = total + 1
        if box >= mastered then masteredCount = masteredCount + 1 end
    end
    return { groups = groups, total = total, mastered = masteredCount, masteredBox = mastered }
end)

--- Série de révision : mots « dus » en priorité, puis les moins maîtrisés.
Rpc.Register('vocab:session', { cap = 'vocabulary.use', cost = 2 }, function(ctx, data)
    local size = V.int(data.size, 3, 40, 'size', settings().SessionSize or 10)
    local courseId = V.optId(data.courseId, 'courseId')
    local mode = V.enum(data.direction, { mixed = true, en_fr = true, fr_en = true }, 'direction', 'mixed')
    local words = wordsFor(ctx.profile, courseId)
    if #words == 0 then return { items = {} } end

    local t = EC.Now()
    local due, others = {}, {}
    for _, w in ipairs(U.shuffle(words)) do
        if not w.due_at or w.due_at <= t then due[#due + 1] = w else others[#others + 1] = w end
    end
    table.sort(due, function(a, b) return (a.box or 0) < (b.box or 0) end)
    table.sort(others, function(a, b) return (a.due_at or 0) < (b.due_at or 0) end)

    local items = {}
    for _, list in ipairs({ due, others }) do
        for _, w in ipairs(list) do
            if #items >= size then break end
            local direction = directionFor(mode)
            items[#items + 1] = {
                wordId = w.id, direction = direction,
                prompt = direction == 'fr_en' and w.translation or w.term,
                box = w.box or 0,
            }
        end
    end
    return { items = items }
end)

--- Vérifie une réponse de révision et met à jour la maîtrise du mot.
Rpc.Register('vocab:check', { cap = 'vocabulary.use' }, function(ctx, data)
    local p = ctx.profile
    local wordId = V.id(data.wordId, 'wordId')
    local direction = V.enum(data.direction, { en_fr = true, fr_en = true }, 'direction')
    local answer = V.str(data.answer, 200, 'answer', { optional = true, default = '' })
    if not p.classId then EC.Fail('not_found') end

    local word = DB.single([[
        SELECT v.id, v.term, v.translation, v.example, st.box
        FROM campus_english_vocabulary v
        JOIN campus_english_courses c ON c.id = v.course_id AND c.status = 'published'
        JOIN campus_english_course_classes cc ON cc.course_id = c.id AND cc.class_id = ?
        LEFT JOIN campus_english_vocab_stats st ON st.word_id = v.id AND st.student_id = ?
        WHERE v.id = ?
    ]], p.classId, p.campusId, wordId)
    if not word then EC.Fail('not_found') end

    local expected = direction == 'fr_en' and word.term or word.translation
    local correct, typo = Grading.matchText(answer, variants(expected), 1)
    local intervals = settings().Intervals or { 0, 3600, 86400 }
    local box = word.box or 0
    if correct then box = math.min(#intervals - 1, box + 1) else box = 0 end
    local t = EC.Now()
    DB.update([[
        INSERT INTO campus_english_vocab_stats (student_id, word_id, box, correct, wrong, last_seen_at, due_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE box = VALUES(box), correct = correct + VALUES(correct), wrong = wrong + VALUES(wrong),
            last_seen_at = VALUES(last_seen_at), due_at = VALUES(due_at)
    ]], p.campusId, wordId, box, correct and 1 or 0, correct and 0 or 1, t, t + (intervals[box + 1] or 0))

    return {
        correct = correct, typo = typo, term = word.term, translation = word.translation,
        example = word.example, box = box, mastered = box >= (settings().MasteredBox or 4),
    }
end)

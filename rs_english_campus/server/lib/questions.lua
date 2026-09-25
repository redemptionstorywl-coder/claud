--[[
    English Campus — questions : validation de l'éditeur, stockage, vues élève / professeur.

    Une question est stockée en deux parties :
      • data     : ce que l'élève peut voir (options, phrase à trous, mots à remettre en ordre...)
      • solution : la correction (JAMAIS envoyée à un élève avant sa réponse)
]]

local U = EC.U

Questions = {}

local function limits()
    return Config.Pedagogy.Limits
end

local function defaultTolerance()
    return (Config.Pedagogy.Grading and Config.Pedagogy.Grading.TypoTolerance) or 0
end

--- Liste de réponses acceptées (textes non vides, dédoublonnés).
local function acceptedList(value, field)
    local list = V.list(value, limits().AcceptedAnswers, field)
    local out, seen = {}, {}
    for i = 1, #list do
        local text = V.str(list[i], 300, field, { optional = true, default = '' })
        local key = U.normalizeAnswer(text, { ignoreAccents = false })
        if text ~= '' and not seen[key] then
            seen[key] = true
            out[#out + 1] = text
        end
    end
    if #out == 0 then EC.Fail('bad_request', field .. ':required') end
    return out
end

--- Découpe « I {go|walk} to school » en parties + réponses acceptées par trou.
---@return table|nil parts, table|string blanksOrError
function Questions.parseBlanks(sentence)
    local parts, blanks = {}, {}
    local pos = 1
    while true do
        local s, e, inner = sentence:find('{([^{}]*)}', pos)
        if not s then break end
        if s > pos then parts[#parts + 1] = { t = sentence:sub(pos, s - 1) } end
        local accepted = {}
        for alt in inner:gmatch('[^|]+') do
            local a = U.trim(alt)
            if a ~= '' then accepted[#accepted + 1] = a end
        end
        if #accepted == 0 then return nil, 'empty_blank' end
        blanks[#blanks + 1] = accepted
        parts[#parts + 1] = { b = #blanks }
        pos = e + 1
    end
    if pos <= #sentence then parts[#parts + 1] = { t = sentence:sub(pos) } end
    if #blanks == 0 then return nil, 'no_blank' end
    if #blanks > 10 then return nil, 'too_many_blanks' end
    for _, part in ipairs(parts) do
        if part.t and part.t:find('[{}]') then return nil, 'unbalanced_braces' end
    end
    return parts, blanks
end

--- Découpe une phrase en mots (tokens) pour l'exercice « remettre dans l'ordre ».
function Questions.tokenize(sentence)
    local tokens = {}
    for word in sentence:gmatch('%S+') do tokens[#tokens + 1] = word end
    return tokens
end

local REQUIRES_PROMPT = { mcq = true, truefalse = true, short_answer = true, open = true }

--- Valide une question saisie dans l'éditeur et la convertit au format de stockage.
---@param input table
---@param field string préfixe du champ pour les messages d'erreur
---@return table { uid, type, prompt, explanation, points, difficulty, theme, data, solution }
function Questions.fromEditor(input, field)
    local L = limits()
    V.table(input, field)
    local q = {}
    q.type = V.enum(input.type, EC.Const.QuestionTypes, field .. '.type')
    q.prompt = V.str(input.prompt, L.QuestionPrompt, field .. '.prompt', {
        multiline = true, optional = not REQUIRES_PROMPT[q.type], default = '',
    })
    q.explanation = V.str(input.explanation, L.Explanation, field .. '.explanation', { multiline = true, optional = true })
    q.points = U.roundTo(V.num(input.points, 0.25, L.MaxPoints, field .. '.points', 1), 0.25)
    q.difficulty = V.int(input.difficulty, 1, 3, field .. '.difficulty', 1)
    q.theme = V.enum(input.theme, EC.Const.Themes, field .. '.theme', 'grammar')
    q.uid = U.isUid(input.uid) and input.uid or nil

    local data, sol = {}, {}
    local t = q.type

    if t == 'mcq' then
        local options = V.list(input.options, L.OptionsPerQuestion, field .. '.options')
        if #options < 2 then EC.Fail('bad_request', field .. '.options:too_few') end
        data.multiple = V.bool(input.multiple, false)
        data.options, sol.correct = {}, {}
        local letters = 'abcdefgh'
        for i, option in ipairs(options) do
            V.table(option, field .. '.options')
            local id = letters:sub(i, i)
            data.options[i] = { id = id, text = V.str(option.text, L.OptionText, field .. '.options.text') }
            if option.correct == true then sol.correct[#sol.correct + 1] = id end
        end
        if #sol.correct == 0 then EC.Fail('bad_request', field .. ':no_correct_option') end
        if not data.multiple and #sol.correct > 1 then EC.Fail('bad_request', field .. ':too_many_correct') end

    elseif t == 'truefalse' then
        if type(input.answer) ~= 'boolean' then EC.Fail('bad_request', field .. '.answer') end
        sol.value = input.answer

    elseif t == 'translation' then
        data.source = V.str(input.source, 300, field .. '.source', { multiline = false })
        data.direction = V.enum(input.direction, { en_fr = true, fr_en = true }, field .. '.direction', 'en_fr')
        sol.accepted = acceptedList(input.accepted, field .. '.accepted')
        sol.tolerance = V.int(input.tolerance, 0, 2, field .. '.tolerance', defaultTolerance())

    elseif t == 'short_answer' then
        sol.accepted = acceptedList(input.accepted, field .. '.accepted')
        sol.tolerance = V.int(input.tolerance, 0, 2, field .. '.tolerance', defaultTolerance())

    elseif t == 'fill_blank' then
        local sentence = V.str(input.sentence, 600, field .. '.sentence')
        local parts, blanks = Questions.parseBlanks(sentence)
        if not parts then EC.Fail('bad_request', field .. '.sentence:' .. blanks) end
        data.parts = parts
        sol.blanks = blanks
        sol.sentence = sentence
        sol.tolerance = V.int(input.tolerance, 0, 2, field .. '.tolerance', defaultTolerance())
        local distractors = {}
        for _, d in ipairs(V.list(input.distractors, 10, field .. '.distractors', true)) do
            local text = V.str(d, 60, field .. '.distractors', { optional = true, default = '' })
            if text ~= '' then distractors[#distractors + 1] = text end
        end
        sol.distractors = distractors
        if V.bool(input.wordBank, false) then
            -- Banque de mots : la première réponse de chaque trou + les intrus.
            local bank, seen = {}, {}
            for _, accepted in ipairs(blanks) do
                if not seen[accepted[1]] then seen[accepted[1]] = true; bank[#bank + 1] = accepted[1] end
            end
            for _, d in ipairs(distractors) do
                if not seen[d] then seen[d] = true; bank[#bank + 1] = d end
            end
            data.bank = bank
        end

    elseif t == 'word_order' then
        local sentence = V.str(input.sentence, 300, field .. '.sentence')
        local tokens = Questions.tokenize(sentence)
        if #tokens < 2 then EC.Fail('bad_request', field .. '.sentence:too_short') end
        if #tokens > 24 then EC.Fail('bad_request', field .. '.sentence:too_long') end
        data.tokens = tokens
        sol.sentence = sentence
        sol.alternatives = {}
        for _, alt in ipairs(V.list(input.alternatives, 5, field .. '.alternatives', true)) do
            local text = V.str(alt, 300, field .. '.alternatives', { optional = true, default = '' })
            if text ~= '' then sol.alternatives[#sol.alternatives + 1] = text end
        end

    elseif t == 'matching' then
        local pairsIn = V.list(input.pairs, 10, field .. '.pairs')
        if #pairsIn < 2 then EC.Fail('bad_request', field .. '.pairs:too_few') end
        data.left, data.right, sol.map = {}, {}, {}
        local seenL, seenR = {}, {}
        for _, pair in ipairs(pairsIn) do
            V.table(pair, field .. '.pairs')
            local left = V.str(pair.left, 120, field .. '.pairs.left')
            local right = V.str(pair.right, 120, field .. '.pairs.right')
            local kl, kr = U.normKey(left), U.normKey(right)
            if seenL[kl] or seenR[kr] then EC.Fail('bad_request', field .. '.pairs:duplicate') end
            seenL[kl], seenR[kr] = true, true
            -- Identifiants aléatoires : ils ne révèlent pas les associations.
            local lid, rid = 'l' .. U.uid(6), 'r' .. U.uid(6)
            data.left[#data.left + 1] = { id = lid, text = left }
            data.right[#data.right + 1] = { id = rid, text = right }
            sol.map[lid] = rid
        end

    elseif t == 'open' then
        data.minWords = V.int(input.minWords, 0, 1000, field .. '.minWords', 0)
        data.maxWords = V.int(input.maxWords, 0, 2000, field .. '.maxWords', 0)
        if data.maxWords > 0 and data.maxWords < data.minWords then EC.Fail('bad_request', field .. '.maxWords') end
        sol.guidelines = V.str(input.guidelines, L.Explanation, field .. '.guidelines', { multiline = true, optional = true, default = '' })
    end

    q.data, q.solution = data, sol
    return q
end

--- Décode une ligne SQL de question.
function Questions.decode(row)
    return {
        id          = row.id,
        uid         = row.uid,
        exerciseId  = row.exercise_id,
        position    = row.position,
        type        = row.type,
        prompt      = row.prompt or '',
        explanation = row.explanation,
        points      = tonumber(row.points) or 1,
        difficulty  = row.difficulty or 1,
        theme       = row.theme or 'grammar',
        data        = EC.JsonDecode(row.data, {}),
        solution    = EC.JsonDecode(row.solution, {}),
    }
end

--- Format éditeur (professeur) — contient les solutions.
function Questions.toEditor(q)
    local out = {
        id = q.id, uid = q.uid, type = q.type, prompt = q.prompt, explanation = q.explanation,
        points = q.points, difficulty = q.difficulty, theme = q.theme,
    }
    local d, s = q.data, q.solution
    local t = q.type
    if t == 'mcq' then
        local correct = U.toSet(s.correct or {})
        out.multiple = d.multiple == true
        out.options = {}
        for i, option in ipairs(d.options or {}) do
            out.options[i] = { text = option.text, correct = correct[option.id] == true }
        end
    elseif t == 'truefalse' then
        out.answer = s.value == true
    elseif t == 'translation' then
        out.source, out.direction = d.source, d.direction
        out.accepted, out.tolerance = s.accepted or {}, s.tolerance
    elseif t == 'short_answer' then
        out.accepted, out.tolerance = s.accepted or {}, s.tolerance
    elseif t == 'fill_blank' then
        out.sentence = s.sentence
        out.distractors = s.distractors or {}
        out.wordBank = d.bank ~= nil
        out.tolerance = s.tolerance
    elseif t == 'word_order' then
        out.sentence = s.sentence
        out.alternatives = s.alternatives or {}
    elseif t == 'matching' then
        local rightText = {}
        for _, item in ipairs(d.right or {}) do rightText[item.id] = item.text end
        out.pairs = {}
        for i, item in ipairs(d.left or {}) do
            out.pairs[i] = { left = item.text, right = rightText[(s.map or {})[item.id]] or '' }
        end
    elseif t == 'open' then
        out.minWords, out.maxWords, out.guidelines = d.minWords, d.maxWords, s.guidelines
    end
    return out
end

--- Mélange des mots en s'assurant que l'ordre obtenu diffère de l'original.
local function shuffleTokens(tokens)
    if #tokens < 2 then return U.copy(tokens) end
    local original = table.concat(tokens, '\0')
    local shuffled = U.shuffle(tokens)
    local tries = 0
    while table.concat(shuffled, '\0') == original and tries < 8 do
        shuffled = U.shuffle(tokens)
        tries = tries + 1
    end
    return shuffled
end

--- Format élève (AUCUNE solution). Les options / mots sont mélangés côté serveur.
---@param q table question décodée
---@param opts table|nil { shuffleOptions = bool }
function Questions.toStudent(q, opts)
    opts = opts or {}
    local d = q.data
    local out = {
        id = q.id, type = q.type, prompt = q.prompt, points = q.points,
        difficulty = q.difficulty, theme = q.theme,
    }
    local t = q.type
    if t == 'mcq' then
        out.multiple = d.multiple == true
        out.options = opts.shuffleOptions and U.shuffle(d.options or {}) or d.options
    elseif t == 'translation' then
        out.source, out.direction = d.source, d.direction
    elseif t == 'fill_blank' then
        out.parts = d.parts
        out.bank = d.bank and U.shuffle(d.bank) or nil
    elseif t == 'word_order' then
        out.tokens = shuffleTokens(d.tokens or {})
    elseif t == 'matching' then
        out.left = opts.shuffleOptions and U.shuffle(d.left or {}) or d.left
        out.right = U.shuffle(d.right or {})
    elseif t == 'open' then
        out.minWords, out.maxWords = d.minWords, d.maxWords
    end
    return out
end

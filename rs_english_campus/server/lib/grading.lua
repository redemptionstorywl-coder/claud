--[[
    English Campus — moteur de correction (100 % côté serveur).

    Les solutions ne quittent jamais le serveur avant que l'élève ait répondu :
    l'interface envoie uniquement la réponse brute, le serveur la nettoie, la compare
    à la solution stockée en base et calcule lui-même les points.
]]

local U = EC.U

Grading = {}

local function settings()
    return (Config.Pedagogy and Config.Pedagogy.Grading) or {}
end

local function normalizeOptions()
    local g = settings()
    return {
        ignoreAccents      = g.IgnoreAccents ~= false,
        ignorePunctuation  = g.IgnorePunctuation ~= false,
        expandContractions = g.ExpandContractions ~= false,
    }
end

--- Points partiels (si activés), arrondis au centième.
local function partial(points, ratio)
    if ratio >= 1 then return points end
    if not settings().PartialCredit then return 0 end
    return U.round(points * math.max(0, ratio), 2)
end

--- Compare une réponse libre à la liste des réponses acceptées.
---@return boolean matched, boolean typo
function Grading.matchText(given, accepted, tolerance)
    if type(given) ~= 'string' or type(accepted) ~= 'table' then return false, false end
    local opts = normalizeOptions()
    local g = U.normalizeAnswer(given, opts)
    if g == '' then return false, false end

    local normalized = {}
    for i = 1, #accepted do
        local n = U.normalizeAnswer(accepted[i], opts)
        normalized[i] = n
        if n ~= '' and n == g then return true, false end
    end

    tolerance = tonumber(tolerance) or 0
    if tolerance > 0 then
        for i = 1, #normalized do
            local n = normalized[i]
            -- 1 faute tolérée à partir de 5 caractères, 2 à partir de 10 (si la question l'autorise).
            local allowed = math.min(tolerance, math.floor(#n / 5))
            if allowed > 0 and U.editDistance(g, n, allowed) <= allowed then
                return true, true
            end
        end
    end
    return false, false
end

local function stringList(value, maxItems, maxLen)
    local out = {}
    if type(value) ~= 'table' then return out end
    for i = 1, math.min(#value, maxItems) do
        local v = value[i]
        if type(v) == 'string' then
            out[#out + 1] = U.utf8sub(U.cleanText(v, nil, false) or '', maxLen)
        else
            out[#out + 1] = ''
        end
    end
    return out
end

local function cleanAnswer(value, maxLen, multiline)
    if type(value) ~= 'string' then return '' end
    local cleaned = U.cleanText(value, nil, multiline) or ''
    return U.utf8sub(cleaned, maxLen)
end

--- Nettoie la réponse brute envoyée par l'interface selon le type de question.
--- Tout ce qui n'est pas attendu est ignoré.
---@param q table question décodée { type, data, solution }
---@param raw any
---@return table answer
function Grading.sanitizeAnswer(q, raw)
    local limits = Config.Pedagogy.Limits
    raw = type(raw) == 'table' and raw or {}
    local t, data = q.type, q.data or {}

    if t == 'mcq' then
        local valid = {}
        for _, option in ipairs(data.options or {}) do valid[option.id] = true end
        if data.multiple then
            local out, seen = {}, {}
            if type(raw.choices) == 'table' then
                for _, c in ipairs(raw.choices) do
                    if type(c) == 'string' and valid[c] and not seen[c] then
                        seen[c] = true
                        out[#out + 1] = c
                    end
                end
            end
            return { choices = out }
        end
        if type(raw.choice) == 'string' and valid[raw.choice] then return { choice = raw.choice } end
        return {}

    elseif t == 'truefalse' then
        if type(raw.value) == 'boolean' then return { value = raw.value } end
        return {}

    elseif t == 'translation' or t == 'short_answer' then
        return { text = cleanAnswer(raw.text, limits.AnswerText) }

    elseif t == 'fill_blank' then
        local count = 0
        for _, part in ipairs(data.parts or {}) do
            if part.b then count = count + 1 end
        end
        local given = type(raw.blanks) == 'table' and raw.blanks or {}
        local out = {}
        for i = 1, count do out[i] = cleanAnswer(given[i], 200) end
        return { blanks = out }

    elseif t == 'word_order' then
        return { words = stringList(raw.words, 40, 80) }

    elseif t == 'matching' then
        local left, right = {}, {}
        for _, item in ipairs(data.left or {}) do left[item.id] = true end
        for _, item in ipairs(data.right or {}) do right[item.id] = true end
        local out = {}
        if type(raw.pairs) == 'table' then
            for l, r in pairs(raw.pairs) do
                if type(l) == 'string' and left[l] and type(r) == 'string' and right[r] then out[l] = r end
            end
        end
        return { pairs = out }

    elseif t == 'open' then
        return { text = cleanAnswer(raw.text, limits.OpenAnswerText, true) }
    end

    return {}
end

--- Indique si une réponse nettoyée est vide (question non répondue).
function Grading.isEmpty(q, answer)
    local t = q.type
    if t == 'mcq' then
        if q.data and q.data.multiple then return not answer.choices or #answer.choices == 0 end
        return answer.choice == nil
    elseif t == 'truefalse' then
        return answer.value == nil
    elseif t == 'translation' or t == 'short_answer' or t == 'open' then
        return not answer.text or answer.text == ''
    elseif t == 'fill_blank' then
        for _, v in ipairs(answer.blanks or {}) do
            if v ~= '' then return false end
        end
        return true
    elseif t == 'word_order' then
        return not answer.words or #answer.words == 0
    elseif t == 'matching' then
        return not answer.pairs or next(answer.pairs) == nil
    end
    return true
end

--- Corrige une réponse (déjà nettoyée).
---@param q table question décodée { type, points, data, solution }
---@param answer table
---@return table { correct = bool|nil, points, max, pending, partial, typo, detail }
function Grading.grade(q, answer)
    local t = q.type
    local max = tonumber(q.points) or 1
    local data, sol = q.data or {}, q.solution or {}
    answer = type(answer) == 'table' and answer or {}
    local r = { max = max, points = 0, correct = false }

    if t == 'mcq' then
        local correct = U.toSet(sol.correct or {})
        local expected = #(sol.correct or {})
        if data.multiple then
            local good, wrong = 0, 0
            for _, c in ipairs(answer.choices or {}) do
                if correct[c] then good = good + 1 else wrong = wrong + 1 end
            end
            r.correct = expected > 0 and good == expected and wrong == 0
            r.points = r.correct and max or partial(max, expected > 0 and (good - wrong) / expected or 0)
        else
            r.correct = answer.choice ~= nil and correct[answer.choice] == true
            r.points = r.correct and max or 0
        end

    elseif t == 'truefalse' then
        r.correct = type(answer.value) == 'boolean' and answer.value == sol.value
        r.points = r.correct and max or 0

    elseif t == 'translation' or t == 'short_answer' then
        local ok, typo = Grading.matchText(answer.text or '', sol.accepted or {}, sol.tolerance)
        r.correct, r.typo = ok, typo
        r.points = ok and max or 0

    elseif t == 'fill_blank' then
        local blanks = sol.blanks or {}
        local given = answer.blanks or {}
        local good, detail = 0, {}
        for i = 1, #blanks do
            local ok, typo = Grading.matchText(given[i] or '', blanks[i], sol.tolerance)
            detail[i] = ok
            if ok then good = good + 1 end
            if typo then r.typo = true end
        end
        r.correct = #blanks > 0 and good == #blanks
        r.points = r.correct and max or partial(max, #blanks > 0 and good / #blanks or 0)
        r.detail = { blanks = detail }

    elseif t == 'word_order' then
        local sentence = table.concat(answer.words or {}, ' ')
        local accepted = { sol.sentence or '' }
        for _, alt in ipairs(sol.alternatives or {}) do accepted[#accepted + 1] = alt end
        r.correct = (Grading.matchText(sentence, accepted, 0))
        r.points = r.correct and max or 0

    elseif t == 'matching' then
        local given = answer.pairs or {}
        local total, good, detail = 0, 0, {}
        for leftId, rightId in pairs(sol.map or {}) do
            total = total + 1
            local ok = given[leftId] == rightId
            detail[leftId] = ok
            if ok then good = good + 1 end
        end
        r.correct = total > 0 and good == total
        r.points = r.correct and max or partial(max, total > 0 and good / total or 0)
        r.detail = { pairs = detail }

    elseif t == 'open' then
        -- Expression écrite : corrigée par le professeur.
        r.correct = nil
        r.pending = true
        r.points = 0
    end

    r.points = U.round(r.points, 2)
    r.partial = r.correct == false and r.points > 0
    return r
end

--- Reconstitue une phrase à trous avec des réponses.
function Grading.fillSentence(parts, answers)
    local out = {}
    for _, part in ipairs(parts or {}) do
        if part.t then
            out[#out + 1] = part.t
        elseif part.b then
            out[#out + 1] = answers[part.b] or '___'
        end
    end
    return table.concat(out)
end

--- Correction affichable (envoyée à l'élève APRÈS sa réponse, ou au professeur).
function Grading.solutionView(q)
    local t, sol, data = q.type, q.solution or {}, q.data or {}
    if t == 'mcq' then
        return { correct = sol.correct or {} }
    elseif t == 'truefalse' then
        return { value = sol.value }
    elseif t == 'translation' or t == 'short_answer' then
        return { answers = sol.accepted or {} }
    elseif t == 'fill_blank' then
        local firsts = {}
        for i, accepted in ipairs(sol.blanks or {}) do firsts[i] = accepted[1] end
        return { blanks = firsts, full = Grading.fillSentence(data.parts, firsts) }
    elseif t == 'word_order' then
        return { sentence = sol.sentence }
    elseif t == 'matching' then
        return { map = sol.map or {} }
    elseif t == 'open' then
        return { guidelines = sol.guidelines }
    end
    return {}
end

--- Note finale : points → note sur `scale`, arrondie selon la configuration.
function Grading.toGrade(points, maxPoints, scale)
    if not maxPoints or maxPoints <= 0 then return 0, 0 end
    local ratio = math.max(0, math.min(1, points / maxPoints))
    local step = settings().Rounding or 0.5
    local grade = U.roundTo(ratio * scale, step)
    return U.round(grade, 2), U.round(ratio * 100, 1)
end

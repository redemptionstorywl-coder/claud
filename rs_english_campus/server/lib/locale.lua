--[[
    English Campus — textes générés côté serveur (notifications téléphone + centre de notifications).
    L'interface a ses propres traductions (web/js/i18n) ; ici uniquement ce que le serveur écrit.
]]

local STRINGS = {
    fr = {
        ['notif.course.title']      = 'Nouveau cours disponible',
        ['notif.course.body']       = '%s vient de publier « %s ».',
        ['notif.assessment.title']  = 'Nouvelle évaluation',
        ['notif.assessment.body']   = '« %s » est maintenant disponible.',
        ['notif.assessment.until']  = '« %s » est disponible — fin dans %s.',
        ['notif.result.title']      = 'Résultat disponible',
        ['notif.result.body']       = 'Votre professeur a corrigé « %s ». Note : %s',
        ['notif.result.instant']    = '« %s » : note %s',
        ['notif.auto.title']        = 'Temps écoulé',
        ['notif.auto.body']         = '« %s » a été rendu automatiquement.',
        ['notif.submission.title']  = 'Copie à corriger',
        ['notif.submission.body']   = '%s a rendu « %s ».',
        ['duration.minutes']        = '%d min',
        ['duration.hours']          = '%d h',
        ['duration.hoursMinutes']   = '%d h %02d',
        ['duration.days']           = '%d j',
        ['decimal']                 = ',',
    },
    en = {
        ['notif.course.title']      = 'New lesson available',
        ['notif.course.body']       = '%s just published “%s”.',
        ['notif.assessment.title']  = 'New test',
        ['notif.assessment.body']   = '“%s” is now available.',
        ['notif.assessment.until']  = '“%s” is available — closes in %s.',
        ['notif.result.title']      = 'Result available',
        ['notif.result.body']       = 'Your teacher graded “%s”. Grade: %s',
        ['notif.result.instant']    = '“%s”: grade %s',
        ['notif.auto.title']        = 'Time is up',
        ['notif.auto.body']         = '“%s” was submitted automatically.',
        ['notif.submission.title']  = 'Paper to grade',
        ['notif.submission.body']   = '%s submitted “%s”.',
        ['duration.minutes']        = '%d min',
        ['duration.hours']          = '%d h',
        ['duration.hoursMinutes']   = '%dh%02d',
        ['duration.days']           = '%d d',
        ['decimal']                 = '.',
    },
}

--- Texte traduit (langue Config.Locale, repli en français).
function EC.L(key, ...)
    local lang = STRINGS[Config.Locale] or STRINGS.fr
    local text = lang[key] or STRINGS.fr[key] or key
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then return formatted end
    end
    return text
end

--- Durée relative lisible (indépendante du fuseau horaire des joueurs).
function EC.FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds))
    local minutes = math.ceil(seconds / 60)
    if minutes < 60 then return EC.L('duration.minutes', minutes) end
    local hours = math.floor(minutes / 60)
    if hours >= 48 then return EC.L('duration.days', math.floor(hours / 24)) end
    local rest = minutes % 60
    if rest == 0 then return EC.L('duration.hours', hours) end
    return EC.L('duration.hoursMinutes', hours, rest)
end

--- Note affichable : « 15,5/20 ».
function EC.FormatGrade(grade, max)
    local function num(n)
        n = tonumber(n) or 0
        local text = (n % 1 == 0) and ('%d'):format(n) or (('%.2f'):format(n):gsub('0+$', ''):gsub('%.$', ''))
        return (text:gsub('%.', EC.L('decimal')))
    end
    return ('%s/%s'):format(num(grade), num(max))
end

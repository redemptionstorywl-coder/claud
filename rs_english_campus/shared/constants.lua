--[[
    English Campus — constantes partagées (types de contenus, statuts, rôles).
]]

EC = EC or {}

EC.Const = {
    ResourceEvents = {
        Rpc         = 'rs_english_campus:rpc',          -- client → serveur (requête)
        RpcResponse = 'rs_english_campus:rpc:response', -- serveur → client (réponse)
        Push        = 'rs_english_campus:push',         -- serveur → client (évènement temps réel)
    },

    -- Rang des rôles (plus grand = plus de privilèges).
    RoleRank = { student = 1, teacher = 2, admin = 3 },

    -- Blocs d'un cours.
    SectionTypes = {
        text       = true, -- titre + texte mis en forme
        vocabulary = true, -- liste de mots anglais → traduction
        exercise   = true, -- série de questions corrigées automatiquement
        assessment = true, -- lien vers une évaluation (évaluation finale)
    },

    -- Types de questions.
    QuestionTypes = {
        mcq          = true, -- QCM (une ou plusieurs bonnes réponses)
        truefalse    = true, -- Vrai / Faux
        translation  = true, -- traduire un mot / une phrase
        short_answer = true, -- trouver la bonne réponse (réponse libre courte)
        fill_blank   = true, -- compléter une phrase (texte à trous)
        word_order   = true, -- remettre les mots dans l'ordre
        matching     = true, -- associer (anglais ↔ traduction)
        open         = true, -- expression écrite (correction par le professeur)
    },

    Themes = {
        vocabulary    = true,
        grammar       = true,
        conjugation   = true,
        comprehension = true,
        expression    = true,
    },

    CourseStatus     = { draft = true, published = true, archived = true },
    AssessmentStatus = { draft = true, published = true, archived = true },
    ReleaseModes     = { immediate = true, manual = true },
    ReviewModes      = { after_submit = true, after_close = true, never = true },

    -- Icônes disponibles pour les cours (clés d'icônes de l'interface).
    Emblems = {
        book = true, grammar = true, chat = true, globe = true, pen = true, headphones = true,
        star = true, bulb = true, flag = true, clock = true, theater = true, music = true,
    },

    -- Niveaux de difficulté
    Difficulty = { [1] = 'easy', [2] = 'medium', [3] = 'hard' },
}

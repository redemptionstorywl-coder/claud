--[[
    ███████╗███╗   ██╗ ██████╗ ██╗     ██╗███████╗██╗  ██╗     ██████╗ █████╗ ███╗   ███╗██████╗ ██╗   ██╗███████╗
    English Campus — Redemption Story School RP

    Toute la configuration du script est ici. Chaque section est commentée.
    Le fichier est partagé (client + serveur) : n'y mettez JAMAIS de secret (mot de passe, token...).
]]

Config = {}

-- ════════════════════════════════════════════════════════════════════════════
--  GÉNÉRAL
-- ════════════════════════════════════════════════════════════════════════════

Config.AppName        = 'English Campus'
Config.AppDescription = "Cours d'anglais, exercices, évaluations et progression — directement sur ton téléphone."
Config.Developer      = 'Redemption Story'
Config.SchoolName     = 'Redemption Story School'

-- Langue de l'interface : 'fr' ou 'en'
Config.Locale = 'fr'

-- Affiche des logs détaillés dans la console serveur/client (à désactiver en production).
Config.Debug = false

-- ════════════════════════════════════════════════════════════════════════════
--  APPARENCE (appliquée à l'interface NUI)
-- ════════════════════════════════════════════════════════════════════════════

Config.Theme = {
    -- 'auto'  : suit le thème clair/sombre du téléphone (recommandé)
    -- 'light' : toujours clair  |  'dark' : toujours sombre
    Mode = 'auto',

    -- Identité visuelle « copie d'école » : encre bleue, stylo rouge, étoile dorée.
    Accent  = '#2447A8', -- bleu encre : actions principales, navigation, progression
    Correct = '#1F8A5B', -- vert : bonne réponse
    Wrong   = '#D13B3B', -- rouge correcteur : erreurs, corrections, notes entourées
    Gold    = '#C8961E', -- or : distinctions, moyennes, badges

    -- Arrondi des cartes (px)
    Radius = 16,

    -- Animations de l'interface (désactivées automatiquement si l'OS demande moins d'animations)
    Animations = true,
}

-- ════════════════════════════════════════════════════════════════════════════
--  RÔLES & PERMISSIONS
-- ════════════════════════════════════════════════════════════════════════════
--  Ordre de résolution du rôle d'un joueur (le premier qui répond l'emporte) :
--    1. ACE admin / groupes admin            → admin
--    2. Rôle forcé par un admin dans l'app   → rôle forcé (table campus_english_members)
--    3. ACE / groupes / jobs professeur      → teacher
--    4. Rôle fourni par le compte Campus      → selon Config.Campus.RoleMap
--    5. Par défaut                            → student
-- ════════════════════════════════════════════════════════════════════════════

-- Permissions ACE (fonctionne sans framework) :
--   add_ace group.admin englishcampus.admin allow
--   add_ace group.teacher englishcampus.teacher allow
Config.AdminAce   = 'englishcampus.admin'
Config.TeacherAce = 'englishcampus.teacher'

-- Groupes (ACE « group.xxx », groupe ESX ou permission QBCore) donnant le rôle correspondant.
Config.AdminGroups = {
    'admin',
    'superadmin',
    'god',
}

Config.TeacherGroups = {
    'teacher',
    'professor',
}

-- Jobs du framework (ESX / QBCore / Qbox) donnant le rôle professeur : [nom du job] = grade minimum.
-- Laisser vide si les professeurs sont définis uniquement par le compte Campus.
Config.TeacherJobs = {
    -- teacher = 0,
    -- professeur = 0,
}

-- Matrice des capacités par rôle. '*' = toutes les capacités.
-- Les vérifications de propriété (« ses » cours, « ses » classes) sont faites en plus côté serveur.
Config.Permissions = {
    student = {
        ['courses.view']      = true, -- consulter les cours de sa classe
        ['exercises.do']      = true, -- faire les exercices
        ['assessments.take']  = true, -- passer les évaluations
        ['results.own']       = true, -- voir ses notes
        ['progress.own']      = true, -- voir sa progression
        ['vocabulary.use']    = true, -- réviser le vocabulaire
    },
    teacher = {
        ['courses.create']     = true, -- créer des cours
        ['courses.edit']       = true, -- modifier SES cours
        ['courses.publish']    = true, -- publier / dépublier SES cours
        ['courses.delete']     = true, -- supprimer SES cours (sans résultats d'élèves)
        ['assessments.create'] = true, -- créer / gérer SES évaluations
        ['students.view']      = true, -- voir les élèves de SES classes
        ['results.view']       = true, -- voir les résultats de SES classes
        ['results.grade']      = true, -- corriger / publier les notes
        ['notify.send']        = true, -- envoyer des notifications à SES classes
        ['live.use']           = true, -- suivi en direct pendant le cours
    },
    admin = {
        ['*'] = true,                  -- tout, sur tous les cours / classes / professeurs
    },
}

-- ════════════════════════════════════════════════════════════════════════════
--  COMPTE CAMPUS (source d'identité principale)
-- ════════════════════════════════════════════════════════════════════════════
--  English Campus ne crée AUCUN compte : il lit le compte Campus du joueur.
--  Adaptez le mode à votre ressource « campus ». Voir README > Intégration Campus.
-- ════════════════════════════════════════════════════════════════════════════

Config.Campus = {
    -- 'export'    : appelle exports[Resource][Export](source) et lit les champs ci-dessous
    -- 'statebag'  : lit Player(source).state[StateBagKey]
    -- 'sql'       : lit la table SQL du Campus (voir Sql)
    -- 'framework' : identité = personnage ESX / QBCore / Qbox (pas de Campus)
    -- 'custom'    : utilise Config.Campus.Custom(source) ci-dessous
    Mode = 'export',

    -- Si le mode principal échoue (ressource arrêtée, export absent...), on essaie celui-ci.
    -- Mettre false pour refuser l'accès aux joueurs sans compte Campus.
    Fallback = 'framework',

    Resource    = 'campus',
    Export      = 'GetPlayerAccount', -- exports.campus:GetPlayerAccount(source) → table
    StateBagKey = 'campus',

    -- Mode 'sql' : lecture directe de la table des comptes Campus.
    Sql = {
        Table            = 'campus_accounts',
        -- Colonne qui relie le compte au joueur, et type d'identifiant utilisé.
        -- IdentifierType : 'character' (citizenid ESX/QB), 'license', 'discord', 'steam', 'fivem'
        IdentifierColumn = 'identifier',
        IdentifierType   = 'character',
    },

    -- Correspondance des champs (mode export / statebag / sql). Les chemins « a.b.c » sont acceptés.
    Fields = {
        id            = 'id',           -- identifiant Campus (OBLIGATOIRE, unique)
        characterId   = 'citizenid',    -- identifiant du personnage (facultatif)
        firstName     = 'firstname',
        lastName      = 'lastname',
        class         = 'class',        -- ex. « Terminale B » (texte) ou code de classe
        role          = 'role',         -- ex. « eleve », « professeur », « admin »
        studentNumber = 'student_id',   -- identifiant étudiant affiché
        title         = 'title',        -- civilité des professeurs (Mr., Mrs., Dr....) — facultatif
    },

    -- Valeurs du champ « role » du Campus → rôle English Campus.
    -- Les clés sont comparées sans accents ni majuscules.
    RoleMap = {
        student     = 'student',
        eleve       = 'student',
        etudiant    = 'student',
        teacher     = 'teacher',
        professeur  = 'teacher',
        prof        = 'teacher',
        enseignant  = 'teacher',
        admin       = 'admin',
        directeur   = 'admin',
        direction   = 'admin',
        proviseur   = 'admin',
    },

    -- Mode 'custom' : écrivez ici votre propre lecture du compte (côté serveur uniquement).
    -- Doit retourner nil ou une table { id, characterId, firstName, lastName, class, role, studentNumber, title }.
    Custom = function(source)
        return nil
    end,

    -- Durée (secondes) pendant laquelle le profil résolu est gardé en mémoire.
    CacheSeconds = 300,

    -- Événements serveur (déclenchés par votre Campus / framework) qui forcent le rechargement du profil.
    -- Le premier argument doit être le source du joueur (ou rien : source implicite).
    RefreshEvents = {
        'campus:server:accountLoaded',
        'campus:server:accountUpdated',
        'QBCore:Server:OnPlayerLoaded',
        'esx:playerLoaded',
    },
}

-- ════════════════════════════════════════════════════════════════════════════
--  TÉLÉPHONE
-- ════════════════════════════════════════════════════════════════════════════

Config.Phone = {
    -- 'sd-phone'   : application native de sd-phone (addCustomApp) — recommandé
    -- 'lb-phone'   : application lb-phone (AddCustomApp)
    -- 'standalone' : pas de téléphone, l'app s'ouvre dans son propre cadre (commande ci-dessous)
    Adapter = 'sd-phone',

    Resource   = 'sd-phone',
    Identifier = 'english_campus', -- identifiant unique de l'app dans le téléphone
    DefaultApp = true,             -- true = pré-installée, false = à télécharger dans l'App Store
    Size       = 24800,            -- taille affichée dans l'App Store (Ko)

    -- Bannières de notification du téléphone (nouveau cours, évaluation, note...)
    Notifications = true,

    -- Ouvre directement l'écran concerné quand le joueur touche une notification.
    DeepLinks = true,
}

-- ════════════════════════════════════════════════════════════════════════════
--  ORDINATEUR (rs_pc)
-- ════════════════════════════════════════════════════════════════════════════

Config.PC = {
    -- 'rs_pc'      : enregistre l'application dans rs_pc (voir README > Intégration rs_pc)
    -- 'standalone' : fenêtre « ordinateur » propre à English Campus (commande / postes ci-dessous)
    -- 'none'       : pas de version PC
    Adapter = 'rs_pc',

    Resource = 'rs_pc',
    AppId    = 'english_campus',

    -- Nom de l'export rs_pc qui enregistre une application (adapter à votre rs_pc).
    -- Il reçoit une table { id, name, description, icon, url, width, height }.
    RegisterExport = 'RegisterApp',

    -- Si l'enregistrement dans rs_pc échoue, ouvrir la fenêtre standalone à la place.
    FallbackToStandalone = true,

    -- Fenêtre standalone
    Command = 'englishpc', -- /englishpc (false pour désactiver)

    -- Postes informatiques (standalone) : [E] pour ouvrir English Campus à proximité.
    Locations = {
        -- { coords = vector3(-1638.12, 181.54, 61.76), label = 'Salle informatique' },
    },
    InteractDistance = 1.6,
    InteractKey      = 38, -- E
}

-- ════════════════════════════════════════════════════════════════════════════
--  MODE AUTONOME (sans téléphone, utile pour les tests ou un serveur sans phone)
-- ════════════════════════════════════════════════════════════════════════════

Config.Standalone = {
    Command = 'english',   -- /english ouvre l'app dans son cadre téléphone (false pour désactiver)
    Keybind = false,       -- ex. 'F7' (touche configurable dans les paramètres GTA), false = aucune
    -- Autoriser la commande même quand un téléphone est configuré (pratique pour les admins/tests).
    AllowWithPhone = true,
}

-- ════════════════════════════════════════════════════════════════════════════
--  CLASSES
-- ════════════════════════════════════════════════════════════════════════════

Config.Classes = {
    -- Classes créées au premier démarrage (modifiables ensuite dans l'app, onglet Administration).
    Default = {
        { code = '2A', label = 'Seconde A',   level = 'Seconde' },
        { code = '2B', label = 'Seconde B',   level = 'Seconde' },
        { code = '1A', label = 'Première A',  level = 'Première' },
        { code = '1B', label = 'Première B',  level = 'Première' },
        { code = 'TA', label = 'Terminale A', level = 'Terminale' },
        { code = 'TB', label = 'Terminale B', level = 'Terminale' },
    },

    -- Si la classe renvoyée par le Campus n'existe pas encore, la créer automatiquement.
    AutoCreateFromCampus = true,

    -- Alias supplémentaires reconnus dans le compte Campus : ['texte campus'] = 'CODE'
    Aliases = {
        -- ['Term B'] = 'TB',
        -- ['T-B']    = 'TB',
    },

    -- Un professeur peut choisir lui-même les classes qu'il enseigne (Paramètres).
    TeachersCanPickClasses = true,

    -- Un professeur sans classe attribuée voit toutes les classes (pratique au lancement).
    -- Mettre false pour qu'un professeur ne voie QUE les classes attribuées.
    TeacherSeesAllClassesIfNone = true,
}

-- ════════════════════════════════════════════════════════════════════════════
--  PÉDAGOGIE
-- ════════════════════════════════════════════════════════════════════════════

Config.Pedagogy = {
    -- Thèmes utilisés pour la progression par compétence.
    Themes = { 'vocabulary', 'grammar', 'conjugation', 'comprehension', 'expression' },

    DefaultCourseDuration = 30, -- minutes (durée estimée proposée à la création)

    Grading = {
        Scale             = 20,   -- barème des moyennes (/20)
        Rounding          = 0.5,  -- arrondi des notes (0.5 → 15,5 ; 0.25 → 15,75 ; 1 → 16)
        PartialCredit     = true, -- points partiels (texte à trous, association, QCM multiple)
        IgnoreAccents     = true, -- « ecole » = « école » dans les réponses écrites
        IgnorePunctuation = true, -- « I went. » = « I went »
        ExpandContractions = true, -- « I've » = « I have », « don't » = « do not »
        TypoTolerance     = 1,    -- fautes de frappe tolérées par défaut (0 = aucune)
    },

    Assessment = {
        DefaultDuration    = 20,  -- minutes
        DefaultMaxScore    = 20,
        MaxDuration        = 240, -- minutes
        GraceSeconds       = 20,  -- tolérance réseau après la fin du chrono
        SweepInterval      = 30,  -- secondes entre deux vérifications (évaluations expirées / ouvertures programmées)
    },

    Vocabulary = {
        SessionSize = 10,
        -- Intervalles de révision (secondes) par niveau de maîtrise (boîte de Leitner 0 → 5).
        Intervals = { 0, 3600, 86400, 259200, 604800, 1209600 },
        MasteredBox = 4, -- niveau à partir duquel un mot est « maîtrisé »
    },

    -- Limites de contenu (protègent la base de données et le réseau).
    Limits = {
        CourseTitle         = 120,
        CourseDescription   = 1200,
        SectionsPerCourse   = 60,
        SectionTitle        = 120,
        TextBody            = 12000,
        WordsPerVocabulary  = 120,
        VocabularyTerm      = 120,
        QuestionsPerExercise = 60,
        QuestionPrompt      = 600,
        Explanation         = 1200,
        OptionsPerQuestion  = 8,
        OptionText          = 200,
        AcceptedAnswers     = 12,
        AnswerText          = 2000,
        OpenAnswerText      = 6000,
        MaxPoints           = 20,
        NotificationTitle   = 80,
        NotificationBody    = 400,
    },
}

-- ════════════════════════════════════════════════════════════════════════════
--  NOTIFICATIONS
-- ════════════════════════════════════════════════════════════════════════════

Config.Notifications = {
    OnCoursePublished     = true, -- élèves : nouveau cours disponible
    OnAssessmentOpened    = true, -- élèves : nouvelle évaluation disponible
    OnResultReleased      = true, -- élève : note disponible
    OnSubmissionToCorrect = true, -- professeur : une copie attend une correction
    RetentionDays         = 30,   -- suppression automatique des anciennes notifications
    TeacherMessagesPerHour = 20,  -- anti-spam des messages professeur
}

-- ════════════════════════════════════════════════════════════════════════════
--  SÉCURITÉ
-- ════════════════════════════════════════════════════════════════════════════

Config.Security = {
    -- Limitation des appels (seau à jetons) par joueur.
    RateLimit = {
        Capacity        = 30, -- rafale maximale
        RefillPerSecond = 6,  -- jetons regagnés par seconde
    },
    MaxInFlight  = 6,      -- requêtes simultanées maximum par joueur
    MaxPayload   = 262144, -- taille maximale d'une requête (octets)
    StrikeLimit  = 40,     -- dépassements tolérés par fenêtre avant sanction
    StrikeWindow = 60,     -- secondes
    KickOnAbuse  = false,  -- expulser automatiquement en cas d'abus répété
    KickMessage  = 'English Campus : activité anormale détectée.',
    RequestTimeout = 15,   -- secondes (côté client)
}

-- ════════════════════════════════════════════════════════════════════════════
--  BASE DE DONNÉES
-- ════════════════════════════════════════════════════════════════════════════

Config.Database = {
    -- Crée automatiquement les tables au démarrage si elles n'existent pas (sql/install.sql).
    AutoInstall      = true,
    LogRetentionDays = 60,
}

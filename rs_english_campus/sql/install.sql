-- ════════════════════════════════════════════════════════════════════════════
--  English Campus — schéma SQL (MySQL 5.7+ / MariaDB 10.3+)
--
--  • Toutes les références aux joueurs utilisent l'identifiant du compte Campus
--    (colonne `campus_id` / `student_id` / `teacher_id`, VARCHAR(64)).
--    Aucun second système de compte n'est créé : la table `campus_english_members`
--    n'est qu'un cache d'affichage (nom, classe) + les réglages propres à l'app.
--  • Toutes les dates sont des timestamps UNIX (secondes, UTC) : aucun souci de fuseau.
--  • Ce fichier est exécuté automatiquement au démarrage si Config.Database.AutoInstall = true.
--    Il est idempotent (CREATE TABLE IF NOT EXISTS) : vous pouvez aussi l'importer à la main.
-- ════════════════════════════════════════════════════════════════════════════

-- ─── Classes ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `campus_english_classes` (
    `id`         INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    `code`       VARCHAR(32)       NOT NULL,
    `label`      VARCHAR(64)       NOT NULL,
    `level`      VARCHAR(32)       NULL,
    `position`   SMALLINT          NOT NULL DEFAULT 0,
    `active`     TINYINT(1)        NOT NULL DEFAULT 1,
    `created_at` INT UNSIGNED      NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_class_code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Membres (cache du compte Campus + réglages English Campus) ─────────────
CREATE TABLE IF NOT EXISTS `campus_english_members` (
    `campus_id`      VARCHAR(64)   NOT NULL,             -- identifiant du compte Campus
    `character_id`   VARCHAR(64)   NULL,
    `first_name`     VARCHAR(64)   NOT NULL DEFAULT '',
    `last_name`      VARCHAR(64)   NOT NULL DEFAULT '',
    `student_number` VARCHAR(64)   NULL,
    `role`           VARCHAR(16)   NOT NULL DEFAULT 'student', -- dernier rôle résolu
    `class_id`       INT UNSIGNED  NULL,                       -- dernière classe résolue
    `role_override`  VARCHAR(16)   NULL,                       -- rôle forcé par un admin
    `class_override` INT UNSIGNED  NULL,                       -- classe forcée par un admin
    `title`          VARCHAR(24)   NULL,                       -- civilité affichée (Campus ou forcée)
    `title_override` VARCHAR(24)   NULL,                       -- civilité choisie dans l'app
    `prefs`          TEXT          NULL,                       -- JSON (préférences d'affichage)
    `last_seen_at`   INT UNSIGNED  NOT NULL DEFAULT 0,
    `created_at`     INT UNSIGNED  NOT NULL DEFAULT 0,
    PRIMARY KEY (`campus_id`),
    KEY `idx_member_class` (`class_id`, `role`),
    KEY `idx_member_name` (`last_name`, `first_name`),
    CONSTRAINT `fk_member_class` FOREIGN KEY (`class_id`) REFERENCES `campus_english_classes` (`id`) ON DELETE SET NULL,
    CONSTRAINT `fk_member_class_override` FOREIGN KEY (`class_override`) REFERENCES `campus_english_classes` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Classes enseignées par chaque professeur ───────────────────────────────
CREATE TABLE IF NOT EXISTS `campus_english_teacher_classes` (
    `teacher_id` VARCHAR(64)  NOT NULL,
    `class_id`   INT UNSIGNED NOT NULL,
    PRIMARY KEY (`teacher_id`, `class_id`),
    KEY `idx_tc_class` (`class_id`),
    CONSTRAINT `fk_tc_class` FOREIGN KEY (`class_id`) REFERENCES `campus_english_classes` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Cours ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `campus_english_courses` (
    `id`           INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    `teacher_id`   VARCHAR(64)       NOT NULL,
    `title`        VARCHAR(160)      NOT NULL,
    `description`  TEXT              NULL,
    `theme`        VARCHAR(24)       NOT NULL DEFAULT 'grammar',
    `level`        TINYINT UNSIGNED  NOT NULL DEFAULT 1,
    `duration`     SMALLINT UNSIGNED NOT NULL DEFAULT 30,
    `emblem`       VARCHAR(24)       NOT NULL DEFAULT 'book',
    `status`       VARCHAR(16)       NOT NULL DEFAULT 'draft',  -- draft | published | archived
    `published_at` INT UNSIGNED      NULL,
    `created_at`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `updated_at`   INT UNSIGNED      NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `idx_course_teacher` (`teacher_id`, `status`),
    KEY `idx_course_status` (`status`, `published_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `campus_english_course_classes` (
    `course_id` INT UNSIGNED NOT NULL,
    `class_id`  INT UNSIGNED NOT NULL,
    PRIMARY KEY (`course_id`, `class_id`),
    KEY `idx_cc_class` (`class_id`),
    CONSTRAINT `fk_cc_course` FOREIGN KEY (`course_id`) REFERENCES `campus_english_courses` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_cc_class` FOREIGN KEY (`class_id`) REFERENCES `campus_english_classes` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Parties d'un cours (texte, vocabulaire, exercice, lien d'évaluation) ───
CREATE TABLE IF NOT EXISTS `campus_english_course_sections` (
    `id`         INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    `uid`        CHAR(16)          NOT NULL,
    `course_id`  INT UNSIGNED      NOT NULL,
    `position`   SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `type`       VARCHAR(16)       NOT NULL,                 -- text | vocabulary | exercise | assessment
    `title`      VARCHAR(160)      NOT NULL DEFAULT '',
    `content`    MEDIUMTEXT        NULL,                     -- JSON (texte mis en forme...)
    `ref_id`     INT UNSIGNED      NULL,                     -- évaluation liée (type = assessment)
    `created_at` INT UNSIGNED      NOT NULL DEFAULT 0,
    `updated_at` INT UNSIGNED      NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_section_uid` (`uid`),
    KEY `idx_section_course` (`course_id`, `position`),
    KEY `idx_section_ref` (`type`, `ref_id`),
    CONSTRAINT `fk_section_course` FOREIGN KEY (`course_id`) REFERENCES `campus_english_courses` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Évaluations ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `campus_english_assignments` (
    `id`                INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    `teacher_id`        VARCHAR(64)       NOT NULL,
    `course_id`         INT UNSIGNED      NULL,                  -- cours lié (facultatif)
    `title`             VARCHAR(160)      NOT NULL,
    `description`       TEXT              NULL,
    `theme`             VARCHAR(24)       NOT NULL DEFAULT 'grammar',
    `difficulty`        TINYINT UNSIGNED  NOT NULL DEFAULT 2,
    `duration`          SMALLINT UNSIGNED NOT NULL DEFAULT 20,     -- minutes (0 = illimité)
    `question_count`    SMALLINT UNSIGNED NOT NULL DEFAULT 0,      -- 0 = toutes les questions
    `max_score`         DOUBLE            NOT NULL DEFAULT 20,
    `coefficient`       DOUBLE            NOT NULL DEFAULT 1,
    `opens_at`          INT UNSIGNED      NULL,
    `closes_at`         INT UNSIGNED      NULL,
    `max_attempts`      TINYINT UNSIGNED  NOT NULL DEFAULT 1,      -- 0 = illimité
    `shuffle_questions` TINYINT(1)        NOT NULL DEFAULT 1,
    `shuffle_options`   TINYINT(1)        NOT NULL DEFAULT 1,
    `release_mode`      VARCHAR(16)       NOT NULL DEFAULT 'immediate', -- immediate | manual
    `review_mode`       VARCHAR(16)       NOT NULL DEFAULT 'after_submit', -- after_submit | after_close | never
    `status`            VARCHAR(16)       NOT NULL DEFAULT 'draft', -- draft | published | archived
    `announced_at`      INT UNSIGNED      NULL,
    `published_at`      INT UNSIGNED      NULL,
    `created_at`        INT UNSIGNED      NOT NULL DEFAULT 0,
    `updated_at`        INT UNSIGNED      NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `idx_assign_teacher` (`teacher_id`, `status`),
    KEY `idx_assign_open` (`status`, `announced_at`, `opens_at`),
    CONSTRAINT `fk_assign_course` FOREIGN KEY (`course_id`) REFERENCES `campus_english_courses` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `campus_english_assignment_classes` (
    `assignment_id` INT UNSIGNED NOT NULL,
    `class_id`      INT UNSIGNED NOT NULL,
    PRIMARY KEY (`assignment_id`, `class_id`),
    KEY `idx_ac_class` (`class_id`),
    CONSTRAINT `fk_ac_assignment` FOREIGN KEY (`assignment_id`) REFERENCES `campus_english_assignments` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_ac_class` FOREIGN KEY (`class_id`) REFERENCES `campus_english_classes` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Exercices (série de questions d'un cours OU banque de questions d'une évaluation) ─
CREATE TABLE IF NOT EXISTS `campus_english_exercises` (
    `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `uid`           CHAR(16)     NOT NULL,
    `course_id`     INT UNSIGNED NULL,
    `section_id`    INT UNSIGNED NULL,
    `assignment_id` INT UNSIGNED NULL,
    `title`         VARCHAR(160) NOT NULL DEFAULT '',
    `instructions`  TEXT         NULL,
    `created_at`    INT UNSIGNED NOT NULL DEFAULT 0,
    `updated_at`    INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_exercise_uid` (`uid`),
    UNIQUE KEY `uq_exercise_section` (`section_id`),
    UNIQUE KEY `uq_exercise_assignment` (`assignment_id`),
    KEY `idx_exercise_course` (`course_id`),
    CONSTRAINT `fk_exercise_course` FOREIGN KEY (`course_id`) REFERENCES `campus_english_courses` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_exercise_section` FOREIGN KEY (`section_id`) REFERENCES `campus_english_course_sections` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_exercise_assignment` FOREIGN KEY (`assignment_id`) REFERENCES `campus_english_assignments` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Questions ──────────────────────────────────────────────────────────────
--  `data`     : partie publique (options, phrase à trous, mots à ordonner...)
--  `solution` : partie secrète — JAMAIS envoyée à un élève avant qu'il ait répondu
CREATE TABLE IF NOT EXISTS `campus_english_questions` (
    `id`          INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    `uid`         CHAR(16)          NOT NULL,
    `exercise_id` INT UNSIGNED      NOT NULL,
    `position`    SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `type`        VARCHAR(16)       NOT NULL,
    `prompt`      TEXT              NOT NULL,
    `data`        MEDIUMTEXT        NOT NULL,
    `solution`    MEDIUMTEXT        NOT NULL,
    `explanation` TEXT              NULL,
    `points`      DOUBLE            NOT NULL DEFAULT 1,
    `difficulty`  TINYINT UNSIGNED  NOT NULL DEFAULT 1,
    `theme`       VARCHAR(24)       NOT NULL DEFAULT 'grammar',
    `created_at`  INT UNSIGNED      NOT NULL DEFAULT 0,
    `updated_at`  INT UNSIGNED      NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_question_uid` (`uid`),
    KEY `idx_question_exercise` (`exercise_id`, `position`),
    CONSTRAINT `fk_question_exercise` FOREIGN KEY (`exercise_id`) REFERENCES `campus_english_exercises` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Vocabulaire (mots des parties « vocabulaire » des cours) ───────────────
CREATE TABLE IF NOT EXISTS `campus_english_vocabulary` (
    `id`          INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    `uid`         CHAR(16)          NOT NULL,
    `section_id`  INT UNSIGNED      NOT NULL,
    `course_id`   INT UNSIGNED      NOT NULL,
    `position`    SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `term`        VARCHAR(160)      NOT NULL,
    `translation` VARCHAR(160)      NOT NULL,
    `example`     VARCHAR(255)      NULL,
    `created_at`  INT UNSIGNED      NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_vocab_uid` (`uid`),
    KEY `idx_vocab_section` (`section_id`, `position`),
    KEY `idx_vocab_course` (`course_id`),
    CONSTRAINT `fk_vocab_section` FOREIGN KEY (`section_id`) REFERENCES `campus_english_course_sections` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_vocab_course` FOREIGN KEY (`course_id`) REFERENCES `campus_english_courses` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Résultats : une ligne par exercice d'entraînement ou par tentative d'évaluation ─
CREATE TABLE IF NOT EXISTS `campus_english_results` (
    `id`              INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    `kind`            VARCHAR(16)       NOT NULL,                 -- practice | assessment
    `student_id`      VARCHAR(64)       NOT NULL,
    `class_id`        INT UNSIGNED      NULL,                     -- classe au moment de la tentative
    `course_id`       INT UNSIGNED      NULL,
    `exercise_id`     INT UNSIGNED      NULL,                     -- entraînement uniquement
    `assignment_id`   INT UNSIGNED      NULL,                     -- évaluation uniquement
    `attempt_no`      SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `status`          VARCHAR(16)       NOT NULL DEFAULT 'in_progress',
                      -- entraînement : in_progress | completed
                      -- évaluation   : in_progress | submitted (à corriger) | graded | released | void
    `questions`       TEXT              NULL,                     -- JSON : questions tirées (ordre) pour une évaluation
    `started_at`      INT UNSIGNED      NOT NULL DEFAULT 0,
    `expires_at`      INT UNSIGNED      NULL,                     -- fin du chrono (serveur)
    `submitted_at`    INT UNSIGNED      NULL,
    `graded_at`       INT UNSIGNED      NULL,
    `released_at`     INT UNSIGNED      NULL,
    `score`           DOUBLE            NOT NULL DEFAULT 0,       -- points obtenus
    `max_points`      DOUBLE            NOT NULL DEFAULT 0,
    `grade`           DOUBLE            NULL,                     -- note sur `grade_max`
    `grade_max`       DOUBLE            NULL,
    `percent`         DOUBLE            NULL,
    `best_percent`    DOUBLE            NULL,                     -- meilleur score d'entraînement
    `duration_sec`    INT UNSIGNED      NULL,
    `needs_review`    TINYINT(1)        NOT NULL DEFAULT 0,       -- contient des réponses à corriger
    `auto_submitted`  TINYINT(1)        NOT NULL DEFAULT 0,
    `teacher_comment` TEXT              NULL,
    `graded_by`       VARCHAR(64)       NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_result_practice` (`student_id`, `exercise_id`),
    UNIQUE KEY `uq_result_attempt` (`student_id`, `assignment_id`, `attempt_no`),
    KEY `idx_result_assignment` (`assignment_id`, `status`),
    KEY `idx_result_student` (`student_id`, `kind`, `status`),
    KEY `idx_result_expiry` (`status`, `expires_at`),
    KEY `idx_result_course` (`course_id`, `student_id`),
    CONSTRAINT `fk_result_exercise` FOREIGN KEY (`exercise_id`) REFERENCES `campus_english_exercises` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_result_assignment` FOREIGN KEY (`assignment_id`) REFERENCES `campus_english_assignments` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_result_course` FOREIGN KEY (`course_id`) REFERENCES `campus_english_courses` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_result_class` FOREIGN KEY (`class_id`) REFERENCES `campus_english_classes` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Réponses des élèves (une ligne par question d'un résultat) ─────────────
CREATE TABLE IF NOT EXISTS `campus_english_answers` (
    `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `result_id`   INT UNSIGNED NOT NULL,
    `question_id` INT UNSIGNED NOT NULL,
    `answer`      TEXT         NULL,           -- JSON de la réponse
    `is_correct`  TINYINT(1)   NULL,           -- NULL = en attente de correction
    `points`      DOUBLE       NOT NULL DEFAULT 0,
    `max_points`  DOUBLE       NOT NULL DEFAULT 0,
    `graded`      TINYINT(1)   NOT NULL DEFAULT 0,
    `feedback`    TEXT         NULL,           -- commentaire du professeur
    `answered_at` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_answer` (`result_id`, `question_id`),
    KEY `idx_answer_question` (`question_id`),
    CONSTRAINT `fk_answer_result` FOREIGN KEY (`result_id`) REFERENCES `campus_english_results` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_answer_question` FOREIGN KEY (`question_id`) REFERENCES `campus_english_questions` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Progression par cours ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `campus_english_progress` (
    `student_id`      VARCHAR(64)  NOT NULL,
    `course_id`       INT UNSIGNED NOT NULL,
    `status`          VARCHAR(16)  NOT NULL DEFAULT 'in_progress', -- in_progress | completed
    `last_section_id` INT UNSIGNED NULL,
    `started_at`      INT UNSIGNED NOT NULL DEFAULT 0,
    `updated_at`      INT UNSIGNED NOT NULL DEFAULT 0,
    `completed_at`    INT UNSIGNED NULL,
    PRIMARY KEY (`student_id`, `course_id`),
    KEY `idx_progress_course` (`course_id`, `status`),
    CONSTRAINT `fk_progress_course` FOREIGN KEY (`course_id`) REFERENCES `campus_english_courses` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Parties terminées (le pourcentage est recalculé à partir de la structure actuelle du cours).
CREATE TABLE IF NOT EXISTS `campus_english_progress_sections` (
    `student_id`   VARCHAR(64)  NOT NULL,
    `section_id`   INT UNSIGNED NOT NULL,
    `course_id`    INT UNSIGNED NOT NULL,
    `completed_at` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`student_id`, `section_id`),
    KEY `idx_ps_course` (`course_id`, `student_id`),
    CONSTRAINT `fk_ps_section` FOREIGN KEY (`section_id`) REFERENCES `campus_english_course_sections` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_ps_course` FOREIGN KEY (`course_id`) REFERENCES `campus_english_courses` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Révision du vocabulaire (répétition espacée) ───────────────────────────
CREATE TABLE IF NOT EXISTS `campus_english_vocab_stats` (
    `student_id`   VARCHAR(64)       NOT NULL,
    `word_id`      INT UNSIGNED      NOT NULL,
    `box`          TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `correct`      SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `wrong`        SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `last_seen_at` INT UNSIGNED      NOT NULL DEFAULT 0,
    `due_at`       INT UNSIGNED      NOT NULL DEFAULT 0,
    PRIMARY KEY (`student_id`, `word_id`),
    KEY `idx_vs_word` (`word_id`),
    CONSTRAINT `fk_vs_word` FOREIGN KEY (`word_id`) REFERENCES `campus_english_vocabulary` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Notifications ──────────────────────────────────────────────────────────
--  target_type : user (campus_id) | class (id de classe) | role (student/teacher/admin) | all
CREATE TABLE IF NOT EXISTS `campus_english_notifications` (
    `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `target_type` VARCHAR(8)   NOT NULL,
    `target_id`   VARCHAR(64)  NOT NULL DEFAULT '',
    `sender_id`   VARCHAR(64)  NULL,
    `sender_name` VARCHAR(96)  NULL,
    `kind`        VARCHAR(16)  NOT NULL,          -- course | assessment | result | message | submission | system
    `title`       VARCHAR(120) NOT NULL,
    `body`        VARCHAR(500) NOT NULL DEFAULT '',
    `link_type`   VARCHAR(16)  NULL,              -- course | assessment | result | attempt
    `link_id`     INT UNSIGNED NULL,
    `created_at`  INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `idx_notif_target` (`target_type`, `target_id`, `created_at`),
    KEY `idx_notif_created` (`created_at`),
    KEY `idx_notif_sender` (`sender_id`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `campus_english_notification_reads` (
    `notification_id` INT UNSIGNED NOT NULL,
    `campus_id`       VARCHAR(64)  NOT NULL,
    `read_at`         INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`notification_id`, `campus_id`),
    KEY `idx_nr_campus` (`campus_id`),
    CONSTRAINT `fk_nr_notification` FOREIGN KEY (`notification_id`) REFERENCES `campus_english_notifications` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Journal d'activité (statistiques admin, audit de sécurité) ─────────────
CREATE TABLE IF NOT EXISTS `campus_english_logs` (
    `id`         INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `campus_id`  VARCHAR(64)  NULL,
    `action`     VARCHAR(48)  NOT NULL,
    `target`     VARCHAR(64)  NULL,
    `details`    TEXT         NULL,
    `created_at` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `idx_log_created` (`created_at`),
    KEY `idx_log_campus` (`campus_id`, `created_at`),
    KEY `idx_log_action` (`action`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ─── Méta (version du schéma) ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS `campus_english_meta` (
    `meta_key`   VARCHAR(48)  NOT NULL,
    `meta_value` VARCHAR(255) NOT NULL,
    PRIMARY KEY (`meta_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO `campus_english_meta` (`meta_key`, `meta_value`) VALUES ('schema_version', '1');

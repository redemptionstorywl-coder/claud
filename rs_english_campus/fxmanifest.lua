fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'rs_english_campus'
author 'Redemption Story'
version '1.0.0'
description 'English Campus — plateforme d’apprentissage de l’anglais (téléphone + PC) reliée au compte Campus'

shared_scripts {
    'config/config.lua',
    'shared/utils.lua',
    'shared/constants.lua',
}

client_scripts {
    'bridge/client/phone.lua',
    'bridge/client/pc.lua',
    'client/nui.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- Bibliothèques internes
    'server/lib/core.lua',
    'server/lib/locale.lua',
    'server/lib/db.lua',
    'server/lib/validate.lua',
    'server/lib/grading.lua',
    'server/lib/questions.lua',
    -- Adaptateurs (Campus, framework)
    'bridge/server/framework.lua',
    'bridge/server/campus.lua',
    -- Noyau
    'server/sessions.lua',
    'server/permissions.lua',
    'server/rpc.lua',
    -- Modules métier
    'server/classes.lua',
    'server/notifications.lua',
    'server/live.lua',
    'server/courses.lua',
    'server/exercises.lua',
    'server/assessments.lua',
    'server/grades.lua',
    'server/vocabulary.lua',
    'server/admin.lua',
    'server/main.lua',
}

-- Page NUI propre à la ressource : un « pont » invisible qui relaie les évènements temps réel
-- vers l'application (téléphone / PC) et affiche le mode autonome si besoin.
ui_page 'web/bridge.html'

files {
    'web/bridge.html',
    'web/index.html',
    'web/css/*.css',
    'web/js/*.js',
    'web/js/**/*.js',
    'web/assets/*',
    'web/assets/**/*',
}

dependencies {
    'oxmysql',
}

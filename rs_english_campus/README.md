# English Campus — Redemption Story School RP

Plateforme d'apprentissage de l'anglais pour FiveM, disponible **comme une vraie application du téléphone (sd-phone)** et **comme application de l'ordinateur (rs_pc)**, reliée au **compte Campus** existant du joueur.

- **Élèves :** cours, exercices corrigés instantanément, évaluations chronométrées, notes, progression par compétence et révision du vocabulaire.
- **Professeurs :** éditeur de cours par blocs, banque de questions, évaluations, correction, carnet de notes, suivi en direct pendant le cours et messages aux classes.
- **Administration :** classes, rôles, statistiques, tous les cours et journal d'activité.

> Aucune donnée envoyée par l'interface n'est considérée comme fiable. Le serveur vérifie tout : identité, rôle, classe, permissions, cours, évaluation, réponses et points. Un joueur ne peut ni modifier sa note, ni voir les cours d'une autre classe, ni se donner le rôle de professeur.

---

## Sommaire

1. [Dépendances](#1-dépendances)
2. [Installation](#2-installation)
3. [Intégration Campus (identité)](#3-intégration-campus-identité)
4. [Intégration sd-phone](#4-intégration-sd-phone)
5. [Intégration rs_pc](#5-intégration-rs_pc)
6. [Rôles et permissions](#6-rôles-et-permissions)
7. [Guide d'utilisation](#7-guide-dutilisation)
8. [Sécurité](#8-sécurité)
9. [Performances](#9-performances)
10. [Base de données](#10-base-de-données)
11. [Exports et commandes](#11-exports-et-commandes)
12. [Fichiers à modifier dans vos ressources](#12-fichiers-à-modifier-dans-vos-ressources)
13. [Tests et développement](#13-tests-et-développement)
14. [Dépannage](#14-dépannage)
15. [Structure des fichiers](#15-structure-des-fichiers)

---

## 1. Dépendances

| Ressource | Obligatoire | Pourquoi |
|---|---|---|
| **oxmysql** | **Oui** | Le seul prérequis. English Campus stocke les cours, les copies, les notes et la progression dans votre base MySQL/MariaDB. oxmysql est la bibliothèque SQL standard de FiveM. Toutes les requêtes sont préparées : aucune concaténation de données joueur. |
| sd-phone | Non (recommandé) | Application native du téléphone. Sans téléphone, l'app s'ouvre dans son propre cadre (`/english`). |
| rs_pc | Non | Application de l'ordinateur. Sans rs_pc, une fenêtre « ordinateur » autonome est disponible (`/englishpc` ou des postes à placer sur la carte). |
| campus | Non (recommandé) | Source de l'identité : le compte Campus. Plusieurs modes de lecture sont disponibles (§3). |
| ESX / QBCore / Qbox | **Non** | Détectés automatiquement s'ils sont présents : ils servent au repli d'identité, aux jobs « professeur » et aux groupes admin. Rien n'est requis. |

---

## 2. Installation

1. Copiez le dossier `rs_english_campus` dans vos ressources, par exemple `resources/[1_Scripts]/[5_Addons]/rs_english_campus`.
2. Dans `server.cfg`, respectez cet ordre de démarrage :

   ```cfg
   ensure oxmysql
   ensure campus          # votre ressource Campus
   ensure sd-phone        # le téléphone
   ensure rs_pc           # l'ordinateur
   ensure rs_english_campus
   ```

   English Campus se réenregistre tout seul si le téléphone ou le PC redémarre après lui. L'ordre ci-dessus reste le plus propre.

3. Donnez les droits d'administration (ACE, sans framework) :

   ```cfg
   add_ace group.admin englishcampus.admin allow
   # Facultatif : professeurs par ACE (sinon, ils sont reconnus via le compte Campus)
   add_ace group.teacher englishcampus.teacher allow
   add_principal identifier.license:xxxxxxxx group.teacher
   ```

4. Ouvrez `config/config.lua` et réglez au minimum `Config.Campus` (§3).
5. Démarrez le serveur. Au premier lancement, les tables sont créées automatiquement (`Config.Database.AutoInstall = true`) et les classes par défaut sont ajoutées. Si vous préférez, importez `sql/install.sql` à la main : il est idempotent.
6. La console affiche : `Prêt — Campus : export | téléphone : sd-phone | PC : rs_pc | framework : …`

---

## 3. Intégration Campus (identité)

English Campus **ne crée aucun compte**. À chaque ouverture, le serveur lit le compte Campus du joueur et en déduit :

- son identifiant Campus ;
- son personnage ;
- son rôle (élève, professeur ou admin) ;
- sa classe ;
- son professeur d'anglais.

Le résultat est mis en cache pendant 5 min (`CacheSeconds`) pour éviter les requêtes répétées.

Choisissez le mode dans `Config.Campus.Mode` :

| Mode | Fonctionnement | À faire dans `campus` |
|---|---|---|
| `export` (défaut) | `exports.campus:GetPlayerAccount(source)` | Ajouter l'export ci-dessous, sauf si un export équivalent existe déjà : renseignez alors son nom dans `Config.Campus.Export`. |
| `statebag` | Lit `Player(source).state.campus` | Mettre le compte dans le state bag du joueur. |
| `sql` | Lit directement la table des comptes Campus | Rien. Renseignez `Config.Campus.Sql` (table, colonne, type d'identifiant). |
| `push` | Le Campus envoie le compte : `exports.rs_english_campus:SetCampusAccount(source, compte)` | Appeler l'export à la connexion et à chaque changement. |
| `framework` | Identité = personnage ESX/QBCore/Qbox | Rien (utile pour tester sans Campus). |
| `custom` | `Config.Campus.Custom(source)` | Rien : écrivez votre lecture dans la config. |

Le repli `Config.Campus.Fallback` (par défaut `'framework'`) est utilisé si le mode principal échoue. Mettez-le à `false` pour refuser l'accès aux joueurs sans compte Campus.

### Export à ajouter dans votre ressource `campus` (mode `export`)

Fichier suggéré : `campus/server/english_campus.lua`, à déclarer dans les `server_scripts` du `fxmanifest.lua` de campus.

```lua
-- Donne à English Campus le compte Campus d'un joueur (lecture seule).
exports('GetPlayerAccount', function(source)
    local account = GetCampusAccountOf(source) -- ⚠ remplacez par VOTRE fonction qui retrouve le compte
    if not account then return nil end
    return {
        id         = account.id,          -- identifiant Campus unique (OBLIGATOIRE)
        citizenid  = account.citizenid,   -- personnage (facultatif)
        firstname  = account.firstname,
        lastname   = account.lastname,
        class      = account.class,       -- « Terminale B » ou un code (« TB »)
        role       = account.role,        -- « eleve », « professeur », « admin »…
        student_id = account.student_id,  -- n° étudiant affiché (facultatif)
        title      = account.title,       -- « Mr. », « Mrs. »… pour les professeurs (facultatif)
    }
end)
```

- **Noms de champs différents ?** Ne touchez pas au Campus : adaptez `Config.Campus.Fields`. Les chemins imbriqués sont acceptés, par exemple `class = 'school.class.label'`.
- **Valeurs de rôle différentes ?** Complétez `Config.Campus.RoleMap`. La comparaison ignore les accents et les majuscules.
- **Classes :** la classe du Campus est reconnue par son nom ou son code. Si elle n'existe pas encore, elle est créée automatiquement (`AutoCreateFromCampus`). Des alias sont possibles dans `Config.Classes.Aliases`.
- **Changement de classe ou de rôle en jeu :** appelez `exports.rs_english_campus:RefreshProfile(source)`, ou déclenchez un des évènements de `Config.Campus.RefreshEvents`, par exemple `TriggerEvent('campus:server:accountUpdated', source)`. L'application du joueur se met à jour immédiatement.

---

## 4. Intégration sd-phone

**Aucune modification de sd-phone n'est nécessaire.** English Campus utilise l'API officielle des applications tierces de sd-phone :

- `addCustomApp` pour l'icône, l'App Store et la page de l'app ;
- `sendCustomAppMessage` pour le temps réel ;
- `showNotification` pour les bannières ;
- `openApp` pour ouvrir l'écran concerné quand on touche une notification.

Réglages dans `Config.Phone` :

- `DefaultApp = true` : l'app est préinstallée. Avec `false`, elle se télécharge dans l'App Store.
- `Notifications` : bannières « Nouveau cours », « Nouvelle évaluation », « Note disponible ».
- `DeepLinks` : toucher la bannière ouvre directement le cours, l'évaluation ou le résultat.
- Le thème clair/sombre suit celui du téléphone (`Config.Theme.Mode = 'auto'`).

Téléphone compatible lb-phone ? Mettez `Adapter = 'lb-phone'`. Sans téléphone, mettez `Adapter = 'standalone'` : l'app s'ouvre dans un cadre de téléphone propre avec `/english`.

---

## 5. Intégration rs_pc

Au démarrage, English Campus appelle **côté client** :

```lua
exports[Config.PC.Resource][Config.PC.RegisterExport]({
    id = 'english_campus', name = 'English Campus', description = '…',
    icon = 'https://cfx-nui-rs_english_campus/web/assets/icon.png',
    url  = 'https://cfx-nui-rs_english_campus/web/index.html?host=pc',
    width = 1180, height = 760, resource = 'rs_english_campus',
})
```

rs_pc n'a qu'une chose à faire : **afficher `url` dans une fenêtre (iframe)**. L'app gère elle-même ses données, son temps réel et ses échanges avec le serveur.

### Si rs_pc possède déjà un système d'applications externes

Mettez simplement le nom de son export dans `Config.PC.RegisterExport`.

### Sinon, ajoutez à rs_pc (2 petits ajouts)

**a) Côté client** — nouveau fichier `rs_pc/client/external_apps.lua`, à ajouter aux `client_scripts` :

```lua
-- Applications fournies par d'autres ressources (ex. English Campus).
local externalApps = {}

exports('RegisterApp', function(app)
    if type(app) ~= 'table' or type(app.id) ~= 'string' or type(app.url) ~= 'string' then return false end
    externalApps[app.id] = app
    SendNUIMessage({ action = 'registerExternalApp', app = app }) -- adaptez au format de messages de votre NUI
    return true
end)

-- Si votre NUI est rechargée, renvoyez-lui la liste (à appeler là où rs_pc initialise son bureau).
function GetExternalApps() return externalApps end
```

**b) Côté NUI de rs_pc** — à la réception de `registerExternalApp`, ajoutez une icône sur le bureau. Au clic, ouvrez une fenêtre contenant :

```html
<iframe src="{{ app.url }}" style="width:100%;height:100%;border:0;background:transparent"></iframe>
```

### Solution minimale sans iframe

Une icône de rs_pc peut aussi fermer le PC puis appeler `exports.rs_english_campus:OpenPC()` : cela ouvre la fenêtre « ordinateur » d'English Campus.

### Sans rs_pc

Avec `Config.PC.Adapter = 'standalone'`, ou en repli automatique si l'export est introuvable (`FallbackToStandalone`), la version PC s'ouvre avec `/englishpc`. Vous pouvez aussi placer des postes sur la carte avec `Config.PC.Locations` (touche **E** à proximité).

---

## 6. Rôles et permissions

Ordre de résolution du rôle (le premier qui répond l'emporte) :

1. ACE `englishcampus.admin` ou groupe de `Config.AdminGroups` → **admin**
2. Rôle forcé par un admin dans l'app (Administration → Membres & rôles)
3. ACE `englishcampus.teacher`, groupe de `Config.TeacherGroups` ou job de `Config.TeacherJobs` → **professeur**
4. Rôle du compte Campus (`RoleMap`)
5. Par défaut → **élève**

Les capacités de chaque rôle sont réglables dans `Config.Permissions`. Les contrôles de propriété s'ajoutent toujours côté serveur, quelle que soit la matrice :

- un professeur ne modifie que **ses** cours et évaluations ;
- il ne voit que **ses** classes ;
- un élève ne voit que les contenus **publiés pour sa classe**.

Un admin serveur (ACE ou groupe) reste admin même si quelqu'un tente de le rétrograder dans l'app.

---

## 7. Guide d'utilisation

### Élève

- **Accueil** — « Bonjour Lucas ». On y trouve :
  - la classe et le professeur ;
  - la progression globale ;
  - les raccourcis (Mes cours, Exercices, Ma progression, Mes résultats, Notifications) ;
  - les évaluations à faire, les cours à reprendre, les nouveaux cours et les dernières notes.
- **Cours** — les cours de sa classe, filtrables : à commencer, en cours, terminés.
  - Chaque cours se lit partie par partie : leçon, vocabulaire (liste ou cartes), exercice, évaluation finale.
- **Exercices** — correction immédiate avec explication. Les points partiels et les fautes de frappe légères sont acceptés et signalés. On peut recommencer : le meilleur score est conservé.
- **Évaluations** — le chrono est tenu par le serveur et continue même si l'app est fermée.
  - Les réponses sont enregistrées automatiquement.
  - Une vue d'ensemble permet de naviguer entre les questions et de marquer celles à revoir.
  - La copie est rendue automatiquement à la fin du temps.
  - Résultat : **16/20, 80 %, temps 14 min 32**, puis **Voir mes réponses** (selon le réglage du professeur).
- **Progrès** — progression globale et par compétence (Vocabulaire, Grammaire, Conjugaison, Compréhension, Expression), moyenne et historique des notes.
- **Vocabulaire** — tous les mots des cours publiés, avec un **mode révision** à répétition espacée (boîtes de Leitner) dans les deux sens.

### Professeur

- **Accueil** — actions rapides, statistiques, copies à corriger, classes, notifications.
- **Mes cours → Créer un cours** — l'éditeur par blocs permet d'ajouter, modifier, supprimer et déplacer les blocs.
  - Il propose aussi : aperçu élève, brouillon, publier, dépublier, dupliquer, archiver.
  - Une sauvegarde locale protège les modifications non enregistrées.
- **Types de contenu** :
  - texte ;
  - vocabulaire (import rapide « anglais = français = exemple ») ;
  - traduction ;
  - QCM (une ou plusieurs bonnes réponses) ;
  - vrai/faux ;
  - réponse courte (« trouver la bonne réponse ») ;
  - texte à trous ;
  - remettre dans l'ordre ;
  - association ;
  - expression écrite, corrigée à la main.
- **Chaque question** a :
  - une consigne ;
  - des réponses ;
  - la bonne réponse ;
  - une explication (facultative) ;
  - des points et une difficulté ;
  - un aperçu élève en direct.
- **Mes évaluations** — réglages disponibles :
  - nom, description et classes ;
  - durée, nombre de questions tirées, difficulté ;
  - note maximale et coefficient ;
  - dates d'ouverture et de fermeture ;
  - tentatives ;
  - publication des notes (immédiate ou manuelle) ;
  - accès aux réponses après la copie.
- **Résultats** — carnet par évaluation. Le professeur corrige les copies (points bornés au barème de la question, remarque par question, appréciation générale), publie les notes, annule une copie ou autorise une nouvelle tentative.
- **Élèves** — par classe : moyenne, progression, historique et détail par compétence.
- **Suivi en direct** — pendant la scène de cours, la progression de chaque élève s'affiche en temps réel, sur un cours ou une évaluation.
- **Messages aux classes** — notification avec lien vers un cours ou une évaluation (anti-spam : `TeacherMessagesPerHour`).

### Syntaxe des textes de cours

```text
# Titre   ## Sous-titre   **gras**   *italique*   __souligné__   ==surligné==
- liste   1. liste numérotée
> encadré « À retenir »      !> encadré « Exemple »      ---  (séparateur)
I ___ never been to London.   (« ___ » s'affiche comme un trou)
```

Texte à trous : `She {has finished} her homework.` — les réponses acceptées sont séparées par `|` : `I {go|walk} to school`. Une **banque de mots** avec des intrus est possible.

### Administration

L'onglet Administration (PC) donne accès à :

- les statistiques ;
- les classes (créer, renommer, ordonner) ;
- les membres et rôles : forcer le rôle, la classe ou la civilité, et nommer professeur un joueur connecté ;
- tous les cours ;
- le journal d'activité.

---

## 8. Sécurité

- **Un seul point d'entrée réseau** (`rs_english_campus:rpc`). Chaque action est enregistrée avec le rôle et la capacité requis. Tout le reste est refusé.
- **Rien n'est accepté de la NUI** hormis l'intention et le texte saisi. L'identité, le rôle, la classe, les points, la note, le chrono et le statut sont calculés par le serveur.
- **Validation stricte** de chaque champ (types, bornes, longueurs) et requêtes SQL préparées.
- **Aucune solution** n'est envoyée à un élève avant qu'il ait répondu. Les évaluations tirent et mélangent leurs questions côté serveur, et la copie ne contient que les questions tirées.
- **Chrono serveur** : les réponses arrivées après la fin (plus `GraceSeconds` de tolérance réseau) sont refusées. Un balayage rend automatiquement les copies expirées.
- **Verrous par copie** : un double envoi ou deux onglets ouverts ne comptent qu'une fois. Les réponses aux exercices sont idempotentes.
- **Anti-abus** :
  - limitation par joueur (seau à jetons `RateLimit`) ;
  - nombre de requêtes simultanées plafonné ;
  - taille maximale des requêtes ;
  - compteur d'abus avec expulsion facultative (`KickOnAbuse`) ;
  - journal des alertes (Administration → Journal).
- **Interface** : aucun `innerHTML` avec des données. Les textes des cours sont rendus par un moteur de mise en forme maison, donc aucune injection HTML ou script n'est possible.

---

## 9. Performances

- **Aucune boucle permanente.** Le seul thread périodique est le balayage des évaluations (toutes les 30 s, requêtes indexées). Le repérage des postes PC n'existe que si vous en placez, avec une attente adaptative.
- **Chargement à la demande :** chaque écran ne charge que ses données, à l'ouverture.
- **Caches serveur :**
  - structure des cours et des évaluations (invalidée à l'enregistrement) ;
  - profils joueurs ;
  - classes.
- **Gros volumes :** envoyés en évènements *latents*, pour ne pas saturer le réseau.
- **Interface légère :** JavaScript natif sans framework, polices et icônes embarquées, aucune ressource externe.

---

## 10. Base de données

Les 20 tables sont préfixées `campus_english_` et utilisent les **identifiants Campus existants** (`student_id`, `teacher_id` = identifiant Campus) :

| Domaine | Tables |
|---|---|
| Classes et membres | `classes`, `members`, `teacher_classes` |
| Cours | `courses`, `course_classes`, `course_sections`, `exercises`, `questions`, `vocabulary` |
| Évaluations | `assignments`, `assignment_classes` |
| Copies et notes | `results`, `answers` |
| Progression | `progress`, `progress_sections`, `vocab_stats` |
| Notifications | `notifications`, `notification_reads` |
| Administration | `logs`, `meta` |

Les anciennes notifications et les anciens journaux sont purgés automatiquement à chaque démarrage (`RetentionDays`, `LogRetentionDays`).

---

## 11. Exports et commandes

**Serveur**

```lua
exports.rs_english_campus:GetProfile(source)                    -- profil (campusId, role, classId, className…)
exports.rs_english_campus:RefreshProfile(source)                -- relire le compte Campus
exports.rs_english_campus:Notify('class', classId, 'Titre', 'Texte') -- 'user' | 'class' | 'role' | 'all'
exports.rs_english_campus:SetCampusAccount(source, compte)      -- mode 'push'
exports.rs_english_campus:ClearCampusAccount(source)
```

**Client**

```lua
exports.rs_english_campus:OpenApp()   -- ouvre l'app (téléphone ou cadre autonome)
exports.rs_english_campus:OpenPC()    -- ouvre la fenêtre PC autonome
exports.rs_english_campus:Close()
exports.rs_english_campus:IsOpen()
exports.rs_english_campus:GetPCUrl()  -- URL à afficher dans une iframe de PC
```

**Commandes :**

- `/english` : cadre téléphone autonome, désactivable. Une touche est possible via `Config.Standalone.Keybind`.
- `/englishpc` : fenêtre PC.

---

## 12. Fichiers à modifier dans vos ressources

| Ressource | Modification | Obligatoire ? |
|---|---|---|
| `sd-phone` | **Aucune** | — |
| `campus` | Ajouter l'export `GetPlayerAccount` (§3), **ou** choisir le mode `sql`/`statebag`/`push` dans `Config.Campus`. Facultatif : appeler `RefreshProfile(source)` quand la classe ou le rôle change. | Selon le mode |
| `rs_pc` | Ajouter l'export client `RegisterApp` + l'affichage de l'URL dans une iframe (§5), **ou** une icône qui appelle `OpenPC()`. Sans rien, la fenêtre PC autonome prend le relais. | Non |
| `server.cfg` | `ensure` dans l'ordre (§2) + ACE admin. | Oui |
| `rs_english_campus/config/config.lua` | `Config.Campus` (mode, champs, rôles), `Config.PC`, vos classes. | Oui |

---

## 13. Tests et développement

Le code serveur est testé **tel quel** : les vrais fichiers Lua sont exécutés dans un banc de test qui simule l'API FiveM, contre une vraie base MariaDB.

```bash
pip install lupa pymysql cffi
# MariaDB/MySQL local accessible en root sans mot de passe (base créée puis supprimée automatiquement)
python3 tests/test_server.py            # 11 scénarios de bout en bout
python3 tests/test_server.py security   # un seul scénario
```

Scénarios couverts :

- cycle de vie d'un cours et de l'éditeur ;
- publication, notifications et absence de solutions côté élève ;
- correction de tous les types de questions ;
- points partiels et fautes de frappe ;
- évaluation complète ;
- expiration, rendu automatique et ouverture programmée ;
- correction manuelle et publication ;
- **sécurité et permissions** (autre classe, faux professeur, notes gonflées, injection, limitation de débit…) ;
- carnet de notes, suivi en direct et vocabulaire ;
- administration ;
- modes Campus et classes automatiques.

**Interface dans un navigateur**, branchée sur le vrai serveur Lua et des données de démo :

```bash
python3 tests/dev_server.py --port 8765
# http://localhost:8765/index.html?host=phone&as=student   (élève, format téléphone)
# http://localhost:8765/index.html?host=pc&as=teacher      (professeur, format PC)
# http://localhost:8765/index.html?host=pc&as=admin        (administrateur)
```

---

## 14. Dépannage

| Symptôme | Cause probable |
|---|---|
| « Compte Campus introuvable » | `Config.Campus.Mode` ne correspond pas à votre Campus. Mettez `Config.Debug = true` : la console indique pourquoi la lecture échoue. |
| Un professeur est vu comme élève | Ajoutez sa valeur de rôle Campus à `RoleMap`, ou forcez son rôle dans Administration → Membres & rôles, ou utilisez l'ACE `englishcampus.teacher`. |
| L'app n'apparaît pas dans le téléphone | sd-phone doit être démarré, et `Config.Phone.Resource` doit porter le nom exact du dossier. English Campus se réenregistre automatiquement si sd-phone redémarre. |
| « Intégration rs_pc indisponible » dans la console | L'export `RegisterApp` n'existe pas dans rs_pc (§5). La fenêtre autonome est utilisée en attendant. |
| Un élève ne voit aucun cours | Le cours doit être **publié** et ciblé sur **sa classe**. Vérifiez sa classe dans Administration → Membres. |
| « Trop de requêtes » | Protection anti-abus. Ajustez `Config.Security.RateLimit` si vos usages légitimes la déclenchent. |

---

## 15. Structure des fichiers

```text
rs_english_campus/
├─ fxmanifest.lua
├─ config/config.lua            ← toute la configuration
├─ shared/                      ← utilitaires partagés (normalisation des réponses…)
├─ bridge/
│  ├─ server/campus.lua         ← lecture du compte Campus (modes)
│  ├─ server/framework.lua      ← détection ESX / QBCore / Qbox (facultatif)
│  ├─ client/phone.lua          ← sd-phone / lb-phone / autonome
│  └─ client/pc.lua             ← rs_pc / fenêtre autonome
├─ server/
│  ├─ lib/                      ← SQL, validation, moteur de correction, questions
│  ├─ rpc.lua                   ← point d'entrée unique sécurisé + anti-abus
│  ├─ sessions.lua, permissions.lua
│  └─ courses, exercises, assessments, grades, vocabulary, notifications, live, classes, admin, main
├─ client/                      ← relais NUI, ouverture, notifications, deep-links
├─ web/                         ← interface (HTML/CSS/JS natif, polices et icône embarquées)
├─ sql/install.sql
└─ tests/                       ← banc de test Lua + serveur de démo
```

--[[
    English Campus — accès base de données (surcouche oxmysql).

    Pourquoi une surcouche ?
      • Paramètres passés en varargs : `DB.single('... WHERE id = ?', id)`.
        Les valeurs nil sont transformées en NULL littéral dans la requête : une table Lua
        avec des « trous » (nil) est mal sérialisée vers oxmysql, ce qui décalerait les paramètres.
      • Toutes les requêtes sont paramétrées (aucune concaténation de valeurs dans le SQL).
      • Les erreurs SQL sont journalisées et converties en EC.Fail('db_error').
      • Un seul endroit à modifier si vous utilisez une autre bibliothèque SQL.
]]

DB = {}

--- Marqueur explicite pour NULL (équivalent à nil).
DB.NULL = setmetatable({}, { __tostring = function() return 'NULL' end })

--- Remplace les « ? » dont la valeur est nil/DB.NULL par NULL et compacte les paramètres.
---@return string sql, table params
local function prepare(sql, n, ...)
    local args = { ... }
    local params, count, index = {}, 0, 0
    local out = sql:gsub('%?', function()
        index = index + 1
        local value = args[index]
        if value == nil or value == DB.NULL then return 'NULL' end
        count = count + 1
        params[count] = value
        return '?'
    end)
    if index ~= n then
        error(('DB: %d placeholder(s) for %d value(s) in: %s'):format(index, n, sql), 3)
    end
    return out, params
end

local function run(kind, sql, n, ...)
    local query, params = prepare(sql, n, ...)
    local ok, result = pcall(MySQL[kind].await, query, params)
    if not ok then
        EC.Error('SQL error (%s): %s\n  → %s', kind, tostring(result), query)
        EC.Fail('db_error')
    end
    return result
end

--- Liste de lignes.
function DB.query(sql, ...)
    local rows = run('query', sql, select('#', ...), ...)
    if rows == nil then
        EC.Error('SQL query returned nil: %s', sql)
        EC.Fail('db_error')
    end
    return rows
end

--- Première ligne ou nil.
function DB.single(sql, ...)
    return run('single', sql, select('#', ...), ...)
end

--- Première colonne de la première ligne ou nil.
function DB.scalar(sql, ...)
    return run('scalar', sql, select('#', ...), ...)
end

--- INSERT → identifiant auto-incrémenté.
function DB.insert(sql, ...)
    local id = run('insert', sql, select('#', ...), ...)
    if id == nil then
        EC.Error('SQL insert failed: %s', sql)
        EC.Fail('db_error')
    end
    return id
end

--- UPDATE / DELETE → nombre de lignes affectées.
function DB.update(sql, ...)
    return run('update', sql, select('#', ...), ...) or 0
end

--- Requête « fire and forget » (journal d'activité...) : ne bloque pas le thread appelant.
function DB.fire(sql, ...)
    local query, params = prepare(sql, select('#', ...), ...)
    MySQL.insert(query, params)
end

--- Génère « ?, ?, ? » pour une clause IN (n ≥ 1).
function DB.placeholders(n)
    return string.rep('?, ', n - 1) .. '?'
end

--- Transaction : toutes les requêtes réussissent ou aucune n'est appliquée.
---   local tx = DB.transaction()
---   tx:add('UPDATE ... WHERE id = ?', id)
---   tx:commit()
function DB.transaction()
    local tx = { queries = {} }

    function tx:add(sql, ...)
        local query, params = prepare(sql, select('#', ...), ...)
        self.queries[#self.queries + 1] = { query = query, values = params }
        return self
    end

    function tx:size()
        return #self.queries
    end

    function tx:commit()
        if #self.queries == 0 then return true end
        local ok, result = pcall(MySQL.transaction.await, self.queries)
        if not ok or not result then
            EC.Error('SQL transaction failed (%d queries): %s', #self.queries, tostring(result))
            EC.Fail('db_error')
        end
        return true
    end

    return tx
end

--- Exécute un fichier SQL de la ressource (installation). Les requêtes sont séparées par « ; ».
function DB.runFile(path)
    local content = LoadResourceFile(GetCurrentResourceName(), path)
    if not content then return false, 'file not found: ' .. path end
    content = content:gsub('%-%-[^\n]*', '')
    local count = 0
    for chunk in content:gmatch('[^;]+') do
        local statement = EC.U.trim(chunk)
        if statement ~= '' then
            local ok, err = pcall(MySQL.query.await, statement, {})
            if not ok then return false, err end
            count = count + 1
        end
    end
    return true, count
end

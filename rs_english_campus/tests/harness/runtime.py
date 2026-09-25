"""
Banc de test English Campus : exécute le VRAI code serveur Lua (Lua 5.4 via lupa)
contre une vraie base MariaDB/MySQL, avec des joueurs simulés.

Aucune dépendance FiveM : les natives sont remplacées par tests/harness/fivem.lua.
Utilisé par tests/test_server.py et par tests/dev_server.py (aperçu de l'interface).
"""
import datetime
import decimal
import json
import os
import re
import time

import pymysql
from lupa import lua54

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
HARNESS = os.path.dirname(os.path.abspath(__file__))

SERVER_SCRIPTS = [
    'config/config.lua',
    'shared/utils.lua',
    'shared/constants.lua',
    'server/lib/core.lua',
    'server/lib/locale.lua',
    'server/lib/db.lua',
    'server/lib/validate.lua',
    'server/lib/grading.lua',
    'server/lib/questions.lua',
    'bridge/server/framework.lua',
    'bridge/server/campus.lua',
    'server/sessions.lua',
    'server/permissions.lua',
    'server/rpc.lua',
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
]


def manifest_scripts():
    """Vérifie que la liste ci-dessus correspond au fxmanifest (ordre inclus)."""
    text = open(os.path.join(ROOT, 'fxmanifest.lua'), encoding='utf-8').read()
    shared = re.search(r"shared_scripts\s*\{(.*?)\}", text, re.S).group(1)
    server = re.search(r"server_scripts\s*\{(.*?)\}", text, re.S).group(1)
    files = re.findall(r"'([^']+\.lua)'", shared) + [f for f in re.findall(r"'([^']+\.lua)'", server) if not f.startswith('@')]
    return files


class Harness:
    def __init__(self, database='ec_test', user='root', password='', host='localhost', reset=True, config_overrides=None, realtime=False):
        self.database = database
        self.conn = pymysql.connect(host=host, user=user, password=password, charset='utf8mb4', autocommit=True,
                                    unix_socket='/run/mysqld/mysqld.sock' if host == 'localhost' else None)
        if reset:
            with self.conn.cursor() as cur:
                cur.execute(f'DROP DATABASE IF EXISTS `{database}`')
                cur.execute(f'CREATE DATABASE `{database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci')
        self.conn.select_db(database)

        self.realtime = realtime
        self.clock_ms = 1_000_000
        self.epoch_base = int(time.time())
        self._t0 = time.monotonic()
        self.time_offset = 0
        self.players = {}          # src -> dict(name, license, aces:set, account:dict)
        self.outbox = []           # (event, target, args)
        self.errors = []
        self.dropped = []
        self.resources = {'oxmysql': 'started', 'campus': 'started'}
        self.req_id = 0
        self.queries = 0

        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f"package.path = '{HARNESS}/?.lua;' .. package.path")
        host = self.lua.table_from({
            'epoch': lambda: (int(time.time()) if self.realtime else self.epoch_base + self.clock_ms // 1000) + self.time_offset,
            'now_ms': lambda: self._now_ms(),
            'outbox': self._outbox,
            'error': self._error,
            'players': lambda: self.lua.table_from(sorted(self.players.keys())),
            'player_name': lambda src: self.players[src]['name'] if src in self.players else None,
            'player_license': lambda src: self.players[src]['license'] if src in self.players else None,
            'has_ace': lambda src, ace: src in self.players and ace in self.players[src]['aces'],
            'drop': lambda src, reason: self.dropped.append((src, reason)),
            'resource_state': lambda name: self.resources.get(name, 'missing'),
            'load_file': self._load_file,
            'db': self._db,
            'db_transaction': self._db_transaction,
        })
        loader = self.lua.eval('function(code, name, host) return load(code, "@" .. name)(host) end')
        loader(open(os.path.join(HARNESS, 'fivem.lua'), encoding='utf-8').read(), 'fivem.lua', host)

        # Compte Campus simulé : exports.campus:GetPlayerAccount(source)
        self.lua.globals()['__defineExternalExport']('campus', 'GetPlayerAccount', self._campus_account)

        scripts = manifest_scripts()
        assert scripts == SERVER_SCRIPTS, f'fxmanifest order differs from harness list:\n{scripts}'
        for rel in scripts:
            code = open(os.path.join(ROOT, rel), encoding='utf-8').read()
            chunk = self.lua.eval('function(code, name) local f, err = load(code, "@" .. name); if not f then error(err) end; return f end')(code, rel)
            chunk()
            if rel == 'config/config.lua' and config_overrides:
                config_overrides(self.lua.globals().Config, self.lua)

        self.lua.globals()['__mysqlReady']()
        self.run(200)
        if self.errors:
            raise RuntimeError('\n'.join(self.errors))

    # ── Hôte ────────────────────────────────────────────────────────────────
    def _outbox(self, name, target, encoded):
        args = [json.loads(encoded[i]) for i in range(1, len(encoded) + 1)]
        self.outbox.append((name, target, args))

    def _error(self, message):
        self.errors.append(message)
        print('LUA ERROR:', message)

    def _load_file(self, path):
        full = os.path.join(ROOT, path)
        if not os.path.exists(full):
            return None
        return open(full, encoding='utf-8').read()

    def _campus_account(self, src):
        player = self.players.get(src)
        if not player or not player.get('account'):
            return None
        return self.lua.table_from(player['account'])

    # ── Base de données ─────────────────────────────────────────────────────
    @staticmethod
    def _params(params):
        if params is None:
            return []
        return [params[i] for i in range(1, len(params) + 1)]

    @staticmethod
    def _sql(query):
        return query.replace('%', '%%').replace('?', '%s')

    def _convert_value(self, value, desc):
        if value is None:
            return None
        type_code, display_size = desc[1], desc[2]
        if isinstance(value, decimal.Decimal):
            return str(value)  # comme mysql2 par défaut : DECIMAL → chaîne
        if isinstance(value, float):
            return int(value) if value.is_integer() and abs(value) < 2 ** 53 else value
        if isinstance(value, (datetime.datetime, datetime.date)):
            return str(value)
        if isinstance(value, bytes):
            return value.decode('utf-8')
        if type_code == pymysql.constants.FIELD_TYPE.TINY and display_size == 1:
            return bool(value)  # oxmysql : TINYINT(1) → booléen
        return value

    def _rows(self, cur):
        if cur.description is None:
            return []
        out = []
        for row in cur.fetchall():
            item = {}
            for desc, value in zip(cur.description, row):
                converted = self._convert_value(value, desc)
                if converted is not None:
                    item[desc[0]] = converted
            out.append(item)
        return out

    def _to_lua(self, value):
        if isinstance(value, list):
            return self.lua.table_from([self._to_lua(v) for v in value])
        if isinstance(value, dict):
            return self.lua.table_from({k: self._to_lua(v) for k, v in value.items()})
        return value

    def _execute(self, cur, query, params):
        self.queries += 1
        cur.execute(self._sql(query), self._params(params))

    def _db(self, kind, query, params):
        with self.conn.cursor() as cur:
            try:
                self._execute(cur, query, params)
            except Exception as exc:  # noqa: BLE001 — remonté à Lua comme oxmysql
                raise RuntimeError(f'{exc} :: {query}')
            if kind == 'query':
                return self._to_lua(self._rows(cur))
            if kind == 'single':
                rows = self._rows(cur)
                return self._to_lua(rows[0]) if rows else None
            if kind == 'scalar':
                if cur.description is None:
                    return None
                row = cur.fetchone()
                if not row or row[0] is None:
                    return None
                return self._convert_value(row[0], cur.description[0])
            if kind == 'insert':
                return cur.lastrowid
            if kind == 'update':
                return cur.rowcount
        return None

    def _db_transaction(self, queries):
        self.conn.begin()
        try:
            with self.conn.cursor() as cur:
                for i in range(1, len(queries) + 1):
                    q = queries[i]
                    self._execute(cur, q['query'], q['values'])
            self.conn.commit()
            return True
        except Exception as exc:  # noqa: BLE001
            self.conn.rollback()
            print('TRANSACTION FAILED:', exc)
            return False

    # ── Simulation ──────────────────────────────────────────────────────────
    def _now_ms(self):
        if self.realtime:
            return 1_000_000 + int((time.monotonic() - self._t0) * 1000)
        return self.clock_ms

    def run(self, ms=0, until=None, max_ms=60_000):
        """Fait tourner les threads Lua ; avance l'horloge si tout le monde attend."""
        if self.realtime:
            return self._run_realtime(ms, until, max_ms)
        g = self.lua.globals()
        target = self.clock_ms + ms
        spent = 0
        while True:
            g['__tick']()
            if until and until():
                return True
            if self.clock_ms >= target and not until:
                return True
            nxt = g['__nextWake']()
            step = 50 if nxt is None else max(1, min(1000, nxt - self.clock_ms))
            self.clock_ms += step
            spent += step
            if spent > max_ms:
                return False

    def _run_realtime(self, ms, until, max_ms):
        g = self.lua.globals()
        deadline = time.monotonic() + (max_ms if until else ms) / 1000
        while True:
            g['__tick']()
            if until and until():
                return True
            if time.monotonic() >= deadline:
                return not until
            time.sleep(0.002)

    def advance(self, seconds):
        """Avance le temps réel simulé (os.time) sans faire tourner les threads."""
        self.time_offset += seconds

    def add_player(self, src, name, account, aces=()):
        self.players[src] = {
            'name': name,
            'license': f'license:{src:040d}',
            'aces': set(aces),
            'account': account,
        }

    def remove_player(self, src):
        self.players.pop(src, None)
        self.lua.globals()['__trigger']('playerDropped', src, 'left')
        self.run(10)

    def pushes(self, src=None, kind=None, clear=True):
        out = [(t, a[0], a[1]) for (n, t, a) in self.outbox
               if n == 'rs_english_campus:push' and (src is None or t == src) and (kind is None or a[0] == kind)]
        if clear:
            self.outbox = [e for e in self.outbox if e[0] != 'rs_english_campus:push']
        return out

    def rpc(self, src, action, payload=None, raw_payload=None):
        """Appelle une action comme le ferait le client ; retourne (ok, data|error, detail)."""
        self.req_id += 1
        rid = self.req_id
        body = raw_payload if raw_payload is not None else json.dumps(payload or {})
        self.lua.globals()['__trigger']('rs_english_campus:rpc', src, rid, action, body)

        def done():
            return any(n == 'rs_english_campus:rpc:response' and args[0] == rid for (n, t, args) in self.outbox)

        if not self.run(until=done, max_ms=20_000):
            raise TimeoutError(f'RPC {action} timed out; errors={self.errors}')
        for i, (n, t, args) in enumerate(self.outbox):
            if n == 'rs_english_campus:rpc:response' and args[0] == rid:
                del self.outbox[i]
                assert t == src, 'response sent to wrong player'
                body = json.loads(args[1])
                if body.get('ok'):
                    return True, body.get('data'), None
                return False, body.get('error'), body.get('detail')
        raise AssertionError('unreachable')

    def ok(self, src, action, payload=None):
        ok, data, detail = self.rpc(src, action, payload)
        if not ok:
            raise AssertionError(f'{action} failed: {data} ({detail}); lua errors: {self.errors[-3:]}')
        return data

    def fail(self, src, action, payload=None):
        ok, data, detail = self.rpc(src, action, payload)
        if ok:
            raise AssertionError(f'{action} unexpectedly succeeded: {json.dumps(data)[:300]}')
        return data, detail

    def sql(self, query, *params):
        with self.conn.cursor(pymysql.cursors.DictCursor) as cur:
            cur.execute(query, params)
            return cur.fetchall()

"""
Serveur de développement : l'interface English Campus dans un navigateur, branchée sur le VRAI
code serveur Lua (banc de test lupa) et une vraie base MariaDB/MySQL, avec des données de démo.

    python3 tests/dev_server.py [--port 8765] [--no-seed]

Puis ouvrir par exemple :
    http://localhost:8765/index.html?host=phone&as=student     (élève, format téléphone)
    http://localhost:8765/index.html?host=pc&as=teacher        (professeur, format PC)
    http://localhost:8765/index.html?host=pc&as=admin          (administrateur)

Joueurs simulés : teacher (Mr. Anderson), student (Lucas Martin, Terminale B),
student2 (Emma Bernard, Terminale B), other (Thomas Dupont, Seconde A), admin (Claire Proviseur).
"""
import argparse
import json
import mimetypes
import os
import queue
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'harness'))
from runtime import Harness, ROOT  # noqa: E402

WEB = os.path.join(ROOT, 'web')
PLAYERS = {'teacher': 1, 'student': 2, 'student2': 3, 'other': 4, 'admin': 5}

lock = threading.RLock()
subscribers = {}  # src -> [queue]


def build_harness(seed=True):
    h = Harness(database='ec_dev', realtime=True)
    h.add_player(1, 'Teacher', {'id': 'T-100', 'firstname': 'John', 'lastname': 'Anderson', 'role': 'professeur', 'title': 'Mr.'})
    h.add_player(2, 'Lucas', {'id': 'S-200', 'firstname': 'Lucas', 'lastname': 'Martin', 'role': 'eleve', 'class': 'Terminale B', 'student_id': 'RS-2041'})
    h.add_player(3, 'Emma', {'id': 'S-201', 'firstname': 'Emma', 'lastname': 'Bernard', 'role': 'eleve', 'class': 'Terminale B', 'student_id': 'RS-2042'})
    h.add_player(4, 'Thomas', {'id': 'S-300', 'firstname': 'Thomas', 'lastname': 'Dupont', 'role': 'eleve', 'class': 'Seconde A'})
    h.add_player(5, 'Admin', {'id': 'A-1', 'firstname': 'Claire', 'lastname': 'Proviseur', 'role': 'directeur'}, aces=['englishcampus.admin'])
    for src in (1, 2, 3, 4, 5):
        h.ok(src, 'app:init')
    if seed:
        seed_demo(h)
    return h


def seed_demo(h):
    # Le remplissage enchaîne des dizaines d'actions en une seconde : on desserre la limitation de débit le temps du seed.
    limits = h.lua.globals().Config.Security.RateLimit
    saved = (limits.Capacity, limits.RefillPerSecond)
    limits.Capacity, limits.RefillPerSecond = 100000, 100000
    try:
        _seed(h)
    finally:
        limits.Capacity, limits.RefillPerSecond = saved


def _seed(h):
    tb = h.sql("SELECT id FROM campus_english_classes WHERE code = 'TB'")[0]['id']
    ta = h.sql("SELECT id FROM campus_english_classes WHERE code = 'TA'")[0]['id']
    h.ok(1, 'settings:save', {'classIds': [ta, tb]})

    assessment = h.ok(1, 'tassessment:save', {'publish': True, 'assessment': {
        'title': 'English Test #4', 'description': 'Present Perfect — contrôle de fin de séquence.', 'theme': 'grammar',
        'difficulty': 2, 'duration': 20, 'questionCount': 0, 'maxScore': 20, 'maxAttempts': 1, 'classIds': [tb],
        'releaseMode': 'immediate', 'reviewMode': 'after_submit',
        'questions': [
            {'type': 'mcq', 'prompt': 'I ___ never been to London.', 'options': [{'text': 'has'}, {'text': 'have', 'correct': True}, {'text': 'had'}, {'text': 'having'}], 'theme': 'grammar'},
            {'type': 'fill_blank', 'prompt': 'Complete with the present perfect.', 'sentence': 'She {has finished} her homework.', 'theme': 'conjugation', 'points': 2},
            {'type': 'truefalse', 'prompt': '"Since" is used with a point in time.', 'answer': True, 'theme': 'grammar'},
            {'type': 'translation', 'prompt': 'Traduis en anglais.', 'source': "J'ai perdu mes clés.", 'direction': 'fr_en', 'accepted': ['I have lost my keys', "I've lost my keys"], 'theme': 'expression', 'points': 2},
            {'type': 'open', 'prompt': 'Write 3 sentences about what you have done this week.', 'points': 4, 'minWords': 15, 'guidelines': 'Present perfect + just / already / yet.', 'theme': 'expression'},
        ],
    }})
    upcoming = h.ok(1, 'tassessment:save', {'publish': True, 'assessment': {
        'title': 'Vocabulary Quiz — School', 'description': 'Les mots de l’école.', 'theme': 'vocabulary', 'duration': 10,
        'classIds': [tb], 'opensAt': int(time.time()) + 2 * 86400, 'closesAt': int(time.time()) + 2 * 86400 + 3600,
        'questions': [{'type': 'short_answer', 'prompt': 'What does "homework" mean?', 'accepted': ['devoirs', 'les devoirs']}],
    }})

    course = h.ok(1, 'tcourse:save', {'publish': True, 'course': {
        'title': 'The Present Perfect', 'description': 'Apprendre à utiliser le Present Perfect dans différentes situations : expériences, actions récentes, résultats.',
        'theme': 'grammar', 'level': 2, 'duration': 30, 'emblem': 'grammar', 'classIds': [tb],
        'sections': [
            {'type': 'text', 'title': 'Introduction', 'body': "# Le Present Perfect\nOn l'utilise pour relier le **passé** au **présent**.\n\n> Structure : **have / has** + participe passé\n\n- une expérience : *I have visited London.*\n- une action récente : *She has just arrived.*\n- un résultat : *I have lost my keys.*\n\n!> Exemple : ==Have you ever been to New York?== — No, I haven't."},
            {'type': 'vocabulary', 'title': 'School', 'words': [
                {'term': 'teacher', 'translation': 'professeur / enseignant', 'example': 'Our teacher has given us a test.'},
                {'term': 'student', 'translation': 'élève'}, {'term': 'classroom', 'translation': 'salle de classe'},
                {'term': 'homework', 'translation': 'devoirs', 'example': 'I have already done my homework.'},
                {'term': 'timetable', 'translation': 'emploi du temps'}, {'term': 'to fail', 'translation': 'échouer / rater'},
            ]},
            {'type': 'text', 'title': 'Explication : for / since', 'body': "## for + durée\nI have lived here **for** three years.\n\n## since + point de départ\nI have lived here **since** 2021.\n\n> *already* et *just* se placent entre l'auxiliaire et le participe."},
            {'type': 'exercise', 'title': 'Exercice 1 — Choisir', 'instructions': 'Choisis la bonne forme.', 'questions': [
                {'type': 'mcq', 'prompt': 'What is the past participle of "go"?', 'options': [{'text': 'goed'}, {'text': 'went'}, {'text': 'gone', 'correct': True}, {'text': 'going'}], 'explanation': '*go → went → gone* : verbe irrégulier.', 'theme': 'conjugation'},
                {'type': 'truefalse', 'prompt': '"I have seen him yesterday" is correct.', 'answer': False, 'explanation': 'Avec *yesterday* (moment précis et terminé) on utilise le prétérit : *I saw him yesterday.*', 'theme': 'grammar'},
                {'type': 'mcq', 'prompt': 'Choose the time markers used with the present perfect.', 'multiple': True, 'options': [{'text': 'already', 'correct': True}, {'text': 'last week'}, {'text': 'yet', 'correct': True}, {'text': 'in 2010'}], 'points': 2, 'theme': 'grammar'},
            ]},
            {'type': 'exercise', 'title': 'Exercice 2 — Compléter & ordonner', 'questions': [
                {'type': 'fill_blank', 'prompt': 'Complète avec for ou since.', 'sentence': 'I have known her {for} ten years and I have lived here {since} 2019.', 'wordBank': True, 'distractors': ['ago', 'during'], 'points': 2, 'theme': 'grammar'},
                {'type': 'word_order', 'prompt': 'Remets les mots dans l’ordre.', 'sentence': 'Have you ever been to New York?', 'theme': 'grammar'},
                {'type': 'matching', 'prompt': 'Associe chaque verbe à son participe passé.', 'pairs': [{'left': 'eat', 'right': 'eaten'}, {'left': 'write', 'right': 'written'}, {'left': 'see', 'right': 'seen'}, {'left': 'buy', 'right': 'bought'}], 'points': 2, 'theme': 'conjugation'},
                {'type': 'translation', 'prompt': 'Traduis :', 'source': 'She has just finished her homework.', 'direction': 'en_fr', 'accepted': ['Elle vient de finir ses devoirs', 'Elle vient juste de finir ses devoirs', 'Elle vient de terminer ses devoirs'], 'theme': 'comprehension'},
            ]},
            {'type': 'assessment', 'title': 'Évaluation finale', 'assessmentId': assessment['id']},
        ],
    }})
    h.ok(1, 'tcourse:save', {'course': {
        'title': 'Daily Routine', 'description': 'Parler de sa journée au présent simple.', 'theme': 'vocabulary', 'level': 1, 'duration': 20,
        'emblem': 'clock', 'classIds': [tb], 'sections': [{'type': 'text', 'title': 'Morning', 'body': 'I **wake up** at 7.'}],
    }})
    h.ok(1, 'tcourse:save', {'publish': True, 'course': {
        'title': 'London Calling', 'description': 'Découvrir Londres et ses monuments.', 'theme': 'comprehension', 'level': 1, 'duration': 25,
        'emblem': 'globe', 'classIds': [tb, ta], 'sections': [
            {'type': 'text', 'title': 'Welcome to London', 'body': 'London is the capital of England and of the United Kingdom.'},
            {'type': 'exercise', 'title': 'Quiz', 'questions': [{'type': 'truefalse', 'prompt': 'London is the capital of England.', 'answer': True, 'theme': 'comprehension'}]},
        ],
    }})

    # Lucas avance dans le cours
    c = h.ok(2, 'course:get', {'id': course['id']})
    h.ok(2, 'course:start', {'id': course['id']})
    h.ok(2, 'course:section:done', {'courseId': course['id'], 'sectionId': c['sections'][0]['id']})
    h.ok(2, 'course:section:done', {'courseId': course['id'], 'sectionId': c['sections'][1]['id']})
    ex = c['sections'][3]
    h.ok(2, 'exercise:answer', {'courseId': course['id'], 'sectionId': ex['id'], 'questionId': ex['questions'][0]['id'], 'answer': {'choice': 'c'}})

    # Emma a fait l'évaluation (note publiée) ; Lucas a une note sur le quiz Londres
    attempt = h.ok(3, 'assessment:start', {'id': assessment['id']})
    for q in attempt['questions']:
        answer = {'mcq': {'choice': 'b'}, 'fill_blank': {'blanks': ['has finished']}, 'truefalse': {'value': True},
                  'translation': {'text': "I've lost my keys"}, 'open': {'text': 'This week I have visited my grandmother, I have finished a book and I have played football with my friends.'}}[q['type']]
        h.ok(3, 'assessment:save', {'attemptId': attempt['attempt']['id'], 'questionId': q['id'], 'answer': answer})
    h.ok(3, 'assessment:submit', {'attemptId': attempt['attempt']['id']})
    h.ok(1, 'notifications:send', {'classIds': [tb], 'title': 'Sortez vos téléphones !', 'body': 'Ouvrez English Campus : nous travaillons le Present Perfect.'})
    print(f'[dev] demo data ready (course {course["id"]}, assessment {assessment["id"]}, upcoming {upcoming["id"]})')


def pump(h):
    """Distribue les évènements temps réel aux navigateurs (SSE) et fait tourner les threads Lua."""
    while True:
        with lock:
            h.run(20)
            pushes = [(t, a) for (n, t, a) in h.outbox if n == 'rs_english_campus:push']
            h.outbox = [e for e in h.outbox if e[0] != 'rs_english_campus:push']
        for target, args in pushes:
            message = {'action': 'ec:push', 'mid': f'{time.time()}:{id(args)}', 'kind': args[0], 'data': args[1]}
            for q in subscribers.get(target, []):
                q.put(message)
        time.sleep(0.2)


class Handler(BaseHTTPRequestHandler):
    harness = None

    def log_message(self, fmt, *args):  # noqa: D401 — silence
        pass

    def _who(self):
        qs = parse_qs(urlparse(self.path).query)
        return PLAYERS.get((qs.get('as') or ['student'])[0], 2)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == '/events':
            src = self._who()
            q = queue.Queue()
            subscribers.setdefault(src, []).append(q)
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            try:
                while True:
                    try:
                        msg = q.get(timeout=15)
                        self.wfile.write(f'data: {json.dumps(msg)}\n\n'.encode())
                    except queue.Empty:
                        self.wfile.write(b': ping\n\n')
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                subscribers[src].remove(q)
            return
        path = url.path.lstrip('/') or 'index.html'
        full = os.path.normpath(os.path.join(WEB, path))
        if not full.startswith(WEB) or not os.path.isfile(full):
            self.send_error(404)
            return
        self.send_response(200)
        ctype = mimetypes.guess_type(full)[0] or 'application/octet-stream'
        if full.endswith('.js'):
            ctype = 'application/javascript'
        self.send_header('Content-Type', ctype)
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        with open(full, 'rb') as fh:
            self.wfile.write(fh.read())

    def do_POST(self):
        url = urlparse(self.path)
        length = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(length) or b'{}')
        event = unquote(url.path.rsplit('/', 1)[-1])
        src = self._who()
        h = self.harness
        if event == 'ec:rpc':
            with lock:
                h.req_id += 1
                rid = h.req_id
                h.lua.globals()['__trigger']('rs_english_campus:rpc', src, rid, body.get('a'), body.get('p'))

                def done():
                    return any(n == 'rs_english_campus:rpc:response' and a[0] == rid for (n, t, a) in h.outbox)

                h.run(until=done, max_ms=15000)
                result = '{"ok":false,"error":"timeout"}'
                for i, (n, t, a) in enumerate(h.outbox):
                    if n == 'rs_english_campus:rpc:response' and a[0] == rid:
                        result = a[1]
                        del h.outbox[i]
                        break
            return self._json(result, raw=True)
        if event == 'ec:boot':
            with lock:
                cfg = h.lua.globals().Config
                theme = {k: cfg.Theme[k] for k in ('Mode', 'Accent', 'Correct', 'Wrong', 'Gold', 'Radius', 'Animations')}
                data = {'resource': 'rs_english_campus', 'appName': cfg.AppName, 'schoolName': cfg.SchoolName, 'locale': cfg.Locale, 'theme': theme}
            return self._json(json.dumps(data), raw=True)
        return self._json('true', raw=True)

    def _json(self, text, raw=False):
        payload = text.encode() if raw else json.dumps(text).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--no-seed', action='store_true')
    args = parser.parse_args()
    h = build_harness(seed=not args.no_seed)
    Handler.harness = h
    threading.Thread(target=pump, args=(h,), daemon=True).start()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    print(f'[dev] English Campus → http://localhost:{args.port}/index.html?host=phone&as=student')
    server.serve_forever()


if __name__ == '__main__':
    main()

"""
Scénarios de bout en bout du serveur English Campus (vrai code Lua + vraie base MariaDB).

    python3 tests/test_server.py            # tous les tests
    python3 tests/test_server.py security   # tests dont le nom contient « security »
"""
import json
import sys
import time
import traceback

sys.path.insert(0, __file__.rsplit('/', 1)[0] + '/harness')
from runtime import Harness  # noqa: E402

TEACHER, STUDENT, STUDENT2, OTHER_CLASS, ADMIN, TEACHER2 = 1, 2, 3, 4, 5, 6


def setup(**kwargs):
    h = Harness(**kwargs)
    h.add_player(TEACHER, 'Teacher', {'id': 'T-100', 'firstname': 'John', 'lastname': 'Anderson', 'role': 'professeur', 'title': 'Mr.'})
    h.add_player(STUDENT, 'Lucas', {'id': 'S-200', 'firstname': 'Lucas', 'lastname': 'Martin', 'role': 'élève', 'class': 'Terminale B', 'student_id': 'RS-2041'})
    h.add_player(STUDENT2, 'Emma', {'id': 'S-201', 'firstname': 'Emma', 'lastname': 'Bernard', 'role': 'eleve', 'class': 'TB'})
    h.add_player(OTHER_CLASS, 'Thomas', {'id': 'S-300', 'firstname': 'Thomas', 'lastname': 'Dupont', 'role': 'eleve', 'class': 'Seconde A'})
    h.add_player(ADMIN, 'Admin', {'id': 'A-1', 'firstname': 'Claire', 'lastname': 'Proviseur', 'role': 'eleve'}, aces=['englishcampus.admin'])
    h.add_player(TEACHER2, 'Teacher2', {'id': 'T-101', 'firstname': 'Sarah', 'lastname': 'Connor', 'role': 'prof', 'title': 'Mrs.'})
    for src in (TEACHER, STUDENT, STUDENT2, OTHER_CLASS, ADMIN, TEACHER2):
        h.ok(src, 'app:init')
    return h


def class_id(h, label):
    return h.sql('SELECT id FROM campus_english_classes WHERE label = %s', label)[0]['id']


ALL_QUESTIONS = [
    {'type': 'mcq', 'prompt': 'What is the past tense of "go"?', 'points': 1, 'theme': 'conjugation',
     'options': [{'text': 'Goed'}, {'text': 'Went', 'correct': True}, {'text': 'Gone'}, {'text': 'Going'}],
     'explanation': '"go" is irregular: go → went → gone.'},
    {'type': 'truefalse', 'prompt': 'London is the capital of England.', 'answer': True, 'theme': 'comprehension'},
    {'type': 'translation', 'prompt': 'Traduis :', 'source': 'The school', 'direction': 'en_fr', 'accepted': ["L'école", 'une école'], 'theme': 'vocabulary'},
    {'type': 'short_answer', 'prompt': 'What does "school" mean?', 'accepted': ['école'], 'theme': 'vocabulary'},
    {'type': 'fill_blank', 'prompt': 'Complète.', 'sentence': 'I {go|walk} to school every day, and I {have} lunch at noon.', 'theme': 'grammar', 'points': 2},
    {'type': 'word_order', 'prompt': 'Remets dans l’ordre.', 'sentence': 'I have never been to London.', 'theme': 'grammar'},
    {'type': 'matching', 'prompt': 'Associe.', 'pairs': [{'left': 'Apple', 'right': 'Pomme'}, {'left': 'House', 'right': 'Maison'}, {'left': 'School', 'right': 'École'}], 'theme': 'vocabulary', 'points': 3},
    {'type': 'mcq', 'prompt': 'Choose all colours', 'multiple': True, 'points': 2, 'theme': 'vocabulary',
     'options': [{'text': 'Red', 'correct': True}, {'text': 'Blue', 'correct': True}, {'text': 'Dog'}]},
]


def course_payload(h, classes=('Terminale B',), questions=None, title='The Present Perfect'):
    return {
        'title': title, 'description': 'Apprendre à utiliser le Present Perfect.', 'theme': 'grammar',
        'level': 2, 'duration': 30, 'emblem': 'grammar',
        'classIds': [class_id(h, c) for c in classes],
        'sections': [
            {'type': 'text', 'title': 'Introduction', 'body': '# Present perfect\n**have** + past participle.'},
            {'type': 'vocabulary', 'title': 'School', 'words': [
                {'term': 'teacher', 'translation': 'professeur / enseignant'},
                {'term': 'student', 'translation': 'élève'},
                {'term': 'homework', 'translation': 'devoirs', 'example': 'I have done my homework.'},
            ]},
            {'type': 'exercise', 'title': 'Exercice 1', 'instructions': 'Réponds aux questions.', 'questions': questions or ALL_QUESTIONS},
        ],
    }


CORRECT_ANSWERS = [
    {'choice': 'b'},
    {'value': True},
    {'text': "l'ecole"},                   # sans accent, minuscules
    {'text': 'École.'},                    # ponctuation ignorée
    {'blanks': ['walk', 'HAVE']},
    None,                                   # word order : dépend du mélange → reconstruit dans le test
    None,                                   # matching : reconstruit
    {'choices': ['a', 'b']},
]


def create_published_course(h, **kwargs):
    saved = h.ok(TEACHER, 'tcourse:save', {'course': course_payload(h, **kwargs)})
    h.ok(TEACHER, 'tcourse:status', {'id': saved['id'], 'status': 'published'})
    return saved['id']


# ─────────────────────────────────────────────────────────────────────────────

def test_course_roundtrip_and_editor():
    h = setup()
    saved = h.ok(TEACHER, 'tcourse:save', {'course': course_payload(h)})
    course = saved['course']
    assert course['status'] == 'draft'
    assert [s['type'] for s in course['sections']] == ['text', 'vocabulary', 'exercise']
    qs = course['sections'][2]['questions']
    assert len(qs) == len(ALL_QUESTIONS)
    assert qs[0]['options'][1]['correct'] is True and qs[0]['options'][0]['correct'] is False
    assert qs[4]['sentence'].startswith('I {go|walk}')
    assert qs[6]['pairs'][2] == {'left': 'School', 'right': 'École'}
    assert course['sections'][1]['words'][0]['translation'] == 'professeur / enseignant'

    # Modification : on garde les uid (les identifiants SQL doivent rester identiques).
    ids_before = {r['uid']: r['id'] for r in h.sql('SELECT id, uid FROM campus_english_questions')}
    course['sections'][2]['questions'][0]['prompt'] = 'Past of go?'
    course['sections'].insert(0, {'type': 'text', 'title': 'Warm-up', 'body': 'Hello'})
    course['sections'][3]['questions'].pop(1)  # suppression d'une question
    saved2 = h.ok(TEACHER, 'tcourse:save', {'course': course})
    ids_after = {r['uid']: r['id'] for r in h.sql('SELECT id, uid FROM campus_english_questions')}
    assert len(ids_after) == len(ALL_QUESTIONS) - 1
    for uid, qid in ids_after.items():
        assert ids_before.get(uid) == qid, 'question ids must be stable across saves'
    assert saved2['course']['sections'][0]['title'] == 'Warm-up'
    assert saved2['course']['sections'][3]['questions'][0]['prompt'] == 'Past of go?'

    # Duplication
    dup = h.ok(TEACHER, 'tcourse:duplicate', {'id': saved['id']})
    copy = h.ok(TEACHER, 'tcourse:get', {'id': dup['id']})
    assert copy['title'].endswith('(copie)') and copy['status'] == 'draft'
    assert len(copy['sections']) == 4
    lst = h.ok(TEACHER, 'tcourses:list')
    assert len(lst) == 2


def test_publish_notifies_and_student_view_has_no_solutions():
    h = setup()
    h.pushes()
    course_id = create_published_course(h)
    h.run(100)
    got = h.pushes(STUDENT, 'notification')
    assert got and 'Anderson' in got[0][2]['body'], got
    assert not h.pushes(OTHER_CLASS, 'notification'), 'other class must not be notified'

    listing = h.ok(STUDENT, 'courses:list')
    assert listing[0]['id'] == course_id and listing[0]['state'] == 'new' and listing[0]['teacher'] == 'Mr. Anderson'
    assert h.ok(OTHER_CLASS, 'courses:list') == []

    course = h.ok(STUDENT, 'course:get', {'id': course_id})
    raw = json.dumps(course)
    for forbidden in ('"solution"', '"accepted"', '"correct"', '"map"', '"sentence"', 'Went"', 'walk'):
        if forbidden == 'Went"':
            continue  # « Went » est une option visible du QCM
        assert forbidden not in raw, f'{forbidden} leaked in student course payload'
    wo = course['sections'][2]['questions'][5]
    assert sorted(wo['tokens']) == sorted('I have never been to London.'.split())
    assert wo['tokens'] != 'I have never been to London.'.split(), 'tokens must be shuffled'

    data, _ = h.fail(OTHER_CLASS, 'course:get', {'id': course_id})
    assert data == 'not_found'
    unread = h.ok(STUDENT, 'notifications:list')
    assert unread['unread'] >= 1
    h.ok(STUDENT, 'notifications:read', {'all': True})
    assert h.ok(STUDENT, 'notifications:list')['unread'] == 0


def answer_all(h, src, course_id, correct=True):
    course = h.ok(src, 'course:get', {'id': course_id})
    section = course['sections'][2]
    results = []
    for i, q in enumerate(section['questions']):
        answer = CORRECT_ANSWERS[i]
        if q['type'] == 'word_order':
            answer = {'words': 'I have never been to London.'.split()}
        if q['type'] == 'matching':
            right = {r['text']: r['id'] for r in q['right']}
            expected = {'Apple': 'Pomme', 'House': 'Maison', 'School': 'École'}
            answer = {'pairs': {l['id']: right[expected[l['text']]] for l in q['left']}}
        if not correct:
            answer = {'choice': 'a'} if q['type'] == 'mcq' else {'value': False} if q['type'] == 'truefalse' else {'text': 'nope', 'blanks': ['x', 'y'], 'words': ['London', 'I'], 'pairs': {}}
        # Tentative de triche : l'élève envoie des points et un statut → ignorés.
        answer = dict(answer or {}, points=999, correct=True)
        fb = h.ok(src, 'exercise:answer', {'courseId': course_id, 'sectionId': section['id'], 'questionId': q['id'], 'answer': answer})
        results.append(fb)
    return course, results


def test_practice_grading_all_types():
    h = setup()
    course_id = create_published_course(h)
    course, results = answer_all(h, STUDENT, course_id, correct=True)
    for i, fb in enumerate(results):
        assert fb['correct'] is True, (i, fb)
        assert fb['points'] == fb['max'], (i, fb)
        assert 'solution' in fb
    assert results[0]['explanation'].startswith('"go" is irregular')
    last = results[-1]['exercise']
    assert last['completed'] is True and last['percent'] == 100
    assert last['progress']['done'] == 1 and last['progress']['total'] == 3

    # Rejouer une question déjà répondue ne change rien.
    q = course['sections'][2]['questions'][0]
    again = h.ok(STUDENT, 'exercise:answer', {'courseId': course_id, 'sectionId': course['sections'][2]['id'], 'questionId': q['id'], 'answer': {'choice': 'a'}})
    assert again['alreadyAnswered'] and again['correct'] is True

    # Parties de lecture → cours terminé à 100 %.
    for s in course['sections'][:2]:
        prog = h.ok(STUDENT, 'course:section:done', {'courseId': course_id, 'sectionId': s['id']})
    assert prog['completed'] and prog['percent'] == 100
    assert h.ok(STUDENT, 'courses:list')[0]['state'] == 'completed'

    # Mauvaises réponses pour l'autre élève + points partiels
    _, wrong = answer_all(h, STUDENT2, course_id, correct=False)
    assert all(fb['correct'] is False for fb in wrong)
    assert wrong[-1]['exercise']['percent'] == 0

    # Recommencer conserve le meilleur score
    reset = h.ok(STUDENT, 'exercise:reset', {'courseId': course_id, 'sectionId': course['sections'][2]['id']})
    assert len(reset['questions']) == len(ALL_QUESTIONS)
    again = h.ok(STUDENT, 'course:get', {'id': course_id})
    assert again['sections'][2]['result']['bestPercent'] == 100
    assert again['sections'][2]['answered'] == 0

    prog = h.ok(STUDENT, 'progress:mine')
    themes = {t['theme']: t.get('percent') for t in prog['themes']}
    assert themes['vocabulary'] == 100 and themes['grammar'] == 100, themes


def test_partial_credit_and_typos():
    h = setup()
    qs = [
        {'type': 'fill_blank', 'prompt': 'x', 'sentence': 'I {have} {been} there.', 'points': 2},
        {'type': 'short_answer', 'prompt': 'Spell "necessary"', 'accepted': ['necessary'], 'tolerance': 1},
        {'type': 'matching', 'prompt': 'x', 'pairs': [{'left': 'a', 'right': '1'}, {'left': 'b', 'right': '2'}], 'points': 2},
        {'type': 'short_answer', 'prompt': 'Contraction', 'accepted': ['I have been'], 'tolerance': 0},
    ]
    course_id = create_published_course(h, questions=qs)
    course = h.ok(STUDENT, 'course:get', {'id': course_id})
    sec = course['sections'][2]
    fb = h.ok(STUDENT, 'exercise:answer', {'courseId': course_id, 'sectionId': sec['id'], 'questionId': sec['questions'][0]['id'], 'answer': {'blanks': ['have', 'gone']}})
    assert fb['correct'] is False and fb['points'] == 1 and fb['partial'] is True, fb
    fb = h.ok(STUDENT, 'exercise:answer', {'courseId': course_id, 'sectionId': sec['id'], 'questionId': sec['questions'][1]['id'], 'answer': {'text': 'neccessary'}})
    assert fb['correct'] is True and fb['typo'] is True, fb
    m = sec['questions'][2]
    right = {r['text']: r['id'] for r in m['right']}
    left = {l['text']: l['id'] for l in m['left']}
    fb = h.ok(STUDENT, 'exercise:answer', {'courseId': course_id, 'sectionId': sec['id'], 'questionId': m['id'], 'answer': {'pairs': {left['a']: right['1'], left['b']: right['1']}}})
    assert fb['points'] == 1 and fb['detail']['pairs'][left['a']] is True, fb
    fb = h.ok(STUDENT, 'exercise:answer', {'courseId': course_id, 'sectionId': sec['id'], 'questionId': sec['questions'][3]['id'], 'answer': {'text': "I've been"}})
    assert fb['correct'] is True, fb


def make_assessment(h, **overrides):
    payload = {
        'title': 'English Test #4', 'description': 'Present Perfect', 'theme': 'grammar', 'difficulty': 2,
        'duration': 20, 'questionCount': 3, 'maxScore': 20, 'maxAttempts': 1, 'releaseMode': 'immediate',
        'reviewMode': 'after_submit', 'classIds': [class_id(h, 'Terminale B')],
        'questions': [
            {'type': 'mcq', 'prompt': 'Q1', 'options': [{'text': 'A', 'correct': True}, {'text': 'B'}]},
            {'type': 'truefalse', 'prompt': 'Q2', 'answer': False},
            {'type': 'short_answer', 'prompt': 'Q3', 'accepted': ['went']},
            {'type': 'mcq', 'prompt': 'Q4', 'options': [{'text': 'A'}, {'text': 'B', 'correct': True}]},
            {'type': 'truefalse', 'prompt': 'Q5', 'answer': True},
        ],
    }
    payload.update(overrides)
    saved = h.ok(TEACHER, 'tassessment:save', {'assessment': payload, 'publish': True})
    return saved['id']


def good_answer(q):
    return {
        'Q1': {'choice': 'a'}, 'Q2': {'value': False}, 'Q3': {'text': 'Went'}, 'Q4': {'choice': 'b'}, 'Q5': {'value': True},
    }[q['prompt']]


def test_assessment_flow():
    h = setup()
    h.pushes()
    aid = make_assessment(h)
    h.run(50)
    assert h.pushes(STUDENT, 'notification'), 'students notified when an assessment opens'
    lst = h.ok(STUDENT, 'assessments:list')
    assert lst[0]['state'] == 'todo' and lst[0]['canStart'] and lst[0]['questionCount'] == 3

    attempt = h.ok(STUDENT, 'assessment:start', {'id': aid})
    qs = attempt['questions']
    assert len(qs) == 3
    assert 'solution' not in json.dumps(attempt) and 'accepted' not in json.dumps(attempt)
    att = attempt['attempt']
    assert att['expiresAt'] - att['startedAt'] == 20 * 60

    # Reprise : même tentative, mêmes questions.
    again = h.ok(STUDENT, 'assessment:start', {'id': aid})
    assert again['attempt']['id'] == att['id'] and [q['id'] for q in again['questions']] == [q['id'] for q in qs]

    # Réponse à une question hors tirage → refusée.
    all_ids = [r['id'] for r in h.sql('SELECT id FROM campus_english_questions')]
    foreign = [i for i in all_ids if i not in [q['id'] for q in qs]][0]
    err, _ = h.fail(STUDENT, 'assessment:save', {'attemptId': att['id'], 'questionId': foreign, 'answer': {'value': True}})
    assert err == 'not_found'
    # Un autre élève ne peut pas écrire dans la copie.
    err, _ = h.fail(STUDENT2, 'assessment:save', {'attemptId': att['id'], 'questionId': qs[0]['id'], 'answer': {}})
    assert err == 'not_found'

    for i, q in enumerate(qs):
        ans = good_answer(q) if i < 2 else {'text': 'wrong', 'choice': 'a', 'value': not good_answer(q).get('value', True)}
        saved = h.ok(STUDENT, 'assessment:save', {'attemptId': att['id'], 'questionId': q['id'], 'answer': ans})
    assert saved['answered'] == 3

    h.advance(14 * 60 + 32)
    result = h.ok(STUDENT, 'assessment:submit', {'attemptId': att['id']})
    assert result['status'] == 'released'
    assert abs(result['grade'] - 13.5) < 0.01 or abs(result['grade'] - 13.0) < 0.6, result  # 2/3 → 13,33 → arrondi 0.5
    assert result['durationSec'] == 14 * 60 + 32
    assert result['canReview'] and len(result['review']) == 3

    # Double rendu → même résultat, pas de nouvelle correction.
    again = h.ok(STUDENT, 'assessment:submit', {'attemptId': att['id']})
    assert again['id'] == result['id'] and again['grade'] == result['grade']

    err, _ = h.fail(STUDENT, 'assessment:start', {'id': aid})
    assert err == 'no_attempts_left'
    mine = h.ok(STUDENT, 'results:mine')
    assert mine['items'][0]['grade'] == result['grade'] and mine['average'] is not None

    res = h.ok(TEACHER, 'tassessment:results', {'id': aid})
    names = {s['name']: s for s in res['students']}
    assert names['Lucas Martin']['status'] == 'released'
    assert names['Emma Bernard']['status'] == 'not_started'
    assert res['stats']['submitted'] == 1

    # Annulation de tentative → l'élève peut recommencer.
    h.ok(TEACHER, 'attempt:void', {'id': att['id']})
    attempt2 = h.ok(STUDENT, 'assessment:start', {'id': aid})
    assert attempt2['attempt']['attemptNo'] == 2


def test_assessment_expiry_autosubmit_and_window():
    h = setup()
    t = h.ok(STUDENT, 'app:init')['serverNow']
    aid = make_assessment(h, duration=1, questionCount=0, maxAttempts=2)
    attempt = h.ok(STUDENT, 'assessment:start', {'id': aid})
    q = attempt['questions'][0]
    h.ok(STUDENT, 'assessment:save', {'attemptId': attempt['attempt']['id'], 'questionId': q['id'], 'answer': good_answer(q)})
    h.pushes()
    h.advance(60 + 25)  # fin du chrono + délai de grâce
    err, _ = h.fail(STUDENT, 'assessment:save', {'attemptId': attempt['attempt']['id'], 'questionId': q['id'], 'answer': {}})
    assert err == 'attempt_expired'
    row = h.sql('SELECT status, auto_submitted, grade FROM campus_english_results WHERE id = %s', attempt['attempt']['id'])[0]
    assert row['status'] == 'released' and row['auto_submitted'] == 1 and row['grade'] == 4, row

    # Tentative expirée détectée par la surveillance (sans action de l'élève).
    attempt2 = h.ok(STUDENT, 'assessment:start', {'id': aid})
    h.advance(120)
    h.run(31_000)
    row = h.sql('SELECT status, auto_submitted FROM campus_english_results WHERE id = %s', attempt2['attempt']['id'])[0]
    assert row['status'] == 'released' and row['auto_submitted'] == 1, row
    assert h.pushes(STUDENT, 'attempt:closed')

    # Fenêtre d'ouverture
    future = make_assessment(h, title='Later', opensAt=t + 7200, closesAt=t + 10800)
    err, _ = h.fail(STUDENT, 'assessment:start', {'id': future})
    assert err == 'assessment_not_open'
    h.pushes()
    h.advance(7300)
    h.run(31_000)
    assert h.pushes(STUDENT, 'notification'), 'scheduled assessment announced by the sweeper'
    h.ok(STUDENT, 'assessment:start', {'id': future})


def test_manual_grading_and_release():
    h = setup()
    aid = make_assessment(h, releaseMode='manual', questionCount=0, questions=[
        {'type': 'open', 'prompt': 'Describe your school (50 words).', 'points': 4, 'minWords': 5, 'guidelines': 'Use the present perfect.'},
        {'type': 'truefalse', 'prompt': 'Q5', 'answer': True},
    ])
    attempt = h.ok(STUDENT, 'assessment:start', {'id': aid})
    by_prompt = {q['prompt']: q for q in attempt['questions']}
    open_q = by_prompt['Describe your school (50 words).']
    h.ok(STUDENT, 'assessment:save', {'attemptId': attempt['attempt']['id'], 'questionId': open_q['id'], 'answer': {'text': 'My school has been great this year.'}})
    h.ok(STUDENT, 'assessment:save', {'attemptId': attempt['attempt']['id'], 'questionId': by_prompt['Q5']['id'], 'answer': {'value': True}})
    h.pushes()
    result = h.ok(STUDENT, 'assessment:submit', {'attemptId': attempt['attempt']['id']})
    assert result['status'] == 'submitted' and 'grade' not in result, result
    h.run(50)
    assert h.pushes(TEACHER, 'notification'), 'teacher notified: paper to grade'

    view = h.ok(TEACHER, 'attempt:get', {'id': attempt['attempt']['id']})
    assert view['student']['name'] == 'Lucas Martin' and view['needsReview']
    # Points supérieurs au barème → refusés.
    err, detail = h.fail(TEACHER, 'attempt:grade', {'id': view['id'], 'grades': [{'questionId': open_q['id'], 'points': 99}]})
    assert err == 'bad_request', (err, detail)
    # Un élève ne peut pas corriger.
    err, _ = h.fail(STUDENT, 'attempt:grade', {'id': view['id'], 'grades': []})
    assert err == 'forbidden'
    # Un autre professeur non plus.
    err, _ = h.fail(TEACHER2, 'attempt:grade', {'id': view['id'], 'grades': []})
    assert err == 'forbidden'

    h.pushes()
    graded = h.ok(TEACHER, 'attempt:grade', {'id': view['id'], 'grades': [{'questionId': open_q['id'], 'points': 3, 'feedback': 'Good!'}], 'comment': 'Bien joué', 'release': True})
    assert graded['status'] == 'released' and graded['grade'] == 16, graded
    h.run(50)
    notes = h.pushes(STUDENT, 'notification')
    assert notes and '16/20' in notes[-1][2]['body'], notes
    mine = h.ok(STUDENT, 'result:get', {'id': view['id']})
    assert mine['grade'] == 16 and mine['teacherComment'] == 'Bien joué'
    fb = [r for r in mine['review'] if r['type'] == 'open'][0]
    assert fb['teacherFeedback'] == 'Good!' and fb['earned'] == 3


def test_security_and_permissions():
    h = setup()
    course_id = create_published_course(h)
    # Élève → actions professeur
    for action, payload in [('tcourse:save', {'course': course_payload(h)}), ('tcourse:status', {'id': course_id, 'status': 'draft'}),
                            ('tcourses:list', {}), ('students:list', {'classId': 1}), ('admin:overview', {}),
                            ('notifications:send', {'classIds': [1], 'title': 'hi'})]:
        err, _ = h.fail(STUDENT, action, payload)
        assert err == 'forbidden', (action, err)
    # Professeur → cours d'un autre professeur
    err, _ = h.fail(TEACHER2, 'tcourse:get', {'id': course_id})
    assert err == 'forbidden'
    err, _ = h.fail(TEACHER2, 'tcourse:delete', {'id': course_id})
    assert err == 'forbidden'
    # Actions inconnues / charge utile invalide
    err, _ = h.fail(STUDENT, 'grades:set', {})
    assert err == 'unknown_action'
    ok, err, _ = h.rpc(STUDENT, 'course:get', raw_payload='{"id": "1 OR 1=1"}')
    assert not ok and err == 'bad_request'
    ok, err, _ = h.rpc(STUDENT, 'course:get', raw_payload='not json')
    assert not ok and err == 'bad_request'
    ok, err, _ = h.rpc(STUDENT, 'course:get', raw_payload='x' * 300000)
    assert not ok and err == 'payload_too_large'
    # Injection SQL dans une recherche admin (paramétrée)
    res = h.ok(ADMIN, 'admin:members', {'query': "' OR 1=1 --"})
    assert res == []
    # XSS stocké : conservé tel quel (échappé à l'affichage côté interface)
    payload = course_payload(h, title='<img src=x onerror=alert(1)>')
    saved = h.ok(TEACHER, 'tcourse:save', {'course': payload})
    assert saved['course']['title'] == '<img src=x onerror=alert(1)>'
    # Un professeur ne peut pas publier pour une classe qui ne lui est pas attribuée (si restreint)
    h.ok(TEACHER2, 'settings:save', {'classIds': [class_id(h, 'Seconde A')]})
    err, _ = h.fail(TEACHER2, 'tcourse:save', {'course': course_payload(h)})
    assert err == 'forbidden_class'
    # Limitation de débit
    codes = [h.rpc(STUDENT, 'classes:list')[1] for _ in range(60)]
    assert 'rate_limited' in codes
    # Joueur sans compte Campus (fallback framework désactivé)
    h.add_player(9, 'Ghost', None)
    h.lua.globals().Config.Campus.Fallback = False
    err, _ = h.fail(9, 'app:init')
    assert err == 'no_campus_account'


def test_teacher_gradebook_live_and_vocab():
    h = setup()
    course_id = create_published_course(h)
    live = h.ok(TEACHER, 'live:subscribe', {'type': 'course', 'id': course_id})
    assert {e['name'] for e in live['entries']} == {'Lucas Martin', 'Emma Bernard'}
    h.pushes()
    answer_all(h, STUDENT, course_id)
    updates = h.pushes(TEACHER, 'live')
    assert updates and updates[-1][2]['entry']['studentId'] == 'S-200'
    h.ok(TEACHER, 'live:unsubscribe')

    aid = make_assessment(h, questionCount=0)
    attempt = h.ok(STUDENT, 'assessment:start', {'id': aid})
    for q in attempt['questions']:
        h.ok(STUDENT, 'assessment:save', {'attemptId': attempt['attempt']['id'], 'questionId': q['id'], 'answer': good_answer(q)})
    res = h.ok(STUDENT, 'assessment:submit', {'attemptId': attempt['attempt']['id']})
    assert res['grade'] == 20

    tb = class_id(h, 'Terminale B')
    book = h.ok(TEACHER, 'students:list', {'classId': tb})
    lucas = [s for s in book['students'] if s['name'] == 'Lucas Martin'][0]
    assert lucas['average'] == 20 and lucas['progress'] > 0
    detail = h.ok(TEACHER, 'student:detail', {'studentId': 'S-200'})
    assert detail['average'] == 20 and detail['history'][0]['grade'] == 20
    dash = h.ok(TEACHER, 'dashboard:get')['dashboard']
    assert dash['courses']['published'] == 1 and dash['submissions']

    vocab = h.ok(STUDENT, 'vocab:list')
    assert vocab['total'] == 3
    session = h.ok(STUDENT, 'vocab:session', {'direction': 'fr_en', 'size': 5})
    item = [i for i in session['items'] if i['prompt'].startswith('professeur')][0]
    check = h.ok(STUDENT, 'vocab:check', {'wordId': item['wordId'], 'direction': 'fr_en', 'answer': 'Teacher'})
    assert check['correct'] and check['box'] == 1
    check = h.ok(STUDENT, 'vocab:check', {'wordId': item['wordId'], 'direction': 'en_fr', 'answer': 'enseignant'})
    assert check['correct'] and check['box'] == 2
    check = h.ok(STUDENT, 'vocab:check', {'wordId': item['wordId'], 'direction': 'en_fr', 'answer': 'chien'})
    assert not check['correct'] and check['box'] == 0
    err, _ = h.fail(OTHER_CLASS, 'vocab:check', {'wordId': item['wordId'], 'direction': 'en_fr', 'answer': 'x'})
    assert err == 'not_found'

    progress = h.ok(STUDENT, 'progress:mine')
    assert progress['average'] == 20 and progress['courses']['total'] == 1 and progress['vocabulary']['total'] == 3

    msg = h.ok(TEACHER, 'notifications:send', {'classIds': [tb], 'title': 'Sortez vos téléphones', 'body': 'Ouvrez English Campus.'})
    assert msg['sent'] == 1
    assert h.ok(TEACHER, 'notifications:sent')[0]['title'] == 'Sortez vos téléphones'


def test_admin_management():
    h = setup()
    ov = h.ok(ADMIN, 'admin:overview')
    assert ov['members']['students'] >= 3
    classes = h.ok(ADMIN, 'admin:class:save', {'label': 'Terminale C', 'code': 'tc', 'level': 'Terminale'})
    assert any(c['code'] == 'TC' for c in classes)
    err, _ = h.fail(ADMIN, 'admin:class:save', {'label': 'Dup', 'code': 'TC'})
    assert err == 'class_code_taken'
    member = h.ok(ADMIN, 'admin:member:set', {'campusId': 'S-201', 'roleOverride': 'teacher', 'teachingClassIds': [class_id(h, 'Terminale C')]})
    assert member['roleOverride'] == 'teacher'
    h.run(10)
    assert h.pushes(STUDENT2, 'profile:changed')
    prof = h.ok(STUDENT2, 'app:init')['profile']
    assert prof['role'] == 'teacher' and prof['teachingClasses'][0]['label'] == 'Terminale C'
    err, _ = h.fail(ADMIN, 'admin:class:delete', {'id': class_id(h, 'Terminale B')})
    assert err == 'class_not_empty'
    logs = h.ok(ADMIN, 'admin:logs')
    assert any(l['action'] == 'admin.member.set' for l in logs)
    grant = h.ok(ADMIN, 'admin:grant:online', {'serverId': OTHER_CLASS, 'role': 'teacher'})
    assert grant['role'] == 'teacher'
    # L'admin voit et gère tous les cours
    saved = h.ok(TEACHER, 'tcourse:save', {'course': course_payload(h)})
    assert h.ok(ADMIN, 'tcourse:get', {'id': saved['id']})['id'] == saved['id']
    assert len(h.ok(ADMIN, 'tcourses:list', {'scope': 'all'})) == 1
    h.ok(ADMIN, 'tcourse:delete', {'id': saved['id']})


def test_campus_auto_class_and_modes():
    h = setup()
    h.add_player(10, 'New', {'id': 'S-900', 'firstname': 'Nina', 'lastname': 'Roy', 'role': 'eleve', 'class': 'Première Z'})
    prof = h.ok(10, 'app:init')['profile']
    assert prof['className'] == 'Première Z'
    # Changement de classe côté Campus + évènement de rafraîchissement
    h.players[10]['account']['class'] = 'Terminale B'
    h.lua.globals()['__trigger']('campus:server:accountUpdated', 10, 10)
    h.run(10)
    assert h.ok(10, 'app:init')['profile']['className'] == 'Terminale B'
    # Mode push : le Campus fournit le compte lui-même
    h.lua.globals().Config.Campus.Mode = 'push'
    h.lua.globals()['__callOwnExport']('SetCampusAccount', 11, h.lua.table_from({'id': 'S-901', 'firstname': 'Paul', 'lastname': 'Petit', 'class': 'Seconde B'}))
    h.add_player(11, 'Paul', None)
    prof = h.ok(11, 'app:init')['profile']
    assert prof['campusId'] == 'S-901' and prof['className'] == 'Seconde B'


# ─────────────────────────────────────────────────────────────────────────────

def main():
    only = sys.argv[1] if len(sys.argv) > 1 else ''
    tests = [(n, f) for n, f in globals().items() if n.startswith('test_') and only in n]
    failed = 0
    for name, fn in tests:
        start = time.time()
        try:
            fn()
            print(f'  ✓ {name} ({time.time() - start:.1f}s)')
        except Exception:  # noqa: BLE001
            failed += 1
            print(f'  ✗ {name}')
            traceback.print_exc()
    print(f'\n{len(tests) - failed}/{len(tests)} passed')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()

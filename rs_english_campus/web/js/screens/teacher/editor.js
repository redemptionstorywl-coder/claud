/**
 * Professeur — éditeur de cours : informations, parties (texte, vocabulaire, exercice,
 * évaluation finale), réorganisation par glisser-déposer, aperçu, brouillon, publication.
 * Contient aussi l'éditeur de questions (réutilisé par l'éditeur d'évaluations).
 */
import { route, nav } from '../../core/router.js';
import { h, debounce } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr, obj } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { store, local } from '../../core/store.js';
import {
  skeletonDetail, emptyState, toast, toastError, confirmDialog, actionSheet, sheet, busy, promptDialog,
} from '../../core/ui.js';
import { renderMarkdown, plainText } from '../../core/markdown.js';
import {
  field, textInput, textArea, select, segmented, chipSelect, stepper, toggleRow, emblem, EMBLEMS, THEME_ICONS, themeLabel, notice, badge, section,
} from '../../components/widgets.js';
import { questionView, TYPE_ICONS, typeLabel } from '../../components/question.js';
import { statusBadge, courseActions } from './courses.js';

const LIMITS = () => (store.settings && store.settings.limits) || {};
const QUESTION_TYPES = ['mcq', 'truefalse', 'translation', 'short_answer', 'fill_blank', 'word_order', 'matching', 'open'];
const SECTION_ICONS = { text: 'text', vocabulary: 'cards', exercise: 'pen', assessment: 'clipboard' };

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

/** Classes que ce professeur peut cibler. */
export function targetableClasses() {
  const p = store.profile;
  const all = arr(store.classes);
  if (p.allClasses || p.role === 'admin') return all;
  const allowed = new Set(arr(p.teachingClasses).map((c) => c.id));
  return all.filter((c) => allowed.has(c.id));
}

// ─────────────────────────────────────────────────────────────────────────────
//  Questions : modèles, validation, aperçu
// ─────────────────────────────────────────────────────────────────────────────

export function newQuestion(type) {
  const theme = { translation: 'vocabulary', matching: 'vocabulary', open: 'expression', truefalse: 'comprehension' }[type] || 'grammar';
  const q = { type, prompt: '', points: 1, difficulty: 1, theme, explanation: '' };
  if (type === 'mcq') Object.assign(q, { multiple: false, options: [{ text: '', correct: true }, { text: '', correct: false }, { text: '', correct: false }] });
  if (type === 'truefalse') q.answer = true;
  if (type === 'translation') Object.assign(q, { source: '', direction: 'en_fr', accepted: [''], tolerance: 1 });
  if (type === 'short_answer') Object.assign(q, { accepted: [''], tolerance: 1 });
  if (type === 'fill_blank') Object.assign(q, { sentence: '', wordBank: false, distractors: [], tolerance: 1 });
  if (type === 'word_order') Object.assign(q, { sentence: '', alternatives: [] });
  if (type === 'matching') Object.assign(q, { pairs: [{ left: '', right: '' }, { left: '', right: '' }, { left: '', right: '' }] });
  if (type === 'open') Object.assign(q, { minWords: 0, maxWords: 0, guidelines: '' });
  return q;
}

function parseBlanks(sentence) {
  const parts = [];
  const blanks = [];
  const re = /\{([^{}]*)\}/g;
  let last = 0;
  let m;
  const text = String(sentence || '');
  while ((m = re.exec(text))) {
    if (m.index > last) parts.push({ t: text.slice(last, m.index) });
    const accepted = m[1].split('|').map((x) => x.trim()).filter(Boolean);
    blanks.push(accepted);
    parts.push({ b: blanks.length });
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push({ t: text.slice(last) });
  return { parts, blanks };
}

function shuffle(list) {
  const out = list.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

/** Problème bloquant d'une question (clé de traduction) ou null. */
export function questionProblem(q) {
  const needsPrompt = ['mcq', 'truefalse', 'short_answer', 'open'].indexOf(q.type) !== -1;
  if (needsPrompt && !String(q.prompt || '').trim()) return 'editor.errors.prompt';
  if (q.type === 'mcq') {
    const options = arr(q.options).filter((o) => String(o.text || '').trim());
    if (options.length < 2) return 'editor.errors.options';
    const correct = options.filter((o) => o.correct).length;
    if (!correct) return 'editor.errors.noCorrect';
    if (!q.multiple && correct > 1) return 'editor.errors.oneCorrect';
  }
  if (q.type === 'translation' && !String(q.source || '').trim()) return 'editor.errors.source';
  if ((q.type === 'translation' || q.type === 'short_answer') && !arr(q.accepted).some((a) => String(a).trim())) return 'editor.errors.accepted';
  if (q.type === 'fill_blank' && !parseBlanks(q.sentence).blanks.length) return 'editor.errors.blanks';
  if (q.type === 'word_order' && String(q.sentence || '').trim().split(/\s+/).filter(Boolean).length < 2) return 'editor.errors.sentence';
  if (q.type === 'matching' && arr(q.pairs).filter((p) => String(p.left || '').trim() && String(p.right || '').trim()).length < 2) return 'editor.errors.pairs';
  return null;
}

/** Nettoie une question avant l'envoi (le serveur valide de toute façon). */
export function cleanQuestion(q) {
  const out = clone(q);
  const trim = (v) => String(v || '').trim();
  out.prompt = trim(out.prompt);
  out.explanation = trim(out.explanation);
  if (out.type === 'mcq') out.options = arr(out.options).filter((o) => trim(o.text)).map((o) => ({ text: trim(o.text), correct: !!o.correct }));
  if (out.accepted) out.accepted = arr(out.accepted).map(trim).filter(Boolean);
  if (out.alternatives) out.alternatives = arr(out.alternatives).map(trim).filter(Boolean);
  if (out.distractors) out.distractors = arr(out.distractors).map(trim).filter(Boolean);
  if (out.pairs) out.pairs = arr(out.pairs).filter((p) => trim(p.left) && trim(p.right)).map((p) => ({ left: trim(p.left), right: trim(p.right) }));
  if (out.sentence !== undefined) out.sentence = trim(out.sentence);
  if (out.source !== undefined) out.source = trim(out.source);
  return out;
}

/** Forme « élève » d'une question de l'éditeur (aperçu en direct). */
function previewShape(q) {
  const base = { id: 0, type: q.type, prompt: q.prompt, points: q.points || 1 };
  if (q.type === 'mcq') return Object.assign(base, { multiple: !!q.multiple, options: arr(q.options).map((o, i) => ({ id: 'abcdefgh'[i], text: o.text || '…' })) });
  if (q.type === 'translation') return Object.assign(base, { source: q.source || '…', direction: q.direction });
  if (q.type === 'fill_blank') {
    const parsed = parseBlanks(q.sentence);
    const bank = q.wordBank ? shuffle(parsed.blanks.map((b) => b[0]).concat(arr(q.distractors))) : undefined;
    return Object.assign(base, { parts: parsed.parts.length ? parsed.parts : [{ t: '…' }], bank });
  }
  if (q.type === 'word_order') return Object.assign(base, { tokens: shuffle(String(q.sentence || '').split(/\s+/).filter(Boolean)) });
  if (q.type === 'matching') {
    const pairs = arr(q.pairs);
    return Object.assign(base, {
      left: pairs.map((p, i) => ({ id: `l${i}`, text: p.left || '…' })),
      right: shuffle(pairs.map((p, i) => ({ id: `r${i}`, text: p.right || '…' }))),
    });
  }
  if (q.type === 'open') return Object.assign(base, { minWords: q.minWords, maxWords: q.maxWords });
  return base;
}

function questionSummary(q) {
  const text = plainText(q.prompt || (q.type === 'translation' ? q.source : q.sentence) || t(`qdefault.${q.type}`), 90);
  return text;
}

/** Liste de questions éditable (exercice de cours ou banque d'évaluation). */
export function questionList(questions, { onChange, locked, context }) {
  const wrap = h('div.stack');
  const render = () => {
    wrap.replaceChildren();
    if (!questions.length) {
      wrap.appendChild(h('div.card', null, emptyState({ icon: 'help', title: t('editor.noQuestions'), text: t('editor.noQuestionsText'), compact: true })));
    } else {
      wrap.appendChild(h('div.q-edit-list', null, ...questions.map((q, i) => {
        const problem = questionProblem(q);
        return h(`div.q-edit-card${problem ? '.block.invalid' : ''}`, null,
          h('span.n', null, String(i + 1)),
          h('div.emblem.sm', null, icon(TYPE_ICONS[q.type] || 'help', 17)),
          h('div.grow', { style: { cursor: locked ? 'default' : 'pointer', minWidth: '0' }, onClick: () => !locked && editQuestion(questions, i, { onChange: () => { onChange(); render(); }, context }) },
            h('div', { style: { fontSize: '0.6875rem', fontWeight: '700', letterSpacing: '0.08em', textTransform: 'uppercase', color: 'var(--ec-accent)' } }, `${typeLabel(q.type)} · ${tn('question.points', q.points || 1, { n: f.num(q.points || 1) })}`),
            h('div.truncate', { style: { fontWeight: '600' } }, questionSummary(q)),
            problem ? h('div', { style: { fontSize: '0.75rem', color: 'var(--ec-wrong)' } }, t(problem)) : null),
          locked ? null : h('div.block-actions', null,
            h('button.icon-btn', { disabled: i === 0, 'aria-label': t('editor.moveUp'), onClick: () => { questions.splice(i - 1, 0, questions.splice(i, 1)[0]); onChange(); render(); } }, icon('arrowUp', 18)),
            h('button.icon-btn', {
              'aria-label': t('common.more'),
              onClick: async () => {
                const choice = await actionSheet({ options: [
                  { value: 'edit', label: t('common.edit'), icon: 'pen' },
                  { value: 'duplicate', label: t('editor.duplicate'), icon: 'copy' },
                  i < questions.length - 1 ? { value: 'down', label: t('editor.moveDown'), icon: 'arrowDown' } : null,
                  { value: 'delete', label: t('common.delete'), icon: 'trash', danger: true },
                ] });
                if (choice === 'edit') editQuestion(questions, i, { onChange: () => { onChange(); render(); }, context });
                if (choice === 'duplicate') { const copy = clone(q); delete copy.uid; delete copy.id; questions.splice(i + 1, 0, copy); }
                if (choice === 'down') questions.splice(i + 1, 0, questions.splice(i, 1)[0]);
                if (choice === 'delete' && await confirmDialog({ title: t('editor.deleteQuestion'), confirm: t('common.delete'), danger: true })) questions.splice(i, 1);
                if (choice && choice !== 'edit') { onChange(); render(); }
              },
            }, icon('more', 18))));
      })));
    }
    if (!locked) {
      wrap.appendChild(h('button.add-btn', { onClick: () => pickQuestionType((type) => {
        const q = newQuestion(type);
        nav.push('teacher.questionEditor', { question: q, isNew: true, context, onSave: () => { questions.push(q); onChange(); render(); } });
      }) }, icon('plus', 18), t('editor.addQuestion')));
    }
  };
  render();
  return wrap;
}

function editQuestion(questions, index, { onChange, context }) {
  const working = clone(questions[index]);
  nav.push('teacher.questionEditor', {
    question: working,
    context,
    onSave: () => { questions[index] = working; onChange(); },
  });
}

export function pickQuestionType(onPick) {
  const api = sheet({
    title: t('editor.chooseType'),
    content: h('div.type-grid', null, ...QUESTION_TYPES.map((type) => h('button.type-card', { onClick: () => { api.close(); onPick(type); } },
      h('div.emblem.sm', null, icon(TYPE_ICONS[type], 17)),
      h('b', null, typeLabel(type)),
      h('span', null, t(`qtypesHint.${type}`))))),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  Éditeur de cours
// ─────────────────────────────────────────────────────────────────────────────

function emptyCourse() {
  return {
    title: '', description: '', theme: 'grammar', level: 1, emblem: 'book', status: 'draft',
    duration: (store.settings && store.settings.defaultDuration) || 30,
    classIds: targetableClasses().length === 1 ? [targetableClasses()[0].id] : [],
    sections: [],
  };
}

function sectionSummary(s) {
  if (s.type === 'text') return plainText(s.body, 80) || t('editor.emptyText');
  if (s.type === 'vocabulary') return tn('course.words', arr(s.words).length);
  if (s.type === 'exercise') return tn('exercise.questions', arr(s.questions).length);
  if (s.type === 'assessment') return s.assessmentTitle || t('editor.noAssessment');
  return '';
}

function sectionProblem(s) {
  if (s.type === 'exercise') {
    if (!arr(s.questions).length) return 'editor.errors.emptyExercise';
    if (arr(s.questions).some((q) => questionProblem(q))) return 'editor.errors.invalidQuestion';
  }
  if (s.type === 'assessment' && !s.assessmentId) return 'editor.errors.noAssessment';
  if (s.type === 'vocabulary' && arr(s.words).some((w) => !String(w.term || '').trim() || !String(w.translation || '').trim())) return 'editor.errors.incompleteWords';
  return null;
}

function newSection(type, questionType) {
  if (type === 'text') return { type, title: t('editor.defaults.text'), body: '' };
  if (type === 'vocabulary') return { type, title: t('editor.defaults.vocabulary'), words: [{ term: '', translation: '', example: '' }] };
  if (type === 'assessment') return { type, title: t('editor.defaults.assessment') };
  const q = questionType ? [newQuestion(questionType)] : [];
  return { type: 'exercise', title: t('editor.defaults.exercise'), instructions: '', questions: q };
}

function cleanCourse(course) {
  const out = clone(course);
  out.title = String(out.title || '').trim();
  out.description = String(out.description || '').trim();
  out.sections = arr(out.sections).map((s) => {
    const sec = Object.assign({}, s);
    sec.title = String(sec.title || '').trim();
    if (sec.type === 'vocabulary') {
      sec.words = arr(sec.words)
        .filter((w) => String(w.term || '').trim() || String(w.translation || '').trim())
        .map((w) => ({ uid: w.uid, term: String(w.term || '').trim(), translation: String(w.translation || '').trim(), example: String(w.example || '').trim() }));
    }
    if (sec.type === 'exercise') sec.questions = arr(sec.questions).map(cleanQuestion);
    delete sec.assessmentTitle;
    return sec;
  });
  delete out.stats;
  delete out.teacher;
  return out;
}

export function register() {
  route('teacher.courseEditor', {
    title: (ctx) => (ctx.params.id ? t('editor.editCourse') : t('editor.newCourse')),
    hideTabs: true,
    skeleton: skeletonDetail,
    async load(ctx) {
      const course = ctx.params.id ? await rpc('tcourse:get', { id: ctx.params.id }) : emptyCourse();
      const key = `draft:course:${ctx.params.id || 'new'}`;
      const backup = local.get(key, null);
      ctx.set('draft', clone(course));
      ctx.set('dirty', false);
      if (backup && backup.savedAt && (!course.updatedAt || backup.savedAt / 1000 > course.updatedAt) && backup.course) {
        ctx.timeout(async () => {
          const ok = await confirmDialog({ title: t('editor.restoreTitle'), message: t('editor.restoreText', { when: f.ago(Math.round(backup.savedAt / 1000)) }), confirm: t('editor.restore'), icon: 'refresh' });
          if (ok) {
            ctx.set('draft', backup.course);
            ctx.set('dirty', true);
            ctx.rerender();
          } else {
            local.set(key, null);
          }
        }, 250);
      }
      return course;
    },
    onShow(ctx) {
      ctx.rerender();
    },
    confirmLeave: async (ctx) => {
      if (!ctx.get('dirty')) return true;
      return confirmDialog({ title: t('editor.leaveTitle'), message: t('editor.leaveText'), confirm: t('editor.leave'), danger: true });
    },
    actions: (ctx) => (ctx.params.id ? [h('button.icon-btn', {
      'aria-label': t('common.more'),
      onClick: async () => {
        const draft = ctx.get('draft');
        if (!draft) return;
        if (ctx.get('dirty')) {
          toast(t('editor.saveFirst'), { tone: 'info', icon: 'info' });
          return;
        }
        if (await courseActions(Object.assign({ id: ctx.params.id }, draft), ctx)) ctx.refresh();
      },
    }, icon('more', 20))] : []),
    render(ctx) {
      return courseEditor(ctx);
    },
  });

  route('teacher.blockEditor', {
    title: (ctx) => t(`sections.${ctx.params.block.type}`),
    hideTabs: true,
    bell: false,
    onShow(ctx) { ctx.rerender(); },
    render(ctx) {
      return blockEditor(ctx);
    },
  });

  route('teacher.questionEditor', {
    title: (ctx) => typeLabel(ctx.params.question.type),
    subtitle: (ctx) => (ctx.params.isNew ? t('editor.newQuestion') : t('editor.editQuestion')),
    hideTabs: true,
    bell: false,
    confirmLeave: async (ctx) => {
      if (ctx.get('saved') || !ctx.get('touched')) return true;
      return confirmDialog({ title: t('editor.discardQuestion'), confirm: t('editor.discard'), danger: true });
    },
    render(ctx) {
      return questionEditor(ctx);
    },
  });
}

function courseEditor(ctx) {
  const course = ctx.get('draft');
  const L = LIMITS();
  const key = `draft:course:${ctx.params.id || 'new'}`;
  const backup = debounce(() => local.set(key, { savedAt: Date.now(), course }), 800);
  const status = h('span.status-line');
  const paintStatus = () => {
    // Nouveau cours jamais enregistré : ni « non enregistré » alarmant, ni « tout est enregistré » trompeur.
    const isNew = !course.id && !ctx.params.id;
    if (isNew && !ctx.get('dirty')) { status.replaceChildren(icon('info', 14), t('editor.notSavedYet')); return; }
    status.replaceChildren(
      ctx.get('dirty') ? h('span.dirty-dot') : icon('checkCircle', 14),
      ctx.get('dirty') ? t('editor.unsaved') : t('editor.saved'));
  };
  const touch = () => {
    ctx.set('dirty', true);
    backup();
    paintStatus();
  };
  paintStatus();

  const out = h('div.editor-layout');
  const side = h('div.stack.editor-side');
  const main = h('div.stack');

  // Informations générales
  const classes = targetableClasses();
  side.appendChild(h('div.card.form-card', null,
    h('div.row.between', null, h('div.overline', null, t('editor.info')), course.status ? statusBadge(course.status) : null),
    field(t('editor.fields.title'), textInput({ value: course.title, max: L.courseTitle || 120, className: 'serif-input', placeholder: t('editor.placeholders.title'), onInput: (v) => { course.title = v; touch(); } })),
    field(t('editor.fields.description'), textArea({ value: course.description, max: L.courseDescription || 1200, rows: 3, placeholder: t('editor.placeholders.description'), onInput: (v) => { course.description = v; touch(); } })),
    field(t('editor.fields.classes'), classes.length
      ? chipSelect(classes.map((c) => ({ value: c.id, label: c.label })), arr(course.classIds), (ids) => { course.classIds = ids; touch(); })
      : notice(t('editor.noTargetClasses'), 'warn'), { hint: t('editor.classesHint') }),
    h('div.form-grid', null,
      field(t('editor.fields.theme'), select(arr(store.settings && store.settings.themes).map((th) => ({ value: th, label: themeLabel(th) })), course.theme, (v) => { course.theme = v; touch(); })),
      field(t('editor.fields.duration'), stepper(course.duration || 30, { min: 5, max: 600, step: 5, format: (n) => f.minutes(n), onChange: (v) => { course.duration = v; touch(); } }))),
    field(t('editor.fields.level'), segmented([1, 2, 3].map((n) => ({ value: n, label: t(`levels.${n}`) })), course.level || 1, (v) => { course.level = Number(v); touch(); })),
    field(t('editor.fields.emblem'), h('div.emblem-picker', null, ...EMBLEMS.map((name) => {
      const btn = h('button', { type: 'button', class: { on: course.emblem === name }, onClick: () => {
        course.emblem = name;
        btn.parentNode.querySelectorAll('button').forEach((b) => b.classList.remove('on'));
        btn.classList.add('on');
        touch();
      } }, icon(name, 20));
      return btn;
    })))));

  // Parties
  const blocks = h('div.block-list');
  const renderBlocks = () => {
    blocks.replaceChildren();
    const sections = arr(course.sections);
    if (!sections.length) {
      blocks.appendChild(h('div.card', null, emptyState({ icon: 'layers', title: t('editor.noSections'), text: t('editor.noSectionsText'), compact: true })));
      return;
    }
    sections.forEach((s, i) => {
      const problem = sectionProblem(s);
      const el = h(`div.block${problem ? '.invalid' : ''}`, { dataset: { index: String(i) } },
        h('span.handle', { 'aria-label': t('editor.drag') }, icon('grip', 18)),
        h('div.emblem.sm', null, icon(SECTION_ICONS[s.type], 17)),
        h('div.block-main', { onClick: () => openBlock(i) },
          h('div.block-type', null, `${i + 1}. ${t(`sections.${s.type}`)}`),
          h('div.block-title', null, s.title || t(`sections.${s.type}`)),
          h('div.block-sub', { style: problem ? { color: 'var(--ec-wrong)' } : null }, problem ? t(problem) : sectionSummary(s))),
        h('div.block-actions', null,
          h('button.icon-btn', { disabled: i === 0, 'aria-label': t('editor.moveUp'), onClick: () => move(i, i - 1) }, icon('arrowUp', 17)),
          h('button.icon-btn', { disabled: i === sections.length - 1, 'aria-label': t('editor.moveDown'), onClick: () => move(i, i + 1) }, icon('arrowDown', 17)),
          h('button.icon-btn', {
            'aria-label': t('common.more'),
            onClick: async () => {
              const choice = await actionSheet({ options: [
                { value: 'edit', label: t('common.edit'), icon: 'pen' },
                { value: 'duplicate', label: t('editor.duplicate'), icon: 'copy' },
                { value: 'delete', label: t('common.delete'), icon: 'trash', danger: true },
              ] });
              if (choice === 'edit') openBlock(i);
              if (choice === 'duplicate') {
                const copy = clone(s);
                delete copy.uid;
                arr(copy.questions).forEach((q) => { delete q.uid; delete q.id; });
                arr(copy.words).forEach((w) => { delete w.uid; });
                course.sections.splice(i + 1, 0, copy);
                touch();
                renderBlocks();
              }
              if (choice === 'delete' && await confirmDialog({ title: t('editor.deleteSection'), message: t('editor.deleteSectionText'), confirm: t('common.delete'), danger: true, icon: 'trash' })) {
                course.sections.splice(i, 1);
                touch();
                renderBlocks();
              }
            },
          }, icon('more', 17))));
      enableDrag(el, i);
      blocks.appendChild(el);
    });
  };
  const move = (from, to) => {
    if (to < 0 || to >= course.sections.length) return;
    course.sections.splice(to, 0, course.sections.splice(from, 1)[0]);
    touch();
    renderBlocks();
  };
  const openBlock = (i) => nav.push('teacher.blockEditor', { block: course.sections[i], onChange: touch });

  // Glisser-déposer (pointeur) sur la poignée.
  function enableDrag(el, index) {
    const handle = el.querySelector('.handle');
    handle.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      const items = Array.from(blocks.querySelectorAll('.block'));
      let target = index;
      el.classList.add('dragging');
      handle.setPointerCapture(e.pointerId);
      const onMove = (ev) => {
        items.forEach((it) => it.classList.remove('drop-before', 'drop-after'));
        target = index;
        for (let k = 0; k < items.length; k++) {
          const rect = items[k].getBoundingClientRect();
          if (ev.clientY < rect.top + rect.height / 2) { target = k; break; }
          target = k + 1;
        }
        const ref = items[Math.min(target, items.length - 1)];
        if (ref && ref !== el) ref.classList.add(target >= items.length ? 'drop-after' : 'drop-before');
      };
      const onUp = () => {
        handle.removeEventListener('pointermove', onMove);
        handle.removeEventListener('pointerup', onUp);
        handle.removeEventListener('pointercancel', onUp);
        items.forEach((it) => it.classList.remove('drop-before', 'drop-after', 'dragging'));
        let to = target > index ? target - 1 : target;
        to = Math.max(0, Math.min(course.sections.length - 1, to));
        if (to !== index) move(index, to);
      };
      handle.addEventListener('pointermove', onMove);
      handle.addEventListener('pointerup', onUp);
      handle.addEventListener('pointercancel', onUp);
    });
  }

  const add = (type, questionType) => {
    course.sections = arr(course.sections);
    if (course.sections.length >= (L.sections || 60)) return toast(t('editor.tooManySections'), { tone: 'error' });
    const s = newSection(type, questionType);
    course.sections.push(s);
    touch();
    renderBlocks();
    nav.push('teacher.blockEditor', { block: s, onChange: touch, isNew: true });
  };

  main.appendChild(section(t('editor.content'), status, blocks));
  main.appendChild(h('div.add-grid', null,
    h('button.add-btn', { onClick: () => add('text') }, icon('text', 18), t('editor.add.text')),
    h('button.add-btn', { onClick: () => add('vocabulary') }, icon('cards', 18), t('editor.add.vocabulary')),
    h('button.add-btn', { onClick: () => add('exercise', 'short_answer') }, icon('help', 18), t('editor.add.question')),
    h('button.add-btn', { onClick: () => add('exercise', 'mcq') }, icon('choice', 18), t('editor.add.mcq')),
    h('button.add-btn', { onClick: () => add('exercise', 'truefalse') }, icon('toggle', 18), t('editor.add.truefalse')),
    h('button.add-btn', { onClick: () => add('exercise') }, icon('pen', 18), t('editor.add.exercise')),
    h('button.add-btn', { onClick: () => add('assessment') }, icon('clipboard', 18), t('editor.add.assessment'))));
  renderBlocks();

  out.append(side, main);

  // Barre d'actions
  const save = async (publish) => {
    if (!String(course.title || '').trim()) return toast(t('editor.errors.title'), { tone: 'error' });
    if (publish) {
      if (!arr(course.classIds).length) return toast(t('editor.errors.classes'), { tone: 'error' });
      if (!arr(course.sections).length) return toast(t('editor.errors.sections'), { tone: 'error' });
      const bad = arr(course.sections).findIndex((s) => sectionProblem(s));
      if (bad !== -1) return toast(t('editor.errors.fixSection', { n: bad + 1 }), { tone: 'error', body: t(sectionProblem(course.sections[bad])) });
      if (course.status !== 'published' && !(await confirmDialog({ title: t('teacher.publishTitle'), message: t('teacher.publishText'), confirm: t('teacher.courseActions.publish'), icon: 'send' }))) return;
    }
    try {
      const payload = cleanCourse(course);
      if (ctx.params.id) payload.id = ctx.params.id;
      const res = await busy(() => rpc('tcourse:save', { course: payload, publish: !!publish }), publish ? t('editor.publishing') : t('editor.saving'));
      local.set(key, null);
      ctx.params.id = res.id;
      ctx.set('draft', clone(res.course));
      ctx.set('dirty', false);
      toast(publish ? t('editor.publishedToast') : t('editor.savedToast'), { tone: 'success', body: res.course.title });
      nav.invalidate(['teacher.courses', 'teacher.home']);
      ctx.setTitle(t('editor.editCourse'));
      ctx.rerender();
    } catch (err) {
      toastError(err);
    }
  };
  const published = course.status === 'published';
  ctx.footer(h('div.action-bar', null,
    ctx.params.id ? h('button.btn.secondary', { onClick: async () => {
      if (ctx.get('dirty')) await save(false);
      nav.push('student.course', { id: ctx.params.id, preview: true });
    } }, icon('eye', 18), t('editor.preview')) : null,
    h('button.btn.secondary', { onClick: () => save(false) }, icon('check', 18), t('common.save')),
    h('button.btn.primary', { onClick: () => save(true) }, icon('send', 18), published ? t('editor.saveAndUpdate') : t('teacher.courseActions.publish'))));
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Éditeur de partie
// ─────────────────────────────────────────────────────────────────────────────

function blockEditor(ctx) {
  const block = ctx.params.block;
  const changed = () => { if (ctx.params.onChange) ctx.params.onChange(); };
  const L = LIMITS();
  const out = h('div.content-narrow.stack');
  out.appendChild(field(t('editor.fields.sectionTitle'), textInput({ value: block.title || '', max: L.sectionTitle || 120, className: 'serif-input', onInput: (v) => { block.title = v; changed(); } })));

  if (block.type === 'text') out.appendChild(textBlockEditor(block, changed));
  if (block.type === 'vocabulary') out.appendChild(vocabularyEditor(block, changed));
  if (block.type === 'exercise') {
    out.appendChild(field(t('editor.fields.instructions'), textArea({ value: block.instructions || '', max: L.explanation || 1200, rows: 2, placeholder: t('editor.placeholders.instructions'), onInput: (v) => { block.instructions = v; changed(); } })));
    block.questions = arr(block.questions);
    out.appendChild(section(t('editor.questions'), h('span.pill-count', null, String(block.questions.length)), questionList(block.questions, { onChange: changed, context: 'course' })));
  }
  if (block.type === 'assessment') out.appendChild(assessmentLinkEditor(block, changed));

  ctx.footer(h('div.action-bar', null, h('button.btn.primary', { onClick: () => nav.back() }, icon('check', 18), t('editor.done'))));
  return out;
}

function textBlockEditor(block, changed) {
  const area = h('textarea.input', { rows: 12, maxlength: LIMITS().textBody || 12000, placeholder: t('editor.placeholders.text') });
  area.value = block.body || '';
  const preview = h('div.card.preview-box.notebook.hidden');
  const refreshPreview = () => preview.replaceChildren(renderMarkdown(area.value || t('editor.emptyText')));
  area.addEventListener('input', () => { block.body = area.value; changed(); });
  const wrap = (before, after = before, placeholder = t('editor.sample')) => {
    const start = area.selectionStart;
    const end = area.selectionEnd;
    const selected = area.value.slice(start, end) || placeholder;
    area.setRangeText(`${before}${selected}${after}`, start, end, 'end');
    area.focus();
    block.body = area.value;
    changed();
  };
  const linePrefix = (prefix) => {
    const start = area.value.lastIndexOf('\n', area.selectionStart - 1) + 1;
    area.setRangeText(prefix, start, start, 'end');
    area.focus();
    block.body = area.value;
    changed();
  };
  const tool = (ic, label, fn) => h('button', { type: 'button', title: label, 'aria-label': label, onClick: fn }, icon(ic, 17));
  const toolbar = h('div.toolbar', null,
    tool('bold', t('editor.tools.bold'), () => wrap('**')),
    tool('italic', t('editor.tools.italic'), () => wrap('*')),
    tool('underline', t('editor.tools.underline'), () => wrap('__')),
    tool('highlight', t('editor.tools.highlight'), () => wrap('==')),
    h('span.sep'),
    tool('heading', t('editor.tools.heading'), () => linePrefix('## ')),
    tool('list', t('editor.tools.list'), () => linePrefix('- ')),
    tool('quote', t('editor.tools.callout'), () => linePrefix('> ')),
    tool('star', t('editor.tools.example'), () => linePrefix('!> ')));
  const modes = segmented([{ value: 'edit', label: t('editor.write') }, { value: 'preview', label: t('editor.previewTab') }], 'edit', (mode) => {
    const isPreview = mode === 'preview';
    if (isPreview) refreshPreview();
    preview.classList.toggle('hidden', !isPreview);
    area.classList.toggle('hidden', isPreview);
    toolbar.classList.toggle('hidden', isPreview);
  });
  return h('div.stack.tight', null, modes, toolbar, area, preview, h('div.hint.muted', { style: { fontSize: '0.75rem' } }, t('editor.formatHelp')));
}

function vocabularyEditor(block, changed) {
  block.words = arr(block.words);
  const L = LIMITS();
  const wrap = h('div.stack');
  const render = () => {
    wrap.replaceChildren();
    const rows = h('div.vocab-rows');
    block.words.forEach((w, i) => {
      rows.appendChild(h('div.vocab-item', null,
        h('div.vocab-row', null,
          textInput({ value: w.term || '', max: L.term || 120, placeholder: t('editor.placeholders.term'), onInput: (v) => { w.term = v; changed(); } }),
          textInput({ value: w.translation || '', max: L.term || 120, placeholder: t('editor.placeholders.translation'), onInput: (v) => { w.translation = v; changed(); } }),
          h('button.icon-btn', { 'aria-label': t('common.delete'), onClick: () => { block.words.splice(i, 1); changed(); render(); } }, icon('trash', 17)),
          h('div.ex', null, textInput({ value: w.example || '', max: 255, placeholder: t('editor.placeholders.example'), onInput: (v) => { w.example = v; changed(); } })))));
    });
    wrap.appendChild(rows);
    wrap.appendChild(h('div.row', null,
      h('button.add-btn.grow', { onClick: () => { block.words.push({ term: '', translation: '', example: '' }); changed(); render(); } }, icon('plus', 18), t('editor.addWord')),
      h('button.add-btn', { onClick: importWords }, icon('list', 18), t('editor.importWords'))));
  };
  const importWords = async () => {
    const text = await promptDialog({ title: t('editor.importTitle'), message: t('editor.importHelp'), multiline: true, max: 20000, placeholder: 'teacher = professeur\nstudent = élève' });
    if (!text) return;
    let added = 0;
    text.split(/\r?\n/).forEach((line) => {
      const parts = line.split(/\s*(?:=|;|\t|→|->)\s*/).map((x) => x.trim()).filter(Boolean);
      if (parts.length >= 2 && block.words.length < (L.words || 120)) {
        block.words.push({ term: parts[0], translation: parts[1], example: parts[2] || '' });
        added += 1;
      }
    });
    block.words = block.words.filter((w) => String(w.term || '').trim() || String(w.translation || '').trim());
    changed();
    render();
    toast(tn('editor.imported', added), { tone: 'success' });
  };
  render();
  return wrap;
}

function assessmentLinkEditor(block, changed) {
  const wrap = h('div.stack', null, h('div.skeleton.block'));
  rpc('tassessments:list', {}).then((list) => {
    const items = arr(list).filter((a) => a.status !== 'archived');
    wrap.replaceChildren(notice(t('editor.assessmentLinkHelp'), '', 'info'));
    if (!items.length) {
      wrap.appendChild(emptyState({ icon: 'clipboard', title: t('editor.noAssessments'), compact: true,
        action: h('button.btn.secondary', { onClick: () => nav.push('teacher.assessmentEditor', {}) }, icon('plus', 18), t('teacher.quick.newAssessment')) }));
      return;
    }
    wrap.appendChild(h('div.card.list', null, ...items.map((a) => h('button.list-row', {
      onClick: () => {
        block.assessmentId = a.id;
        block.assessmentTitle = a.title;
        if (!block.title || block.title === t('editor.defaults.assessment')) block.title = a.title;
        changed();
        nav.back();
      },
    },
    h(`div.emblem.sm${block.assessmentId === a.id ? '.solid' : ''}`, null, icon(block.assessmentId === a.id ? 'check' : 'clipboard', 17)),
    h('div.main', null, h('div.t', null, a.title), h('div.s', null, `${tn('assessments.questions', a.questionCount)} · ${t(`status.${a.status}`)}`))))));
  }).catch((err) => {
    wrap.replaceChildren(notice(t('errors.title'), 'danger'));
    toastError(err);
  });
  return wrap;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Éditeur de question
// ─────────────────────────────────────────────────────────────────────────────

function listEditor(values, { placeholder, max = 12, min = 1, onChange }) {
  const wrap = h('div.stack.tight');
  const render = () => {
    wrap.replaceChildren();
    values.forEach((v, i) => {
      wrap.appendChild(h('div.input-group', null,
        textInput({ value: v, placeholder, max: 300, onInput: (val) => { values[i] = val; onChange(); } }),
        values.length > min ? h('button.icon-btn', { onClick: () => { values.splice(i, 1); onChange(); render(); } }, icon('close', 17)) : null));
    });
    if (values.length < max) wrap.appendChild(h('button.btn.ghost.sm', { onClick: () => { values.push(''); onChange(); render(); } }, icon('plus', 16), t('editor.addAlternative')));
  };
  render();
  return wrap;
}

function questionEditor(ctx) {
  const q = ctx.params.question;
  const L = LIMITS();
  const out = h('div.editor-layout');
  const form = h('div.stack');
  const previewBox = h('div.card.pad-lg');
  const problemBox = h('div');
  const refresh = debounce(() => {
    const view = questionView(previewShape(q), { header: true, index: 0, total: 1 });
    previewBox.replaceChildren(h('div.overline', { style: { marginBottom: '0.75rem' } }, t('editor.studentPreview')), view.el);
    const problem = questionProblem(q);
    problemBox.replaceChildren(problem ? notice(t(problem), 'warn') : '');
  }, 250);
  const touch = () => { ctx.set('touched', true); refresh(); };

  form.appendChild(field(t('editor.fields.prompt'), textArea({ value: q.prompt || '', max: L.prompt || 600, rows: 2, placeholder: t(`qdefault.${q.type}`), onInput: (v) => { q.prompt = v; touch(); } })));

  // Champs propres au type
  if (q.type === 'mcq') {
    q.options = arr(q.options);
    const optionsBox = h('div.stack.tight');
    const renderOptions = () => {
      optionsBox.replaceChildren();
      q.options.forEach((o, i) => {
        const toggleBtn = h('button.correct-toggle', {
          type: 'button', class: { on: !!o.correct }, 'aria-label': t('editor.markCorrect'),
          onClick: () => {
            if (!q.multiple) q.options.forEach((x) => { x.correct = false; });
            o.correct = q.multiple ? !o.correct : true;
            touch();
            renderOptions();
          },
        }, icon('check', 18));
        optionsBox.appendChild(h('div.option-row', null,
          h('span.letter', null, 'ABCDEFGH'[i]),
          textInput({ value: o.text || '', max: L.optionText || 200, placeholder: t('editor.placeholders.option', { n: i + 1 }), onInput: (v) => { o.text = v; touch(); } }),
          toggleBtn,
          q.options.length > 2 ? h('button.icon-btn', { onClick: () => { q.options.splice(i, 1); touch(); renderOptions(); } }, icon('close', 17)) : null));
      });
      if (q.options.length < (L.options || 8)) optionsBox.appendChild(h('button.btn.ghost.sm', { onClick: () => { q.options.push({ text: '', correct: false }); touch(); renderOptions(); } }, icon('plus', 16), t('editor.addOption')));
    };
    renderOptions();
    form.appendChild(field(t('editor.fields.options'), optionsBox, { hint: t('editor.optionsHint') }));
    form.appendChild(h('div.card.pad', null, toggleRow(t('editor.multiple'), t('editor.multipleHint'), !!q.multiple, (on) => {
      q.multiple = on;
      if (!on) {
        let seen = false;
        q.options.forEach((o) => { if (o.correct && !seen) seen = true; else o.correct = false; });
      }
      touch();
      renderOptions();
    })));
  }
  if (q.type === 'truefalse') {
    form.appendChild(field(t('editor.fields.correctAnswer'), segmented([{ value: 'true', label: t('question.true') }, { value: 'false', label: t('question.false') }], String(q.answer !== false), (v) => { q.answer = v === 'true'; touch(); })));
  }
  if (q.type === 'translation') {
    form.appendChild(field(t('editor.fields.direction'), segmented([{ value: 'en_fr', label: t('question.dir.en_fr') }, { value: 'fr_en', label: t('question.dir.fr_en') }], q.direction || 'en_fr', (v) => { q.direction = v; touch(); })));
    form.appendChild(field(t('editor.fields.source'), textInput({ value: q.source || '', max: 300, placeholder: t('editor.placeholders.source'), onInput: (v) => { q.source = v; touch(); } })));
  }
  if (q.type === 'translation' || q.type === 'short_answer') {
    q.accepted = arr(q.accepted);
    if (!q.accepted.length) q.accepted.push('');
    form.appendChild(field(t('editor.fields.accepted'), listEditor(q.accepted, { placeholder: t('editor.placeholders.accepted'), max: L.accepted || 12, onChange: touch }), { hint: t('editor.acceptedHint') }));
  }
  if (q.type === 'fill_blank') {
    form.appendChild(field(t('editor.fields.sentence'), textArea({ value: q.sentence || '', max: 600, rows: 3, placeholder: 'I {go|walk} to school every day.', onInput: (v) => { q.sentence = v; touch(); } }), { hint: t('editor.blanksHint') }));
    form.appendChild(h('div.card.pad', null, toggleRow(t('editor.wordBank'), t('editor.wordBankHint'), !!q.wordBank, (on) => { q.wordBank = on; touch(); })));
    form.appendChild(field(t('editor.fields.distractors'), textInput({ value: arr(q.distractors).join(', '), max: 300, placeholder: 'went, gone', onInput: (v) => { q.distractors = v.split(',').map((x) => x.trim()).filter(Boolean); touch(); } }), { hint: t('editor.distractorsHint') }));
  }
  if (q.type === 'word_order') {
    form.appendChild(field(t('editor.fields.orderSentence'), textInput({ value: q.sentence || '', max: 300, placeholder: 'I have never been to London.', onInput: (v) => { q.sentence = v; touch(); } }), { hint: t('editor.orderHint') }));
    q.alternatives = arr(q.alternatives);
    form.appendChild(field(t('editor.fields.alternatives'), listEditor(q.alternatives, { placeholder: t('editor.placeholders.alternative'), max: 5, min: 0, onChange: touch })));
  }
  if (q.type === 'matching') {
    q.pairs = arr(q.pairs);
    const pairsBox = h('div.stack.tight');
    const renderPairs = () => {
      pairsBox.replaceChildren();
      q.pairs.forEach((p, i) => {
        pairsBox.appendChild(h('div.vocab-row', null,
          textInput({ value: p.left || '', max: 120, placeholder: t('editor.placeholders.left'), onInput: (v) => { p.left = v; touch(); } }),
          textInput({ value: p.right || '', max: 120, placeholder: t('editor.placeholders.right'), onInput: (v) => { p.right = v; touch(); } }),
          q.pairs.length > 2 ? h('button.icon-btn', { onClick: () => { q.pairs.splice(i, 1); touch(); renderPairs(); } }, icon('close', 17)) : h('span')));
      });
      if (q.pairs.length < 10) pairsBox.appendChild(h('button.btn.ghost.sm', { onClick: () => { q.pairs.push({ left: '', right: '' }); touch(); renderPairs(); } }, icon('plus', 16), t('editor.addPair')));
    };
    renderPairs();
    form.appendChild(field(t('editor.fields.pairs'), pairsBox, { hint: t('editor.pairsHint') }));
  }
  if (q.type === 'open') {
    form.appendChild(h('div.form-grid', null,
      field(t('editor.fields.minWords'), stepper(q.minWords || 0, { min: 0, max: 1000, step: 10, onChange: (v) => { q.minWords = v; touch(); } })),
      field(t('editor.fields.maxWords'), stepper(q.maxWords || 0, { min: 0, max: 2000, step: 10, format: (n) => (n ? String(n) : '∞'), onChange: (v) => { q.maxWords = v; touch(); } }))));
    form.appendChild(field(t('editor.fields.guidelines'), textArea({ value: q.guidelines || '', max: L.explanation || 1200, rows: 3, placeholder: t('editor.placeholders.guidelines'), onInput: (v) => { q.guidelines = v; touch(); } }), { hint: t('editor.guidelinesHint') }));
  }
  if (['translation', 'short_answer', 'fill_blank'].indexOf(q.type) !== -1) {
    form.appendChild(field(t('editor.fields.tolerance'), segmented([
      { value: 0, label: t('editor.tolerance.0') }, { value: 1, label: t('editor.tolerance.1') }, { value: 2, label: t('editor.tolerance.2') },
    ], q.tolerance === undefined ? 1 : q.tolerance, (v) => { q.tolerance = Number(v); touch(); }), { hint: t('editor.toleranceHint') }));
  }

  // Barème et classement
  form.appendChild(h('div.card.form-card', null,
    h('div.form-grid', null,
      field(t('editor.fields.points'), stepper(q.points || 1, { min: 0.5, max: L.maxPoints || 20, step: 0.5, format: (n) => f.num(n), onChange: (v) => { q.points = v; touch(); } })),
      field(t('editor.fields.theme'), select(arr(store.settings && store.settings.themes).map((th) => ({ value: th, label: themeLabel(th) })), q.theme || 'grammar', (v) => { q.theme = v; touch(); }))),
    field(t('editor.fields.difficulty'), segmented([1, 2, 3].map((n) => ({ value: n, label: t(`levels.${n}`) })), q.difficulty || 1, (v) => { q.difficulty = Number(v); touch(); })),
    field(t('editor.fields.explanation'), textArea({ value: q.explanation || '', max: L.explanation || 1200, rows: 2, placeholder: t('editor.placeholders.explanation'), onInput: (v) => { q.explanation = v; touch(); } }), { hint: t('editor.explanationHint') })));

  out.append(h('div.stack', null, form), h('div.stack.editor-side', null, problemBox, previewBox));
  refresh.flush();

  ctx.footer(h('div.action-bar', null,
    h('button.btn.secondary', { onClick: () => nav.back() }, t('common.cancel')),
    h('button.btn.primary', {
      onClick: () => {
        const problem = questionProblem(q);
        if (problem) return toast(t(problem), { tone: 'error' });
        ctx.set('saved', true);
        if (ctx.params.onSave) ctx.params.onSave(q);
        nav.back();
      },
    }, icon('check', 18), t('editor.saveQuestion'))));
  return out;
}

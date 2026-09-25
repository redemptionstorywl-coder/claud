/**
 * Professeur — évaluations : liste, paramétrage + banque de questions, résultats de la classe,
 * correction d'une copie (questions ouvertes, commentaires), publication des notes.
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr, obj, serverNow } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { store, isAdmin, local } from '../../core/store.js';
import {
  skeletonList, skeletonDetail, emptyState, toast, toastError, confirmDialog, actionSheet, busy,
} from '../../core/ui.js';
import {
  field, textInput, textArea, select, segmented, chipSelect, stepper, toggleRow, notice, badge, section, emblem,
  themeLabel, gradeChip, avatar, penGrade, stat, assessmentStatus,
} from '../../components/widgets.js';
import { questionView } from '../../components/question.js';
import { questionList, questionProblem, cleanQuestion, targetableClasses } from './editor.js';
import { statusBadge } from './courses.js';

function windowBadge(a) {
  if (a.status !== 'published') return statusBadge(a.status);
  if (a.window === 'upcoming') return badge(t('assessments.window.upcoming'), '');
  if (a.window === 'closed') return badge(t('assessments.window.closed'), '');
  return h('span.badge.danger', null, h('span.pulse-dot'), t('assessments.window.open'));
}

function emptyAssessment() {
  const s = (store.settings && store.settings.assessment) || {};
  return {
    title: '', description: '', theme: 'grammar', difficulty: 2, duration: s.defaultDuration || 20, questionCount: 0,
    maxScore: s.defaultMaxScore || 20, coefficient: 1, maxAttempts: 1, shuffleQuestions: true, shuffleOptions: true,
    releaseMode: 'immediate', reviewMode: 'after_submit', status: 'draft',
    classIds: targetableClasses().length === 1 ? [targetableClasses()[0].id] : [], questions: [],
  };
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

export function register() {
  // ─── Liste ─────────────────────────────────────────────────────────────────
  route('teacher.assessments', {
    title: () => t('teacher.assessments'),
    tab: 'assessments',
    large: true,
    skeleton: () => skeletonList(4),
    load: (ctx) => rpc('tassessments:list', { scope: ctx.get('scope') || 'mine' }),
    actions: () => [h('button.icon-btn', { 'aria-label': t('teacher.quick.newAssessment'), onClick: () => nav.push('teacher.assessmentEditor', {}) }, icon('plus', 22))],
    render(ctx, list) {
      const items = arr(list);
      const out = h('div.content-wide.stack');
      if (isAdmin()) {
        out.appendChild(segmented([{ value: 'mine', label: t('teacher.scope.mine') }, { value: 'all', label: t('teacher.scope.all') }],
          ctx.get('scope') || 'mine', (v) => { ctx.set('scope', v); ctx.refresh(); }));
      }
      if (!items.length) {
        out.appendChild(emptyState({
          icon: 'clipboard', title: t('teacher.noAssessments'), text: t('teacher.noAssessmentsText'),
          action: h('button.btn.primary', { onClick: () => nav.push('teacher.assessmentEditor', {}) }, icon('plus', 18), t('teacher.quick.newAssessment')),
        }));
        return out;
      }
      out.appendChild(h('div.grid-auto.stagger', null, ...items.map((a) => h('div.card.pad.clickable', { onClick: () => nav.push('teacher.assessmentResults', { id: a.id }) },
        h('div.row.top', null,
          emblem('clipboard', { tone: a.status === 'published' && a.window === 'open' ? 'danger' : 'neutral' }),
          h('div.grow', null,
            h('div.row.between', null, h('span.overline', null, themeLabel(a.theme)), windowBadge(a)),
            h('div.course-title.serif', { style: { fontSize: '1.0625rem', margin: '0.2rem 0 0.35rem', fontWeight: '600' } }, a.title),
            h('div.meta', null,
              h('span', null, icon('help', 13), tn('assessments.questions', a.questionCount)),
              h('span', null, icon('timer', 13), f.minutes(a.duration)),
              a.closesAt ? h('span', null, icon('calendar', 13), f.dateTime(a.closesAt)) : null),
            h('div.meta', { style: { marginTop: '0.35rem' } },
              h('span', null, icon('inbox', 13), tn('teacher.submitted', a.submitted)),
              a.running ? h('span', { style: { color: 'var(--ec-gold)' } }, icon('timer', 13), tn('teacher.running', a.running)) : null,
              a.toReview ? h('span', { style: { color: 'var(--ec-wrong)' } }, icon('pen', 13), tn('teacher.toReviewShort', a.toReview)) : null,
              a.average !== undefined && a.average !== null ? h('span', null, icon('trophy', 13), t('teacher.averageShort', { n: f.num(a.average) })) : null)),
          h('button.icon-btn', {
            'aria-label': t('common.more'),
            onClick: async (e) => {
              e.stopPropagation();
              if (await assessmentActions(a)) ctx.refresh({ silent: true });
            },
          }, icon('more', 20)))))));
      return out;
    },
  });

  // ─── Éditeur ───────────────────────────────────────────────────────────────
  route('teacher.assessmentEditor', {
    title: (ctx) => (ctx.params.id ? t('assessmentEditor.edit') : t('assessmentEditor.new')),
    hideTabs: true,
    skeleton: skeletonDetail,
    async load(ctx) {
      const a = ctx.params.id ? await rpc('tassessment:get', { id: ctx.params.id }) : emptyAssessment();
      ctx.set('draft', clone(a));
      ctx.set('dirty', false);
      try { ctx.set('courses', arr(await rpc('tcourses:list', {}))); } catch (e) { ctx.set('courses', []); }
      return a;
    },
    onShow(ctx) { ctx.rerender(); },
    confirmLeave: async (ctx) => {
      if (!ctx.get('dirty')) return true;
      return confirmDialog({ title: t('editor.leaveTitle'), message: t('editor.leaveText'), confirm: t('editor.leave'), danger: true });
    },
    render(ctx) {
      return assessmentEditor(ctx);
    },
  });

  // ─── Résultats ─────────────────────────────────────────────────────────────
  route('teacher.assessmentResults', {
    title: (ctx, d) => (d ? d.assessment.title : t('teacher.results')),
    subtitle: () => t('teacher.results'),
    skeleton: skeletonDetail,
    refreshOnShow: true,
    load: (ctx) => rpc('tassessment:results', { id: ctx.params.id }),
    actions: (ctx, d) => (d ? [h('button.icon-btn', {
      'aria-label': t('common.more'),
      onClick: async () => { if (await assessmentActions(Object.assign({ id: ctx.params.id }, d.assessment))) ctx.refresh({ silent: true }); },
    }, icon('more', 20))] : []),
    render(ctx, d) {
      ctx.onPush('live', (msg) => { if (msg.key === `assessment:${ctx.params.id}`) ctx.refresh({ silent: true }); });
      return resultsView(ctx, d);
    },
  });

  // ─── Correction d'une copie ────────────────────────────────────────────────
  route('teacher.attempt', {
    title: (ctx, d) => (d ? d.student.name : t('teacher.paper')),
    subtitle: (ctx, d) => (d ? d.assessment.title : ''),
    skeleton: skeletonDetail,
    load: (ctx) => rpc('attempt:get', { id: ctx.params.id }),
    render(ctx, d) {
      return attemptCorrection(ctx, d);
    },
  });
}

async function assessmentActions(a) {
  const published = a.status === 'published';
  const choice = await actionSheet({
    title: a.title,
    options: [
      { value: 'results', label: t('teacher.assessmentActions.results'), icon: 'chart' },
      { value: 'edit', label: t('teacher.assessmentActions.edit'), icon: 'pen' },
      published ? { value: 'live', label: t('teacher.courseActions.live'), icon: 'live' } : null,
      published ? { value: 'unpublish', label: t('teacher.courseActions.unpublish'), icon: 'eyeOff' } : { value: 'publish', label: t('teacher.courseActions.publish'), icon: 'send', tone: 'success' },
      { value: 'duplicate', label: t('teacher.courseActions.duplicate'), icon: 'copy' },
      a.status !== 'archived' ? { value: 'archive', label: t('teacher.courseActions.archive'), icon: 'inbox' } : null,
      { value: 'delete', label: t('common.delete'), icon: 'trash', danger: true },
    ],
  });
  if (!choice) return false;
  try {
    if (choice === 'results') nav.push('teacher.assessmentResults', { id: a.id });
    else if (choice === 'edit') nav.push('teacher.assessmentEditor', { id: a.id });
    else if (choice === 'live') nav.push('teacher.live', { type: 'assessment', id: a.id });
    else if (choice === 'publish' || choice === 'unpublish' || choice === 'archive') {
      const status = choice === 'publish' ? 'published' : choice === 'archive' ? 'archived' : 'draft';
      await busy(() => rpc('tassessment:status', { id: a.id, status }));
      toast(t(`teacher.status.${status}`), { tone: 'success' });
      return true;
    } else if (choice === 'duplicate') {
      const res = await busy(() => rpc('tassessment:duplicate', { id: a.id }));
      nav.push('teacher.assessmentEditor', { id: res.id });
      return true;
    } else if (choice === 'delete') {
      if (!(await confirmDialog({ title: t('teacher.deleteAssessment'), message: t('teacher.deleteText', { title: a.title }), confirm: t('common.delete'), danger: true, icon: 'trash' }))) return false;
      await busy(() => rpc('tassessment:delete', { id: a.id }));
      toast(t('teacher.deleted'), { tone: 'success' });
      nav.invalidate(['teacher.assessments']);
      if (nav.top().name === 'teacher.assessmentResults') nav.back();
      return true;
    }
  } catch (err) {
    toastError(err);
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────

function dateInput(value, onChange) {
  const input = h('input.input', { type: 'datetime-local', value: f.toLocalInput(value) });
  input.addEventListener('change', () => onChange(f.fromLocalInput(input.value)));
  const clearBtn = h('button.btn.ghost.sm', { type: 'button', onClick: () => { input.value = ''; onChange(null); } }, t('assessmentEditor.none'));
  const nowBtn = h('button.btn.ghost.sm', { type: 'button', onClick: () => { const ts = Math.round(serverNow() / 1000); input.value = f.toLocalInput(ts); onChange(ts); } }, t('assessmentEditor.now'));
  return h('div.stack.tight', null, input, h('div.row', null, nowBtn, clearBtn));
}

function assessmentEditor(ctx) {
  const a = ctx.get('draft');
  const L = (store.settings && store.settings.limits) || {};
  const maxDuration = (store.settings && store.settings.assessment && store.settings.assessment.maxDuration) || 240;
  const touch = () => ctx.set('dirty', true);
  const out = h('div.editor-layout');
  const side = h('div.stack.editor-side');
  const main = h('div.stack');
  const classes = targetableClasses();
  a.questions = arr(a.questions);

  if (a.locked) side.appendChild(notice(tn('assessmentEditor.locked', a.attempts), 'warn', 'lock'));

  side.appendChild(h('div.card.form-card', null,
    h('div.row.between', null, h('div.overline', null, t('editor.info')), a.status ? statusBadge(a.status) : null),
    field(t('editor.fields.title'), textInput({ value: a.title, max: L.courseTitle || 120, className: 'serif-input', placeholder: t('assessmentEditor.titlePlaceholder'), onInput: (v) => { a.title = v; touch(); } })),
    field(t('editor.fields.description'), textArea({ value: a.description || '', max: L.courseDescription || 1200, rows: 2, placeholder: t('assessmentEditor.descriptionPlaceholder'), onInput: (v) => { a.description = v; touch(); } })),
    field(t('editor.fields.classes'), classes.length ? chipSelect(classes.map((c) => ({ value: c.id, label: c.label })), arr(a.classIds), (ids) => { a.classIds = ids; touch(); }) : notice(t('editor.noTargetClasses'), 'warn')),
    field(t('assessmentEditor.course'), select([{ value: '', label: t('assessmentEditor.noCourse') }].concat(arr(ctx.get('courses')).map((c) => ({ value: c.id, label: c.title }))), a.courseId || '', (v) => { a.courseId = v ? Number(v) : null; touch(); })),
    h('div.form-grid', null,
      field(t('editor.fields.theme'), select(arr(store.settings && store.settings.themes).map((th) => ({ value: th, label: themeLabel(th) })), a.theme, (v) => { a.theme = v; touch(); })),
      field(t('assessmentEditor.difficulty'), select([1, 2, 3].map((n) => ({ value: n, label: t(`levels.${n}`) })), a.difficulty || 2, (v) => { a.difficulty = Number(v); touch(); })))));

  side.appendChild(h('div.card.form-card', null,
    h('div.overline', null, t('assessmentEditor.rules')),
    h('div.form-grid', null,
      field(t('course.duration'), stepper(a.duration, { min: 0, max: maxDuration, step: 5, format: (n) => f.minutes(n), onChange: (v) => { a.duration = v; touch(); } })),
      field(t('assessmentEditor.questionCount'), stepper(a.questionCount || 0, { min: 0, max: 200, step: 1, format: (n) => (n ? String(n) : t('assessmentEditor.all')), onChange: (v) => { a.questionCount = v; touch(); } })),
      field(t('assessmentEditor.maxScore'), stepper(a.maxScore || 20, { min: 5, max: 100, step: 5, format: (n) => `/${n}`, onChange: (v) => { a.maxScore = v; touch(); } })),
      field(t('assessmentEditor.coefficient'), stepper(a.coefficient || 1, { min: 0.5, max: 10, step: 0.5, format: (n) => f.num(n), onChange: (v) => { a.coefficient = v; touch(); } })),
      field(t('assessmentEditor.attempts'), stepper(a.maxAttempts === undefined ? 1 : a.maxAttempts, { min: 0, max: 20, step: 1, format: (n) => (n ? String(n) : '∞'), onChange: (v) => { a.maxAttempts = v; touch(); } }))),
    h('div.form-grid', null,
      field(t('assessmentEditor.opensAt'), dateInput(a.opensAt, (v) => { a.opensAt = v; touch(); })),
      field(t('assessmentEditor.closesAt'), dateInput(a.closesAt, (v) => { a.closesAt = v; touch(); }))),
    toggleRow(t('assessmentEditor.shuffleQuestions'), t('assessmentEditor.shuffleQuestionsHint'), a.shuffleQuestions !== false, (on) => { a.shuffleQuestions = on; touch(); }),
    toggleRow(t('assessmentEditor.shuffleOptions'), t('assessmentEditor.shuffleOptionsHint'), a.shuffleOptions !== false, (on) => { a.shuffleOptions = on; touch(); }),
    field(t('assessmentEditor.release'), segmented([
      { value: 'immediate', label: t('assessmentEditor.releaseImmediate') },
      { value: 'manual', label: t('assessmentEditor.releaseManual') },
    ], a.releaseMode || 'immediate', (v) => { a.releaseMode = v; touch(); }), { hint: t('assessmentEditor.releaseHint') }),
    field(t('assessmentEditor.review'), select([
      { value: 'after_submit', label: t('assessmentEditor.reviewAfterSubmit') },
      { value: 'after_close', label: t('assessmentEditor.reviewAfterClose') },
      { value: 'never', label: t('assessmentEditor.reviewNever') },
    ], a.reviewMode || 'after_submit', (v) => { a.reviewMode = v; touch(); }))));

  const pts = a.questions.reduce((s, q) => s + (Number(q.points) || 1), 0);
  main.appendChild(section(t('assessmentEditor.questions'), h('span.muted', { style: { fontSize: '0.75rem', fontWeight: '700' } }, `${tn('exercise.questions', a.questions.length)} · ${f.num(pts)} ${t('question.pts')}`),
    questionList(a.questions, { onChange: () => { touch(); }, locked: !!a.locked, context: 'assessment' })));
  if (a.questionCount && a.questionCount < a.questions.length) {
    main.appendChild(notice(t('assessmentEditor.drawNotice', { n: a.questionCount, total: a.questions.length }), '', 'shuffle'));
  }
  out.append(side, main);

  const save = async (publish) => {
    if (!String(a.title || '').trim()) return toast(t('editor.errors.title'), { tone: 'error' });
    if (a.opensAt && a.closesAt && a.closesAt <= a.opensAt) return toast(t('assessmentEditor.errors.dates'), { tone: 'error' });
    if (publish) {
      if (!arr(a.classIds).length) return toast(t('editor.errors.classes'), { tone: 'error' });
      if (!a.questions.length) return toast(t('assessmentEditor.errors.noQuestions'), { tone: 'error' });
      const bad = a.questions.findIndex((q) => questionProblem(q));
      if (bad !== -1) return toast(t('assessmentEditor.errors.fixQuestion', { n: bad + 1 }), { tone: 'error' });
    }
    try {
      const payload = clone(a);
      payload.questions = arr(payload.questions).map(cleanQuestion);
      if (ctx.params.id) payload.id = ctx.params.id;
      ['locked', 'attempts', 'teacher', 'teacherId', 'courseTitle', 'announcedAt', 'publishedAt', 'updatedAt', 'status'].forEach((k) => delete payload[k]);
      const res = await busy(() => rpc('tassessment:save', { assessment: payload, publish: !!publish }), t('editor.saving'));
      ctx.params.id = res.id;
      ctx.set('draft', clone(res.assessment));
      ctx.set('dirty', false);
      if (res.locked && !a.locked) toast(t('assessmentEditor.lockedToast'), { tone: 'info', icon: 'lock' });
      toast(publish ? t('editor.publishedToast') : t('editor.savedToast'), { tone: 'success', body: res.assessment.title });
      nav.invalidate(['teacher.assessments', 'teacher.home']);
      ctx.setTitle(t('assessmentEditor.edit'));
      ctx.rerender();
    } catch (err) {
      toastError(err);
    }
  };
  ctx.footer(h('div.action-bar', null,
    ctx.params.id ? h('button.btn.secondary', { onClick: () => nav.push('teacher.assessmentResults', { id: ctx.params.id }) }, icon('chart', 18), t('teacher.results')) : null,
    h('button.btn.secondary', { onClick: () => save(false) }, icon('check', 18), t('common.save')),
    a.status === 'published'
      ? h('button.btn.primary', { onClick: () => save(false) }, icon('send', 18), t('editor.saveAndUpdate'))
      : h('button.btn.primary', { onClick: () => save(true) }, icon('send', 18), t('teacher.courseActions.publish'))));
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────

const STATUS_BADGE = {
  not_started: () => badge(t('grades.status.not_started'), ''),
  in_progress: () => badge(t('grades.status.in_progress'), 'gold'),
  submitted: () => badge(t('grades.status.submitted'), 'danger'),
  graded: () => badge(t('grades.status.graded'), 'accent'),
  released: () => badge(t('grades.status.released'), 'success'),
};

function resultsView(ctx, d) {
  const a = d.assessment;
  const students = arr(d.students);
  const s = obj(d.stats);
  const out = h('div.content-wide.stack');

  out.appendChild(h('div.row.wrap', null, windowBadge(a),
    ...arr(a.classes).map((c) => h('span.chip.static', { style: { minHeight: '1.625rem', fontSize: '0.75rem' } }, c.label)),
    a.closesAt ? h('span.muted', { style: { fontSize: '0.8125rem' } }, t('assessments.until', { when: f.dateTime(a.closesAt) })) : null));

  out.appendChild(h('div.grid-2.grid-3-wide', null,
    stat({ value: `${s.submitted || 0}`, suffix: `/ ${students.length}`, label: t('teacher.stats.submittedPapers'), icon: 'inbox' }),
    stat({ value: s.average !== undefined && s.average !== null ? f.num(s.average) : '—', suffix: `/ ${f.num(a.maxScore)}`, label: t('teacher.stats.average'), icon: 'trophy', tone: 'gold' }),
    stat({ value: s.min !== undefined ? `${f.num(s.min)} – ${f.num(s.max)}` : '—', label: t('teacher.stats.range'), icon: 'chart' }),
    s.running ? stat({ value: String(s.running), label: t('teacher.stats.running'), icon: 'timer', tone: 'gold' }) : null,
    s.toReview ? stat({ value: String(s.toReview), label: t('teacher.stats.toReview'), icon: 'pen', tone: 'wrong' }) : null,
    s.toRelease ? stat({ value: String(s.toRelease), label: t('teacher.stats.toRelease'), icon: 'send', tone: 'correct' }) : null));

  if (s.toRelease > 0) {
    out.appendChild(h('button.btn.success.lg.block', {
      onClick: async () => {
        if (!(await confirmDialog({ title: t('teacher.releaseAllTitle'), message: tn('teacher.releaseAllText', s.toRelease), confirm: t('teacher.releaseAll'), icon: 'send' }))) return;
        try {
          const res = await busy(() => rpc('tassessment:releaseAll', { id: a.id }));
          toast(tn('teacher.releasedToast', res.released), { tone: 'success' });
          ctx.refresh({ silent: true });
        } catch (err) { toastError(err); }
      },
    }, icon('send', 18), tn('teacher.releaseAllButton', s.toRelease)));
  }

  if (!students.length) {
    out.appendChild(emptyState({ icon: 'users', title: t('teacher.noStudentsYet'), text: t('teacher.noStudentsYetText') }));
    return out;
  }

  // Tableau (PC) + liste (téléphone) : même données, deux mises en page.
  const rows = students.map((st) => ({
    st,
    open: st.attemptId ? () => nav.push('teacher.attempt', { id: st.attemptId }) : null,
  }));
  out.appendChild(h('div.card.list.hide-wide', null, ...rows.map(({ st, open }) => h(open ? 'button.student-row' : 'div.student-row', { onClick: open },
    h('span', { class: st.online ? 'dot-online' : 'dot-offline' }),
    avatar(st.name, 'sm'),
    h('div.grow', null,
      h('div', { style: { fontWeight: '600' } }, st.name),
      h('div.muted', { style: { fontSize: '0.75rem' } }, [st.classLabel, st.durationSec ? f.duration(st.durationSec) : null, st.attempts > 1 ? tn('teacher.attemptsCount', st.attempts) : null].filter(Boolean).join(' · '))),
    st.grade !== undefined && st.grade !== null && st.status !== 'submitted' ? gradeChip(st.grade, st.gradeMax) : (STATUS_BADGE[st.status] || STATUS_BADGE.not_started)()))));

  out.appendChild(h('div.card.show-wide', { style: { overflow: 'hidden' } }, h('table.table', null,
    h('thead', null, h('tr', null,
      h('th', null, t('grades.student')), h('th', null, t('grades.class')), h('th', null, t('grades.statusCol')),
      h('th.num', null, t('grades.time')), h('th.num', null, t('grades.success')), h('th.num', null, t('grades.grade')))),
    h('tbody', null, ...rows.map(({ st, open }) => h(`tr${open ? '.clickable' : ''}`, { onClick: open },
      h('td', null, h('div.row', null, h('span', { class: st.online ? 'dot-online' : 'dot-offline' }), h('b', null, st.name))),
      h('td', null, st.classLabel || '—'),
      h('td', null, (STATUS_BADGE[st.status] || STATUS_BADGE.not_started)(), st.autoSubmitted ? h('span.muted', { style: { marginLeft: '0.4rem', fontSize: '0.75rem' } }, t('grades.auto')) : null),
      h('td.num', null, st.durationSec ? f.duration(st.durationSec) : '—'),
      h('td.num', null, st.percent !== undefined && st.percent !== null ? f.percent(st.percent) : '—'),
      h('td.num', null, st.grade === undefined || st.grade === null ? '—'
        : st.status === 'submitted' ? h('span.grade-chip.provisional', { title: t('grades.provisional') }, f.grade(st.grade, st.gradeMax))
        : gradeChip(st.grade, st.gradeMax))))))));
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────

function attemptCorrection(ctx, d) {
  const out = h('div.content-narrow.stack');
  const review = arr(d.review);
  const grades = {};
  review.forEach((item) => { grades[item.id] = { points: item.earned || 0, feedback: item.teacherFeedback || '' }; });

  const header = h('div.card.result-card', null,
    h('div.row.between', null,
      h('div.row', null, avatar(d.student.name), h('div', { style: { textAlign: 'left' } },
        h('div', { style: { fontWeight: '700' } }, d.student.name),
        h('div.muted', { style: { fontSize: '0.75rem' } }, [d.student.classLabel, d.student.studentNumber].filter(Boolean).join(' · ')))),
      (STATUS_BADGE[d.status] || STATUS_BADGE.submitted)()),
    h('div', { style: { marginTop: '1rem' } }, d.grade !== undefined && d.grade !== null ? penGrade(d.grade, d.gradeMax, { small: true }) : null),
    h('div.result-facts', null,
      h('div', null, h('b', null, f.duration(d.durationSec)), h('span', null, t('result.time'))),
      h('div', null, h('b', null, `${f.num(d.score)}/${f.num(d.maxPoints)}`), h('span', null, t('question.pts'))),
      h('div', null, h('b', null, f.dateTime(d.submittedAt)), h('span', null, t('grades.submittedAt')))),
    d.autoSubmitted ? h('div', { style: { marginTop: '0.75rem' } }, badge(t('result.autoSubmitted'), 'gold')) : null);
  out.appendChild(header);

  review.forEach((item, i) => {
    const view = questionView(item, { index: i, total: review.length, value: item.answer });
    view.showFeedback({
      correct: item.correct, partial: item.correct === false && item.earned > 0, pending: item.pending,
      points: item.earned, max: item.max, solution: item.solution, detail: item.detail, explanation: item.explanation,
    }, { panel: false });
    const pts = h('input.input', { type: 'number', min: 0, max: item.max, step: 0.25, value: String(grades[item.id].points) });
    pts.addEventListener('input', () => { grades[item.id].points = Math.max(0, Math.min(item.max, Number(pts.value) || 0)); grades[item.id].touched = true; });
    const fb = h('input.input', { type: 'text', maxlength: 600, placeholder: t('grades.feedbackPlaceholder'), value: grades[item.id].feedback });
    fb.addEventListener('input', () => { grades[item.id].feedback = fb.value; grades[item.id].touched = true; });
    const tone = item.pending ? 'danger' : item.correct ? 'success' : item.earned > 0 ? 'gold' : 'danger';
    out.appendChild(h(`div.card.pad-lg.stack${item.pending ? '.tinted' : ''}`, null,
      view.el,
      h('div.divider'),
      h('div.row.wrap', null,
        h('div.grade-input', null, h('span.muted', { style: { fontSize: '0.8125rem', fontWeight: '600' } }, t('grades.points')), pts, h('span.muted', null, `/ ${f.num(item.max)}`)),
        item.pending ? badge(t('grades.toGrade'), 'danger') : badge(item.correct ? t('grades.correct') : item.earned > 0 ? t('grades.partial') : t('grades.wrong'), tone)),
      fb));
  });

  const comment = h('textarea.input', { rows: 3, maxlength: 1200, placeholder: t('grades.commentPlaceholder') });
  comment.value = d.teacherComment || '';
  out.appendChild(h('div.card.pad.stack.tight', null, h('div.overline', null, t('result.teacherComment')), comment));

  const send = async (release) => {
    const payload = review.map((item) => ({ questionId: item.id, points: grades[item.id].points, feedback: grades[item.id].feedback || undefined }));
    try {
      const res = await busy(() => rpc('attempt:grade', { id: d.id, grades: payload, comment: comment.value.trim() || undefined, release }), t('editor.saving'));
      toast(release ? t('grades.releasedToast', { grade: f.grade(res.grade, res.gradeMax) }) : t('grades.savedToast'), { tone: 'success' });
      nav.invalidate(['teacher.assessmentResults', 'teacher.home', 'teacher.student']);
      ctx.refresh({ silent: true });
    } catch (err) {
      toastError(err);
    }
  };

  out.appendChild(h('button.btn.danger-soft.block', {
    onClick: async () => {
      if (!(await confirmDialog({ title: t('grades.voidTitle'), message: t('grades.voidText'), confirm: t('grades.void'), danger: true, icon: 'refresh' }))) return;
      try {
        await busy(() => rpc('attempt:void', { id: d.id }));
        toast(t('grades.voidedToast'), { tone: 'success' });
        nav.invalidate(['teacher.assessmentResults']);
        nav.back();
      } catch (err) { toastError(err); }
    },
  }, icon('refresh', 18), t('grades.void')));

  ctx.footer(h('div.action-bar', null,
    h('button.btn.secondary', { onClick: () => send(false) }, icon('check', 18), t('common.save')),
    d.status !== 'released' ? h('button.btn.primary', { onClick: () => send(true) }, icon('send', 18), t('grades.saveAndRelease')) : null));
  return out;
}

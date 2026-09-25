/**
 * Élève — liste des cours, page d'un cours, lecteur des parties (texte, vocabulaire, exercice, évaluation).
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr, obj } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { store } from '../../core/store.js';
import { skeletonList, skeletonDetail, emptyState, toastError, busy, toast } from '../../core/ui.js';
import { renderMarkdown } from '../../core/markdown.js';
import {
  courseCard, segmented, progressBar, emblem, badge, themeLabel, assessmentCard, notice, segments,
} from '../../components/widgets.js';
import { exerciseRunner } from '../../components/exercise-runner.js';

// Cours chargés (partagés entre la page du cours et le lecteur de parties).
const courseCache = new Map();

const SECTION_ICONS = { text: 'text', vocabulary: 'cards', exercise: 'pen', assessment: 'clipboard' };

export function sectionLabel(type) {
  return t(`sections.${type}`);
}

function sectionSubtitle(s) {
  if (s.type === 'vocabulary') return tn('course.words', arr(s.words).length);
  if (s.type === 'exercise') {
    const total = arr(s.questions).length;
    const answered = s.answered || 0;
    if (s.done && s.result && s.result.bestPercent !== undefined && s.result.bestPercent !== null) return t('course.exerciseBest', { n: Math.round(s.result.bestPercent) });
    return answered ? t('course.exerciseProgress', { done: answered, total }) : tn('exercise.questions', total);
  }
  if (s.type === 'assessment') return s.assessment && s.assessment.title ? s.assessment.title : t('sections.assessment');
  // Leçon : durée de lecture estimée (~160 mots par minute pour un élève).
  const words = String(s.body || '').split(/\s+/).filter(Boolean).length;
  return t('course.readingTime', { n: Math.max(1, Math.round(words / 160)) });
}

async function loadCourse(id, preview) {
  const course = preview ? await rpc('tcourse:preview', { id }) : await rpc('course:get', { id });
  courseCache.set(id, course);
  return course;
}

function firstOpenIndex(course) {
  const i = arr(course.sections).findIndex((s) => !s.done);
  return i === -1 ? 0 : i;
}

export function register() {
  // ─── Liste ─────────────────────────────────────────────────────────────────
  route('student.courses', {
    title: () => t('courses.title'),
    subtitle: () => (store.profile && store.profile.className) || '',
    tab: 'courses',
    large: true,
    skeleton: () => skeletonList(4),
    load: () => rpc('courses:list'),
    render(ctx, list) {
      const courses = arr(list);
      const filter = ctx.get('filter') || ctx.params.filter || 'all';
      const counts = {
        all: courses.length,
        new: courses.filter((c) => c.state === 'new').length,
        started: courses.filter((c) => c.state === 'started').length,
        completed: courses.filter((c) => c.state === 'completed').length,
      };
      const listEl = h('div.stack.tight.stagger');
      const paint = (value) => {
        ctx.set('filter', value);
        listEl.replaceChildren();
        const shown = courses.filter((c) => value === 'all' || c.state === value);
        if (!shown.length) {
          listEl.appendChild(emptyState({
            icon: 'book',
            title: courses.length ? t('courses.emptyFilter') : t('courses.empty'),
            text: courses.length ? '' : t('courses.emptyText'),
          }));
          return;
        }
        shown.forEach((c) => listEl.appendChild(courseCard(c, () => nav.push('student.course', { id: c.id }))));
      };
      const tabs = segmented([
        { value: 'all', label: t('courses.filter.all'), count: counts.all },
        { value: 'new', label: t('courses.filter.new'), count: counts.new },
        { value: 'started', label: t('courses.filter.started'), count: counts.started },
        { value: 'completed', label: t('courses.filter.completed'), count: counts.completed },
      ], filter, paint);
      paint(filter);
      return h('div.content-narrow.stack', null, tabs, listEl);
    },
  });

  // ─── Page d'un cours ───────────────────────────────────────────────────────
  route('student.course', {
    title: (ctx, c) => (c ? c.title : t('course.title')),
    subtitle: (ctx, c) => (c ? c.teacher : ''),
    skeleton: skeletonDetail,
    refreshOnShow: true,
    load: (ctx) => loadCourse(ctx.params.id, ctx.params.preview),
    render(ctx, c) {
      const sections = arr(c.sections);
      const progress = obj(c.progress);
      const out = h('div.content-narrow.stack.stagger');

      out.appendChild(h('div.card.course-hero', null,
        h('div.row.between', null,
          h('div.row', null, emblem(c.emblem, { size: 'lg' }), h('div', null,
            h('div.overline', null, themeLabel(c.theme)),
            h('div.muted', { style: { fontSize: '0.8125rem', marginTop: '0.15rem' } }, t('course.by', { teacher: c.teacher })))),
          c.preview ? badge(t('course.preview'), 'gold') : progress.completed ? badge(t('courses.state.completed'), 'success') : null),
        h('h1', null, c.title),
        c.description ? h('p.desc', null, c.description) : null,
        h('div.facts', null,
          h('div.fact', null, h('div.k', null, t('course.duration')), h('div.v', null, f.minutes(c.duration))),
          h('div.fact', null, h('div.k', null, t('course.level')), h('div.v', null, t(`levels.${c.level || 1}`))),
          h('div.fact', null, h('div.k', null, t('course.parts')), h('div.v', null, String(sections.length)))),
        !c.preview ? h('div', { style: { marginTop: '1rem' } },
          h('div.row.between', { style: { marginBottom: '0.4rem', fontSize: '0.75rem', fontWeight: '700' } },
            h('span.muted', null, t('course.progress')), h('span.tnum', null, `${progress.percent || 0}%`)),
          progressBar(progress.percent || 0, progress.completed ? 'success' : '')) : null));

      if (!sections.length) {
        out.appendChild(emptyState({ icon: 'layers', title: t('course.noSections') }));
        return out;
      }

      const current = firstOpenIndex(c);
      out.appendChild(h('div.card.pad', null, h('div.outline', null, ...sections.map((s, i) => h(`button.outline-item${s.done ? '.done' : ''}${!s.done && i === current ? '.current' : ''}`, {
        onClick: () => nav.push('student.section', { courseId: c.id, index: i, preview: c.preview }),
      },
      h('span.step', null, s.done ? icon('check', 18) : icon(SECTION_ICONS[s.type] || 'text', 18)),
      h('span.grow', null,
        h('div.t', null, s.title || sectionLabel(s.type)),
        h('div.s', null, `${sectionLabel(s.type)} · ${sectionSubtitle(s)}`)),
      icon('chevronRight', 18, 'chev'))))));

      const label = c.preview ? t('course.previewStart') : progress.completed ? t('course.review') : progress.status ? t('course.continue') : t('course.start');
      ctx.footer(h('div.action-bar', null, h('button.btn.primary.lg', {
        onClick: async () => {
          if (!c.preview && !progress.status) {
            try { await rpc('course:start', { id: c.id }); } catch (err) { toastError(err); }
          }
          nav.push('student.section', { courseId: c.id, index: progress.completed ? 0 : current, preview: c.preview });
        },
      }, icon('play', 18), label)));
      return out;
    },
  });

  // ─── Lecteur de partie ─────────────────────────────────────────────────────
  route('student.section', {
    title: (ctx) => {
      const c = courseCache.get(ctx.params.courseId);
      return c ? c.title : t('course.title');
    },
    subtitle: (ctx) => {
      const c = courseCache.get(ctx.params.courseId);
      return c ? t('course.partOf', { n: ctx.params.index + 1, total: arr(c.sections).length }) : '';
    },
    hideTabs: true,
    skeleton: skeletonDetail,
    async load(ctx) {
      const cached = courseCache.get(ctx.params.courseId);
      if (cached) return cached;
      return loadCourse(ctx.params.courseId, ctx.params.preview);
    },
    render(ctx, c) {
      const sections = arr(c.sections);
      const index = Math.max(0, Math.min(sections.length - 1, ctx.params.index || 0));
      const s = sections[index];
      if (!s) return emptyState({ icon: 'layers', title: t('course.noSections') });
      const isLast = index === sections.length - 1;
      const out = h('div.content-narrow');

      out.appendChild(h('div.reader-top', null,
        segments(sections.map((x, i) => (i === index ? 'current' : x.done ? 'done' : '')))));
      out.appendChild(h('div.row', null, badge(sectionLabel(s.type), 'accent')));
      out.appendChild(h('h2.reader-title', null, s.title || sectionLabel(s.type)));

      const markDone = async () => {
        if (c.preview || s.done || (s.type !== 'text' && s.type !== 'vocabulary')) return;
        try {
          const prog = await rpc('course:section:done', { courseId: c.id, sectionId: s.id });
          s.done = true;
          c.progress = Object.assign({}, c.progress, prog);
          nav.invalidate(['student.course', 'student.courses', 'student.home']);
          if (prog.justCompleted) celebrate(c);
        } catch (err) {
          toastError(err);
        }
      };
      const goTo = (i) => nav.replace('student.section', { courseId: c.id, index: i, preview: c.preview });
      const finish = async () => {
        await markDone();
        if (isLast) {
          await nav.back();
          return;
        }
        goTo(index + 1);
      };

      if (s.type === 'text') {
        out.appendChild(h('div.card.reading.notebook', null, renderMarkdown(s.body)));
      } else if (s.type === 'vocabulary') {
        out.appendChild(vocabularyView(s, c));
      } else if (s.type === 'exercise') {
        out.appendChild(exerciseRunner({
          courseId: c.id,
          section: s,
          preview: c.preview,
          nextLabel: isLast ? t('course.finish') : t('course.nextPart'),
          onNext: finish,
          onProgress: (ex) => {
            s.answered = ex.answered;
            if (ex.completed) s.done = true;
            if (ex.progress) {
              c.progress = Object.assign({}, c.progress, ex.progress);
              if (ex.progress.justCompleted) celebrate(c);
            }
            nav.invalidate(['student.course', 'student.courses', 'student.home']);
          },
        }));
      } else if (s.type === 'assessment') {
        const a = s.assessment;
        if (!a || a.unavailable) {
          out.appendChild(notice(t('course.assessmentUnavailable'), 'warn'));
        } else {
          out.appendChild(assessmentCard(a, () => (c.preview ? null : nav.push('student.assessment', { id: a.id }))));
          if (!c.preview) out.appendChild(h('p.muted', { style: { fontSize: '0.8125rem', marginTop: '0.75rem' } }, t('course.assessmentHint')));
        }
      }

      const bar = h('div.action-bar', null,
        index > 0 ? h('button.btn.secondary', { onClick: () => goTo(index - 1) }, icon('chevronLeft', 18), t('common.previous')) : null,
        h('button.btn.primary', { onClick: finish }, isLast ? t('course.finish') : t('common.next'), icon(isLast ? 'check' : 'chevronRight', 18)));
      ctx.footer(bar);
      return out;
    },
  });
}

function celebrate(course) {
  toast(t('course.completedToast'), { tone: 'success', icon: 'trophy', body: course.title, duration: 4500 });
}

function vocabularyView(s, c) {
  const words = arr(s.words);
  const wrap = h('div.stack');
  const listView = h('div.card.word-list', null, ...words.map((w) => h('div.word', null,
    h('div.col', null,
      h('div.term', null, w.term),
      h('div.tr', null, w.translation),
      w.example ? h('div.ex', null, w.example) : null))));
  let cardMode = false;
  const cardsView = h('div');
  const toggleBtn = h('button.btn.secondary.sm', { onClick: () => { cardMode = !cardMode; paint(); } });
  const paint = () => {
    toggleBtn.replaceChildren(icon(cardMode ? 'list' : 'cards', 16), cardMode ? t('vocab.listMode') : t('vocab.cardMode'));
    listView.classList.toggle('hidden', cardMode);
    cardsView.classList.toggle('hidden', !cardMode);
  };
  cardsView.appendChild(flashcards(words));
  wrap.append(
    h('div.row.between', null, h('span.muted', { style: { fontSize: '0.8125rem', fontWeight: '600' } }, tn('course.words', words.length)), toggleBtn),
    listView,
    cardsView,
    c.preview ? null : h('button.btn.soft.block', { onClick: () => nav.push('student.revision', { courseId: c.id }) }, icon('sparkle', 18), t('vocab.reviseThese')));
  paint();
  return wrap;
}

export function flashcards(words) {
  let i = 0;
  const root = h('div.stack');
  const render = () => {
    const w = words[i];
    if (!w) return;
    const card = h('div.flashcard', { onClick: () => card.classList.toggle('flipped') },
      h('div.inner', null,
        h('div.face.card', null, h('div.hint', null, t('vocab.english')), h('div.big', null, w.term), h('div.muted', { style: { fontSize: '0.75rem' } }, t('vocab.tapToFlip'))),
        h('div.face.back', null, h('div.hint', null, t('vocab.french')), h('div.big', null, w.translation), w.example ? h('div', { style: { fontSize: '0.8125rem', opacity: '0.85', fontStyle: 'italic' } }, w.example) : null)));
    root.replaceChildren(card, h('div.row.between', null,
      h('button.btn.secondary.sm', { disabled: i === 0, onClick: () => { i -= 1; render(); } }, icon('chevronLeft', 16)),
      h('span.muted.tnum', { style: { fontWeight: '700', fontSize: '0.8125rem' } }, `${i + 1} / ${words.length}`),
      h('button.btn.secondary.sm', { disabled: i >= words.length - 1, onClick: () => { i += 1; render(); } }, icon('chevronRight', 16))));
  };
  render();
  return root;
}

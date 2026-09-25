/**
 * Élève — évaluations : liste, présentation, passage chronométré, résultat, relecture.
 *
 * Le chronomètre affiché suit l'heure de fin fixée par le SERVEUR. Les réponses sont
 * enregistrées au fil de l'eau (reprise possible après un crash) mais ne sont corrigées
 * qu'au rendu de la copie, côté serveur.
 */
import { route, nav } from '../../core/router.js';
import { h, debounce } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr, obj, serverNow } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { skeletonList, skeletonDetail, emptyState, toastError, confirmDialog, sheet, busy, toast } from '../../core/ui.js';
import { renderMarkdown } from '../../core/markdown.js';
import {
  assessmentCard, segmented, emblem, badge, themeLabel, penGrade, countdown, notice, assessmentStatus, gradeChip,
} from '../../components/widgets.js';
import { questionView } from '../../components/question.js';

export function register() {
  // ─── Liste ─────────────────────────────────────────────────────────────────
  route('student.assessments', {
    title: () => t('assessments.title'),
    tab: 'assessments',
    large: true,
    skeleton: () => skeletonList(3),
    load: () => rpc('assessments:list'),
    render(ctx, list) {
      const items = arr(list);
      const groups = {
        todo: items.filter((a) => a.window === 'open' && (a.state === 'todo' || a.state === 'in_progress') && a.canStart),
        upcoming: items.filter((a) => a.window === 'upcoming'),
        done: items.filter((a) => a.state === 'done' || a.state === 'pending' || (a.window === 'closed') || (a.window === 'open' && !a.canStart)),
      };
      const filter = ctx.get('filter') || 'todo';
      const listEl = h('div.stack.tight.stagger');
      const paint = (value) => {
        ctx.set('filter', value);
        listEl.replaceChildren();
        const shown = groups[value];
        if (!shown.length) {
          listEl.appendChild(emptyState({ icon: 'clipboard', title: t(`assessments.empty.${value}`), text: value === 'todo' ? t('assessments.emptyText') : '' }));
          return;
        }
        shown.forEach((a) => listEl.appendChild(assessmentCard(a, () => nav.push('student.assessment', { id: a.id }))));
      };
      const tabs = segmented([
        { value: 'todo', label: t('assessments.tabs.todo'), count: groups.todo.length },
        { value: 'upcoming', label: t('assessments.tabs.upcoming'), count: groups.upcoming.length },
        { value: 'done', label: t('assessments.tabs.done'), count: groups.done.length },
      ], filter, paint);
      paint(filter);
      return h('div.content-narrow.stack', null, tabs, listEl,
        h('button.btn.ghost.block', { onClick: () => nav.push('student.results') }, icon('trophy', 18), t('results.title')));
    },
  });

  // ─── Présentation ──────────────────────────────────────────────────────────
  route('student.assessment', {
    title: () => t('assessments.one'),
    skeleton: skeletonDetail,
    refreshOnShow: true,
    load: (ctx) => rpc('assessment:get', { id: ctx.params.id }),
    render(ctx, a) {
      const out = h('div.content-narrow.stack.stagger');
      out.appendChild(h('div.card.course-hero.notebook', { style: { paddingLeft: '3.1rem' } },
        h('div.row.between', null, h('span.overline', null, t('assessments.label')), assessmentStatus(a)),
        h('h1', null, a.title),
        a.description ? h('p.desc', null, a.description) : null,
        h('div.facts', null,
          h('div.fact', null, h('div.k', null, t('assessments.questionsLabel')), h('div.v', null, String(a.questionCount))),
          h('div.fact', null, h('div.k', null, t('course.duration')), h('div.v', null, f.minutes(a.duration))),
          h('div.fact', null, h('div.k', null, t('assessments.scale')), h('div.v', null, `/${f.num(a.maxScore)}`))),
        h('div.meta', { style: { marginTop: '0.875rem' } },
          h('span', null, icon('pen', 13), a.teacher),
          a.coefficient && a.coefficient !== 1 ? h('span', null, icon('layers', 13), t('assessments.coef', { n: f.num(a.coefficient) })) : null,
          h('span', null, icon('star', 13), themeLabel(a.theme)))));

      // Disponibilité
      const lines = [];
      if (a.opensAt || a.closesAt) {
        lines.push(h('div.row', null, icon('calendar', 18), h('div', null,
          h('div', { style: { fontWeight: '600' } }, t('assessments.available')),
          h('div.muted', { style: { fontSize: '0.8125rem' } },
            a.opensAt && a.closesAt ? `${f.dateTime(a.opensAt)} → ${f.time(a.closesAt)}` : a.closesAt ? t('assessments.until', { when: f.dateTime(a.closesAt) }) : t('assessments.from', { when: f.dateTime(a.opensAt) })))));
      }
      lines.push(h('div.row', null, icon('refresh', 18), h('div', null,
        h('div', { style: { fontWeight: '600' } }, a.maxAttempts === 0 ? t('assessments.unlimitedAttempts') : tn('assessments.attempts', a.maxAttempts)),
        h('div.muted', { style: { fontSize: '0.8125rem' } }, a.attemptsLeft === -1 ? t('assessments.attemptsLeftUnlimited') : tn('assessments.attemptsLeft', a.attemptsLeft)))));
      lines.push(h('div.row', null, icon('eye', 18), h('div', null,
        h('div', { style: { fontWeight: '600' } }, a.releaseMode === 'manual' ? t('assessments.manualRelease') : t('assessments.instantRelease')))));
      out.appendChild(h('div.card.pad.stack', null, ...lines));

      if (a.last && a.state !== 'in_progress') {
        const last = a.best || a.last;
        out.appendChild(h('button.card.pad.clickable.row', { onClick: () => nav.push('student.result', { id: last.id }) },
          h('div.emblem.gold', null, icon('trophy', 20)),
          h('div.grow', null, h('div', { style: { fontWeight: '700' } }, t('assessments.myResult')), h('div.muted', { style: { fontSize: '0.8125rem' } }, f.ago(last.submittedAt))),
          last.grade !== undefined && last.grade !== null ? gradeChip(last.grade, last.gradeMax) : badge(t('results.pending'), ''),
          icon('chevronRight', 18, 'chev')));
      }

      if (a.window === 'upcoming') out.appendChild(notice(t('assessments.notYet', { when: f.dateTime(a.opensAt) }), 'info', 'clock'));
      if (a.window === 'closed') out.appendChild(notice(t('assessments.closedNotice'), 'warn', 'lock'));

      if (a.canStart) {
        const label = a.state === 'in_progress' ? t('assessments.resume') : t('assessments.start');
        ctx.footer(h('div.action-bar', null, h('button.btn.primary.lg', {
          onClick: async () => {
            if (a.state !== 'in_progress') {
              const ok = await confirmDialog({
                title: t('assessments.confirmTitle'),
                message: a.duration ? t('assessments.confirmTimed', { duration: f.minutes(a.duration) }) : t('assessments.confirmUntimed'),
                confirm: t('assessments.start'),
                icon: 'timer',
              });
              if (!ok) return;
            }
            try {
              const attempt = await busy(() => rpc('assessment:start', { id: a.id }), t('assessments.preparing'));
              nav.push('student.attempt', { attempt });
            } catch (err) {
              toastError(err);
              ctx.refresh({ silent: true });
            }
          },
        }, icon('play', 18), label)));
      } else {
        ctx.footer(null);
      }
      return out;
    },
  });

  // ─── Passage ───────────────────────────────────────────────────────────────
  route('student.attempt', {
    title: (ctx) => obj(ctx.params.attempt).assessment ? ctx.params.attempt.assessment.title : t('assessments.one'),
    hideTabs: true,
    bell: false,
    confirmLeave: async (ctx) => {
      if (ctx.get('submitted')) return true;
      return confirmDialog({ title: t('attempt.leaveTitle'), message: t('attempt.leaveText'), confirm: t('attempt.leave'), icon: 'info' });
    },
    render(ctx) {
      return attemptView(ctx, ctx.params.attempt);
    },
  });

  // ─── Résultat ──────────────────────────────────────────────────────────────
  route('student.result', {
    title: () => t('result.title'),
    skeleton: skeletonDetail,
    load: (ctx) => (ctx.params.result ? Promise.resolve(ctx.params.result) : rpc('result:get', { id: ctx.params.id })),
    render(ctx, r) {
      return resultView(ctx, r);
    },
  });
}

// ─────────────────────────────────────────────────────────────────────────────

function attemptView(ctx, payload) {
  const attempt = obj(payload.attempt);
  const questions = arr(payload.questions);
  const saved = obj(payload.answers);
  const answers = {};
  Object.keys(saved).forEach((k) => { answers[k] = saved[k]; });
  const flagged = new Set();
  let index = 0;
  let submitting = false;

  const root = h('div.content-narrow');
  const timerBox = h('span.exam-timer', null, icon('timer', 16));
  const saveState = h('span.save-state');
  const qBox = h('div');
  const navRow = h('div.row', { style: { marginTop: '0.875rem' } });

  let timer = null;
  if (attempt.expiresAt) {
    timer = countdown(attempt.expiresAt, {
      warnAt: 60,
      onTick: (left) => {
        if (Math.round(left) === 300) toast(t('attempt.fiveMinutes'), { tone: 'info', icon: 'timer' });
      },
      onEnd: () => submit(true),
    });
    timerBox.appendChild(timer);
    ctx.cleanup(() => timer.stop());
  } else {
    timerBox.appendChild(h('span', null, t('time.unlimited')));
  }

  const pendingSaves = new Map();
  const setSaving = (on) => {
    saveState.classList.toggle('saving', on);
    saveState.replaceChildren(on ? h('span.spinner') : icon('check', 14), on ? t('attempt.saving') : t('attempt.saved'));
  };
  const saveNow = async (qid) => {
    const answer = answers[qid];
    pendingSaves.delete(qid);
    setSaving(true);
    try {
      await rpc('assessment:save', { attemptId: attempt.id, questionId: Number(qid), answer });
    } catch (err) {
      if (err.code === 'attempt_expired' || err.code === 'attempt_closed') {
        onClosedByServer();
        return;
      }
      toastError(err);
    } finally {
      if (!pendingSaves.size) setSaving(false);
    }
  };
  const scheduleSave = (qid) => {
    if (!pendingSaves.has(qid)) pendingSaves.set(qid, debounce(() => saveNow(qid), 700));
    pendingSaves.get(qid)();
  };
  const flushSaves = async () => {
    const ids = Array.from(pendingSaves.keys());
    for (const qid of ids) {
      const fn = pendingSaves.get(qid);
      if (fn) fn.cancel();
      await saveNow(qid);
    }
  };

  const isAnswered = (q) => {
    const a = answers[String(q.id)];
    if (!a) return false;
    if (a.text !== undefined) return String(a.text).trim().length > 0;
    if (a.blanks) return arr(a.blanks).some((b) => String(b).trim());
    if (a.words) return arr(a.words).length > 0;
    if (a.pairs) return Object.keys(obj(a.pairs)).length > 0;
    if (a.choices) return arr(a.choices).length > 0;
    return a.choice !== undefined || a.value !== undefined;
  };

  const progressLabel = h('span.muted.tnum', { style: { fontSize: '0.75rem', fontWeight: '700' } });

  const show = (i) => {
    index = Math.max(0, Math.min(questions.length - 1, i));
    const q = questions[index];
    const view = questionView(q, {
      index,
      total: questions.length,
      value: answers[String(q.id)],
      onChange: (answer) => {
        answers[String(q.id)] = answer;
        scheduleSave(String(q.id));
        paintProgress();
      },
    });
    const flag = h('button.btn.ghost.sm', {
      onClick: () => {
        if (flagged.has(q.id)) flagged.delete(q.id); else flagged.add(q.id);
        flag.classList.toggle('on', flagged.has(q.id));
        flag.replaceChildren(icon('flag', 16), flagged.has(q.id) ? t('attempt.flagged') : t('attempt.flag'));
      },
    }, icon('flag', 16), flagged.has(q.id) ? t('attempt.flagged') : t('attempt.flag'));
    qBox.replaceChildren(h('div.card.pad-lg.rise', null, view.el, h('div.row.between', { style: { marginTop: '0.75rem' } }, flag, saveState)));
    navRow.replaceChildren(
      h('button.btn.secondary.square', { disabled: index === 0, 'aria-label': t('common.previous'), title: t('common.previous'), onClick: () => show(index - 1) }, icon('chevronLeft', 18)),
      h('button.btn.secondary', { onClick: openNavigator }, icon('list', 18), `${index + 1}/${questions.length}`),
      index < questions.length - 1
        ? h('button.btn.primary.grow', { onClick: () => show(index + 1) }, h('span.label', null, t('common.next')), icon('chevronRight', 18))
        : h('button.btn.primary.grow', { onClick: () => submit(false) }, icon('send', 18), h('span.label', null, t('attempt.submit'))));
    paintProgress();
    ctx.body.scrollTop = 0;
  };

  function paintProgress() {
    const n = questions.filter(isAnswered).length;
    progressLabel.textContent = t('attempt.answered', { n, total: questions.length });
  }

  function openNavigator() {
    const grid = h('div.navigator', null, ...questions.map((q, i) => h('button', {
      class: { answered: isAnswered(q), current: i === index, flagged: flagged.has(q.id) },
      onClick: () => { api.close(); show(i); },
    }, String(i + 1))));
    const api = sheet({
      title: t('attempt.overview'),
      content: h('div.stack', null, grid,
        h('div.meta', null,
          h('span', null, h('i.legend-swatch.answered'), t('attempt.legendAnswered')),
          h('span', null, h('i.legend-swatch.flagged'), t('attempt.legendFlagged')))),
      actions: [h('button.btn.primary', { onClick: () => { api.close(); submit(false); } }, icon('send', 18), t('attempt.submit'))],
    });
  }

  async function submit(auto) {
    if (submitting) return;
    if (!auto) {
      const missing = questions.filter((q) => !isAnswered(q)).length;
      const ok = await confirmDialog({
        title: t('attempt.submitTitle'),
        message: missing ? tn('attempt.submitMissing', missing) : t('attempt.submitText'),
        confirm: t('attempt.submit'),
        icon: 'send',
      });
      if (!ok) return;
    }
    submitting = true;
    try {
      await flushSaves();
      const result = await busy(() => rpc('assessment:submit', { attemptId: attempt.id }), auto ? t('attempt.timeUp') : t('attempt.submitting'));
      ctx.set('submitted', true);
      if (timer) timer.stop();
      nav.invalidate(['student.assessments', 'student.assessment', 'student.home', 'student.results']);
      nav.replace('student.result', { id: result.id, result, fresh: true });
    } catch (err) {
      submitting = false;
      if (err.code === 'attempt_expired' || err.code === 'attempt_closed') return onClosedByServer();
      toastError(err);
    }
  }

  function onClosedByServer() {
    if (ctx.get('submitted')) return;
    ctx.set('submitted', true);
    if (timer) timer.stop();
    toast(t('attempt.closedByServer'), { tone: 'info', icon: 'timer' });
    nav.invalidate(['student.assessments', 'student.assessment', 'student.home']);
    nav.replace('student.result', { id: attempt.id });
  }

  ctx.onPush('attempt:closed', (data) => {
    if (data.attemptId === attempt.id) onClosedByServer();
  });

  root.appendChild(h('div.exam-bar', null, timerBox, h('span.grow'), progressLabel));
  root.appendChild(qBox);
  root.appendChild(navRow);
  if (!questions.length) {
    root.replaceChildren(emptyState({ icon: 'alert', title: t('attempt.noQuestions') }));
  } else {
    show(0);
  }
  return root;
}

// ─────────────────────────────────────────────────────────────────────────────

export function resultView(ctx, r) {
  const out = h('div.content-narrow.stack.stagger');
  const a = obj(r.assessment);
  const released = r.grade !== undefined && r.grade !== null;

  const card = h('div.card.result-card.notebook', { style: { paddingLeft: '2.75rem' } },
    h('div.overline', null, r.status === 'in_progress' ? t('result.inProgress') : t('result.finished')),
    h('h2', null, a.title || ''));
  if (released) {
    card.appendChild(penGrade(r.grade, r.gradeMax));
    card.appendChild(h('div.result-facts', null,
      h('div', null, h('b', null, f.percent(r.percent)), h('span', null, t('result.success'))),
      h('div', null, h('b', null, f.duration(r.durationSec)), h('span', null, t('result.time'))),
      h('div', null, h('b', null, `${f.num(r.score)}/${f.num(r.maxPoints)}`), h('span', null, t('question.pts')))));
  } else {
    card.appendChild(h('div', { style: { display: 'grid', placeItems: 'center', gap: '0.75rem', margin: '0.5rem 0' } },
      h('div.emblem.lg', null, icon(r.needsReview ? 'pen' : 'clock', 26)),
      h('div', { style: { fontWeight: '700' } }, r.needsReview ? t('result.awaitingCorrection') : t('result.awaitingRelease')),
      h('p.muted', { style: { margin: 0, fontSize: '0.875rem' } }, t('result.notifyWhenReady'))));
    card.appendChild(h('div.result-facts', null,
      h('div', null, h('b', null, f.duration(r.durationSec)), h('span', null, t('result.time')))));
  }
  if (r.autoSubmitted) card.appendChild(h('div', { style: { marginTop: '1rem' } }, badge(t('result.autoSubmitted'), 'gold')));
  out.appendChild(card);

  if (r.teacherComment) {
    out.appendChild(h('div.card.pad.stack.tight', null,
      h('div.overline', null, t('result.teacherComment')),
      h('p', { style: { margin: 0, fontFamily: 'var(--ec-serif)', fontStyle: 'italic', fontSize: '1.0625rem' } }, `« ${r.teacherComment} »`)));
  }

  const review = arr(r.review);
  if (r.canReview && review.length) {
    const reviewBox = h('div.stack.hidden');
    const toggleBtn = h('button.btn.secondary.lg.block', {
      onClick: () => {
        const hidden = reviewBox.classList.toggle('hidden');
        toggleBtn.replaceChildren(icon(hidden ? 'eye' : 'eyeOff', 18), hidden ? t('result.showAnswers') : t('result.hideAnswers'));
        if (!hidden && !reviewBox.childNodes.length) buildReview(reviewBox, review);
      },
    }, icon('eye', 18), t('result.showAnswers'));
    out.appendChild(toggleBtn);
    out.appendChild(reviewBox);
    if (ctx.params.review) toggleBtn.click();
  } else if (released && r.reviewAt) {
    out.appendChild(notice(t('result.reviewLater', { when: f.dateTime(r.reviewAt) }), 'info', 'clock'));
  } else if (released && a.reviewMode === 'never') {
    out.appendChild(notice(t('result.reviewNever'), 'info', 'lock'));
  }

  ctx.footer(h('div.action-bar', null, h('button.btn.secondary', { onClick: () => nav.tab('assessments') }, t('result.backToList'))));
  return out;
}

function buildReview(box, review) {
  review.forEach((item, i) => {
    const view = questionView(item, { index: i, total: review.length, value: item.answer });
    view.showFeedback({
      correct: item.correct,
      partial: item.correct === false && item.earned > 0,
      pending: item.pending,
      points: item.earned,
      max: item.max,
      solution: item.solution,
      detail: item.detail,
      explanation: item.explanation,
      teacherFeedback: item.teacherFeedback,
    });
    box.appendChild(h('div.card.pad-lg', null, view.el));
  });
}

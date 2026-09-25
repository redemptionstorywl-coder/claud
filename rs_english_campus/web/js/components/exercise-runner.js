/**
 * Déroulé d'un exercice : une question à la fois, correction serveur après chaque réponse,
 * bilan final (score, meilleur score, recommencer). Utilisé par l'élève et par l'aperçu professeur.
 */
import { h, clear, scrollToEl } from '../core/dom.js';
import { icon } from '../core/icons.js';
import { t, tn } from '../core/i18n.js';
import { rpc, arr } from '../core/nui.js';
import * as f from '../core/format.js';
import { toastError, confirmDialog } from '../core/ui.js';
import { renderMarkdown } from '../core/markdown.js';
import { questionView } from './question.js';
import { segments, progressRing } from './widgets.js';

function stateOf(q, i, current) {
  const fb = q.feedback;
  if (fb) {
    if (fb.pending) return 'done';
    if (fb.correct) return 'ok';
    if (fb.partial) return 'part';
    return 'ko';
  }
  return i === current ? 'current' : '';
}

/**
 * @param {{ courseId:number, section:object, preview?:boolean, onProgress?:Function, onNext?:Function, nextLabel?:string }} opts
 */
export function exerciseRunner(opts) {
  const root = h('div.exercise');
  let questions = arr(opts.section.questions).map((q) => Object.assign({}, q));
  let index = questions.findIndex((q) => !q.feedback);
  let started = questions.some((q) => q.feedback);
  let best = opts.section.result ? opts.section.result.bestPercent : null;
  let busyLock = false;

  const nextUnanswered = () => {
    const i = questions.findIndex((q, k) => k > index && !q.feedback);
    if (i !== -1) return i;
    const any = questions.findIndex((q) => !q.feedback);
    return any === -1 ? questions.length : any;
  };

  function render() {
    clear(root);
    if (!questions.length) {
      root.appendChild(h('div.card.pad', null, t('exercise.empty')));
      return;
    }
    if (!started) return intro();
    if (index === -1 || index >= questions.length) return summary();
    return step();
  }

  function intro() {
    const answered = questions.filter((q) => q.feedback).length;
    root.appendChild(h('div.card.pad-lg.stack.rise', null,
      h('div.row', null,
        h('div.emblem.lg', null, icon('pen', 26)),
        h('div.grow', null,
          h('div.overline', null, t('exercise.label')),
          h('div', { style: { fontWeight: '700', fontSize: '1.0625rem' } }, tn('exercise.questions', questions.length)))),
      opts.section.instructions ? renderMarkdown(opts.section.instructions) : h('p.soft', { style: { margin: 0 } }, t('exercise.defaultInstructions')),
      best !== null && best !== undefined ? h('div.row.muted', null, icon('trophy', 16), t('exercise.best', { n: Math.round(best) })) : null,
      h('button.btn.primary.lg.block', { onClick: () => { started = true; if (index === -1) index = 0; render(); } },
        icon('play', 18), answered ? t('exercise.resume') : t('exercise.start'))));
  }

  function step() {
    const q = questions[index];
    const segs = h('div.reader-top', null, segments(questions.map((x, i) => stateOf(x, i, index))), h('span.muted.tnum', { style: { fontSize: '0.75rem', fontWeight: '700' } }, `${index + 1}/${questions.length}`));
    let validate;
    const view = questionView(q, {
      index,
      total: questions.length,
      value: q.feedback ? q.feedback.answer : undefined,
      onChange: () => { if (validate) validate.disabled = !view.isAnswered(); },
    });
    const card = h('div.card.pad-lg.rise', null, view.el);

    const goNext = () => {
      index = nextUnanswered();
      render();
      scrollToEl(root);
    };
    const nextBtn = () => h('button.btn.primary.block', { onClick: goNext },
      nextUnanswered() >= questions.length ? t('exercise.seeResults') : t('common.continue'), icon('arrowRight', 18));

    const submit = async () => {
      if (busyLock || !view.isAnswered()) return;
      busyLock = true;
      validate.disabled = true;
      validate.replaceChildren(h('span.spinner'), t('question.checking'));
      try {
        const fb = opts.preview
          ? await rpc('tcourse:preview:answer', { courseId: opts.courseId, questionId: q.id, answer: view.getAnswer() })
          : await rpc('exercise:answer', { courseId: opts.courseId, sectionId: opts.section.id, questionId: q.id, answer: view.getAnswer() });
        q.feedback = fb;
        view.showFeedback(fb, { action: nextBtn() });
        validate.remove();
        segs.replaceChildren(segments(questions.map((x, i) => stateOf(x, i, index))), h('span.muted.tnum', { style: { fontSize: '0.75rem', fontWeight: '700' } }, `${index + 1}/${questions.length}`));
        if (fb.exercise && opts.onProgress) opts.onProgress(fb.exercise);
        if (fb.exercise && fb.exercise.bestPercent !== undefined) best = fb.exercise.bestPercent;
      } catch (err) {
        toastError(err);
        validate.disabled = false;
        validate.replaceChildren(icon('check', 18), t('question.validate'));
      } finally {
        busyLock = false;
      }
    };

    if (q.feedback) {
      view.showFeedback(q.feedback, { action: nextBtn() });
    } else {
      validate = h('button.btn.primary.lg.block', { disabled: true, onClick: submit }, icon('check', 18), t('question.validate'));
    }
    card.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter' || e.shiftKey || e.target.tagName === 'TEXTAREA') return;
      e.preventDefault();
      if (validate && validate.isConnected && !validate.disabled) submit();
      else if (q.feedback) goNext();
    });
    root.append(segs, card);
    if (validate) root.appendChild(h('div', { style: { marginTop: '0.875rem' } }, validate));
    if (view.focus) setTimeout(() => view.focus(), 120);
  }

  function summary() {
    const answered = questions.filter((q) => q.feedback);
    const graded = answered.filter((q) => !q.feedback.pending);
    const good = graded.filter((q) => q.feedback.correct).length;
    const pts = graded.reduce((s, q) => s + (q.feedback.points || 0), 0);
    const max = graded.reduce((s, q) => s + (q.feedback.max || q.points || 0), 0);
    const pct = max > 0 ? Math.round((pts / max) * 100) : 100;
    const tone = pct >= 80 ? 'gold' : pct >= 50 ? 'success' : '';
    const title = pct >= 80 ? t('exercise.great') : pct >= 50 ? t('exercise.good') : t('exercise.keepGoing');
    root.appendChild(h('div.card.pad-lg.result-card.rise', null,
      h('div.overline', null, t('exercise.finished')),
      h('h2', null, title),
      h('div', { style: { display: 'grid', placeItems: 'center' } }, progressRing(pct, { size: 112, stroke: 9, tone, label: t('exercise.score') })),
      h('div.result-facts', null,
        h('div', null, h('b', null, `${good}/${graded.length}`), h('span', null, t('exercise.correctAnswers'))),
        h('div', null, h('b', null, `${f.num(pts)}/${f.num(max)}`), h('span', null, t('question.pts'))),
        best !== null && best !== undefined ? h('div', null, h('b', null, `${Math.round(best)}%`), h('span', null, t('exercise.bestShort'))) : null)));

    const actions = h('div.stack.tight', { style: { marginTop: '0.875rem' } });
    if (opts.onNext) actions.appendChild(h('button.btn.primary.lg.block', { onClick: opts.onNext }, opts.nextLabel || t('course.nextPart'), icon('arrowRight', 18)));
    actions.appendChild(h('div.row', null,
      h('button.btn.secondary.grow', { onClick: () => review() }, icon('eye', 18), t('exercise.review')),
      h('button.btn.secondary.grow', { onClick: restart }, icon('refresh', 18), t('exercise.restart'))));
    root.appendChild(actions);
  }

  function review() {
    clear(root);
    root.appendChild(h('button.btn.ghost', { onClick: () => { index = questions.length; render(); } }, icon('chevronLeft', 18), t('exercise.backToSummary')));
    questions.forEach((q, i) => {
      const view = questionView(q, { index: i, total: questions.length, value: q.feedback ? q.feedback.answer : undefined });
      if (q.feedback) view.showFeedback(q.feedback);
      else view.lock();
      root.appendChild(h('div.card.pad-lg', { style: { marginTop: '0.75rem' } }, view.el));
    });
  }

  async function restart() {
    if (!(await confirmDialog({ title: t('exercise.restartTitle'), message: t('exercise.restartText'), confirm: t('exercise.restart'), icon: 'refresh' }))) return;
    try {
      if (opts.preview) {
        questions = questions.map((q) => Object.assign({}, q, { feedback: undefined }));
      } else {
        const res = await rpc('exercise:reset', { courseId: opts.courseId, sectionId: opts.section.id });
        questions = arr(res.questions);
      }
      index = 0;
      started = true;
      render();
    } catch (err) {
      toastError(err);
    }
  }

  render();
  return root;
}

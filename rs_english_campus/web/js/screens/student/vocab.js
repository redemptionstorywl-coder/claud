/**
 * Élève — vocabulaire (mots des cours) et mode révision (répétition espacée).
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr } from '../../core/nui.js';
import { skeletonList, skeletonDetail, emptyState, toastError } from '../../core/ui.js';
import { progressRing, segmented, section, progressBar } from '../../components/widgets.js';
import { flashcards } from './courses.js';

function mastery(box, max = 5) {
  const dots = [];
  for (let i = 1; i <= max; i++) dots.push(h(`i${i <= box ? '.on' : ''}`));
  return h('div.mastery', { title: t('vocab.level', { n: box }) }, ...dots);
}

export function register() {
  route('student.vocab', {
    title: () => t('vocab.title'),
    tab: 'vocab',
    large: true,
    skeleton: () => skeletonList(4),
    load: () => rpc('vocab:list'),
    render(ctx, data) {
      const groups = arr(data.groups);
      const out = h('div.content-narrow.stack');
      if (!data.total) {
        out.appendChild(emptyState({ icon: 'cards', title: t('vocab.empty'), text: t('vocab.emptyText') }));
        return out;
      }
      const pct = Math.round((data.mastered / data.total) * 100);
      out.appendChild(h('div.card.progress-hero', null,
        progressRing(pct, { size: 84, stroke: 8, tone: 'gold' }),
        h('div.grow', null,
          h('div.overline', null, t('vocab.mastery')),
          h('div', { style: { fontWeight: '700', fontSize: '1.0625rem', margin: '0.2rem 0' } }, t('progress.wordsMastered', { n: data.mastered, total: data.total })),
          h('button.btn.primary.sm', { onClick: () => nav.push('student.revision', {}) }, icon('sparkle', 16), t('vocab.revise')))));

      const search = h('input.input', { type: 'search', placeholder: t('vocab.search') });
      const list = h('div.stack');
      const paint = () => {
        const q = search.value.trim().toLowerCase();
        list.replaceChildren();
        let shown = 0;
        groups.forEach((g) => {
          const words = arr(g.words).filter((w) => !q || w.term.toLowerCase().includes(q) || w.translation.toLowerCase().includes(q));
          if (!words.length) return;
          shown += words.length;
          list.appendChild(section(g.title, h('button.link', { onClick: () => nav.push('student.revision', { courseId: g.courseId }) }, t('vocab.reviseShort')),
            h('div.card.word-list', null, ...words.map((w) => h('div.word', null,
              h('div.col', null, h('div.term', null, w.term), h('div.tr', null, w.translation), w.example ? h('div.ex', null, w.example) : null),
              mastery(w.box)))),
            g.courseTitle && g.courseTitle !== g.title ? h('div.muted', { style: { fontSize: '0.75rem', margin: '0.4rem 0.25rem 0' } }, g.courseTitle) : null));
        });
        if (!shown) list.appendChild(emptyState({ icon: 'search', title: t('vocab.noMatch'), compact: true }));
      };
      search.addEventListener('input', paint);
      paint();
      out.append(search, list);
      return out;
    },
  });

  route('student.revision', {
    title: () => t('revision.title'),
    hideTabs: true,
    skeleton: skeletonDetail,
    load: (ctx) => rpc('vocab:session', { courseId: ctx.params.courseId, direction: ctx.get('direction') || 'fr_en' }),
    render(ctx, session) {
      const items = arr(session.items);
      const out = h('div.content-narrow.stack');
      const direction = ctx.get('direction') || 'fr_en';
      out.appendChild(segmented([
        { value: 'fr_en', label: t('revision.frEn') },
        { value: 'en_fr', label: t('revision.enFr') },
        { value: 'mixed', label: t('revision.mixed') },
      ], direction, (value) => { ctx.set('direction', value); ctx.refresh(); }));
      if (!items.length) {
        out.appendChild(emptyState({ icon: 'cards', title: t('vocab.empty'), text: t('vocab.emptyText') }));
        return out;
      }
      const stage = h('div.stack');
      out.appendChild(stage);
      let index = 0;
      let good = 0;
      const results = [];

      const ask = () => {
        const item = items[index];
        const input = h('input.input.lg.q-input', { type: 'text', placeholder: item.direction === 'fr_en' ? t('question.placeholderEn') : t('question.placeholderFr'), autocomplete: 'off', spellcheck: 'false' });
        const validate = h('button.btn.primary.lg.block', { onClick: () => check() }, icon('check', 18), t('question.validate'));
        const progress = h('div.reader-top', null, h('div.grow', null, progressBar((index / items.length) * 100)), h('span.muted.tnum', { style: { fontSize: '0.75rem', fontWeight: '700' } }, `${index + 1}/${items.length}`));
        const card = h('div.card.revision-card.notebook.rise', null,
          h('div.ask', null, item.direction === 'fr_en' ? t('revision.askEn') : t('revision.askFr')),
          h('div.word-big', null, `« ${item.prompt} »`));
        const feedback = h('div');
        stage.replaceChildren(progress, card, input, feedback, validate);
        setTimeout(() => input.focus({ preventScroll: true }), 80);

        let checked = false;
        const next = () => {
          index += 1;
          if (index >= items.length) finish();
          else ask();
        };
        async function check() {
          if (checked) return next();
          if (!input.value.trim()) return;
          validate.disabled = true;
          try {
            const res = await rpc('vocab:check', { wordId: item.wordId, direction: item.direction, answer: input.value });
            checked = true;
            if (res.correct) good += 1;
            results.push(res);
            input.classList.add(res.correct ? 'is-correct' : 'is-wrong');
            input.disabled = true;
            feedback.replaceChildren(h(`div.revision-result.${res.correct ? 'ok' : 'ko'}`, null,
              h('div', { style: { fontWeight: '700', display: 'inline-flex', gap: '0.4rem', alignItems: 'center', color: res.correct ? 'var(--ec-correct)' : 'var(--ec-wrong)' } },
                icon(res.correct ? 'checkCircle' : 'xCircle', 18), res.correct ? (res.typo ? t('feedback.correctTypo') : t('revision.good')) : t('revision.bad')),
              h('div.pair', null, `${res.term} = ${res.translation}`),
              res.example ? h('div.muted', { style: { fontSize: '0.8125rem', fontStyle: 'italic', marginTop: '0.25rem' } }, res.example) : null));
            validate.disabled = false;
            validate.replaceChildren(index === items.length - 1 ? t('revision.finish') : t('common.next'), icon('arrowRight', 18));
          } catch (err) {
            validate.disabled = false;
            toastError(err);
          }
        }
        input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); check(); } });
      };

      const finish = () => {
        const pct = Math.round((good / items.length) * 100);
        const mastered = results.filter((r) => r.mastered).length;
        stage.replaceChildren(h('div.card.result-card.rise', null,
          h('div.overline', null, t('revision.done')),
          h('h2', null, pct >= 80 ? t('exercise.great') : pct >= 50 ? t('exercise.good') : t('exercise.keepGoing')),
          h('div', { style: { display: 'grid', placeItems: 'center' } }, progressRing(pct, { size: 110, stroke: 9, tone: pct >= 80 ? 'gold' : 'success', text: `${good}/${items.length}` })),
          h('div.result-facts', null,
            h('div', null, h('b', null, `${pct}%`), h('span', null, t('result.success'))),
            h('div', null, h('b', null, String(mastered)), h('span', null, t('revision.mastered'))))),
        h('div.row', null,
          h('button.btn.secondary.grow', { onClick: () => nav.back() }, t('common.close')),
          h('button.btn.primary.grow', { onClick: () => ctx.refresh() }, icon('refresh', 18), t('revision.again'))));
        nav.invalidate(['student.vocab', 'student.progress']);
      };
      ask();
      return out;
    },
  });
}

export { flashcards };

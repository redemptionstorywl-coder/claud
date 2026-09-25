/**
 * Élève — ma progression (globale + par thème) et mes résultats (historique + moyenne).
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr, obj } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { skeletonDetail, skeletonList, emptyState } from '../../core/ui.js';
import {
  progressRing, progressBar, stat, section, THEME_ICONS, themeLabel, sparkline, gradeChip, badge,
} from '../../components/widgets.js';

export function themeBars(themes) {
  return h('div.theme-bars', null, ...arr(themes).map((th) => {
    const pct = th.percent === undefined || th.percent === null ? null : th.percent;
    return h('div.theme-bar', null,
      h('div.emblem', null, icon(THEME_ICONS[th.theme] || 'book', 16)),
      h('div', null, h('div.name', null, themeLabel(th.theme)), progressBar(pct || 0, pct >= 80 ? 'success' : pct !== null && pct < 50 ? 'gold' : '')),
      h('span.val', null, pct === null ? '—' : `${pct}%`));
  }));
}

export function register() {
  route('student.progress', {
    title: () => t('progress.title'),
    tab: 'progress',
    large: true,
    skeleton: skeletonDetail,
    load: () => rpc('progress:mine'),
    render(ctx, p) {
      const courses = obj(p.courses);
      const ex = obj(p.exercises);
      const vocab = obj(p.vocabulary);
      const history = arr(p.history);
      const out = h('div.content-narrow.stack.stagger');

      out.appendChild(h('div.card.progress-hero', null,
        progressRing(p.overall || 0, { size: 108, stroke: 9, label: t('progress.english') }),
        h('div.grow', null,
          h('div.overline', null, t('progress.overall')),
          h('div', { style: { fontFamily: 'var(--ec-serif)', fontSize: '1.375rem', fontWeight: '700', margin: '0.2rem 0 0.4rem', letterSpacing: '-0.02em' } },
            p.overall >= 80 ? t('progress.excellent') : p.overall >= 50 ? t('progress.onTrack') : t('progress.gettingStarted')),
          h('div.muted', { style: { fontSize: '0.8125rem', lineHeight: '1.45' } }, t('progress.explain')))));

      out.appendChild(h('div.grid-2', null,
        stat({ value: `${courses.completed || 0}`, suffix: `/ ${courses.total || 0}`, label: t('progress.coursesDone'), icon: 'book' }),
        stat({ value: `${ex.done || 0}`, suffix: `/ ${ex.total || 0}`, label: t('progress.exercisesDone'), icon: 'pen' }),
        stat({ value: `${p.assessments || 0}`, label: t('progress.assessmentsDone'), icon: 'clipboard', onClick: () => nav.push('student.results') }),
        stat({ value: p.average === undefined || p.average === null ? '—' : f.num(p.average), suffix: `/ ${p.scale || 20}`, label: t('progress.average'), icon: 'trophy', tone: 'gold', onClick: () => nav.push('student.results') })));

      out.appendChild(section(t('progress.byTheme'), null, h('div.card.pad-lg', null, themeBars(p.themes))));

      if (vocab.total) {
        const pct = Math.round((vocab.mastered / vocab.total) * 100);
        out.appendChild(section(t('progress.vocabulary'), null,
          h('button.card.pad.clickable.row', { onClick: () => nav.tab('vocab') },
            progressRing(pct, { size: 58, stroke: 6, tone: 'gold' }),
            h('div.grow', null,
              h('div', { style: { fontWeight: '700' } }, t('progress.wordsMastered', { n: vocab.mastered, total: vocab.total })),
              h('div.muted', { style: { fontSize: '0.8125rem' } }, t('progress.reviseCta'))),
            icon('chevronRight', 18, 'chev'))));
      }

      if (history.length > 1) {
        out.appendChild(section(t('progress.evolution'), null, h('div.card.pad', null,
          sparkline(history.map((x) => x.value), p.scale || 20),
          h('div.row.between.muted', { style: { fontSize: '0.6875rem', fontWeight: '600', marginTop: '0.4rem' } },
            h('span', null, f.shortDate(history[0].at)), h('span', null, f.shortDate(history[history.length - 1].at))))));
      }
      return out;
    },
  });

  route('student.results', {
    title: () => t('results.title'),
    tab: 'results',
    skeleton: () => skeletonList(4),
    load: () => rpc('results:mine'),
    render(ctx, data) {
      const items = arr(data.items);
      const out = h('div.content-narrow.stack.stagger');
      out.appendChild(h('div.card.average-card.notebook', { style: { paddingLeft: '3rem' } },
        h('div', null, h('div.overline', null, t('results.average')), h('div.muted', { style: { fontSize: '0.75rem', marginTop: '0.2rem' } }, tn('results.counted', data.counted || 0))),
        h('div.v', null, data.average === undefined || data.average === null ? h('span.none', null, '–') : f.num(data.average), h('small', null, ` / ${data.scale || 20}`))));
      if (!items.length) {
        out.appendChild(emptyState({ icon: 'trophy', title: t('results.empty'), text: t('results.emptyText') }));
        return out;
      }
      out.appendChild(h('div.card.list', null, ...items.map((r) => h('button.grade-row', { onClick: () => nav.push('student.result', { id: r.id }) },
        h('div.grow', null,
          h('div', { style: { fontWeight: '600' } }, r.title, r.attemptNo > 1 ? h('span.muted', null, ` · ${t('results.attempt', { n: r.attemptNo })}`) : null),
          h('div.muted', { style: { fontSize: '0.75rem' } }, `${f.date(r.submittedAt)} · ${f.duration(r.durationSec)}`)),
        r.status === 'released' ? gradeChip(r.grade, r.gradeMax) : badge(t('results.pending'), ''),
        icon('chevronRight', 18, 'chev')))));
      return out;
    },
  });
}

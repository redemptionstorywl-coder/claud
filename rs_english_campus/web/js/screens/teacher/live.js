/**
 * Professeur — suivi en direct pendant le cours (RP) : chaque élève avance, sa tuile se met
 * à jour en temps réel (poussé par le serveur, aucun sondage).
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr, serverNow } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { skeletonList, skeletonDetail, emptyState, toastError } from '../../core/ui.js';
import { progressRing, segmented, stat, gradeChip, badge, emblem } from '../../components/widgets.js';

export function register() {
  // Choix de la séance à suivre
  route('teacher.live', {
    title: () => t('live.title'),
    tab: 'live',
    skeleton: () => skeletonList(4),
    async load(ctx) {
      if (ctx.params.type && ctx.params.id) return { direct: true };
      const [courses, assessments] = await Promise.all([rpc('tcourses:list', {}), rpc('tassessments:list', {})]);
      return {
        courses: arr(courses).filter((c) => c.status === 'published'),
        assessments: arr(assessments).filter((a) => a.status === 'published'),
      };
    },
    mounted(ctx, data) {
      if (data && data.direct) nav.replace('teacher.liveSession', { type: ctx.params.type, id: ctx.params.id });
    },
    render(ctx, data) {
      if (data.direct) return h('div');
      const out = h('div.content-wide.stack');
      out.appendChild(h('div.notice', null, icon('live', 18), h('div', null, t('live.intro'))));
      const list = h('div.stack');
      const paint = (kind) => {
        ctx.set('kind', kind);
        const items = kind === 'course' ? data.courses : data.assessments;
        list.replaceChildren();
        if (!items.length) {
          list.appendChild(emptyState({ icon: kind === 'course' ? 'book' : 'clipboard', title: t('live.nothing'), text: t('live.nothingText'), compact: true }));
          return;
        }
        list.appendChild(h('div.grid-auto', null, ...items.map((it) => h('button.card.pad.clickable.row', { onClick: () => nav.push('teacher.liveSession', { type: kind, id: it.id }) },
          emblem(kind === 'course' ? it.emblem : 'clipboard', { tone: kind === 'course' ? '' : 'danger' }),
          h('div.grow', { style: { textAlign: 'left' } },
            h('div', { style: { fontWeight: '700' } }, it.title),
            h('div.muted', { style: { fontSize: '0.75rem' } }, kind === 'course' ? tn('teacher.startedBy', it.started || 0) : tn('teacher.submitted', it.submitted))),
          icon('live', 18)))));
      };
      out.appendChild(segmented([{ value: 'course', label: t('nav.courses') }, { value: 'assessment', label: t('nav.assessments') }], ctx.get('kind') || 'course', paint));
      out.appendChild(list);
      paint(ctx.get('kind') || 'course');
      return out;
    },
  });

  // Séance en direct
  route('teacher.liveSession', {
    title: (ctx, data) => (data && data.title) || t('live.title'),
    subtitle: (ctx) => (ctx.params.type === 'course' ? t('live.courseSession') : t('live.assessmentSession')),
    hideTabs: true,
    skeleton: skeletonDetail,
    load: (ctx) => rpc('live:subscribe', { type: ctx.params.type, id: ctx.params.id }),
    render(ctx, data) {
      ctx.cleanup(() => { rpc('live:unsubscribe').catch(() => {}); });
      const entries = new Map();
      arr(data.entries).forEach((e) => entries.set(e.studentId, e));
      const isCourse = ctx.params.type === 'course';
      const grid = h('div.live-grid');
      const tiles = new Map();
      const statsBox = h('div.grid-3');

      const tileFor = (e) => {
        let content;
        if (isCourse) {
          content = [progressRing(e.percent || 0, { size: 62, stroke: 6, tone: e.completed ? 'success' : '' }),
            h('div.name', null, e.name),
            h('div.sub', null, e.completed ? t('live.completed') : e.started || e.percent ? t('live.inProgress', { done: e.done || 0, total: e.total || 0 }) : t('live.notStarted'))];
        } else {
          const total = e.total || 0;
          const pct = total ? Math.round(((e.answered || 0) / total) * 100) : 0;
          let sub;
          if (e.status === 'in_progress') sub = t('live.answered', { n: e.answered || 0, total });
          else if (e.status === 'not_started') sub = t('live.notStarted');
          else sub = t(`grades.status.${e.status}`);
          content = [
            e.status === 'in_progress' || e.status === 'not_started'
              ? progressRing(pct, { size: 62, stroke: 6, tone: 'gold' })
              : progressRing(e.percent || 0, { size: 62, stroke: 6, tone: 'success', text: e.grade !== undefined && e.grade !== null ? f.num(e.grade) : '✓' }),
            h('div.name', null, e.name),
            h('div.sub', null, sub),
            e.auto ? badge(t('grades.auto'), 'gold') : null,
          ];
        }
        const tile = h(`button.live-tile${e.online === false ? '.offline' : ''}`, {
          onClick: () => (e.attemptId && !isCourse ? nav.push('teacher.attempt', { id: e.attemptId }) : nav.push('teacher.student', { id: e.studentId })),
        }, ...content, h('div.presence', null, h('span', { class: e.online === false ? 'dot-offline' : 'dot-online' }), e.at ? f.ago(e.at) : '—'));
        return tile;
      };

      const paintStats = () => {
        const list = Array.from(entries.values());
        if (isCourse) {
          const done = list.filter((e) => e.completed).length;
          const started = list.filter((e) => e.started || e.percent > 0).length;
          const avg = list.length ? Math.round(list.reduce((s, e) => s + (e.percent || 0), 0) / list.length) : 0;
          statsBox.replaceChildren(
            stat({ value: `${started}`, suffix: `/ ${list.length}`, label: t('live.stats.started'), icon: 'play' }),
            stat({ value: `${done}`, label: t('live.stats.completed'), icon: 'checkCircle', tone: 'correct' }),
            stat({ value: `${avg}%`, label: t('live.stats.average'), icon: 'chart' }));
        } else {
          const running = list.filter((e) => e.status === 'in_progress').length;
          const finished = list.filter((e) => ['submitted', 'graded', 'released'].indexOf(e.status) !== -1).length;
          const graded = list.filter((e) => e.grade !== undefined && e.grade !== null);
          const avg = graded.length ? graded.reduce((s, e) => s + e.grade / (e.gradeMax || 20) * 20, 0) / graded.length : null;
          statsBox.replaceChildren(
            stat({ value: `${running}`, label: t('live.stats.running'), icon: 'timer', tone: 'gold' }),
            stat({ value: `${finished}`, suffix: `/ ${list.length}`, label: t('live.stats.submitted'), icon: 'inbox' }),
            stat({ value: avg === null ? '—' : f.num(avg), suffix: '/ 20', label: t('live.stats.average'), icon: 'trophy', tone: 'gold' }));
        }
      };

      const paintAll = () => {
        grid.replaceChildren();
        tiles.clear();
        Array.from(entries.values()).sort((a, b) => a.name.localeCompare(b.name)).forEach((e) => {
          const tile = tileFor(e);
          tiles.set(e.studentId, tile);
          grid.appendChild(tile);
        });
        paintStats();
      };

      ctx.onPush('live', (msg) => {
        if (msg.key !== data.key || !msg.entry) return;
        const incoming = msg.entry;
        const current = entries.get(incoming.studentId) || { studentId: incoming.studentId, name: incoming.name };
        const merged = Object.assign({}, current, incoming, { online: true, started: true });
        entries.set(incoming.studentId, merged);
        const old = tiles.get(incoming.studentId);
        const tile = tileFor(merged);
        tile.classList.add('flash');
        setTimeout(() => tile.classList.remove('flash'), 1200);
        if (old && old.parentNode) old.replaceWith(tile); else grid.appendChild(tile);
        tiles.set(incoming.studentId, tile);
        paintStats();
      });
      // Rafraîchit les « il y a x min » sans requête serveur.
      ctx.interval(() => {
        tiles.forEach((tile, id) => {
          const e = entries.get(id);
          const p = tile.querySelector('.presence');
          if (p && e && e.at) p.lastChild.textContent = f.ago(e.at);
        });
      }, 15000);

      paintAll();
      const out = h('div.content-wide.stack');
      out.appendChild(h('div.row.wrap', null,
        h('span.badge.danger', null, h('span.pulse-dot'), t('live.badge')),
        ...arr(data.classes).map((c) => h('span.chip.static', { style: { minHeight: '1.625rem', fontSize: '0.75rem' } }, c.label))));
      out.appendChild(statsBox);
      out.appendChild(entries.size ? grid : emptyState({ icon: 'users', title: t('live.noStudents'), text: t('live.noStudentsText') }));
      return out;
    },
  });
}

export { serverNow, toastError };

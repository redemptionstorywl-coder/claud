/**
 * Professeur — mes élèves (carnet de notes par classe) et fiche d'un élève (historique, moyenne).
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr, obj } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { store, local } from '../../core/store.js';
import { skeletonList, skeletonDetail, emptyState } from '../../core/ui.js';
import { avatar, progressBar, stat, section, gradeChip, badge, chipSelect, sparkline } from '../../components/widgets.js';
import { themeBars } from '../student/progress.js';
import { targetableClasses } from './editor.js';

export function register() {
  route('teacher.students', {
    title: () => t('teacher.myStudents'),
    tab: 'students',
    large: true,
    skeleton: () => skeletonList(5),
    async load(ctx) {
      const classes = targetableClasses();
      // Classe affichée : choix explicite > dernière classe consultée (si toujours enseignée) > première classe.
      const remembered = local.get('students.classId');
      const known = (id) => classes.some((c) => c.id === id);
      const classId = ctx.get('classId') || ctx.params.classId || (known(remembered) ? remembered : classes[0] && classes[0].id);
      ctx.set('classId', classId);
      if (classId) local.set('students.classId', classId);
      if (!classId) return { none: true };
      return rpc('students:list', { classId });
    },
    render(ctx, data) {
      const classes = targetableClasses();
      const out = h('div.content-wide.stack');
      if (!classes.length || data.none) {
        out.appendChild(emptyState({ icon: 'users', title: t('teacher.noClasses'), text: t('teacher.noClassesText'),
          action: h('button.btn.secondary', { onClick: () => nav.push('common.settings') }, t('nav.settings')) }));
        return out;
      }
      out.appendChild(h('div.chips.scroll', null, ...classes.map((c) => h(`button.chip${c.id === ctx.get('classId') ? '.on' : ''}`, {
        onClick: () => { ctx.set('classId', c.id); ctx.refresh(); },
      }, c.label))));

      const students = arr(data.students);
      const s = obj(data.summary);
      out.appendChild(h('div.grid-3', null,
        stat({ value: String(s.count || 0), label: t('teacher.stats.students'), icon: 'users' }),
        stat({ value: s.average !== undefined && s.average !== null ? f.num(s.average) : '—', suffix: `/ ${data.scale || 20}`, label: t('teacher.stats.classAverage'), icon: 'trophy', tone: 'gold' }),
        stat({ value: `${s.progress || 0}%`, label: t('teacher.stats.classProgress'), icon: 'chart' })));

      if (!students.length) {
        out.appendChild(emptyState({ icon: 'users', title: t('teacher.noStudentsInClass'), text: t('teacher.noStudentsInClassText') }));
        return out;
      }

      const search = h('input.input', { type: 'search', placeholder: t('teacher.searchStudent') });
      const listBox = h('div');
      const paint = () => {
        const q = search.value.trim().toLowerCase();
        const shown = students.filter((st) => !q || st.name.toLowerCase().includes(q) || String(st.studentNumber || '').toLowerCase().includes(q));
        listBox.replaceChildren(
          h('div.card.list.hide-wide', null, ...shown.map((st) => h('button.student-row', { onClick: () => nav.push('teacher.student', { id: st.studentId }) },
            h('span', { class: st.online ? 'dot-online' : 'dot-offline' }),
            avatar(st.name, 'sm'),
            h('div.grow', null,
              h('div', { style: { fontWeight: '600' } }, st.name),
              h('div.row', { style: { gap: '0.5rem', marginTop: '0.25rem' } }, h('div.mini-progress', null, progressBar(st.progress, '', 'thin')), h('span.muted', { style: { fontSize: '0.6875rem', fontWeight: '700' } }, `${st.progress}%`))),
            h('span.avg', null, st.average !== undefined && st.average !== null ? f.num(st.average) : '—')))),
          h('div.card.show-wide', { style: { overflow: 'hidden' } }, h('table.table', null,
            h('thead', null, h('tr', null,
              h('th', null, t('grades.student')), h('th', null, t('grades.studentNumber')), h('th', null, t('grades.progress')),
              h('th', null, t('grades.lastGrade')), h('th.num', null, t('grades.average')), h('th.num', null, t('grades.lastSeen')))),
            h('tbody', null, ...shown.map((st) => h('tr.clickable', { onClick: () => nav.push('teacher.student', { id: st.studentId }) },
              h('td', null, h('div.row', null, h('span', { class: st.online ? 'dot-online' : 'dot-offline' }), h('b', null, st.name))),
              h('td.tnum', null, st.studentNumber || '—'),
              h('td', null, h('div.row', null, h('div', { style: { width: '6rem' } }, progressBar(st.progress, '', 'thin')), h('span.tnum.muted', null, `${st.progress}%`))),
              h('td', null, st.lastGrade ? gradeChip(st.lastGrade.grade, st.lastGrade.gradeMax) : '—'),
              h('td.num', null, h('b.serif', null, st.average !== undefined && st.average !== null ? `${f.num(st.average)} / ${data.scale || 20}` : '—')),
              h('td.num.muted', null, st.online ? t('teacher.onlineNow') : f.ago(st.lastSeenAt))))))));
      };
      search.addEventListener('input', paint);
      paint();
      out.append(search, listBox);
      return out;
    },
  });

  route('teacher.student', {
    title: (ctx, d) => (d ? d.student.name : t('teacher.student')),
    subtitle: (ctx, d) => (d ? d.student.classLabel : ''),
    skeleton: skeletonDetail,
    refreshOnShow: true,
    load: (ctx) => rpc('student:detail', { studentId: ctx.params.id }),
    render(ctx, d) {
      const st = d.student;
      const history = arr(d.history);
      const released = history.filter((x) => x.status === 'released').slice().reverse();
      const out = h('div.content-wide.stack.stagger');
      out.appendChild(h('div.card.pad-lg.row', null,
        avatar(st.name, 'lg'),
        h('div.grow', null,
          h('div', { style: { fontFamily: 'var(--ec-serif)', fontWeight: '700', fontSize: '1.25rem' } }, st.name),
          h('div.meta', null,
            h('span', null, icon('graduation', 13), st.classLabel || '—'),
            st.studentNumber ? h('span', null, icon('shield', 13), st.studentNumber) : null,
            h('span', null, h('span', { class: st.online ? 'dot-online' : 'dot-offline' }), st.online ? t('teacher.onlineNow') : f.ago(st.lastSeenAt)))),
        h('div', { style: { textAlign: 'right' } },
          h('div.overline', null, t('grades.average')),
          h('div', { style: { fontFamily: 'var(--ec-serif)', fontWeight: '700', fontSize: '1.75rem' } }, d.average !== undefined && d.average !== null ? f.num(d.average) : '—', h('small.muted', { style: { fontSize: '0.875rem' } }, ` / ${d.scale || 20}`)))));

      const grid = h('div.grid-2-wide');
      grid.appendChild(section(t('teacher.history'), h('span.muted', { style: { fontSize: '0.75rem', fontWeight: '700' } }, tn('results.counted', d.counted || 0)),
        history.length
          ? h('div.card.list', null, ...history.map((r) => h(r.mine ? 'button.grade-row' : 'div.grade-row', { onClick: r.mine ? () => nav.push('teacher.attempt', { id: r.attemptId }) : undefined },
            h('div.grow', null,
              h('div', { style: { fontWeight: '600' } }, r.title, r.attemptNo > 1 ? h('span.muted', null, ` · ${t('results.attempt', { n: r.attemptNo })}`) : null),
              h('div.muted', { style: { fontSize: '0.75rem' } }, [f.date(r.submittedAt), r.durationSec ? f.duration(r.durationSec) : null, r.coefficient && r.coefficient !== 1 ? t('assessments.coef', { n: f.num(r.coefficient) }) : null].filter(Boolean).join(' · '))),
            r.status === 'released' || r.status === 'graded' ? gradeChip(r.grade, r.gradeMax) : badge(t(`grades.status.${r.status}`), r.status === 'submitted' ? 'danger' : 'gold'))))
          : h('div.card', null, emptyState({ icon: 'trophy', title: t('teacher.noGrades'), compact: true }))));
      const right = h('div.stack');
      if (released.length > 1) {
        right.appendChild(section(t('progress.evolution'), null, h('div.card.pad', null, sparkline(released.map((r) => (r.grade / r.gradeMax) * (d.scale || 20)), d.scale || 20))));
      }
      right.appendChild(section(t('progress.byTheme'), null, h('div.card.pad-lg', null, themeBars(d.themes))));
      right.appendChild(section(t('teacher.courseProgress'), null, arr(d.courses).length
        ? h('div.card.list', null, ...arr(d.courses).map((c) => h('div.list-row', null,
          h('div.main', null, h('div.t', null, c.title), h('div', { style: { marginTop: '0.35rem' } }, progressBar(c.percent, c.percent >= 100 ? 'success' : '', 'thin'))),
          h('span.tnum', { style: { fontWeight: '700', fontSize: '0.8125rem' } }, `${c.percent}%`))))
        : h('div.card', null, emptyState({ icon: 'book', title: t('courses.empty'), compact: true }))));
      grid.appendChild(right);
      out.appendChild(grid);
      return out;
    },
  });
}

export { store, chipSelect };

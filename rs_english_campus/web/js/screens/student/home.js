/**
 * Élève — tableau de bord « Bonjour Lucas ».
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { store, setUnread } from '../../core/store.js';
import { skeletonDetail, emptyState } from '../../core/ui.js';
import {
  progressRing, section, linkButton, courseCard, assessmentCard, gradeChip, stat, notice,
} from '../../components/widgets.js';
import { notificationRow } from '../common/notifications.js';

function shortcut(ic, label, onClick, count) {
  return h('button.shortcut', { type: 'button', onClick },
    h('span.emblem', null, icon(ic, 20), count ? h('span.count', null, count > 9 ? '9+' : String(count)) : null),
    label);
}

function todoCard(a) {
  const running = a.state === 'in_progress';
  return h('button.card.clickable.todo-card', { onClick: () => nav.push('student.assessment', { id: a.id }) },
    h(`div.emblem${running ? '.gold' : '.danger'}`, null, icon(running ? 'timer' : 'clipboard', 21)),
    h('div.grow', null,
      h('div.overline', null, running ? t('assessments.state.in_progress') : t('home.assessmentOpen')),
      h('div', { style: { fontWeight: '700', marginTop: '0.1rem' } }, a.title),
      h('div.meta', null,
        h('span', null, tn('assessments.questions', a.questionCount)),
        h('span', null, f.minutes(a.duration)))),
    a.closesAt ? h('span.timer-badge', null, icon('clock', 14), f.until(a.closesAt)) : icon('chevronRight', 18, 'chev'));
}

export function register() {
  route('student.home', {
    title: () => store.boot.appName || 'English Campus',
    brand: true,
    tab: 'home',
    skeleton: skeletonDetail,
    refreshOnShow: true,
    async load(ctx) {
      if (!ctx.get('fresh') && store.dashboard) {
        ctx.set('fresh', true);
        return store.dashboard;
      }
      const data = await rpc('dashboard:get');
      setUnread(data.unread || 0);
      store.dashboard = data.dashboard;
      return data.dashboard;
    },
    render(ctx, d) {
      const p = store.profile;
      const c = d.counts || {};
      const out = h('div.content-narrow.stagger');

      out.appendChild(h('div.hero.notebook', null,
        h('div.stamp'),
        h('div.hero-row', null,
          h('div.grow', null,
            h('div.date', null, f.today()),
            h('h1', null, `${f.greeting()} `, h('em', null, p.firstName || p.displayName)),
            h('div.hero-meta', null,
              h('span.hero-chip', null, icon('graduation', 14), p.className || t('profile.noClass')),
              d.teacher ? h('span.hero-chip', null, icon('pen', 14), d.teacher) : null)),
          progressRing(d.overall || 0, { size: 86, stroke: 6, label: t('home.progress') }))));

      out.appendChild(h('div.shortcuts', null,
        shortcut('book', t('home.sc.courses'), () => nav.tab('courses')),
        shortcut('pen', t('home.sc.exercises'), () => nav.tab('courses', { filter: 'started' }), c.exercisesTodo),
        shortcut('chart', t('home.sc.progress'), () => nav.tab('progress')),
        shortcut('trophy', t('home.sc.results'), () => nav.push('student.results')),
        shortcut('bell', t('home.sc.notifications'), () => nav.push('common.notifications'), store.unread)));

      if (!p.classId) {
        out.appendChild(notice(t('home.noClass'), 'warn'));
        return out;
      }

      out.appendChild(h('div.grid-2', null,
        stat({ value: `${c.completed || 0}`, suffix: `/ ${c.available || 0}`, label: t('home.stats.completed'), icon: 'checkCircle', tone: 'correct', onClick: () => nav.tab('courses', { filter: 'completed' }) }),
        stat({ value: `${c.started || 0}`, label: t('home.stats.started'), icon: 'book', onClick: () => nav.tab('courses', { filter: 'started' }) }),
        stat({ value: `${c.exercisesTodo || 0}`, label: t('home.stats.exercises'), icon: 'pen', tone: 'gold', onClick: () => nav.tab('courses', { filter: 'started' }) }),
        stat({ value: `${c.assessmentsTodo || 0}`, label: t('home.stats.assessments'), icon: 'clipboard', tone: 'wrong', onClick: () => nav.tab('assessments') })));

      const todo = arr(d.assessments);
      if (todo.length) {
        out.appendChild(section(t('home.todo'), linkButton(t('common.seeAll'), () => nav.tab('assessments')),
          h('div.stack.tight', null, ...todo.map(todoCard))));
      }

      const cont = arr(d.continue);
      if (cont.length) {
        out.appendChild(section(t('home.continue'), linkButton(t('common.seeAll'), () => nav.tab('courses', { filter: 'started' })),
          h('div.stack.tight', null, ...cont.map((course) => courseCard(course, () => nav.push('student.course', { id: course.id }))))));
      }

      const fresh = arr(d.new);
      if (fresh.length) {
        out.appendChild(section(t('home.newCourses'), linkButton(t('common.seeAll'), () => nav.tab('courses', { filter: 'new' })),
          h('div.stack.tight', null, ...fresh.map((course) => courseCard(course, () => nav.push('student.course', { id: course.id }))))));
      }

      if (!todo.length && !cont.length && !fresh.length) {
        out.appendChild(h('div.card', null, emptyState({ icon: 'sparkle', title: t('home.allDone'), text: t('home.allDoneText'), compact: true })));
      }

      const upcoming = arr(d.upcoming);
      if (upcoming.length) {
        out.appendChild(section(t('home.upcoming'), null,
          h('div.stack.tight', null, ...upcoming.map((a) => assessmentCard(a, () => nav.push('student.assessment', { id: a.id }))))));
      }

      const grades = arr(d.grades);
      if (grades.length) {
        out.appendChild(section(t('home.lastGrades'), linkButton(t('common.seeAll'), () => nav.push('student.results')),
          h('div.card.list', null, ...grades.map((g) => h('button.grade-row', { onClick: () => nav.push('student.result', { id: g.id }) },
            h('div.emblem.sm.gold', null, icon('trophy', 17)),
            h('div.grow', null, h('div', { style: { fontWeight: '600' } }, g.title), h('div.muted', { style: { fontSize: '0.75rem' } }, f.ago(g.at))),
            gradeChip(g.grade, g.gradeMax))))));
      }

      const notes = arr(d.notifications);
      if (notes.length) {
        out.appendChild(section(t('home.teacherNews'), linkButton(t('common.seeAll'), () => nav.push('common.notifications')),
          h('div.card.list', null, ...notes.map((n) => notificationRow(n)))));
      }
      return out;
    },
  });
}

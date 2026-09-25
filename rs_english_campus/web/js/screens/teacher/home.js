/**
 * Professeur — tableau de bord « Bonjour Mr. Anderson ».
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr, obj } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { store, setUnread, isAdmin } from '../../core/store.js';
import { skeletonDetail, emptyState } from '../../core/ui.js';
import { stat, section, linkButton, gradeChip, badge, avatar, notice } from '../../components/widgets.js';
import { notificationRow } from '../common/notifications.js';

function quick(ic, label, onClick, primary) {
  return h(`button.quick-action${primary ? '.primary' : ''}`, { onClick }, h('span.emblem', null, icon(ic, 18)), h('span', null, label));
}

export function register() {
  route('teacher.home', {
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
      const courses = obj(d.courses);
      const assessments = obj(d.assessments);
      const out = h('div.content-wide.stack.stagger');

      out.appendChild(h('div.hero.notebook', null,
        h('div.stamp'),
        h('div.date', null, f.today()),
        h('h1', null, `${f.greeting()} `, h('em', null, p.teacherName || p.displayName)),
        h('div.hero-meta', null,
          h('span.hero-chip', null, icon('shield', 14), t(`roles.${p.role}`)),
          h('span.hero-chip', null, icon('users', 14), p.allClasses ? t('teacher.allClasses') : tn('teacher.classCount', arr(p.teachingClasses).length)))));

      out.appendChild(h('div.quick-actions', null,
        quick('plus', t('teacher.quick.newCourse'), () => nav.push('teacher.courseEditor', {}), true),
        quick('clipboard', t('teacher.quick.newAssessment'), () => nav.push('teacher.assessmentEditor', {})),
        quick('live', t('teacher.quick.live'), () => nav.push('teacher.live', {})),
        quick('megaphone', t('teacher.quick.notify'), () => nav.push('teacher.notify', {}))));

      out.appendChild(h('div.grid-2.grid-3-wide', null,
        stat({ value: String(courses.published || 0), label: t('teacher.stats.published'), icon: 'book', onClick: () => nav.tab('courses') }),
        stat({ value: String(courses.draft || 0), label: t('teacher.stats.drafts'), icon: 'pen', onClick: () => nav.tab('courses') }),
        stat({ value: String(assessments.open || 0), label: t('teacher.stats.open'), icon: 'clipboard', tone: 'wrong', onClick: () => nav.tab('assessments') }),
        stat({ value: String(assessments.scheduled || 0), label: t('teacher.stats.scheduled'), icon: 'calendar', onClick: () => nav.tab('assessments') }),
        stat({ value: String(assessments.toReview || 0), label: t('teacher.stats.toReview'), icon: 'pen', tone: 'gold', onClick: () => nav.tab('assessments') }),
        stat({ value: String(assessments.toRelease || 0), label: t('teacher.stats.toRelease'), icon: 'send', tone: 'correct', onClick: () => nav.tab('assessments') })));

      if (assessments.toReview > 0) out.appendChild(notice(tn('teacher.toReviewNotice', assessments.toReview), 'warn', 'pen'));

      const grid = h('div.grid-2-wide');
      const classes = arr(d.classes);
      grid.appendChild(section(t('teacher.myClasses'), linkButton(t('common.seeAll'), () => nav.tab('students')),
        classes.length
          ? h('div.card.list', null, ...classes.map((c) => h('button.list-row', { onClick: () => nav.tab('students', { classId: c.id }) },
            h('div.emblem.sm', null, icon('graduation', 17)),
            h('div.main', null, h('div.t', null, c.label), h('div.s', null, `${tn('teacher.students', c.students)} · ${t('teacher.activeWeek', { n: c.active })}`)),
            icon('chevronRight', 18, 'chev'))))
          : h('div.card', null, emptyState({ icon: 'users', title: t('teacher.noClasses'), text: t('teacher.noClassesText'), compact: true, action: h('button.btn.secondary', { onClick: () => nav.push('common.settings') }, t('nav.settings')) }))));

      const subs = arr(d.submissions);
      grid.appendChild(section(t('teacher.recentSubmissions'), null,
        subs.length
          ? h('div.card.list', null, ...subs.map((s) => h('button.list-row', { onClick: () => nav.push('teacher.attempt', { id: s.attemptId }) },
            avatar(s.name, 'sm'),
            h('div.main', null, h('div.t', null, s.name), h('div.s', null, `${s.title} · ${f.ago(s.at)}`)),
            s.status === 'submitted' ? badge(t('teacher.toGrade'), 'gold') : gradeChip(s.grade, s.gradeMax))))
          : h('div.card', null, emptyState({ icon: 'inbox', title: t('teacher.noSubmissions'), compact: true }))));
      out.appendChild(grid);

      const notes = arr(d.notifications);
      if (notes.length) {
        out.appendChild(section(t('nav.notifications'), linkButton(t('common.seeAll'), () => nav.push('common.notifications')),
          h('div.card.list', null, ...notes.map((n) => notificationRow(n)))));
      }
      if (isAdmin()) {
        out.appendChild(h('button.card.pad.clickable.row', { onClick: () => nav.push('admin.home') },
          h('div.emblem.solid', null, icon('shield', 20)),
          h('div.grow', null, h('div', { style: { fontWeight: '700' } }, t('nav.admin')), h('div.muted', { style: { fontSize: '0.8125rem' } }, t('admin.subtitle'))),
          icon('chevronRight', 18, 'chev')));
      }
      return out;
    },
  });
}

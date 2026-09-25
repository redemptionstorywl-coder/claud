/**
 * Professeur — mes cours (liste, actions rapides : aperçu, publier, dupliquer, suivi en direct...).
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { isAdmin } from '../../core/store.js';
import { skeletonList, emptyState, actionSheet, confirmDialog, toast, toastError, busy } from '../../core/ui.js';
import { emblem, badge, segmented, themeLabel } from '../../components/widgets.js';

export function statusBadge(status) {
  if (status === 'published') return badge(t('status.published'), 'success');
  if (status === 'archived') return badge(t('status.archived'), '');
  return badge(t('status.draft'), 'gold');
}

/** Menu d'actions d'un cours ; retourne true si la liste doit être rechargée. */
export async function courseActions(course, ctx) {
  const choice = await actionSheet({
    title: course.title,
    options: [
      { value: 'edit', label: t('teacher.courseActions.edit'), icon: 'pen' },
      { value: 'preview', label: t('teacher.courseActions.preview'), icon: 'eye' },
      course.status === 'published'
        ? { value: 'unpublish', label: t('teacher.courseActions.unpublish'), icon: 'eyeOff' }
        : { value: 'publish', label: t('teacher.courseActions.publish'), icon: 'send', tone: 'success' },
      course.status === 'published' ? { value: 'live', label: t('teacher.courseActions.live'), icon: 'live' } : null,
      { value: 'duplicate', label: t('teacher.courseActions.duplicate'), icon: 'copy' },
      course.status !== 'archived' ? { value: 'archive', label: t('teacher.courseActions.archive'), icon: 'inbox' } : null,
      { value: 'delete', label: t('teacher.courseActions.delete'), icon: 'trash', danger: true },
    ],
  });
  if (!choice) return false;
  try {
    if (choice === 'edit') nav.push('teacher.courseEditor', { id: course.id });
    else if (choice === 'preview') nav.push('student.course', { id: course.id, preview: true });
    else if (choice === 'live') nav.push('teacher.live', { type: 'course', id: course.id });
    else if (choice === 'publish' || choice === 'unpublish' || choice === 'archive') {
      const status = choice === 'publish' ? 'published' : choice === 'archive' ? 'archived' : 'draft';
      if (choice === 'publish' && !(await confirmDialog({ title: t('teacher.publishTitle'), message: t('teacher.publishText'), confirm: t('teacher.courseActions.publish'), icon: 'send' }))) return false;
      await busy(() => rpc('tcourse:status', { id: course.id, status }));
      toast(t(`teacher.status.${status}`), { tone: 'success' });
      return true;
    } else if (choice === 'duplicate') {
      const res = await busy(() => rpc('tcourse:duplicate', { id: course.id }));
      toast(t('teacher.duplicated'), { tone: 'success' });
      nav.push('teacher.courseEditor', { id: res.id });
      return true;
    } else if (choice === 'delete') {
      if (!(await confirmDialog({ title: t('teacher.deleteTitle'), message: t('teacher.deleteText', { title: course.title }), confirm: t('common.delete'), danger: true, icon: 'trash' }))) return false;
      await busy(() => rpc('tcourse:delete', { id: course.id }));
      toast(t('teacher.deleted'), { tone: 'success' });
      return true;
    }
  } catch (err) {
    toastError(err);
  }
  return false;
}

export function register() {
  route('teacher.courses', {
    title: () => t('teacher.courses'),
    tab: 'courses',
    large: true,
    skeleton: () => skeletonList(4),
    load: (ctx) => rpc('tcourses:list', { scope: ctx.get('scope') || 'mine', archived: ctx.get('filter') === 'archived' }),
    actions: () => [h('button.icon-btn', { 'aria-label': t('teacher.quick.newCourse'), onClick: () => nav.push('teacher.courseEditor', {}) }, icon('plus', 22))],
    render(ctx, list) {
      const courses = arr(list);
      const filter = ctx.get('filter') || 'all';
      const out = h('div.content-wide.stack');
      const listEl = h('div.grid-auto.stagger');
      const paint = (value) => {
        const changedArchive = (value === 'archived') !== (filter === 'archived');
        ctx.set('filter', value);
        if (changedArchive) { ctx.refresh(); return; }
        listEl.replaceChildren();
        const shown = courses.filter((c) => value === 'all' || value === 'archived' ? (value !== 'archived' || c.status === 'archived') : c.status === value);
        if (!shown.length) {
          listEl.appendChild(emptyState({
            icon: 'book',
            title: courses.length ? t('courses.emptyFilter') : t('teacher.noCourses'),
            text: courses.length ? '' : t('teacher.noCoursesText'),
            action: courses.length ? null : h('button.btn.primary', { onClick: () => nav.push('teacher.courseEditor', {}) }, icon('plus', 18), t('teacher.quick.newCourse')),
          }));
          return;
        }
        shown.forEach((c) => listEl.appendChild(h('div.card.pad.clickable.course-card', { onClick: () => nav.push('teacher.courseEditor', { id: c.id }) },
          h('div.row.top', null,
            emblem(c.emblem, { tone: c.status === 'published' ? '' : 'neutral' }),
            h('div.grow', null,
              h('div.row.between', null, h('span.overline', null, themeLabel(c.theme)), statusBadge(c.status)),
              h('div.course-title.serif', null, c.title),
              h('div.meta', null,
                h('span', null, icon('layers', 13), tn('courses.parts', c.sections)),
                h('span', null, icon('users', 13), tn('teacher.startedBy', c.started || 0)),
                h('span', null, icon('checkCircle', 13), tn('teacher.completedBy', c.completed || 0)),
                !c.mine ? h('span', null, icon('pen', 13), c.teacher) : null),
              h('div.chips', { style: { marginTop: '0.5rem' } }, ...arr(c.classes).map((label) => h('span.chip.static', { style: { minHeight: '1.5rem', fontSize: '0.6875rem' } }, label)))),
            h('button.icon-btn', {
              'aria-label': t('common.more'),
              onClick: async (e) => {
                e.stopPropagation();
                if (await courseActions(c, ctx)) ctx.refresh({ silent: true });
              },
            }, icon('more', 20))))));
      };
      out.appendChild(segmented([
        { value: 'all', label: t('courses.filter.all') },
        { value: 'published', label: t('status.publishedPlural') },
        { value: 'draft', label: t('status.draftPlural') },
        { value: 'archived', label: t('status.archivedPlural') },
      ], filter, paint));
      if (isAdmin()) {
        out.appendChild(segmented([
          { value: 'mine', label: t('teacher.scope.mine') },
          { value: 'all', label: t('teacher.scope.all') },
        ], ctx.get('scope') || 'mine', (value) => { ctx.set('scope', value); ctx.refresh(); }));
      }
      out.appendChild(listEl);
      paint(filter);
      return out;
    },
  });
}

export { f };

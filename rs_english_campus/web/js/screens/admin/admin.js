/**
 * Administration — statistiques, classes, membres & rôles, journal d'activité.
 * Toutes ces actions sont revérifiées côté serveur (rôle admin obligatoire).
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr, obj } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { store } from '../../core/store.js';
import { skeletonDetail, skeletonList, emptyState, toast, toastError, busy, sheet, confirmDialog } from '../../core/ui.js';
import {
  stat, section, field, textInput, select, chipSelect, toggleRow, badge, avatar, linkButton, notice, segmented,
} from '../../components/widgets.js';

const ACTION_LABELS = {
  'course.create': 'admin.log.courseCreate',
  'course.save': 'admin.log.courseSave',
  'course.status': 'admin.log.courseStatus',
  'course.delete': 'admin.log.courseDelete',
  'assessment.create': 'admin.log.assessmentCreate',
  'assessment.save': 'admin.log.assessmentSave',
  'assessment.status': 'admin.log.assessmentStatus',
  'assessment.delete': 'admin.log.assessmentDelete',
  'assessment.start': 'admin.log.assessmentStart',
  'assessment.submit': 'admin.log.assessmentSubmit',
  'assessment.releaseAll': 'admin.log.releaseAll',
  'attempt.grade': 'admin.log.attemptGrade',
  'attempt.void': 'admin.log.attemptVoid',
  'notify.send': 'admin.log.notify',
  'teacher.classes': 'admin.log.teacherClasses',
  'admin.class.save': 'admin.log.classSave',
  'admin.class.delete': 'admin.log.classDelete',
  'admin.member.set': 'admin.log.memberSet',
  'admin.grant': 'admin.log.grant',
  'security.abuse': 'admin.log.abuse',
};

function logLabel(action) {
  const key = ACTION_LABELS[action];
  return key ? t(key) : action;
}

function menuRow(ic, title, subtitle, onClick) {
  return h('button.list-row', { onClick },
    h('div.emblem.sm', null, icon(ic, 18)),
    h('div.main', null, h('div.t', null, title), subtitle ? h('div.s', null, subtitle) : null),
    icon('chevronRight', 18, 'chev'));
}

export function register() {
  // ─── Vue d'ensemble ────────────────────────────────────────────────────────
  route('admin.home', {
    title: () => t('nav.admin'),
    subtitle: () => t('admin.subtitle'),
    tab: 'admin',
    skeleton: skeletonDetail,
    load: () => rpc('admin:overview'),
    render(ctx, d) {
      const m = obj(d.members);
      const c = obj(d.courses);
      const a = obj(d.assessments);
      const out = h('div.content-wide.stack.stagger');
      out.appendChild(h('div.grid-2.grid-3-wide', null,
        stat({ value: String(m.students || 0), label: t('admin.stats.students'), icon: 'graduation' }),
        stat({ value: String(m.teachers || 0), label: t('admin.stats.teachers'), icon: 'pen' }),
        stat({ value: String(m.activeWeek || 0), label: t('admin.stats.activeWeek'), icon: 'users', tone: 'correct' }),
        stat({ value: String(c.published || 0), suffix: tn('admin.stats.drafts', c.draft || 0), label: t('admin.stats.courses'), icon: 'book' }),
        stat({ value: String(a.attemptsWeek || 0), label: t('admin.stats.attemptsWeek'), icon: 'clipboard' }),
        stat({ value: String(a.toReview || 0), label: t('admin.stats.toReview'), icon: 'inbox', tone: 'gold' })));

      out.appendChild(h('div.card.list', null,
        menuRow('graduation', t('admin.classes'), t('admin.classesHint'), () => nav.push('admin.classes')),
        menuRow('users', t('admin.members'), t('admin.membersHint'), () => nav.push('admin.members')),
        menuRow('book', t('admin.allCourses'), t('admin.allCoursesHint'), () => nav.tab('courses')),
        menuRow('list', t('admin.logs'), t('admin.logsHint'), () => nav.push('admin.logs'))));

      const grid = h('div.grid-2-wide');
      grid.appendChild(section(t('admin.classAverages'), null, arr(d.classes).length
        ? h('div.card.list', null, ...arr(d.classes).map((cl) => h('div.list-row', null,
          h('div.main', null, h('div.t', null, cl.label), h('div.s', null, tn('teacher.students', cl.students))),
          h('b.serif', null, cl.average !== undefined && cl.average !== null ? `${f.num(cl.average)} / 20` : '—'))))
        : h('div.card', null, emptyState({ icon: 'graduation', title: t('admin.noClasses'), compact: true }))));
      grid.appendChild(section(t('admin.recent'), linkButton(t('common.seeAll'), () => nav.push('admin.logs')), arr(d.logs).length
        ? h('div.card.list', null, ...arr(d.logs).map((l) => h('div.list-row', null,
          h('div.main', null, h('div.t', null, logLabel(l.action)), h('div.s', null, `${l.who} · ${f.ago(l.at)}`)),
          l.action === 'security.abuse' ? badge(t('admin.alert'), 'danger') : null)))
        : h('div.card', null, emptyState({ icon: 'list', title: t('admin.noLogs'), compact: true }))));
      out.appendChild(grid);
      out.appendChild(h('div.muted', { style: { fontSize: '0.75rem', textAlign: 'center' } }, t('admin.integration', { campus: d.campusMode, framework: d.framework })));
      return out;
    },
  });

  // ─── Classes ───────────────────────────────────────────────────────────────
  route('admin.classes', {
    title: () => t('admin.classes'),
    skeleton: () => skeletonList(6),
    load: () => rpc('admin:classes'),
    actions: (ctx) => [h('button.icon-btn', { 'aria-label': t('admin.addClass'), onClick: () => editClass(ctx, null) }, icon('plus', 22))],
    render(ctx, list) {
      const classes = arr(list);
      if (!classes.length) return emptyState({ icon: 'graduation', title: t('admin.noClasses'), action: h('button.btn.primary', { onClick: () => editClass(ctx, null) }, icon('plus', 18), t('admin.addClass')) });
      const move = async (i, dir) => {
        const ids = classes.map((c) => c.id);
        const j = i + dir;
        if (j < 0 || j >= ids.length) return;
        [ids[i], ids[j]] = [ids[j], ids[i]];
        try {
          await rpc('admin:class:order', { ids });
          ctx.refresh({ silent: true });
        } catch (err) { toastError(err); }
      };
      return h('div.content-narrow.stack', null,
        notice(t('admin.classesNotice'), '', 'info'),
        h('div.card.list', null, ...classes.map((c, i) => h('div.list-row', null,
          h(`div.emblem.sm${c.active ? '' : '.neutral'}`, null, icon('graduation', 17)),
          h('div.main', { style: { cursor: 'pointer' }, onClick: () => editClass(ctx, c) },
            h('div.t', null, c.label, c.active ? null : h('span.muted', null, ` · ${t('admin.inactive')}`)),
            h('div.s', null, `${c.code}${c.level ? ` · ${c.level}` : ''} · ${tn('teacher.students', c.students || 0)}`)),
          h('div.block-actions', null,
            h('button.icon-btn', { disabled: i === 0, onClick: () => move(i, -1) }, icon('arrowUp', 17)),
            h('button.icon-btn', { disabled: i === classes.length - 1, onClick: () => move(i, 1) }, icon('arrowDown', 17)),
            h('button.icon-btn', { onClick: () => editClass(ctx, c) }, icon('pen', 17)))))));
    },
  });

  // ─── Membres & rôles ───────────────────────────────────────────────────────
  route('admin.members', {
    title: () => t('admin.members'),
    skeleton: () => skeletonList(6),
    async load(ctx) {
      const [members, classes] = await Promise.all([
        rpc('admin:members', { query: ctx.get('query') || undefined, role: ctx.get('role') || undefined }),
        rpc('admin:classes'),
      ]);
      ctx.set('classes', arr(classes));
      return arr(members);
    },
    render(ctx, members) {
      const out = h('div.content-wide.stack');
      const search = h('input.input', { type: 'search', placeholder: t('admin.searchMembers'), value: ctx.get('query') || '' });
      let timer = null;
      search.addEventListener('input', () => {
        clearTimeout(timer);
        timer = setTimeout(() => { ctx.set('query', search.value.trim()); ctx.refresh({ silent: true }); }, 350);
      });
      out.appendChild(search);
      out.appendChild(segmented([
        { value: '', label: t('admin.roleAll') },
        { value: 'student', label: t('roles.studentPlural') },
        { value: 'teacher', label: t('roles.teacherPlural') },
        { value: 'admin', label: t('roles.adminPlural') },
      ], ctx.get('role') || '', (v) => { ctx.set('role', v); ctx.refresh({ silent: true }); }));
      out.appendChild(h('button.btn.soft', { onClick: () => grantOnline(ctx) }, icon('sparkle', 18), t('admin.grantOnline')));
      if (!members.length) {
        out.appendChild(emptyState({ icon: 'users', title: t('admin.noMembers'), text: t('admin.noMembersText'), compact: true }));
        return out;
      }
      out.appendChild(h('div.card.list', null, ...members.map((m) => h('button.student-row', { onClick: () => editMember(ctx, m.campusId) },
        h('span', { class: m.online ? 'dot-online' : 'dot-offline' }),
        avatar(m.name, 'sm'),
        h('div.grow', null,
          h('div', { style: { fontWeight: '600' } }, m.title && m.role !== 'student' ? `${m.title} ${m.name}` : m.name),
          h('div.muted', { style: { fontSize: '0.75rem' } }, [m.campusId, m.classLabel, m.studentNumber].filter(Boolean).join(' · '))),
        badge(t(`roles.${m.role}`), m.role === 'admin' ? 'solid' : m.role === 'teacher' ? 'accent' : ''),
        m.roleOverride ? badge(t('admin.forced'), 'gold') : null))));
      return out;
    },
  });

  // ─── Journal ───────────────────────────────────────────────────────────────
  route('admin.logs', {
    title: () => t('admin.logs'),
    skeleton: () => skeletonList(8),
    load: (ctx) => rpc('admin:logs', {}),
    render(ctx, logs) {
      const items = arr(logs);
      const list = h('div.card.list');
      const add = (rows) => rows.forEach((l) => list.appendChild(h('div.list-row', null,
        h(`div.emblem.sm${l.action === 'security.abuse' ? '.danger' : '.neutral'}`, null, icon(l.action === 'security.abuse' ? 'alert' : 'list', 16)),
        h('div.main', null,
          h('div.t', null, logLabel(l.action), l.target ? h('span.muted', null, ` · #${l.target}`) : null),
          h('div.s', null, `${l.who !== '—' ? l.who : l.campusId || t('admin.system')} · ${f.dateTime(l.at)}`)))));
      add(items);
      if (!items.length) return emptyState({ icon: 'list', title: t('admin.noLogs') });
      let last = items[items.length - 1].id;
      const more = h('button.btn.ghost.block', {
        onClick: async () => {
          try {
            const next = arr(await rpc('admin:logs', { before: last }));
            add(next);
            if (next.length) last = next[next.length - 1].id;
            if (next.length < 50) more.remove();
          } catch (err) { toastError(err); }
        },
      }, t('admin.loadMore'));
      return h('div.content-narrow.stack', null, list, items.length >= 50 ? more : null);
    },
  });
}

function editClass(ctx, c) {
  const draft = c ? Object.assign({}, c) : { label: '', code: '', level: '', active: true };
  const api = sheet({
    title: c ? t('admin.editClass') : t('admin.addClass'),
    content: h('div.stack', null,
      field(t('admin.classLabel'), textInput({ value: draft.label, max: 64, placeholder: 'Terminale B', onInput: (v) => { draft.label = v; } })),
      h('div.form-grid', null,
        field(t('admin.classCode'), textInput({ value: draft.code, max: 32, placeholder: 'TB', onInput: (v) => { draft.code = v; } })),
        field(t('admin.classLevel'), textInput({ value: draft.level || '', max: 32, placeholder: 'Terminale', onInput: (v) => { draft.level = v; } }))),
      toggleRow(t('admin.classActive'), t('admin.classActiveHint'), draft.active !== false, (on) => { draft.active = on; })),
    actions: [
      c ? h('button.btn.danger-soft', {
        onClick: async () => {
          if (!(await confirmDialog({ title: t('admin.deleteClass'), message: t('admin.deleteClassText'), confirm: t('common.delete'), danger: true }))) return;
          try {
            await busy(() => rpc('admin:class:delete', { id: c.id }));
            api.close();
            ctx.refresh({ silent: true });
          } catch (err) { toastError(err); }
        },
      }, icon('trash', 18)) : null,
      h('button.btn.primary', {
        onClick: async () => {
          try {
            await busy(() => rpc('admin:class:save', { id: c ? c.id : undefined, label: draft.label.trim(), code: draft.code.trim(), level: (draft.level || '').trim() || undefined, active: draft.active !== false }));
            toast(t('settings.saved'), { tone: 'success' });
            api.close();
            ctx.refresh({ silent: true });
          } catch (err) { toastError(err); }
        },
      }, icon('check', 18), t('common.save')),
    ],
  });
}

async function editMember(ctx, campusId) {
  let m;
  try { m = await busy(() => rpc('admin:member:get', { campusId })); } catch (err) { toastError(err); return; }
  const classes = arr(ctx.get('classes'));
  const draft = { roleOverride: m.roleOverride || '', classOverride: m.classOverride || '', title: m.titleOverride || '', teaching: arr(m.teachingClassIds) };
  const teachingBox = h('div');
  const paintTeaching = () => {
    const role = draft.roleOverride || m.role;
    teachingBox.replaceChildren(role === 'teacher' || role === 'admin'
      ? field(t('admin.teachingClasses'), chipSelect(classes.map((c) => ({ value: c.id, label: c.label })), draft.teaching, (ids) => { draft.teaching = ids; }), { hint: t('admin.teachingHint') })
      : '');
  };
  paintTeaching();
  const api = sheet({
    title: m.name,
    content: h('div.stack', null,
      h('div.meta', null, h('span', null, icon('shield', 13), m.campusId), m.classLabel ? h('span', null, icon('graduation', 13), m.classLabel) : null, h('span', null, t('admin.currentRole', { role: t(`roles.${m.role}`) }))),
      field(t('admin.roleOverride'), select([
        { value: '', label: t('admin.roleFromCampus') },
        { value: 'student', label: t('roles.student') },
        { value: 'teacher', label: t('roles.teacher') },
        { value: 'admin', label: t('roles.admin') },
      ], draft.roleOverride, (v) => { draft.roleOverride = v; paintTeaching(); }), { hint: t('admin.roleOverrideHint') }),
      field(t('admin.classOverride'), select([{ value: '', label: t('admin.classFromCampus') }].concat(classes.map((c) => ({ value: c.id, label: c.label }))), draft.classOverride, (v) => { draft.classOverride = v; })),
      field(t('settings.titleLabel'), textInput({ value: draft.title, max: 24, placeholder: 'Mr., Mrs., Dr.', onInput: (v) => { draft.title = v; } })),
      teachingBox),
    actions: [h('button.btn.primary', {
      onClick: async () => {
        try {
          const role = draft.roleOverride || m.role;
          await busy(() => rpc('admin:member:set', {
            campusId,
            roleOverride: draft.roleOverride || '',
            classOverride: draft.classOverride ? Number(draft.classOverride) : undefined,
            title: draft.title.trim() || undefined,
            teachingClassIds: role === 'teacher' || role === 'admin' ? draft.teaching : undefined,
          }));
          toast(t('settings.saved'), { tone: 'success' });
          api.close();
          ctx.refresh({ silent: true });
        } catch (err) { toastError(err); }
      },
    }, icon('check', 18), t('common.save'))],
  });
}

function grantOnline(ctx) {
  const draft = { serverId: '', role: 'teacher' };
  const api = sheet({
    title: t('admin.grantOnline'),
    content: h('div.stack', null,
      notice(t('admin.grantOnlineHint'), '', 'info'),
      field(t('admin.serverId'), textInput({ type: 'number', placeholder: '12', onInput: (v) => { draft.serverId = v; } })),
      field(t('admin.role'), segmented([
        { value: 'student', label: t('roles.student') },
        { value: 'teacher', label: t('roles.teacher') },
        { value: 'admin', label: t('roles.admin') },
      ], draft.role, (v) => { draft.role = v; }))),
    actions: [h('button.btn.primary', {
      onClick: async () => {
        try {
          const res = await busy(() => rpc('admin:grant:online', { serverId: Number(draft.serverId), role: draft.role }));
          toast(t('admin.granted', { name: res.name, role: t(`roles.${res.role}`) }), { tone: 'success' });
          api.close();
          ctx.refresh({ silent: true });
        } catch (err) { toastError(err); }
      },
    }, icon('check', 18), t('admin.grant'))],
  });
}

export { store };

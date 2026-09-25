/**
 * Professeur — menu « Plus » (téléphone) et envoi de notifications aux classes.
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t, tn } from '../../core/i18n.js';
import { rpc, arr } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { store, isAdmin } from '../../core/store.js';
import { skeletonList, emptyState, toast, toastError, busy } from '../../core/ui.js';
import { field, textInput, textArea, chipSelect, select, section, notice, avatar } from '../../components/widgets.js';
import { targetableClasses } from './editor.js';

function menuRow(ic, title, subtitle, onClick, tone) {
  return h('button.list-row', { onClick },
    h(`div.emblem.sm${tone ? `.${tone}` : ''}`, null, icon(ic, 18)),
    h('div.main', null, h('div.t', null, title), subtitle ? h('div.s', null, subtitle) : null),
    icon('chevronRight', 18, 'chev'));
}

export function register() {
  route('teacher.more', {
    title: () => t('nav.more'),
    tab: 'more',
    large: true,
    render() {
      const p = store.profile;
      return h('div.content-narrow.stack.stagger', null,
        h('div.card.pad.row', null, avatar(p.displayName, 'lg'), h('div.grow', null,
          h('div', { style: { fontWeight: '700', fontSize: '1.0625rem' } }, p.teacherName || p.displayName),
          h('div.muted', { style: { fontSize: '0.8125rem' } }, t(`roles.${p.role}`)))),
        h('div.card.list', null,
          menuRow('live', t('nav.live'), t('more.liveHint'), () => nav.push('teacher.live', {}), 'danger'),
          menuRow('megaphone', t('nav.messages'), t('more.messagesHint'), () => nav.push('teacher.notify', {})),
          menuRow('bell', t('nav.notifications'), t('more.notificationsHint'), () => nav.push('common.notifications'))),
        h('div.card.list', null,
          menuRow('sliders', t('nav.settings'), t('more.settingsHint'), () => nav.push('common.settings')),
          isAdmin() ? menuRow('shield', t('nav.admin'), t('admin.subtitle'), () => nav.push('admin.home'), 'solid') : null));
    },
  });

  route('teacher.notify', {
    title: () => t('notify.title'),
    tab: 'messages',
    skeleton: () => skeletonList(3),
    async load() {
      const [sent, courses, assessments] = await Promise.all([
        rpc('notifications:sent'),
        rpc('tcourses:list', {}).catch(() => []),
        rpc('tassessments:list', {}).catch(() => []),
      ]);
      return { sent: arr(sent), courses: arr(courses).filter((c) => c.status === 'published'), assessments: arr(assessments).filter((a) => a.status === 'published') };
    },
    render(ctx, data) {
      const L = (store.settings && store.settings.limits) || {};
      const classes = targetableClasses();
      const draft = ctx.get('draft') || { classIds: classes.length === 1 ? [classes[0].id] : [], title: '', body: '', link: '' };
      ctx.set('draft', draft);
      const out = h('div.content-narrow.stack');

      out.appendChild(h('div.card.form-card', null,
        h('div.overline', null, t('notify.compose')),
        field(t('notify.to'), classes.length ? chipSelect(classes.map((c) => ({ value: c.id, label: c.label })), draft.classIds, (ids) => { draft.classIds = ids; }) : notice(t('editor.noTargetClasses'), 'warn')),
        field(t('notify.fields.title'), textInput({ value: draft.title, max: L.notificationTitle || 80, placeholder: t('notify.placeholders.title'), onInput: (v) => { draft.title = v; } })),
        field(t('notify.fields.body'), textArea({ value: draft.body, max: L.notificationBody || 400, rows: 3, counter: true, placeholder: t('notify.placeholders.body'), onInput: (v) => { draft.body = v; } })),
        field(t('notify.fields.link'), select(
          [{ value: '', label: t('notify.noLink') }]
            .concat(data.courses.map((c) => ({ value: `course:${c.id}`, label: `${t('notify.course')} · ${c.title}` })))
            .concat(data.assessments.map((a) => ({ value: `assessment:${a.id}`, label: `${t('notify.assessment')} · ${a.title}` }))),
          draft.link, (v) => { draft.link = v; }), { hint: t('notify.linkHint') }),
        h('button.btn.primary.lg', {
          onClick: async () => {
            if (!draft.classIds.length) return toast(t('editor.errors.classes'), { tone: 'error' });
            if (draft.title.trim().length < 2) return toast(t('notify.errors.title'), { tone: 'error' });
            const payload = { classIds: draft.classIds, title: draft.title.trim(), body: draft.body.trim() };
            if (draft.link) {
              const [type, id] = draft.link.split(':');
              payload.linkType = type;
              payload.linkId = Number(id);
            }
            try {
              const res = await busy(() => rpc('notifications:send', payload), t('notify.sending'));
              toast(tn('notify.sentToast', res.sent), { tone: 'success' });
              ctx.set('draft', null);
              ctx.refresh({ silent: true });
            } catch (err) {
              toastError(err);
            }
          },
        }, icon('send', 18), t('notify.send'))));

      out.appendChild(section(t('notify.history'), null, data.sent.length
        ? h('div.card.list', null, ...data.sent.map((n) => h('div.notif', null,
          h('div.emblem.sm.neutral', null, icon('megaphone', 17)),
          h('div.body', null,
            h('b', null, n.title),
            n.body ? h('p', null, n.body) : null,
            h('div.meta', { style: { marginTop: '0.3rem' } },
              h('span', null, icon('graduation', 13), n.classLabel || '—'),
              h('span', null, icon('eye', 13), tn('notify.reads', n.reads)))),
          h('span.when', null, f.ago(n.createdAt)))))
        : h('div.card', null, emptyState({ icon: 'megaphone', title: t('notify.noHistory'), compact: true }))));
      return out;
    },
  });
}

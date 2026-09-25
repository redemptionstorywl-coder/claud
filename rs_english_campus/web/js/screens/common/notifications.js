/**
 * Centre de notifications (élèves et professeurs).
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t } from '../../core/i18n.js';
import { rpc, arr } from '../../core/nui.js';
import * as f from '../../core/format.js';
import { setUnread, store } from '../../core/store.js';
import { skeletonList, emptyState, toastError } from '../../core/ui.js';
import { openLink } from '../index.js';

const KIND_ICON = { course: 'book', assessment: 'clipboard', result: 'trophy', message: 'megaphone', submission: 'pen', system: 'info' };
const KIND_TONE = { course: '', assessment: 'danger', result: 'gold', message: 'neutral', submission: 'gold', system: 'neutral' };

export function notificationRow(n, onOpen) {
  return h(`button.notif${n.read ? '' : '.unread'}`, {
    onClick: async (e) => {
      if (!n.read) {
        n.read = true;
        e.currentTarget.classList.remove('unread');
        try {
          const res = await rpc('notifications:read', { ids: [n.id] });
          setUnread(res.unread);
        } catch (e) { /* non bloquant */ }
      }
      if (onOpen) onOpen(n);
      if (n.linkType && n.linkId) openLink(n.linkType, n.linkId);
    },
  },
  h(`div.emblem.sm${KIND_TONE[n.kind] ? `.${KIND_TONE[n.kind]}` : ''}`, null, icon(KIND_ICON[n.kind] || 'bell', 17)),
  h('div.body', null,
    h('b', null, n.title),
    n.body ? h('p', null, n.body) : null,
    n.sender && n.kind === 'message' ? h('div.muted', { style: { fontSize: '0.75rem', marginTop: '0.25rem' } }, n.sender) : null),
  h('div.side', null, h('span.when', null, f.ago(n.createdAt)), h('i.dot')));
}

function dayKey(ts) {
  const d = new Date(ts * 1000);
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

export function register() {
  route('common.notifications', {
    title: () => t('notifications.title'),
    tab: 'notifications',
    bell: false,
    skeleton: () => skeletonList(5),
    load: () => rpc('notifications:list'),
    actions: (ctx, data) => (data && data.unread > 0 ? [h('button.btn.ghost.sm', {
      onClick: async () => {
        try {
          const res = await rpc('notifications:read', { all: true });
          setUnread(res.unread);
          ctx.refresh({ silent: true });
        } catch (err) {
          toastError(err);
        }
      },
    }, icon('check', 16), t('notifications.markAll'))] : []),
    render(ctx, data) {
      setUnread(data.unread || 0);
      ctx.onPush('notification', () => ctx.refresh({ silent: true }));
      const items = arr(data.items);
      if (!items.length) {
        return emptyState({ icon: 'bell', title: t('notifications.empty'), text: store.profile.role === 'student' ? t('notifications.emptyText') : '' });
      }
      const out = h('div.content-narrow.stack');
      let currentKey = null;
      let group = null;
      items.forEach((n) => {
        const key = dayKey(n.createdAt);
        if (key !== currentKey) {
          currentKey = key;
          group = h('div.card.list');
          out.appendChild(h('div.overline', { style: { margin: '0.75rem 0.25rem 0' } }, f.date(n.createdAt)));
          out.appendChild(group);
        }
        group.appendChild(notificationRow(n, () => ctx.refresh({ silent: true })));
      });
      return out;
    },
  });
}

export { nav };

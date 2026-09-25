/**
 * Paramètres : apparence, compte Campus, (professeur) civilité et classes enseignées.
 */
import { route, nav } from '../../core/router.js';
import { h } from '../../core/dom.js';
import { icon } from '../../core/icons.js';
import { t } from '../../core/i18n.js';
import { rpc, arr, obj } from '../../core/nui.js';
import { store, emit } from '../../core/store.js';
import { skeletonDetail, toast, toastError, busy } from '../../core/ui.js';
import { section, segmented, toggleRow, field, textInput, chipSelect, avatar, notice } from '../../components/widgets.js';

export function register() {
  route('common.settings', {
    title: () => t('settings.title'),
    tab: 'settings',
    skeleton: skeletonDetail,
    load: () => rpc('settings:get'),
    render(ctx, s) {
      const p = store.profile;
      const prefs = Object.assign({}, obj(s.prefs));
      const out = h('div.content-narrow.stack');
      const save = async (patch, quiet) => {
        try {
          const profile = await rpc('settings:save', patch);
          store.profile = profile;
          emit('profile', profile);
          document.dispatchEvent(new CustomEvent('ec:theme'));
          if (!quiet) toast(t('settings.saved'), { tone: 'success' });
        } catch (err) {
          toastError(err);
        }
      };

      // Identité Campus (lecture seule : la source d'identité est le compte Campus)
      out.appendChild(section(t('settings.account'), null, h('div.card.pad.stack', null,
        h('div.row', null, avatar(p.displayName, 'lg'), h('div.grow', null,
          h('div', { style: { fontWeight: '700', fontSize: '1.0625rem' } }, p.role === 'student' ? p.displayName : p.teacherName),
          h('div.muted', { style: { fontSize: '0.8125rem' } }, t(`roles.${p.role}`)))),
        h('div.grid-2', null,
          h('div', null, h('div.overline', null, t('settings.campusId')), h('div.tnum', { style: { fontWeight: '600', marginTop: '0.2rem' } }, p.campusId)),
          h('div', null, h('div.overline', null, p.role === 'student' ? t('settings.class') : t('settings.studentNumber')),
            h('div', { style: { fontWeight: '600', marginTop: '0.2rem' } }, p.role === 'student' ? (p.className || '—') : (p.studentNumber || '—')))),
        p.role === 'student' && p.studentNumber ? h('div', null, h('div.overline', null, t('settings.studentNumber')), h('div.tnum', { style: { fontWeight: '600', marginTop: '0.2rem' } }, p.studentNumber)) : null,
        notice(t('settings.campusNotice'), '', 'shield'))));

      // Apparence
      out.appendChild(section(t('settings.appearance'), null, h('div.card.pad.stack', null,
        field(t('settings.theme'), segmented([
          { value: 'auto', label: t('settings.themeAuto') },
          { value: 'light', label: t('settings.themeLight') },
          { value: 'dark', label: t('settings.themeDark') },
        ], prefs.theme || 'auto', (value) => { prefs.theme = value; store.profile.prefs = prefs; document.dispatchEvent(new CustomEvent('ec:theme')); save({ theme: value }, true); })),
        toggleRow(t('settings.reduceMotion'), t('settings.reduceMotionHint'), !!prefs.reduceMotion, (on) => {
          prefs.reduceMotion = on;
          store.profile.prefs = prefs;
          document.dispatchEvent(new CustomEvent('ec:theme'));
          save({ reduceMotion: on }, true);
        }))));

      // Professeur : civilité + classes
      if (p.role === 'teacher' || p.role === 'admin') {
        const title = textInput({ value: s.title || '', placeholder: t('settings.titlePlaceholder'), max: 24 });
        const teacherBox = h('div.card.pad.stack', null,
          field(t('settings.titleLabel'), title, { hint: t('settings.titleHint') }));
        let chosen = arr(s.teachingClassIds);
        if (s.canPickClasses) {
          teacherBox.appendChild(field(t('settings.classes'), chipSelect(arr(s.classes).map((c) => ({ value: c.id, label: c.label })), chosen, (ids) => { chosen = ids; }),
            { hint: s.allClasses && !chosen.length ? t('settings.allClassesHint') : t('settings.classesHint') }));
        } else if (p.role === 'teacher') {
          teacherBox.appendChild(notice(s.allClasses ? t('settings.allClassesHint') : t('settings.classesByAdmin'), '', 'info'));
        }
        teacherBox.appendChild(h('button.btn.primary', {
          onClick: () => busy(() => save(Object.assign({ title: title.value.trim() }, s.canPickClasses ? { classIds: chosen } : {}))),
        }, icon('check', 18), t('common.save')));
        out.appendChild(section(t('settings.teaching'), null, teacherBox));
      }

      out.appendChild(h('div.muted', { style: { textAlign: 'center', fontSize: '0.75rem', padding: '1rem 0' } },
        `${store.boot.appName || 'English Campus'} · ${store.boot.schoolName || ''}`));
      return out;
    },
  });
}

export { nav };

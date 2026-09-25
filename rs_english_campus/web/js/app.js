/**
 * English Campus — démarrage de l'interface.
 *
 * 1. détecte l'hôte (téléphone / PC / cadre autonome) et applique le thème
 * 2. récupère la configuration d'affichage (ec:boot) puis le profil + tableau de bord (app:init)
 * 3. construit la navigation selon le rôle renvoyé PAR LE SERVEUR (élève / professeur / admin)
 */
import { env, waitForPhoneSdk, phoneTheme } from './core/env.js';
import { nui, rpc, arr } from './core/nui.js';
import { startPush, onPush } from './core/push.js';
import { h, clear } from './core/dom.js';
import { icon, logo } from './core/icons.js';
import { setLocale, t, errorText } from './core/i18n.js';
import { store, setUnread, emit, role, isAdmin, local, on as storeOn } from './core/store.js';
import { nav } from './core/router.js';
import { mountUi, toast } from './core/ui.js';
import { avatar } from './components/widgets.js';
import { registerScreens, openLink } from './screens/index.js';

const els = {};

// ─── Thème ───────────────────────────────────────────────────────────────────

function hexToRgb(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || '').trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function mix(rgb, target, amount) {
  return rgb.map((c, i) => Math.round(c + (target[i] - c) * amount));
}

function rgbStr(rgb, alpha) {
  return alpha === undefined ? `rgb(${rgb.join(', ')})` : `rgba(${rgb.join(', ')}, ${alpha})`;
}

function applyTheme() {
  const theme = (store.boot && store.boot.theme) || {};
  const prefs = (store.profile && store.profile.prefs) || {};
  let mode = prefs.theme && prefs.theme !== 'auto' ? prefs.theme : (theme.Mode || 'auto');
  if (mode === 'auto') mode = phoneTheme() || 'light';
  const dark = mode === 'dark';
  const root = document.documentElement;
  root.setAttribute('data-ec-theme', dark ? 'dark' : 'light');
  root.setAttribute('data-ec-motion', prefs.reduceMotion || theme.Animations === false ? 'reduced' : 'full');

  const set = (name, value) => root.style.setProperty(name, value);
  const accent = hexToRgb(theme.Accent);
  if (accent) {
    const base = dark ? mix(accent, [255, 255, 255], 0.42) : accent;
    set('--ec-accent', rgbStr(base));
    set('--ec-accent-strong', rgbStr(dark ? mix(accent, [255, 255, 255], 0.6) : mix(accent, [0, 0, 0], 0.22)));
    set('--ec-accent-soft', rgbStr(base, dark ? 0.14 : 0.09));
    set('--ec-accent-line', rgbStr(base, dark ? 0.32 : 0.22));
  }
  [['Correct', 'correct'], ['Wrong', 'wrong'], ['Gold', 'gold']].forEach(([key, name]) => {
    const rgb = hexToRgb(theme[key]);
    if (!rgb) return;
    const base = dark ? mix(rgb, [255, 255, 255], 0.22) : rgb;
    set(`--ec-${name}`, rgbStr(base));
    set(`--ec-${name}-soft`, rgbStr(base, dark ? 0.14 : 0.11));
  });
  if (theme.Radius) set('--ec-radius', `${theme.Radius / 16}rem`);
}

function watchPhoneTheme() {
  if (!document.body) return;
  new MutationObserver(applyTheme).observe(document.body, { attributes: true, attributeFilter: ['data-theme'] });
  window.addEventListener('message', (e) => {
    const data = e.data;
    if (!data || typeof data !== 'object') return;
    if (data.type === 'settingsUpdated') applyTheme();
    if (data.type === 'appOpen') onAppVisible(true);
    if (data.type === 'appClose') onAppVisible(false);
    if (data.action === 'ec:host') onAppVisible(!!data.visible);
  });
}

// ─── Coquille ────────────────────────────────────────────────────────────────

function buildShell() {
  const app = document.getElementById('app');
  els.stack = h('div.ec-stack');
  els.tabbar = h('nav.tabbar', { 'aria-label': t('nav.label') });
  els.sidebar = h('aside.sidebar');
  els.layer = h('div.layer');
  els.toasts = h('div.toasts');
  els.splashStatus = h('div.status', null, '');
  els.splash = h('div.splash', null, logo('logo'), h('div.name', null, (store.boot && store.boot.appName) || 'English Campus'), els.splashStatus, h('div.bar'));
  els.root = h('div.ec-root', { dataset: { host: env.host, frame: env.frame, layout: 'compact' } },
    els.sidebar,
    h('main.ec-main', null, els.stack, els.tabbar),
    els.layer,
    els.toasts,
    els.splash);
  clear(app).appendChild(els.root);
  document.body.style.visibility = 'visible';
  mountUi(els.layer, els.toasts);
  nav.mount(els.stack);

  const measure = () => {
    const width = els.root.clientWidth;
    const wide = width >= 760;
    els.root.dataset.layout = wide ? 'wide' : 'compact';
  };
  measure();
  if (window.ResizeObserver) new ResizeObserver(measure).observe(els.root);
  else window.addEventListener('resize', measure);
}

function splash(status) {
  els.splashStatus.textContent = status;
}

function splashError(err) {
  const code = err && err.code ? err.code : 'unknown';
  const box = h('div.error-box', null,
    h('p', { style: { margin: '0 0 1rem', color: 'var(--ec-text-2)', fontSize: '0.875rem', lineHeight: '1.5' } }, errorText(code)),
    h('button.btn.primary', { onClick: () => { box.remove(); start(); } }, icon('refresh', 18), t('common.retry')));
  const bar = els.splash.querySelector('.bar');
  if (bar) bar.classList.add('hidden');
  els.splashStatus.textContent = '';
  els.splash.appendChild(box);
}

// ─── Navigation selon le rôle ────────────────────────────────────────────────

function tabsFor(r) {
  if (r === 'teacher' || r === 'admin') {
    return [
      { id: 'home', label: t('nav.home'), icon: 'home', route: 'teacher.home' },
      { id: 'courses', label: t('nav.courses'), icon: 'book', route: 'teacher.courses' },
      { id: 'assessments', label: t('nav.assessments'), icon: 'clipboard', route: 'teacher.assessments' },
      { id: 'students', label: t('nav.students'), icon: 'users', route: 'teacher.students' },
      { id: 'more', label: t('nav.more'), icon: 'more', route: 'teacher.more', compactOnly: true },
      { id: 'live', label: t('nav.live'), icon: 'live', route: 'teacher.live', wideOnly: true },
      { id: 'messages', label: t('nav.messages'), icon: 'megaphone', route: 'teacher.notify', wideOnly: true },
      { id: 'settings', label: t('nav.settings'), icon: 'sliders', route: 'common.settings', wideOnly: true, group: 'account' },
      { id: 'admin', label: t('nav.admin'), icon: 'shield', route: 'admin.home', wideOnly: true, adminOnly: true, group: 'account' },
    ];
  }
  return [
    { id: 'home', label: t('nav.home'), icon: 'home', route: 'student.home' },
    { id: 'courses', label: t('nav.courses'), icon: 'book', route: 'student.courses' },
    { id: 'assessments', label: t('nav.assessments'), icon: 'clipboard', route: 'student.assessments' },
    { id: 'progress', label: t('nav.progress'), icon: 'chart', route: 'student.progress' },
    { id: 'vocab', label: t('nav.vocabulary'), icon: 'cards', route: 'student.vocab' },
    { id: 'results', label: t('nav.results'), icon: 'trophy', route: 'student.results', wideOnly: true, group: 'account' },
    { id: 'notifications', label: t('nav.notifications'), icon: 'bell', route: 'common.notifications', wideOnly: true, group: 'account', badge: true },
    { id: 'settings', label: t('nav.settings'), icon: 'sliders', route: 'common.settings', wideOnly: true, group: 'account' },
  ];
}

function buildNavigation() {
  const tabs = tabsFor(role()).filter((tab) => !tab.adminOnly || isAdmin());
  nav.tabs = {};
  tabs.forEach((tab) => { nav.tabs[tab.id] = { route: tab.route }; });

  // Barre d'onglets (téléphone)
  clear(els.tabbar);
  const tabButtons = {};
  tabs.filter((tab) => !tab.wideOnly).forEach((tab) => {
    const btn = h('button.tab', { type: 'button', onClick: () => nav.tab(tab.id) }, icon(tab.icon, 22), h('span', null, tab.label));
    tabButtons[tab.id] = btn;
    els.tabbar.appendChild(btn);
  });

  // Barre latérale (PC)
  clear(els.sidebar);
  const sideButtons = {};
  const p = store.profile;
  els.sidebar.appendChild(h('div.brand', null, logo('logo'), h('div', null,
    h('div.name', null, store.boot.appName || 'English Campus'),
    h('div.school', null, store.boot.schoolName || ''))));
  const main = h('nav.side-nav');
  const account = h('nav.side-nav');
  tabs.filter((tab) => !tab.compactOnly).forEach((tab) => {
    const count = tab.badge ? h('span.count.hidden') : null;
    const btn = h('button.side-item', { type: 'button', onClick: () => nav.tab(tab.id) }, icon(tab.icon, 20), h('span', null, tab.label), count);
    btn._count = count;
    sideButtons[tab.id] = btn;
    (tab.group === 'account' ? account : main).appendChild(btn);
  });
  els.sidebar.appendChild(main);
  els.sidebar.appendChild(h('div.side-group.overline', null, t('nav.account')));
  els.sidebar.appendChild(account);
  els.sidebar.appendChild(h('div.me', null, avatar(p.displayName), h('div.who', null,
    h('b', null, p.role === 'student' ? p.displayName : p.teacherName || p.displayName),
    h('span', null, p.role === 'student' ? (p.className || t('profile.noClass')) : t(`roles.${p.role}`)))));

  const paintBadges = () => {
    Object.values(sideButtons).forEach((btn) => {
      if (!btn._count) return;
      btn._count.textContent = store.unread > 9 ? '9+' : String(store.unread);
      btn._count.classList.toggle('hidden', store.unread === 0);
    });
  };
  paintBadges();
  if (els.unsubBadges) els.unsubBadges();
  els.unsubBadges = storeOn('unread', paintBadges);

  nav.onChange = (top, stack) => {
    const rootEntry = stack[0];
    const activeTab = (rootEntry && rootEntry.def.tab) || Object.keys(nav.tabs).find((id) => rootEntry && nav.tabs[id].route === rootEntry.name);
    Object.keys(tabButtons).forEach((id) => tabButtons[id].classList.toggle('active', id === activeTab || (activeTab && !tabButtons[activeTab] && id === 'more')));
    Object.keys(sideButtons).forEach((id) => sideButtons[id].classList.toggle('active', id === activeTab));
    els.tabbar.classList.toggle('hidden-bar', !!(top && (top.def.hideTabs || top.footer)));
  };
  nav.openNotifications = () => nav.push('common.notifications');
}

// ─── Présence, deep-links, évènements globaux ────────────────────────────────

let visible = true;

function presence(open) {
  nui('ec:presence', { host: env.isStandalone ? `${env.host}-standalone` : env.host, open }).catch(() => {});
}

function onAppVisible(isVisible) {
  if (visible === isVisible) return;
  visible = isVisible;
  presence(isVisible);
  if (isVisible && store.profile) {
    consumeLink();
    refreshCounters();
  }
}

async function consumeLink() {
  try {
    const link = await nui('ec:link');
    if (link && link.type && link.id) openLink(link.type, link.id);
  } catch (e) { /* aucun lien en attente */ }
}

async function refreshCounters() {
  try {
    const data = await rpc('notifications:list');
    setUnread(data.unread || 0);
  } catch (e) { /* ignoré */ }
}

function bindGlobalEvents() {
  onPush('notification', (n) => {
    setUnread(store.unread + 1);
    toast(n.title || t('nav.notifications'), {
      tone: 'notification',
      icon: { course: 'book', assessment: 'clipboard', result: 'trophy', message: 'megaphone', submission: 'pen' }[n.kind] || 'bell',
      body: n.body,
      onClick: n.linkType ? () => openLink(n.linkType, n.linkId) : undefined,
      duration: 5000,
    });
    emit('notification', n);
    nav.invalidate(['student.home', 'teacher.home', 'student.courses', 'student.assessments', 'teacher.assessments', 'common.notifications']);
  });
  onPush('profile:changed', () => {
    toast(t('profile.updated'), { tone: 'info', icon: 'refresh' });
    setTimeout(() => start(true), 400);
  });
  onPush('attempt:closed', () => {
    nav.invalidate(['student.assessments', 'student.assessment', 'student.home']);
  });

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || e.defaultPrevented) return;
    if (env.isPhoneEmbed) return; // le téléphone gère lui-même la touche Échap
    if (els.layer && els.layer.children.length) return;
    if (nav.stack.length > 1) nav.back();
    else if (env.isStandalone) nui('ec:close').catch(() => {});
  });

  window.addEventListener('pagehide', () => presence(false));
  document.addEventListener('ec:theme', applyTheme);
}

// ─── Démarrage ───────────────────────────────────────────────────────────────

function applyInit(data) {
  store.profile = data.profile;
  store.settings = data.settings || {};
  store.classes = arr(data.classes);
  store.dashboard = data.dashboard;
  setUnread(data.unread || 0);
  applyTheme();
}

let started = false;

async function start(forceRefresh) {
  splash(t('splash.connecting'));
  els.splash.classList.remove('done');
  try {
    const data = await rpc('app:init');
    applyInit(data);
    local.set('init', { at: Date.now(), campusId: data.profile.campusId });
    buildNavigation();
    nav.tab('home');
    requestAnimationFrame(() => els.splash.classList.add('done'));
    presence(true);
    if (!forceRefresh || !started) consumeLink();
    started = true;
  } catch (err) {
    splashError(err);
  }
}

async function boot() {
  await waitForPhoneSdk();
  let cfg = null;
  try { cfg = await nui('ec:boot'); } catch (e) { cfg = null; }
  store.boot = cfg && typeof cfg === 'object' ? cfg : { appName: 'English Campus', locale: 'fr', theme: {} };
  setLocale(store.boot.locale || 'fr');
  buildShell();
  applyTheme();
  watchPhoneTheme();
  startPush();
  registerScreens();
  bindGlobalEvents();
  start();
}

boot();

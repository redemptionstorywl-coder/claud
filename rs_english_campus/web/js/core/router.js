/**
 * Navigation en pile (style application native) avec transitions.
 *
 *   route('student.course', { title, load, render, ... })
 *   nav.push('student.course', { id: 12 })   nav.back()   nav.tab('courses')
 *
 * Chaque écran reçoit un `ctx` : paramètres, rafraîchissement, abonnements temps réel
 * (désinscrits automatiquement à la fermeture), barre d'actions, titre dynamique.
 */
import { h, replace, clear } from './dom.js';
import { icon, logo } from './icons.js';
import { t } from './i18n.js';
import { onPush } from './push.js';
import { store, on } from './store.js';
import { errorState, skeletonList, closeOverlays } from './ui.js';

const routes = {};

export function route(name, def) {
  routes[name] = def;
}

export function hasRoute(name) {
  return !!routes[name];
}

export const nav = {
  stack: [],
  container: null,
  tabs: {},          // id → { route, params }
  currentTab: null,
  onChange: null,
  openNotifications: null,

  mount(container) {
    this.container = container;
  },

  top() {
    return this.stack[this.stack.length - 1];
  },

  /**
   * Affiche la racine d'un onglet (la pile est réinitialisée). Les écrans qui protègent leur
   * sortie (éditeur non enregistré, évaluation en cours) sont consultés d'abord — utile sur PC,
   * où la barre latérale reste cliquable pendant une évaluation.
   */
  async tab(id, params) {
    const tab = this.tabs[id];
    if (!tab) return false;
    for (let i = this.stack.length - 1; i >= 0; i--) {
      const entry = this.stack[i];
      if (entry.def.confirmLeave && !entry.disposed && !(await entry.def.confirmLeave(entry.ctx))) return false;
    }
    this.currentTab = id;
    this.reset(tab.route, Object.assign({}, tab.params || {}, params || {}));
    return true;
  },

  reset(name, params) {
    closeOverlays();
    const old = this.stack.splice(0);
    old.forEach((entry) => dispose(entry, true));
    const entry = createEntry(name, params);
    this.stack.push(entry);
    entry.el.classList.add('fade-in');
    this.container.appendChild(entry.el);
    notify();
    load(entry);
    return entry;
  },

  push(name, params) {
    closeOverlays();
    const prev = this.top();
    const entry = createEntry(name, params);
    this.stack.push(entry);
    this.container.appendChild(entry.el);
    animate(entry.el, 'enter');
    if (prev) {
      animate(prev.el, 'leave', () => {
        if (this.top() !== prev) prev.el.setAttribute('aria-hidden', 'true');
      });
    }
    notify();
    load(entry);
    return entry;
  },

  replace(name, params) {
    closeOverlays();
    const prev = this.stack.pop();
    if (prev) dispose(prev, true);
    const entry = createEntry(name, params);
    this.stack.push(entry);
    this.container.appendChild(entry.el);
    entry.el.classList.add('fade-in');
    notify();
    load(entry);
    return entry;
  },

  async back() {
    if (this.stack.length < 2) return false;
    const top = this.top();
    if (top.def.confirmLeave) {
      const ok = await top.def.confirmLeave(top.ctx);
      if (!ok) return false;
    }
    closeOverlays();
    this.stack.pop();
    const prev = this.top();
    prev.el.removeAttribute('aria-hidden');
    animate(prev.el, 'enter-back');
    animate(top.el, 'leave-back', () => dispose(top, true));
    top.disposing = true;
    notify();
    if (prev.def.onShow) prev.def.onShow(prev.ctx, prev.data);
    if (prev.stale || prev.def.refreshOnShow) {
      prev.stale = false;
      prev.ctx.refresh({ silent: true });
    }
    return true;
  },

  /** Revient à un écran précis de la pile (s'il existe). */
  async backTo(name) {
    while (this.stack.length > 1 && this.top().name !== name) {
      const ok = await this.back();
      if (!ok) return false;
    }
    return true;
  },

  /** Marque les écrans d'une route comme « à rafraîchir » au prochain affichage. */
  invalidate(names) {
    const list = Array.isArray(names) ? names : [names];
    this.stack.forEach((entry, i) => {
      if (list.indexOf(entry.name) !== -1 || list.indexOf('*') !== -1) {
        if (i === this.stack.length - 1) entry.ctx.refresh({ silent: true });
        else entry.stale = true;
      }
    });
  },
};

function notify() {
  if (nav.onChange) nav.onChange(nav.top(), nav.stack);
}

function animate(el, name, done) {
  const classes = ['enter', 'leave', 'enter-back', 'leave-back', 'fade-in'];
  classes.forEach((c) => el.classList.remove(c));
  // Force un recalcul pour relancer l'animation.
  void el.offsetWidth;
  el.classList.add(name);
  let finished = false;
  const end = () => {
    if (finished) return;
    finished = true;
    el.classList.remove(name);
    if (done) done();
  };
  el.addEventListener('animationend', end, { once: true });
  setTimeout(end, 450);
}

function dispose(entry, removeEl) {
  if (entry.disposed) return;
  entry.disposed = true;
  entry.cleanups.forEach((fn) => { try { fn(); } catch (e) { console.error(e); } });
  entry.cleanups = [];
  if (removeEl && entry.el.parentNode) entry.el.parentNode.removeChild(entry.el);
}

function createEntry(name, params) {
  const def = routes[name];
  if (!def) throw new Error(`Unknown route ${name}`);
  const header = h('header.screen-header');
  const body = h('div.screen-body');
  const el = h('section.screen', { dataset: { route: name } }, header, body);
  const entry = { name, params: params || {}, def, el, header, body, footer: null, cleanups: [], data: null, disposed: false, stale: false };
  if (def.hideTabs) el.classList.add('no-tabs');
  else el.classList.add('with-tabs');
  if (def.flush) body.classList.add('flush');

  body.addEventListener('scroll', () => {
    header.classList.toggle('scrolled', body.scrollTop > 6);
  }, { passive: true });

  entry.ctx = {
    params: entry.params,
    nav,
    el,
    body,
    get data() { return entry.data; },
    isActive: () => nav.top() === entry && !entry.disposed,
    refresh: (opts) => load(entry, opts || {}),
    rerender: () => renderBody(entry, true),
    setTitle: (title, subtitle) => {
      entry.customTitle = title;
      entry.customSubtitle = subtitle;
      renderHeader(entry);
    },
    setActions: (nodes) => {
      entry.customActions = nodes;
      renderHeader(entry);
    },
    footer: (node) => {
      if (entry.footer && entry.footer.parentNode) entry.footer.parentNode.removeChild(entry.footer);
      entry.footer = node || null;
      if (node) el.appendChild(node);
      // Une barre d'actions prend la place de la barre d'onglets sur téléphone.
      el.classList.toggle('has-footer', !!node);
      if (nav.top() === entry) notify();
    },
    cleanup: (fn) => entry.cleanups.push(fn),
    onPush: (kind, fn) => entry.cleanups.push(onPush(kind, fn)),
    on: (event, fn) => entry.cleanups.push(on(event, fn)),
    interval: (fn, ms) => {
      const id = setInterval(fn, ms);
      entry.cleanups.push(() => clearInterval(id));
      return id;
    },
    timeout: (fn, ms) => {
      const id = setTimeout(fn, ms);
      entry.cleanups.push(() => clearTimeout(id));
      return id;
    },
    set: (key, value) => { entry[`_${key}`] = value; },
    get: (key) => entry[`_${key}`],
  };
  renderHeader(entry);
  return entry;
}

function titleOf(entry) {
  if (entry.customTitle !== undefined) return entry.customTitle;
  const def = entry.def;
  if (typeof def.title === 'function') {
    try { return def.title(entry.ctx, entry.data); } catch (e) { return ''; }
  }
  return def.title || '';
}

function subtitleOf(entry) {
  if (entry.customSubtitle !== undefined) return entry.customSubtitle;
  const def = entry.def;
  if (typeof def.subtitle === 'function') {
    try { return def.subtitle(entry.ctx, entry.data); } catch (e) { return ''; }
  }
  return def.subtitle || '';
}

function bellButton() {
  const btn = h('button.icon-btn', { 'aria-label': t('nav.notifications'), onClick: () => nav.openNotifications && nav.openNotifications() }, icon('bell', 22));
  const paint = () => {
    const old = btn.querySelector('.dot');
    if (old) old.remove();
    if (store.unread > 0) btn.appendChild(h('span.dot', null, store.unread > 9 ? '9+' : String(store.unread)));
  };
  paint();
  btn._unsub = on('unread', paint);
  return btn;
}

function renderHeader(entry) {
  const { header, def } = entry;
  if (header._bell && header._bell._unsub) header._bell._unsub();
  header._bell = null;
  clear(header);
  if (def.noHeader) {
    header.classList.add('hidden');
    return;
  }
  const index = nav.stack.indexOf(entry);
  const isRoot = index <= 0;
  header.classList.toggle('large', !!def.large && isRoot);

  if (!isRoot) {
    header.appendChild(h('button.icon-btn', { 'aria-label': t('common.back'), onClick: () => nav.back() }, icon('chevronLeft', 24)));
  } else if (def.brand) {
    header.appendChild(h('div.brand-mark', null, logo('logo')));
  }

  const title = titleOf(entry);
  const subtitle = subtitleOf(entry);
  header.appendChild(h('div.title-wrap', null,
    subtitle && def.large && isRoot ? h('div.overline', null, subtitle) : null,
    h('div.title', null, title),
    subtitle && !(def.large && isRoot) ? h('div.subtitle', null, subtitle) : null));

  const actions = h('div.actions');
  let custom = entry.customActions;
  if (custom === undefined && def.actions) {
    try { custom = def.actions(entry.ctx, entry.data); } catch (e) { custom = null; }
  }
  (custom || []).forEach((node) => node && actions.appendChild(node));
  if (isRoot && def.bell !== false) {
    header._bell = bellButton();
    actions.appendChild(header._bell);
  }
  header.appendChild(actions);
}

async function load(entry, opts = {}) {
  const { def, ctx } = entry;
  const token = (entry.loadToken = (entry.loadToken || 0) + 1);
  renderHeader(entry);
  if (def.load) {
    if (!opts.silent) replace(entry.body, def.skeleton ? def.skeleton(ctx) : skeletonList());
    let data;
    try {
      data = await def.load(ctx);
    } catch (err) {
      if (entry.disposed || token !== entry.loadToken) return;
      if (opts.silent && entry.data) return; // on garde l'affichage précédent
      replace(entry.body, errorState(err, () => load(entry)));
      return;
    }
    if (entry.disposed || token !== entry.loadToken) return;
    entry.data = data;
  }
  renderBody(entry, !!opts.silent);
}

function renderBody(entry, keepScroll) {
  const { def, ctx } = entry;
  if (entry.disposed) return;
  const scroll = entry.body.scrollTop;
  let content;
  try {
    content = def.render(ctx, entry.data);
  } catch (err) {
    console.error(err);
    content = errorState(err, () => load(entry));
  }
  replace(entry.body, content);
  if (keepScroll) entry.body.scrollTop = scroll;
  renderHeader(entry);
  if (def.mounted) def.mounted(ctx, entry.data);
}

/**
 * Kit d'interface : toasts, dialogues de confirmation, feuilles, voile de chargement,
 * états vides / erreurs / squelettes de chargement.
 */
import { h, clear } from './dom.js';
import { icon } from './icons.js';
import { t, errorText } from './i18n.js';

let layer = null;
let toastBox = null;

export function mountUi(layerEl, toastsEl) {
  layer = layerEl;
  toastBox = toastsEl;
}

// ─── Toasts ─────────────────────────────────────────────────────────────────

const TONE_ICON = { info: 'info', success: 'checkCircle', error: 'alert', notification: 'bell' };
const TONE_EMBLEM = { info: 'neutral', success: 'success', error: 'danger', notification: '' };

/**
 * @param {string} title
 * @param {{ body?: string, tone?: string, icon?: string, onClick?: Function, duration?: number }} opts
 */
export function toast(title, opts = {}) {
  if (!toastBox) return;
  const tone = opts.tone || 'info';
  const el = h('div.toast', { class: { clickable: !!opts.onClick }, role: 'status' },
    h(`div.emblem.sm${TONE_EMBLEM[tone] ? `.${TONE_EMBLEM[tone]}` : ''}`, null, icon(opts.icon || TONE_ICON[tone] || 'info', 18)),
    h('div.txt', null, h('b', null, title), opts.body ? h('span', null, opts.body) : null));
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    el.classList.add('closing');
    setTimeout(() => el.remove(), 230);
  };
  el.addEventListener('click', () => {
    if (opts.onClick) opts.onClick();
    close();
  });
  toastBox.appendChild(el);
  while (toastBox.children.length > 3) toastBox.firstChild.remove();
  setTimeout(close, opts.duration || (tone === 'error' ? 4200 : 3200));
  return close;
}

export function toastError(err) {
  const code = err && err.code ? err.code : 'unknown';
  toast(errorText(code), { tone: 'error', body: detailText(err) });
}

function detailText(err) {
  if (!err || !err.detail || typeof err.detail !== 'string') return undefined;
  const field = err.detail.split(':')[0];
  const known = t(`fields.${field.replace(/\[\d+\]/g, '').replace(/\./g, '_')}`);
  return known.indexOf('fields.') === 0 ? undefined : known;
}

// ─── Dialogues ──────────────────────────────────────────────────────────────

// Fenêtres ouvertes (dialogues, feuilles) : refermées d'un coup quand l'écran change.
const openOverlays = new Set();

export function closeOverlays() {
  Array.from(openOverlays).forEach((dismiss) => dismiss());
}

function overlay(onDismiss) {
  const backdrop = h('div.backdrop');
  if (onDismiss) backdrop.addEventListener('click', onDismiss);
  return backdrop;
}

/**
 * Confirmation. Résout true / false.
 * @param {{ title: string, message?: string, confirm?: string, cancel?: string, danger?: boolean, icon?: string }} opts
 */
export function confirmDialog(opts) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      openOverlays.delete(dismiss);
      backdrop.classList.add('closing');
      box.classList.add('closing');
      setTimeout(() => { backdrop.remove(); box.remove(); }, 200);
      document.removeEventListener('keydown', onKey, true);
      resolve(value);
    };
    const dismiss = () => finish(false);
    const onKey = (e) => {
      if (e.key === 'Escape') { e.stopPropagation(); finish(false); }
      if (e.key === 'Enter') { e.stopPropagation(); finish(true); }
    };
    const backdrop = overlay(() => finish(false));
    const box = h('div.dialog', { role: 'dialog', 'aria-modal': 'true' },
      opts.icon ? h(`div.emblem.lg.dialog-icon${opts.danger ? '.danger' : ''}`, null, icon(opts.icon, 26)) : null,
      h('h3', null, opts.title),
      opts.message ? h('p', null, opts.message) : null,
      h('div.dialog-actions', null,
        h('button.btn.secondary', { onClick: () => finish(false) }, opts.cancel || t('common.cancel')),
        h(`button.btn.${opts.danger ? 'danger' : 'primary'}`, { onClick: () => finish(true) }, opts.confirm || t('common.confirm'))));
    layer.append(backdrop, box);
    openOverlays.add(dismiss);
    document.addEventListener('keydown', onKey, true);
  });
}

/** Saisie d'un texte. Résout la valeur ou null. */
export function promptDialog(opts) {
  return new Promise((resolve) => {
    const input = h(opts.multiline ? 'textarea.input' : 'input.input', {
      value: opts.value || '', placeholder: opts.placeholder || '', maxlength: opts.max || 200, rows: opts.multiline ? 4 : undefined,
    });
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      openOverlays.delete(dismiss);
      backdrop.classList.add('closing');
      box.classList.add('closing');
      setTimeout(() => { backdrop.remove(); box.remove(); }, 200);
      resolve(value);
    };
    const dismiss = () => finish(null);
    const backdrop = overlay(dismiss);
    const box = h('div.dialog', { role: 'dialog' },
      h('h3', null, opts.title),
      opts.message ? h('p', null, opts.message) : null,
      input,
      h('div.dialog-actions', null,
        h('button.btn.secondary', { onClick: () => finish(null) }, t('common.cancel')),
        h('button.btn.primary', { onClick: () => finish(input.value.trim()) }, opts.confirm || t('common.ok'))));
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !opts.multiline) finish(input.value.trim());
      if (e.key === 'Escape') finish(null);
    });
    layer.append(backdrop, box);
    openOverlays.add(dismiss);
    setTimeout(() => input.focus({ preventScroll: true }), 50);
  });
}

// ─── Feuilles ───────────────────────────────────────────────────────────────

/**
 * Feuille (bas d'écran sur téléphone, fenêtre centrée sur PC).
 * @param {{ title?: string, content: Node|Function, actions?: Node[], wide?: boolean, onClose?: Function }} opts
 * @returns {{ close: Function, body: HTMLElement, setActions: Function }}
 */
export function sheet(opts) {
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    openOverlays.delete(close);
    backdrop.classList.add('closing');
    el.classList.add('closing');
    document.removeEventListener('keydown', onKey, true);
    setTimeout(() => { backdrop.remove(); el.remove(); }, 240);
    if (opts.onClose) opts.onClose();
  };
  const onKey = (e) => {
    if (e.key === 'Escape') { e.stopPropagation(); close(); }
  };
  const backdrop = overlay(close);
  const body = h('div.sheet-body');
  const actionsBox = h('div.sheet-actions');
  const el = h(`div.sheet${opts.wide ? '.wide' : ''}`, { role: 'dialog', 'aria-modal': 'true' },
    h('div.grabber'),
    opts.title ? h('div.sheet-head', null, h('h3', null, opts.title), h('button.icon-btn', { onClick: close, 'aria-label': t('common.close') }, icon('close', 20))) : null,
    body);
  const api = {
    close,
    body,
    setActions(nodes) {
      clear(actionsBox);
      (nodes || []).forEach((n) => n && actionsBox.appendChild(n));
      if (nodes && nodes.length) el.appendChild(actionsBox);
      else if (actionsBox.parentNode) actionsBox.remove();
    },
  };
  const content = typeof opts.content === 'function' ? opts.content(api) : opts.content;
  if (content) body.appendChild(content);
  if (opts.actions) api.setActions(opts.actions);
  layer.append(backdrop, el);
  openOverlays.add(close);
  document.addEventListener('keydown', onKey, true);
  return api;
}

/** Liste de choix. Résout la valeur choisie ou null. */
export function actionSheet(opts) {
  return new Promise((resolve) => {
    let chosen = null;
    const api = sheet({
      title: opts.title,
      onClose: () => resolve(chosen),
      content: h('div.menu-list', null, ...opts.options.filter(Boolean).map((option) =>
        h(`button.menu-item${option.danger ? '.danger' : ''}`, {
          onClick: () => { chosen = option.value; api.close(); },
        },
        option.icon ? h(`span.emblem${option.danger ? '.danger' : option.tone ? `.${option.tone}` : ''}`, null, icon(option.icon, 18)) : null,
        h('span.grow', null, h('div', null, option.label), option.hint ? h('div.muted', { style: { fontSize: '0.75rem' } }, option.hint) : null)))),
    });
  });
}

// ─── Chargement bloquant ────────────────────────────────────────────────────

/** Exécute une action avec un voile « En cours… » et affiche l'erreur éventuelle. */
export async function busy(task, label) {
  const el = h('div.busy', null, h('div.box', null, h('span.spinner'), label || t('common.working')));
  layer.appendChild(el);
  try {
    return await task();
  } finally {
    el.remove();
  }
}

// ─── États ──────────────────────────────────────────────────────────────────

export function emptyState({ icon: name = 'inbox', title, text, action, compact }) {
  return h(`div.empty${compact ? '.compact' : ''}`, null,
    h('div.art', null, emptyArt(name)),
    title ? h('h3', null, title) : null,
    text ? h('p', null, text) : null,
    action || null);
}

function emptyArt(name) {
  const wrap = h('div', { style: { position: 'relative', width: '4.5rem', height: '4.5rem', display: 'grid', placeItems: 'center' } });
  wrap.appendChild(h('div', { style: { position: 'absolute', inset: '0', borderRadius: '1.4rem', background: 'var(--ec-surface-3)', transform: 'rotate(-6deg)' } }));
  wrap.appendChild(h('div', { class: 'notebook', style: { position: 'absolute', inset: '0.35rem', borderRadius: '1.1rem', boxShadow: 'var(--ec-shadow-1), 0 0 0 1px var(--ec-line)' } }));
  const ic = icon(name, 26);
  ic.style.position = 'relative';
  ic.style.color = 'var(--ec-accent)';
  wrap.appendChild(ic);
  return wrap;
}

export function errorState(err, retry) {
  const code = err && err.code ? err.code : 'unknown';
  if (err && !err.code) console.error(err);
  return emptyState({
    icon: code === 'network' || code === 'timeout' ? 'refresh' : 'alert',
    title: t('errors.title'),
    text: errorText(code),
    action: retry ? h('button.btn.secondary', { onClick: retry }, icon('refresh', 18), t('common.retry')) : null,
  });
}

export function skeletonList(count = 4) {
  const rows = [];
  for (let i = 0; i < count; i++) rows.push(h('div.skeleton.block', { style: { opacity: String(1 - i * 0.15) } }));
  return h('div.stack', { style: { paddingTop: '0.5rem' } }, h('div.skeleton.title'), ...rows);
}

export function skeletonDetail() {
  return h('div.stack', { style: { paddingTop: '0.5rem' } },
    h('div.skeleton.tall'),
    h('div.skeleton.line', { style: { width: '80%' } }),
    h('div.skeleton.line', { style: { width: '65%' } }),
    h('div.skeleton.block'),
    h('div.skeleton.block'));
}

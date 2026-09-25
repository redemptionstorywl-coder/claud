/**
 * Construction du DOM — SANS innerHTML.
 *
 * Tout texte (titres de cours, réponses d'élèves, messages de professeurs...) est inséré via
 * des nœuds texte : aucune injection HTML/JS n'est possible, même si un contenu malveillant
 * a été enregistré en base. C'est essentiel dans une NUI qui peut appeler les callbacks du jeu.
 *
 *   h('div.card.pad', { onClick: fn }, h('h3', null, titre), 'texte')
 */

const SVG_NS = 'http://www.w3.org/2000/svg';

function applyProps(el, props) {
  if (!props) return;
  for (const key of Object.keys(props)) {
    const value = props[key];
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class' || key === 'className') {
      addClass(el, value);
    } else if (key === 'style') {
      if (typeof value === 'string') el.setAttribute('style', value);
      else Object.assign(el.style, value);
    } else if (key === 'dataset') {
      Object.assign(el.dataset, value);
    } else if (key === 'ref') {
      value(el);
    } else if (key.length > 2 && key[0] === 'o' && key[1] === 'n' && typeof value === 'function') {
      el.addEventListener(key.slice(2).toLowerCase(), value);
    } else if (key === 'text') {
      el.textContent = String(value);
    } else if (key === 'value' && ('value' in el)) {
      el.value = value;
    } else if (key === 'checked' || key === 'disabled' || key === 'selected' || key === 'readOnly' || key === 'autofocus') {
      el[key] = !!value;
    } else if (value === true) {
      el.setAttribute(key, '');
    } else {
      el.setAttribute(key, String(value));
    }
  }
}

function addClass(el, value) {
  if (!value) return;
  if (typeof value === 'string') {
    value.split(/\s+/).forEach((c) => c && el.classList.add(c));
  } else if (Array.isArray(value)) {
    value.forEach((c) => addClass(el, c));
  } else if (typeof value === 'object') {
    Object.keys(value).forEach((c) => { if (value[c]) el.classList.add(c); });
  }
}

export function append(el, children) {
  for (const child of children) {
    if (child === null || child === undefined || child === false || child === true) continue;
    if (Array.isArray(child)) append(el, child);
    else if (child instanceof Node) el.appendChild(child);
    else el.appendChild(document.createTextNode(String(child)));
  }
  return el;
}

/** Crée un élément HTML. `tag` accepte la notation « div.classe1.classe2 ». */
export function h(tag, props, ...children) {
  const parts = tag.split('.');
  const el = document.createElement(parts[0] || 'div');
  for (let i = 1; i < parts.length; i++) if (parts[i]) el.classList.add(parts[i]);
  applyProps(el, props);
  return append(el, children);
}

/** Crée un élément SVG. */
export function s(tag, attrs, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  if (attrs) {
    for (const key of Object.keys(attrs)) {
      if (attrs[key] === undefined || attrs[key] === null) continue;
      if (key === 'class') el.setAttribute('class', attrs[key]);
      else el.setAttribute(key, String(attrs[key]));
    }
  }
  for (const child of children) if (child) el.appendChild(child);
  return el;
}

export function clear(el) {
  while (el.firstChild) el.removeChild(el.firstChild);
  return el;
}

export function replace(el, ...children) {
  clear(el);
  return append(el, children);
}

/** Initiales pour les avatars. */
/**
 * Fait défiler le corps de l'écran jusqu'à `el`. N'utilise pas scrollIntoView : celui-ci
 * ferait aussi défiler les conteneurs en overflow:hidden (écran, cadre du téléphone).
 */
export function scrollToEl(el, offset = 12) {
  const body = el && el.closest && el.closest('.screen-body');
  if (!body) return;
  const top = body.scrollTop + el.getBoundingClientRect().top - body.getBoundingClientRect().top - offset;
  body.scrollTo({ top: Math.max(0, top), behavior: 'smooth' });
}

export function initials(name) {
  return String(name || '?')
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0].toUpperCase())
    .join('');
}

/** Anti-rebond. */
export function debounce(fn, ms) {
  let timer = null;
  const wrapped = (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
  wrapped.flush = (...args) => { clearTimeout(timer); fn(...args); };
  wrapped.cancel = () => clearTimeout(timer);
  return wrapped;
}

export function uid() {
  return Math.random().toString(36).slice(2, 10);
}

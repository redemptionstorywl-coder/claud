/**
 * Traductions de l'interface. Langue choisie par Config.Locale (fr par défaut).
 * t('course.start')  •  t('time.minutes', { n: 5 })  •  tn('course.sections', 3)
 */
import fr from '../i18n/fr.js';
import en from '../i18n/en.js';

const DICTS = { fr, en };
let dict = fr;
let lang = 'fr';

export function setLocale(code) {
  lang = DICTS[code] ? code : 'fr';
  dict = DICTS[lang];
  document.documentElement.lang = lang;
}

export function locale() {
  return lang;
}

function lookup(key) {
  const parts = key.split('.');
  let cur = dict;
  for (const p of parts) {
    if (cur == null) break;
    cur = cur[p];
  }
  if (cur == null && dict !== fr) {
    cur = fr;
    for (const p of parts) {
      if (cur == null) break;
      cur = cur[p];
    }
  }
  return cur;
}

export function t(key, vars) {
  let text = lookup(key);
  if (typeof text !== 'string') return key;
  if (vars) {
    text = text.replace(/\{(\w+)\}/g, (_, name) => (vars[name] !== undefined && vars[name] !== null ? String(vars[name]) : ''));
  }
  return text;
}

/** Pluriel : clé.one / clé.other (fr : 0 et 1 au singulier). */
export function tn(key, n, vars) {
  const entry = lookup(key);
  if (!entry || typeof entry !== 'object') return t(key, Object.assign({ n }, vars));
  const singular = lang === 'fr' ? n < 2 : n === 1;
  const text = singular ? entry.one : entry.other;
  return String(text || '').replace(/\{(\w+)\}/g, (_, name) => {
    if (name === 'n') return String(n);
    return vars && vars[name] !== undefined ? String(vars[name]) : '';
  });
}

/** Message lisible pour un code d'erreur serveur. */
export function errorText(code) {
  const text = lookup(`errors.${code}`);
  return typeof text === 'string' ? text : t('errors.unknown');
}

/**
 * État global léger de l'application (profil, badges, réglages) + évènements.
 */
const listeners = {};

export const store = {
  boot: null,        // configuration envoyée par le client (nom, couleurs, langue)
  profile: null,     // profil résolu par le serveur (lecture seule)
  settings: null,    // réglages pédagogiques exposés par le serveur
  classes: [],       // classes actives (professeurs / admin)
  unread: 0,
  dashboard: null,
};

export function on(event, fn) {
  (listeners[event] = listeners[event] || []).push(fn);
  return () => {
    listeners[event] = (listeners[event] || []).filter((f) => f !== fn);
  };
}

export function emit(event, value) {
  (listeners[event] || []).forEach((fn) => {
    try { fn(value); } catch (e) { console.error(e); }
  });
}

export function setUnread(n) {
  store.unread = Math.max(0, n | 0);
  emit('unread', store.unread);
}

export function role() {
  return store.profile ? store.profile.role : 'student';
}

export function isStaff() {
  return role() === 'teacher' || role() === 'admin';
}

export function isAdmin() {
  return role() === 'admin';
}

export function can(capability) {
  const caps = (store.profile && store.profile.capabilities) || [];
  return caps.indexOf(capability) !== -1 || caps.indexOf('admin') !== -1;
}

/** Stockage local tolérant (brouillons de l'éditeur, préférences d'affichage). */
export const local = {
  get(key, fallback) {
    try {
      const raw = localStorage.getItem(`ec:${key}`);
      return raw === null ? fallback : JSON.parse(raw);
    } catch (e) {
      return fallback;
    }
  },
  set(key, value) {
    try {
      if (value === undefined || value === null) localStorage.removeItem(`ec:${key}`);
      else localStorage.setItem(`ec:${key}`, JSON.stringify(value));
    } catch (e) { /* quota ou stockage indisponible */ }
  },
};

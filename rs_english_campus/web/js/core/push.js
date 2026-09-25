/**
 * Évènements temps réel (nouvelle notification, suivi en direct, copie rendue...).
 *
 * Sources possibles, dédoublonnées par identifiant de message (mid) :
 *   • window.postMessage : sd-phone (sendCustomAppMessage) ou SendNUIMessage
 *   • BroadcastChannel   : relais de la page pont (web/bridge.html) vers toutes les instances
 *   • EventSource        : serveur de développement hors jeu
 */
import { env } from './env.js';

const listeners = new Map();
const seen = [];

function dispatch(message) {
  if (!message || typeof message !== 'object' || message.action !== 'ec:push') return;
  if (message.mid) {
    if (seen.indexOf(message.mid) !== -1) return;
    seen.push(message.mid);
    if (seen.length > 300) seen.shift();
  }
  const run = (fn) => { try { fn(message.data || {}, message.kind); } catch (e) { console.error('[push]', e); } };
  (listeners.get(message.kind) || []).forEach(run);
  (listeners.get('*') || []).forEach(run);
}

/** Abonnement à un type d'évènement ('*' = tous). Retourne la fonction de désabonnement. */
export function onPush(kind, fn) {
  if (!listeners.has(kind)) listeners.set(kind, []);
  listeners.get(kind).push(fn);
  return () => {
    const list = listeners.get(kind) || [];
    const i = list.indexOf(fn);
    if (i !== -1) list.splice(i, 1);
  };
}

export function startPush() {
  window.addEventListener('message', (e) => {
    const data = e.data;
    if (data && typeof data === 'object') dispatch(data);
  });
  try {
    const channel = new BroadcastChannel(`${env.resource}:push`);
    channel.onmessage = (e) => dispatch(e.data);
  } catch (e) { /* BroadcastChannel indisponible : les autres canaux suffisent */ }
  if (env.dev && window.EventSource) {
    const source = new EventSource(`/events?as=${encodeURIComponent(env.devAs)}`);
    source.onmessage = (e) => { try { dispatch(JSON.parse(e.data)); } catch (err) { /* ignoré */ } };
  }
}

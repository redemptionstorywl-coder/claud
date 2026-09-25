/**
 * Transport vers le client Lua (et donc le serveur).
 *
 *   rpc('course:get', { id: 12 })  →  fetch https://<ressource>/ec:rpc  →  client.lua  →  serveur
 *
 * L'interface n'envoie QUE des intentions (action + données saisies). Identité, rôle, classe,
 * points et notes sont toujours déterminés par le serveur.
 */
import { env } from './env.js';

export class RpcError extends Error {
  constructor(code, detail) {
    super(code);
    this.code = code || 'unknown';
    this.detail = detail;
  }
}

let serverOffset = 0;

/** Décalage (ms) entre l'horloge du serveur et celle du joueur, pour les chronomètres. */
export function serverNow() {
  return Date.now() + serverOffset;
}

export function syncServerTime(serverSeconds) {
  if (typeof serverSeconds === 'number') serverOffset = serverSeconds * 1000 - Date.now();
}

function parseBody(text) {
  if (!text) return null;
  let value = JSON.parse(text);
  // Le client Lua renvoie la réponse du serveur telle quelle (chaîne JSON) : double décodage si besoin.
  if (typeof value === 'string') {
    try { value = JSON.parse(value); } catch (e) { /* valeur texte simple */ }
  }
  return value;
}

async function devFetch(event, data) {
  const url = `/nui/${encodeURIComponent(event)}?as=${encodeURIComponent(env.devAs)}`;
  const resp = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data || {}) });
  return parseBody(await resp.text());
}

/** Appel brut d'un callback NUI du client. */
export async function nui(event, data = {}) {
  if (env.dev) return devFetch(event, data);
  const resp = await fetch(`https://${env.resource}/${event}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data),
  });
  return parseBody(await resp.text());
}

/** Requête métier vers le serveur. Lève RpcError(code) en cas de refus. */
export async function rpc(action, payload = {}) {
  let res;
  try {
    res = await nui('ec:rpc', { a: action, p: JSON.stringify(payload) });
  } catch (e) {
    throw new RpcError('network');
  }
  if (!res || typeof res !== 'object') throw new RpcError('network');
  if (res.ok !== true) throw new RpcError(res.error, res.detail);
  const data = res.data;
  if (data && typeof data === 'object' && typeof data.serverNow === 'number') syncServerTime(data.serverNow);
  return data;
}

/** Tableau garanti (le JSON Lua encode les tables vides en []). */
export function arr(value) {
  if (Array.isArray(value)) return value;
  if (value && typeof value === 'object') return Object.values(value);
  return [];
}

/** Objet garanti ([] vide → {}). */
export function obj(value) {
  if (value && typeof value === 'object' && !Array.isArray(value)) return value;
  return {};
}

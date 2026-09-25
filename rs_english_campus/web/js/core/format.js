/**
 * Formats d'affichage : dates (fuseau du joueur), durées, notes, pourcentages.
 * Les dates reçues du serveur sont des timestamps UNIX en secondes (UTC).
 */
import { t, tn, locale } from './i18n.js';
import { serverNow } from './nui.js';

const tag = () => (locale() === 'en' ? 'en-GB' : 'fr-FR');

export function num(value, decimals = 2) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return '—';
  const n = Number(value);
  return n.toLocaleString(tag(), { maximumFractionDigits: decimals, minimumFractionDigits: 0 });
}

export function grade(value, max) {
  if (value === null || value === undefined) return '—';
  return `${num(value)}/${num(max)}`;
}

export function percent(value) {
  if (value === null || value === undefined) return '—';
  return `${Math.round(Number(value))} %`.replace(' %', locale() === 'en' ? '%' : ' %');
}

/** « 14 min 32 » */
export function duration(seconds) {
  if (seconds === null || seconds === undefined) return '—';
  const s = Math.max(0, Math.round(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  if (h > 0) return t('time.hm', { h, m: String(m).padStart(2, '0') });
  if (m > 0) return t('time.ms', { m, s: String(r).padStart(2, '0') });
  return t('time.s', { s: r });
}

/** Minutes → « 30 min » / « 1 h 30 ». */
export function minutes(n) {
  if (!n) return t('time.unlimited');
  if (n < 60) return t('time.minutes', { n });
  const h = Math.floor(n / 60);
  const m = n % 60;
  return m ? t('time.hm', { h, m: String(m).padStart(2, '0') }) : t('time.hours', { n: h });
}

export function date(ts, withYear) {
  if (!ts) return '—';
  return new Date(ts * 1000).toLocaleDateString(tag(), { day: 'numeric', month: 'long', year: withYear ? 'numeric' : undefined });
}

export function shortDate(ts) {
  if (!ts) return '—';
  return new Date(ts * 1000).toLocaleDateString(tag(), { day: '2-digit', month: '2-digit' });
}

export function time(ts) {
  if (!ts) return '—';
  return new Date(ts * 1000).toLocaleTimeString(tag(), { hour: '2-digit', minute: '2-digit' });
}

/** « aujourd'hui 18:00 », « demain 09:30 », « 12 mars 14:00 » */
export function dateTime(ts) {
  if (!ts) return '—';
  const d = new Date(ts * 1000);
  const now = new Date(serverNow());
  const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((day(d) - day(now)) / 86400000);
  const hm = time(ts);
  if (diff === 0) return t('time.todayAt', { time: hm });
  if (diff === 1) return t('time.tomorrowAt', { time: hm });
  if (diff === -1) return t('time.yesterdayAt', { time: hm });
  return `${d.toLocaleDateString(tag(), { day: 'numeric', month: 'short' })} ${hm}`;
}

/** « il y a 5 min » */
export function ago(ts) {
  if (!ts) return '—';
  const diff = Math.max(0, Math.round(serverNow() / 1000 - ts));
  if (diff < 45) return t('time.justNow');
  if (diff < 3600) return tn('time.minutesAgo', Math.max(1, Math.round(diff / 60)));
  if (diff < 86400) return tn('time.hoursAgo', Math.round(diff / 3600));
  if (diff < 7 * 86400) return tn('time.daysAgo', Math.round(diff / 86400));
  return date(ts);
}

/** « dans 2 h », « dans 12 min » (échéances) */
export function until(ts) {
  const diff = Math.round(ts - serverNow() / 1000);
  if (diff <= 0) return t('time.now');
  if (diff < 3600) return t('time.inMinutes', { n: Math.max(1, Math.ceil(diff / 60)) });
  if (diff < 86400) return t('time.inHours', { n: Math.round(diff / 3600) });
  return t('time.inDays', { n: Math.round(diff / 86400) });
}

/** Chronomètre « 12:05 » / « 1:02:05 ». */
export function clock(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = String(s % 60).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${r}` : `${m}:${r}`;
}

/** Salutation selon l'heure du joueur. */
export function greeting() {
  const hour = new Date().getHours();
  if (hour < 5 || hour >= 18) return t('home.evening');
  return t('home.morning');
}

export function today() {
  const text = new Date(serverNow()).toLocaleDateString(tag(), { weekday: 'long', day: 'numeric', month: 'long' });
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** Convertit un timestamp en valeur d'<input type="datetime-local"> (heure locale). */
export function toLocalInput(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function fromLocalInput(value) {
  if (!value) return null;
  const ms = new Date(value).getTime();
  return Number.isNaN(ms) ? null : Math.round(ms / 1000);
}

/** Tonalité d'une note (couleur). */
export function gradeTone(value, max) {
  if (value === null || value === undefined || !max) return 'neutral';
  const ratio = value / max;
  if (ratio >= 0.8) return 'gold';
  if (ratio >= 0.5) return 'success';
  return 'danger';
}

/**
 * Composants réutilisables (progression, cartes de cours, notes, champs de formulaire...).
 */
import { h, s, initials } from '../core/dom.js';
import { icon } from '../core/icons.js';
import { t, tn } from '../core/i18n.js';
import * as f from '../core/format.js';
import { serverNow } from '../core/nui.js';

export const THEME_ICONS = {
  vocabulary: 'cards',
  grammar: 'grammar',
  conjugation: 'layers',
  comprehension: 'headphones',
  expression: 'chat',
};

export const EMBLEMS = ['book', 'grammar', 'chat', 'globe', 'pen', 'headphones', 'star', 'bulb', 'flag', 'clock', 'mic', 'music'];

export function themeLabel(theme) {
  return t(`themes.${theme || 'grammar'}`);
}

// ─── Progression ────────────────────────────────────────────────────────────

export function progressBar(pct, tone, size) {
  const value = Math.max(0, Math.min(100, Number(pct) || 0));
  const bar = h('i', { style: { width: '0%' } });
  const el = h(`div.progress${tone ? `.${tone}` : ''}${size ? `.${size}` : ''}`, { role: 'progressbar', 'aria-valuenow': String(Math.round(value)) }, bar);
  requestAnimationFrame(() => requestAnimationFrame(() => { bar.style.width = `${value}%`; }));
  return el;
}

/** Anneau de progression animé. */
export function progressRing(pct, opts = {}) {
  const size = opts.size || 64;
  const stroke = opts.stroke || 6;
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const value = Math.max(0, Math.min(100, Number(pct) || 0));
  const circle = s('circle', { class: 'value', cx: size / 2, cy: size / 2, r, fill: 'none', 'stroke-width': stroke, 'stroke-linecap': 'round', 'stroke-dasharray': c, 'stroke-dashoffset': c });
  const svg = s('svg', { width: `${size / 16}rem`, height: `${size / 16}rem`, viewBox: `0 0 ${size} ${size}` },
    s('circle', { class: 'track', cx: size / 2, cy: size / 2, r, fill: 'none', 'stroke-width': stroke }),
    circle);
  requestAnimationFrame(() => requestAnimationFrame(() => circle.setAttribute('stroke-dashoffset', String(c * (1 - value / 100)))));
  return h(`div.ring${opts.tone ? `.${opts.tone}` : ''}`, null, svg,
    h('div.label', null,
      h('b', { style: { fontSize: `${(opts.fontSize || size * 0.26) / 16}rem` } }, opts.text !== undefined ? opts.text : `${Math.round(value)}%`),
      opts.label ? h('span', null, opts.label) : null));
}

/** Segments (une case par question). states: 'done'|'ok'|'ko'|'part'|'current'|'' */
export function segments(states) {
  return h('div.segments', null, ...states.map((st) => h(`i${st ? `.${st}` : ''}`)));
}

// ─── Petits éléments ────────────────────────────────────────────────────────

export function badge(text, tone) {
  return h(`span.badge${tone ? `.${tone}` : ''}`, null, text);
}

export function emblem(name, opts = {}) {
  return h(`div.emblem${opts.size ? `.${opts.size}` : ''}${opts.tone ? `.${opts.tone}` : ''}`, null, icon(name || 'book', opts.iconSize || (opts.size === 'lg' ? 26 : opts.size === 'sm' ? 18 : 21)));
}

export function avatar(name, size) {
  return h(`div.avatar${size ? `.${size}` : ''}`, null, initials(name));
}

export function stat({ value, suffix, label, icon: ic, onClick, tone }) {
  return h(`div.stat${onClick ? '.clickable' : ''}${ic ? '' : '.no-ico'}`, { onClick },
    ic ? h(`div.ico${tone ? `.tone-${tone}` : ''}`, null, icon(ic, 20)) : null,
    h('div.v', null, value, suffix ? h('small', null, ` ${suffix}`) : null),
    h('div.l', null, label));
}

export function sectionHead(title, action) {
  return h('div.section-head', null, h('h2', null, title), action || null);
}

export function linkButton(label, onClick) {
  return h('button.link', { onClick }, label);
}

export function section(title, action, ...children) {
  return h('section.section', null, sectionHead(title, action), ...children);
}

export function listRow({ leading, title, subtitle, trailing, onClick, chevron = !!onClick }) {
  return h(onClick ? 'button.list-row' : 'div.list-row', { onClick },
    leading || null,
    h('div.main', null, h('div.t', null, title), subtitle ? h('div.s', null, subtitle) : null),
    trailing || chevron ? h('div.trail', null, trailing || null, chevron ? icon('chevronRight', 18, 'chev') : null) : null);
}

export function notice(text, tone, ic) {
  return h(`div.notice${tone ? `.${tone}` : ''}`, null, icon(ic || (tone === 'danger' ? 'alert' : tone === 'warn' ? 'alert' : tone === 'success' ? 'checkCircle' : 'info'), 18), h('div', null, text));
}

// ─── Notes ──────────────────────────────────────────────────────────────────

/** Note entourée au « stylo rouge » (animation de tracé). */
export function penGrade(value, max, opts = {}) {
  const tone = f.gradeTone(value, max);
  const path = s('path', {
    class: 'pen',
    d: 'M18 52C12 28 58 10 104 14c42 3 64 20 58 40-7 22-64 30-104 22C28 70 6 58 22 38c9-11 30-18 52-20',
    fill: 'none',
    'stroke-width': 3.2,
    'stroke-linecap': 'round',
    pathLength: 100,
  });
  return h(`div.pen-grade.${tone}${opts.small ? '.small' : ''}`, null,
    s('svg', { viewBox: '0 0 176 92', class: 'pen-svg', preserveAspectRatio: 'none' }, path),
    h('div.value', null,
      h('span.n', null, f.num(value)),
      h('span.sep', null, '/'),
      h('span.max', null, f.num(max))));
}

export function gradeChip(value, max) {
  if (value === null || value === undefined) return badge(t('results.pending'), '');
  const tone = f.gradeTone(value, max);
  return h(`span.grade-chip.${tone}`, null, f.grade(value, max));
}

// ─── Chronomètre ────────────────────────────────────────────────────────────

/** Compte à rebours basé sur l'horloge serveur. onEnd appelé une fois à 0. */
export function countdown(expiresAt, { onTick, onEnd, warnAt = 60 } = {}) {
  const el = h('span.countdown.tnum');
  let ended = false;
  const tick = () => {
    const left = expiresAt - serverNow() / 1000;
    el.textContent = f.clock(left);
    el.classList.toggle('warn', left <= warnAt);
    if (onTick) onTick(left);
    if (left <= 0 && !ended) {
      ended = true;
      if (onEnd) setTimeout(onEnd, 0);
    }
  };
  tick();
  el._timer = setInterval(tick, 500);
  el.stop = () => clearInterval(el._timer);
  return el;
}

// ─── Cartes ─────────────────────────────────────────────────────────────────

const STATE_BADGE = {
  new: ['courses.state.new', 'accent'],
  started: ['courses.state.started', 'gold'],
  completed: ['courses.state.completed', 'success'],
};

export function courseCard(course, onClick) {
  const [labelKey, tone] = STATE_BADGE[course.state] || STATE_BADGE.new;
  return h('button.card.pad.clickable.course-card', { onClick },
    h('div.row.top', null,
      emblem(course.emblem, { tone: course.state === 'completed' ? 'success' : '' }),
      h('div.grow', null,
        h('div.row.between', null, h('span.overline', null, themeLabel(course.theme)), badge(t(labelKey), tone)),
        h('div.course-title.serif', null, course.title),
        h('div.meta', null,
          h('span', null, icon('pen', 13), course.teacher),
          h('span', null, icon('clock', 13), f.minutes(course.duration)),
          h('span', null, icon('layers', 13), tn('courses.parts', course.total || 0))))),
    course.state !== 'new'
      ? h('div.row', { style: { marginTop: '0.75rem' } }, h('div.grow', null, progressBar(course.percent, course.state === 'completed' ? 'success' : '')), h('span.pct.tnum', null, `${course.percent}%`))
      : null);
}

export function assessmentStatus(a) {
  if (a.state === 'in_progress') return badge(t('assessments.state.in_progress'), 'gold');
  if (a.state === 'done') return badge(t('assessments.state.done'), 'success');
  if (a.state === 'pending') return badge(t('assessments.state.pending'), '');
  if (a.window === 'upcoming') return badge(t('assessments.window.upcoming'), '');
  if (a.window === 'closed') return badge(t('assessments.window.closed'), '');
  return h('span.badge.danger', null, h('span.pulse-dot'), t('assessments.window.open'));
}

export function assessmentCard(a, onClick) {
  let when = null;
  if (a.window === 'upcoming' && a.opensAt) when = t('assessments.opens', { when: f.dateTime(a.opensAt) });
  else if (a.window === 'open' && a.closesAt) when = t('assessments.closesIn', { when: f.until(a.closesAt) });
  else if (a.window === 'closed' && a.closesAt) when = t('assessments.closedOn', { when: f.date(a.closesAt) });
  const grade = a.best || (a.last && a.last.grade !== undefined ? a.last : null);
  return h('button.card.pad.clickable.assessment-card', { onClick },
    h('div.row.top', null,
      emblem('clipboard', { tone: a.state === 'done' ? 'success' : a.window === 'open' ? 'danger' : 'neutral' }),
      h('div.grow', null,
        h('div.row.between', null, h('span.overline', null, themeLabel(a.theme)), assessmentStatus(a)),
        h('div.course-title.serif', null, a.title),
        h('div.meta', null,
          h('span', null, icon('help', 13), tn('assessments.questions', a.questionCount || 0)),
          h('span', null, icon('timer', 13), f.minutes(a.duration)),
          when ? h('span', null, icon('calendar', 13), when) : null)),
      grade && grade.grade !== undefined && grade.grade !== null ? gradeChip(grade.grade, grade.gradeMax) : null));
}

// ─── Formulaires ────────────────────────────────────────────────────────────

export function field(label, input, opts = {}) {
  return h(`div.field${opts.invalid ? '.invalid' : ''}`, null,
    label ? h('label', null, label) : null,
    input,
    opts.hint ? h('div.hint', null, opts.hint) : null);
}

export function textInput({ value = '', placeholder = '', max = 200, onInput, className = '', type = 'text', autofocus }) {
  const el = h(`input.input${className ? `.${className}` : ''}`, { type, value, placeholder, maxlength: max, autofocus });
  if (onInput) el.addEventListener('input', () => onInput(el.value));
  return el;
}

export function textArea({ value = '', placeholder = '', max = 2000, rows = 4, onInput, counter = false }) {
  const el = h('textarea.input', { placeholder, maxlength: max, rows });
  el.value = value;
  if (!counter) {
    if (onInput) el.addEventListener('input', () => onInput(el.value));
    return el;
  }
  const count = h('div.counter');
  const paint = () => { count.textContent = `${el.value.length} / ${max}`; };
  el.addEventListener('input', () => { paint(); if (onInput) onInput(el.value); });
  paint();
  return h('div.stack.tight', null, el, count);
}

export function select(options, value, onChange) {
  const el = h('select.input', { onChange: () => onChange(el.value) },
    ...options.map((o) => h('option', { value: o.value, selected: String(o.value) === String(value) }, o.label)));
  return el;
}

export function segmented(options, value, onChange) {
  const wrap = h('div.segmented', { role: 'tablist' });
  const paint = (current) => {
    Array.from(wrap.children).forEach((btn, i) => btn.classList.toggle('on', String(options[i].value) === String(current)));
  };
  options.forEach((o) => {
    wrap.appendChild(h('button', {
      type: 'button',
      onClick: () => { paint(o.value); onChange(o.value); },
    }, o.label, o.count !== undefined ? h('span.n', null, String(o.count)) : null));
  });
  paint(value);
  return wrap;
}

/** Puces sélectionnables (multi ou simple). */
export function chipSelect(options, selected, onChange, { multi = true } = {}) {
  const set = new Set((selected || []).map(String));
  const wrap = h('div.chips');
  const render = () => {
    Array.from(wrap.children).forEach((chip, i) => chip.classList.toggle('on', set.has(String(options[i].value))));
  };
  options.forEach((o) => {
    wrap.appendChild(h('button.chip', {
      type: 'button',
      onClick: () => {
        const key = String(o.value);
        if (multi) {
          if (set.has(key)) set.delete(key); else set.add(key);
        } else {
          set.clear();
          set.add(key);
        }
        render();
        onChange(options.filter((x) => set.has(String(x.value))).map((x) => x.value));
      },
    }, o.label));
  });
  render();
  return wrap;
}

export function toggle(on, onChange) {
  const el = h('button.switch', { type: 'button', role: 'switch', 'aria-checked': String(!!on) });
  let state = !!on;
  el.classList.toggle('on', state);
  el.addEventListener('click', (e) => {
    e.stopPropagation();
    state = !state;
    el.classList.toggle('on', state);
    el.setAttribute('aria-checked', String(state));
    onChange(state);
  });
  return el;
}

export function toggleRow(title, subtitle, on, onChange) {
  const sw = toggle(on, onChange);
  return h('div.toggle-row', { onClick: () => sw.click() },
    h('div', null, h('div.t', null, title), subtitle ? h('div.s', null, subtitle) : null), sw);
}

export function stepper(value, { min = 0, max = 999, step = 1, format, onChange }) {
  let current = value;
  const val = h('span.val', null, format ? format(current) : String(current));
  const set = (v) => {
    current = Math.max(min, Math.min(max, v));
    val.textContent = format ? format(current) : String(current);
    onChange(current);
  };
  return h('div.stepper', null,
    h('button', { type: 'button', onClick: () => set(current - step), 'aria-label': '-' }, icon('minus', 18)),
    val,
    h('button', { type: 'button', onClick: () => set(current + step), 'aria-label': '+' }, icon('plus', 18)));
}

/** Mini-graphique d'évolution des notes (sur le barème). */
export function sparkline(values, max, opts = {}) {
  const w = opts.width || 280;
  const hgt = opts.height || 72;
  if (!values.length) return h('div');
  const pad = 6;
  const step = values.length > 1 ? (w - pad * 2) / (values.length - 1) : 0;
  const pts = values.map((v, i) => [pad + i * step, hgt - pad - (Math.max(0, Math.min(max, v)) / max) * (hgt - pad * 2)]);
  const line = pts.map((p, i) => `${i ? 'L' : 'M'}${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(' ');
  const area = `${line} L${pts[pts.length - 1][0].toFixed(1)} ${hgt - pad} L${pts[0][0].toFixed(1)} ${hgt - pad} Z`;
  const mid = hgt - pad - 0.5 * (hgt - pad * 2);
  return s('svg', { viewBox: `0 0 ${w} ${hgt}`, class: 'sparkline', preserveAspectRatio: 'none' },
    s('line', { x1: pad, x2: w - pad, y1: mid, y2: mid, class: 'mid' }),
    s('path', { d: area, class: 'area' }),
    s('path', { d: line, class: 'line' }),
    ...pts.map((p) => s('circle', { cx: p[0], cy: p[1], r: 3, class: 'pt' })));
}

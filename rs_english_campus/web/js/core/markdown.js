/**
 * Mise en forme des textes de cours — syntaxe légère, rendu 100 % DOM (aucun HTML interprété).
 *
 *   # Titre            ## Sous-titre
 *   **gras**  *italique*  __souligné__  ==surligné==  `code`   ___ (trou à compléter)
 *   - liste            1. liste numérotée
 *   > encadré « À retenir »          !> encadré « Exemple »
 *   ---                (séparateur)
 */
import { h } from './dom.js';

const INLINE = [
  // « ___ » : trou à compléter (très courant dans les consignes d'anglais), jamais un soulignement.
  { re: /_{3,}/, blank: true },
  { re: /\*\*(.+?)\*\*/, tag: 'strong' },
  { re: /(?<!_)__(?!_)(.+?)(?<!_)__(?!_)/, tag: 'u' },
  { re: /==(.+?)==/, tag: 'mark' },
  { re: /`(.+?)`/, tag: 'code' },
  { re: /\*(.+?)\*/, tag: 'em' },
];

/** Convertit une ligne en nœuds (texte + balises inline autorisées). */
export function inline(text) {
  const nodes = [];
  let rest = String(text || '');
  while (rest.length) {
    let best = null;
    for (const rule of INLINE) {
      const m = rule.re.exec(rest);
      if (m && (!best || m.index < best.m.index)) best = { m, rule };
    }
    if (!best) {
      nodes.push(rest);
      break;
    }
    if (best.m.index > 0) nodes.push(rest.slice(0, best.m.index));
    if (best.rule.blank) nodes.push(h('span.md-blank', { 'aria-label': '___' }));
    else nodes.push(h(best.rule.tag, null, ...(best.rule.tag === 'code' ? [best.m[1]] : inline(best.m[1]))));
    rest = rest.slice(best.m.index + best.m[0].length);
  }
  return nodes;
}

function withBreaks(lines) {
  const out = [];
  lines.forEach((line, i) => {
    if (i > 0) out.push(h('br'));
    out.push(...inline(line));
  });
  return out;
}

/** Rend un texte complet en blocs DOM. */
export function renderMarkdown(source) {
  const root = h('div.md');
  const lines = String(source || '').replace(/\r\n?/g, '\n').split('\n');
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();
    if (!trimmed) { i++; continue; }

    if (/^---+$/.test(trimmed)) {
      root.appendChild(h('hr'));
      i++;
      continue;
    }
    const heading = /^(#{1,3})\s+(.*)$/.exec(trimmed);
    if (heading) {
      root.appendChild(h(heading[1].length === 1 ? 'h3' : 'h4', null, ...inline(heading[2])));
      i++;
      continue;
    }
    if (/^(!>|>)\s?/.test(trimmed)) {
      const example = trimmed.startsWith('!>');
      const block = [];
      while (i < lines.length && /^(!>|>)\s?/.test(lines[i].trim())) {
        block.push(lines[i].trim().replace(/^(!>|>)\s?/, ''));
        i++;
      }
      root.appendChild(h(`aside.callout${example ? '.example' : ''}`, null, h('p', null, ...withBreaks(block))));
      continue;
    }
    if (/^[-*•]\s+/.test(trimmed)) {
      const ul = h('ul');
      while (i < lines.length && /^[-*•]\s+/.test(lines[i].trim())) {
        ul.appendChild(h('li', null, ...inline(lines[i].trim().replace(/^[-*•]\s+/, ''))));
        i++;
      }
      root.appendChild(ul);
      continue;
    }
    if (/^\d+[.)]\s+/.test(trimmed)) {
      const ol = h('ol');
      while (i < lines.length && /^\d+[.)]\s+/.test(lines[i].trim())) {
        ol.appendChild(h('li', null, ...inline(lines[i].trim().replace(/^\d+[.)]\s+/, ''))));
        i++;
      }
      root.appendChild(ol);
      continue;
    }
    const para = [];
    while (i < lines.length && lines[i].trim() && !/^(#{1,3}\s|[-*•]\s|\d+[.)]\s|>|!>|---+$)/.test(lines[i].trim())) {
      para.push(lines[i]);
      i++;
    }
    root.appendChild(h('p', null, ...withBreaks(para)));
  }
  return root;
}

/** Texte brut (aperçus, notifications). */
export function plainText(source, max = 140) {
  // Retire uniquement le balisage : « well-known », « Wait! » et les trous « ___ » sont conservés.
  const text = String(source || '')
    .split('\n')
    .map((line) => line.replace(/^\s*---+\s*$/, '').replace(/^\s*(#{1,3}\s+|!?>\s?|[-*•]\s+)/, ''))
    .join(' ')
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/(?<!_)__(?!_)(.+?)(?<!_)__(?!_)/g, '$1')
    .replace(/==(.+?)==/g, '$1')
    .replace(/`(.+?)`/g, '$1')
    .replace(/\*(.+?)\*/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

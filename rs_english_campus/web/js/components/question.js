/**
 * Affichage interactif d'une question (tous les types) + affichage de la correction.
 *
 *   const view = questionView(q, { value, onChange })
 *   view.getAnswer()  view.isAnswered()  view.showFeedback(feedback)  view.lock()
 *
 * L'élève ne reçoit jamais la solution avant d'avoir répondu : `feedback` vient du serveur
 * APRÈS la validation (exercices) ou lors de la consultation d'une copie corrigée.
 */
import { h, clear, uid } from '../core/dom.js';
import { icon } from '../core/icons.js';
import { t, tn } from '../core/i18n.js';
import { renderMarkdown, inline } from '../core/markdown.js';
import { arr, obj } from '../core/nui.js';
import * as f from '../core/format.js';

const LETTERS = 'ABCDEFGH';

export const TYPE_ICONS = {
  mcq: 'choice',
  truefalse: 'toggle',
  translation: 'translate',
  short_answer: 'help',
  fill_blank: 'blank',
  word_order: 'shuffle',
  matching: 'link',
  open: 'pen',
};

export function typeLabel(type) {
  return t(`qtypes.${type}`);
}

function promptBlock(q) {
  const text = q.prompt && q.prompt.trim() ? q.prompt : t(`qdefault.${q.type}`);
  const el = renderMarkdown(text);
  el.classList.add('q-prompt');
  return el;
}

function wordCount(text) {
  const words = String(text || '').trim().split(/\s+/).filter(Boolean);
  return words.length;
}

// ─────────────────────────────────────────────────────────────────────────────

export function questionView(q, opts = {}) {
  const state = { locked: false, answer: cloneAnswer(opts.value) };
  const root = h(`div.question.qt-${q.type}`); // « qt- » : ne pas entrer en collision avec .q-matching, .q-open…
  const body = h('div.q-body');
  const feedbackBox = h('div.q-feedback-slot');
  const changed = () => { if (opts.onChange) opts.onChange(api.getAnswer()); };

  if (opts.header !== false) {
    root.appendChild(h('div.q-head', null,
      h('span.q-type', null, icon(TYPE_ICONS[q.type] || 'help', 14), typeLabel(q.type)),
      opts.index !== undefined ? h('span.q-count', null, t('question.count', { n: opts.index + 1, total: opts.total })) : null,
      h('span.q-points', null, tn('question.points', q.points || 1, { n: f.num(q.points || 1) }))));
  }
  root.appendChild(promptBlock(q));
  root.appendChild(body);
  root.appendChild(feedbackBox);

  const builders = { mcq, truefalse, translation, short_answer: shortAnswer, fill_blank: fillBlank, word_order: wordOrder, matching, open };
  const impl = (builders[q.type] || shortAnswer)(q, state, body, changed);

  const api = {
    el: root,
    getAnswer: () => impl.get(),
    isAnswered: () => impl.answered(),
    lock() {
      state.locked = true;
      root.classList.add('locked');
      root.querySelectorAll('input, textarea, button.q-option, button.q-tile, button.q-token, button.q-slot, button.q-match').forEach((el) => { el.disabled = true; });
    },
    showFeedback(fb, options = {}) {
      api.lock();
      impl.feedback(obj(fb));
      clear(feedbackBox);
      if (options.panel !== false) feedbackBox.appendChild(feedbackPanel(q, fb, options));
    },
    focus() { if (impl.focus) impl.focus(); },
  };
  return api;
}

function cloneAnswer(value) {
  if (!value || typeof value !== 'object') return {};
  try { return JSON.parse(JSON.stringify(value)); } catch (e) { return {}; }
}

// ─── QCM ─────────────────────────────────────────────────────────────────────

function mcq(q, state, body, changed) {
  const options = arr(q.options);
  const multiple = !!q.multiple;
  const selected = new Set(multiple ? arr(state.answer.choices) : state.answer.choice ? [state.answer.choice] : []);
  const buttons = {};
  const list = h('div.q-options', { role: multiple ? 'group' : 'radiogroup' });
  options.forEach((o, i) => {
    const btn = h('button.q-option', {
      type: 'button',
      role: multiple ? 'checkbox' : 'radio',
      onClick: () => {
        if (state.locked) return;
        if (multiple) {
          if (selected.has(o.id)) selected.delete(o.id); else selected.add(o.id);
        } else {
          selected.clear();
          selected.add(o.id);
        }
        paint();
        changed();
      },
    }, h('span.letter', null, LETTERS[i] || '?'), h('span.text', null, ...inline(o.text)), h('span.mark'));
    buttons[o.id] = btn;
    list.appendChild(btn);
  });
  const paint = () => {
    Object.keys(buttons).forEach((id) => {
      buttons[id].classList.toggle('selected', selected.has(id));
      buttons[id].setAttribute('aria-checked', String(selected.has(id)));
    });
  };
  paint();
  if (multiple) body.appendChild(h('div.q-hint', null, icon('info', 14), t('question.multipleHint')));
  body.appendChild(list);
  return {
    get: () => (multiple ? { choices: Array.from(selected) } : (selected.size ? { choice: Array.from(selected)[0] } : {})),
    answered: () => selected.size > 0,
    feedback(fb) {
      const correct = new Set(arr(obj(fb.solution).correct));
      Object.keys(buttons).forEach((id) => {
        const btn = buttons[id];
        if (correct.has(id)) {
          btn.classList.add('is-correct');
          btn.querySelector('.mark').replaceWith(h('span.mark', null, icon('check', 16)));
        } else if (selected.has(id)) {
          btn.classList.add('is-wrong');
          btn.querySelector('.mark').replaceWith(h('span.mark', null, icon('close', 16)));
        } else {
          btn.classList.add('is-dim');
        }
      });
    },
  };
}

// ─── Vrai / Faux ─────────────────────────────────────────────────────────────

function truefalse(q, state, body, changed) {
  let value = typeof state.answer.value === 'boolean' ? state.answer.value : null;
  const tiles = {};
  const make = (v) => h('button.q-tile', {
    type: 'button',
    onClick: () => {
      if (state.locked) return;
      value = v;
      paint();
      changed();
    },
  }, h('span.q-tile-icon', null, icon(v ? 'check' : 'close', 22)), h('span.q-tile-label', null, t(v ? 'question.true' : 'question.false')), h('span.q-tile-en', null, v ? 'True' : 'False'));
  tiles.true = make(true);
  tiles.false = make(false);
  const paint = () => {
    tiles.true.classList.toggle('selected', value === true);
    tiles.false.classList.toggle('selected', value === false);
  };
  paint();
  body.appendChild(h('div.q-tiles', null, tiles.true, tiles.false));
  return {
    get: () => (value === null ? {} : { value }),
    answered: () => value !== null,
    feedback(fb) {
      const good = obj(fb.solution).value;
      [true, false].forEach((v) => {
        const tile = tiles[String(v)];
        if (v === good) tile.classList.add('is-correct');
        else if (v === value) tile.classList.add('is-wrong');
        else tile.classList.add('is-dim');
      });
    },
  };
}

// ─── Réponses écrites ────────────────────────────────────────────────────────

function writtenAnswer(state, body, changed, placeholder) {
  const input = h('input.input.lg.q-input', {
    type: 'text', value: state.answer.text || '', placeholder, maxlength: 300,
    autocomplete: 'off', autocorrect: 'off', autocapitalize: 'off', spellcheck: 'false',
  });
  input.addEventListener('input', changed);
  body.appendChild(input);
  return {
    input,
    get: () => ({ text: input.value }),
    answered: () => input.value.trim().length > 0,
    focus: () => input.focus({ preventScroll: true }),
    feedback(fb) {
      input.classList.add(fb.correct ? 'is-correct' : 'is-wrong');
      if (!fb.correct) {
        const answers = arr(obj(fb.solution).answers);
        if (answers.length) {
          body.appendChild(h('div.q-expected', null,
            h('span.label', null, t('question.expected')),
            h('b', null, answers[0]),
            answers.length > 1 ? h('span.alt', null, ` · ${t('question.alsoAccepted', { list: answers.slice(1, 4).join(', ') })}`) : null));
        }
      } else if (fb.typo) {
        const answers = arr(obj(fb.solution).answers);
        body.appendChild(h('div.q-expected.typo', null, h('span.label', null, t('question.spelling')), h('b', null, answers[0] || '')));
      }
    },
  };
}

function translation(q, state, body, changed) {
  const direction = q.direction === 'fr_en' ? 'fr_en' : 'en_fr';
  body.appendChild(h('div.q-source', null,
    h('span.q-dir', null, t(`question.dir.${direction}`)),
    h('div.q-source-text', null, q.source || '')));
  return writtenAnswer(state, body, changed, t(direction === 'fr_en' ? 'question.placeholderEn' : 'question.placeholderFr'));
}

function shortAnswer(q, state, body, changed) {
  return writtenAnswer(state, body, changed, t('question.placeholder'));
}

// ─── Texte à trous ───────────────────────────────────────────────────────────

function fillBlank(q, state, body, changed) {
  const parts = arr(q.parts);
  const blankCount = parts.filter((p) => p.b).length;
  const values = arr(state.answer.blanks).slice(0, blankCount);
  while (values.length < blankCount) values.push('');
  const bank = arr(q.bank);
  const slots = [];
  const sentence = h('div.q-sentence');

  if (bank.length) {
    // Banque de mots : on touche un mot pour remplir le premier trou libre.
    const used = new Array(bank.length).fill(false);
    values.forEach((v) => {
      const i = bank.findIndex((w, j) => !used[j] && w === v);
      if (i !== -1) used[i] = true;
    });
    const chips = [];
    const paint = () => {
      slots.forEach((slot, i) => {
        slot.textContent = values[i] || ' ';
        slot.classList.toggle('filled', !!values[i]);
      });
      chips.forEach((chip, j) => chip.classList.toggle('used', used[j]));
    };
    parts.forEach((p) => {
      if (p.t !== undefined) sentence.appendChild(h('span', null, p.t));
      else {
        const index = slots.length;
        const slot = h('button.q-slot', {
          type: 'button',
          onClick: () => {
            if (state.locked || !values[index]) return;
            const j = bank.findIndex((w, k) => used[k] && w === values[index]);
            if (j !== -1) used[j] = false;
            values[index] = '';
            paint();
            changed();
          },
        });
        slots.push(slot);
        sentence.appendChild(slot);
      }
    });
    const bankEl = h('div.q-bank');
    bank.forEach((word, j) => {
      const chip = h('button.q-token', {
        type: 'button',
        onClick: () => {
          if (state.locked || used[j]) return;
          const free = values.findIndex((v) => !v);
          if (free === -1) return;
          values[free] = word;
          used[j] = true;
          paint();
          changed();
        },
      }, word);
      chips.push(chip);
      bankEl.appendChild(chip);
    });
    body.appendChild(sentence);
    body.appendChild(bankEl);
    paint();
  } else {
    parts.forEach((p) => {
      if (p.t !== undefined) sentence.appendChild(h('span', null, p.t));
      else {
        const index = slots.length;
        const input = h('input.q-blank', {
          type: 'text', value: values[index] || '', maxlength: 60, autocomplete: 'off', spellcheck: 'false',
          'aria-label': t('question.blank', { n: index + 1 }),
        });
        const resize = () => { input.style.width = `${Math.max(4, input.value.length + 1.5)}ch`; };
        input.addEventListener('input', () => { values[index] = input.value; resize(); changed(); });
        resize();
        slots.push(input);
        sentence.appendChild(input);
      }
    });
    body.appendChild(sentence);
  }

  return {
    get: () => ({ blanks: values.slice() }),
    answered: () => values.some((v) => String(v).trim()),
    focus: () => { if (slots[0] && slots[0].focus && !bank.length) slots[0].focus({ preventScroll: true }); },
    feedback(fb) {
      const detail = arr(obj(fb.detail).blanks);
      const expected = arr(obj(fb.solution).blanks);
      slots.forEach((slot, i) => {
        const ok = detail.length ? detail[i] === true : !!fb.correct;
        slot.classList.add(ok ? 'is-correct' : 'is-wrong');
        if (!ok && expected[i]) slot.setAttribute('data-expected', expected[i]);
      });
      if (!fb.correct && obj(fb.solution).full) {
        body.appendChild(h('div.q-expected', null, h('span.label', null, t('question.correction')), h('b', null, obj(fb.solution).full)));
      }
    },
  };
}

// ─── Remettre dans l'ordre ───────────────────────────────────────────────────

function wordOrder(q, state, body, changed) {
  const tokens = arr(q.tokens).map((text) => ({ id: uid(), text }));
  const placed = [];
  // Restaure une réponse enregistrée.
  arr(state.answer.words).forEach((word) => {
    const token = tokens.find((tk) => tk.text === word && placed.indexOf(tk) === -1);
    if (token) placed.push(token);
  });
  const line = h('div.q-line', { 'data-placeholder': t('question.orderHint') });
  const pool = h('div.q-pool');
  const render = () => {
    clear(line);
    clear(pool);
    placed.forEach((token) => {
      line.appendChild(h('button.q-token.placed', {
        type: 'button',
        onClick: () => {
          if (state.locked) return;
          placed.splice(placed.indexOf(token), 1);
          render();
          changed();
        },
      }, token.text));
    });
    tokens.forEach((token) => {
      const isPlaced = placed.indexOf(token) !== -1;
      pool.appendChild(h('button.q-token', {
        type: 'button',
        class: { used: isPlaced },
        disabled: isPlaced || state.locked,
        onClick: () => {
          if (state.locked || isPlaced) return;
          placed.push(token);
          render();
          changed();
        },
      }, token.text));
    });
    line.classList.toggle('empty', placed.length === 0);
  };
  render();
  body.appendChild(line);
  body.appendChild(pool);
  return {
    get: () => ({ words: placed.map((tk) => tk.text) }),
    answered: () => placed.length > 0,
    feedback(fb) {
      line.classList.add(fb.correct ? 'is-correct' : 'is-wrong');
      pool.classList.add('hidden');
      if (!fb.correct && obj(fb.solution).sentence) {
        body.appendChild(h('div.q-expected', null, h('span.label', null, t('question.correction')), h('b', null, obj(fb.solution).sentence)));
      }
    },
  };
}

// ─── Association ─────────────────────────────────────────────────────────────

function matching(q, state, body, changed) {
  const left = arr(q.left);
  const right = arr(q.right);
  const pairs = Object.assign({}, obj(state.answer.pairs));
  let active = null;
  const leftBtns = {};
  const rightBtns = {};
  const order = () => left.filter((l) => pairs[l.id]).map((l) => l.id);

  const paint = () => {
    const paired = order();
    left.forEach((l) => {
      const btn = leftBtns[l.id];
      const n = paired.indexOf(l.id);
      btn.classList.toggle('active', active === l.id);
      btn.classList.toggle('paired', n !== -1);
      btn.querySelector('.num').textContent = n !== -1 ? String(n + 1) : '';
    });
    right.forEach((r) => {
      const btn = rightBtns[r.id];
      const owner = left.find((l) => pairs[l.id] === r.id);
      const n = owner ? paired.indexOf(owner.id) : -1;
      btn.classList.toggle('paired', n !== -1);
      btn.querySelector('.num').textContent = n !== -1 ? String(n + 1) : '';
    });
  };

  const colL = h('div.q-col');
  const colR = h('div.q-col');
  left.forEach((l) => {
    leftBtns[l.id] = h('button.q-match', {
      type: 'button',
      onClick: () => {
        if (state.locked) return;
        if (pairs[l.id]) {
          delete pairs[l.id];
          active = null;
          changed();
        } else {
          active = active === l.id ? null : l.id;
        }
        paint();
      },
    }, h('span.num'), h('span.txt', null, l.text));
    colL.appendChild(leftBtns[l.id]);
  });
  right.forEach((r) => {
    rightBtns[r.id] = h('button.q-match.right', {
      type: 'button',
      onClick: () => {
        if (state.locked) return;
        const owner = left.find((l) => pairs[l.id] === r.id);
        if (owner) {
          delete pairs[owner.id];
          changed();
          paint();
          return;
        }
        if (!active) {
          rightBtns[r.id].classList.add('nudge');
          setTimeout(() => rightBtns[r.id].classList.remove('nudge'), 350);
          return;
        }
        pairs[active] = r.id;
        active = null;
        paint();
        changed();
      },
    }, h('span.txt', null, r.text), h('span.num'));
    colR.appendChild(rightBtns[r.id]);
  });
  body.appendChild(h('div.q-hint', null, icon('info', 14), t('question.matchHint')));
  body.appendChild(h('div.q-matching', null, colL, colR));
  paint();

  return {
    get: () => ({ pairs: Object.assign({}, pairs) }),
    answered: () => Object.keys(pairs).length > 0,
    feedback(fb) {
      const detail = obj(obj(fb.detail).pairs);
      const map = obj(obj(fb.solution).map);
      const textOf = {};
      right.forEach((r) => { textOf[r.id] = r.text; });
      left.forEach((l) => {
        const ok = detail[l.id] === true || (!Object.keys(detail).length && pairs[l.id] === map[l.id]);
        const btn = leftBtns[l.id];
        btn.classList.add(ok ? 'is-correct' : 'is-wrong');
        if (!ok && map[l.id]) btn.appendChild(h('span.fix', null, `→ ${textOf[map[l.id]] || ''}`));
        if (pairs[l.id] && rightBtns[pairs[l.id]]) rightBtns[pairs[l.id]].classList.add(ok ? 'is-correct' : 'is-wrong');
      });
    },
  };
}

// ─── Expression écrite ───────────────────────────────────────────────────────

function open(q, state, body, changed) {
  const area = h('textarea.input.q-open', { rows: 7, maxlength: 6000, placeholder: t('question.openPlaceholder') });
  area.value = state.answer.text || '';
  const counter = h('div.q-words');
  const paint = () => {
    const n = wordCount(area.value);
    let text = tn('question.words', n);
    if (q.minWords) text += ` · ${t('question.min', { n: q.minWords })}`;
    if (q.maxWords) text += ` · ${t('question.max', { n: q.maxWords })}`;
    counter.textContent = text;
    counter.classList.toggle('warn', (q.minWords && n < q.minWords) || (q.maxWords && n > q.maxWords));
  };
  area.addEventListener('input', () => { paint(); changed(); });
  paint();
  body.appendChild(area);
  body.appendChild(counter);
  return {
    get: () => ({ text: area.value }),
    answered: () => area.value.trim().length > 0,
    focus: () => area.focus({ preventScroll: true }),
    feedback(fb) {
      const guidelines = obj(fb.solution).guidelines;
      if (guidelines) body.appendChild(h('div.q-expected', null, h('span.label', null, t('question.modelAnswer')), h('div', null, ...renderMarkdown(guidelines).childNodes)));
    },
  };
}

// ─── Panneau de correction ───────────────────────────────────────────────────

export function feedbackPanel(q, fb, options = {}) {
  fb = obj(fb);
  let tone = 'wrong';
  let title = t('feedback.wrong');
  let ic = 'close';
  if (fb.pending) {
    tone = 'pending';
    title = t('feedback.pending');
    ic = 'pen';
  } else if (fb.correct) {
    tone = 'correct';
    title = fb.typo ? t('feedback.correctTypo') : t(`feedback.correct${1 + Math.floor(Math.random() * 3)}`);
    ic = 'check';
  } else if (fb.partial) {
    tone = 'partial';
    title = t('feedback.partial');
    ic = 'minus';
  }
  const maxPts = fb.max || q.points || 1;
  const points = fb.pending ? null : `${f.num(fb.points || 0)} / ${tn('question.points', maxPts, { n: f.num(maxPts) })}`;
  return h(`div.q-feedback.${tone}`, null,
    h('div.q-feedback-head', null,
      h('span.q-feedback-icon', null, icon(ic, 18)),
      h('b', null, title),
      points ? h('span.q-feedback-pts', null, points) : null),
    fb.explanation ? h('div.q-explanation', null, h('span.label', null, t('question.explanation')), renderMarkdown(fb.explanation)) : null,
    fb.teacherFeedback ? h('div.q-explanation.teacher', null, h('span.label', null, t('question.teacherFeedback')), h('p', null, fb.teacherFeedback)) : null,
    options.action || null);
}

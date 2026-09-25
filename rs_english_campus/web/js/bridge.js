/*
 * English Campus — page pont (ui_page de la ressource).
 *
 *  1. Relaie chaque évènement temps réel (SendNUIMessage) vers toutes les instances de l'app
 *     via BroadcastChannel : l'iframe du téléphone, la fenêtre de rs_pc, le cadre autonome.
 *     Toutes ces pages partagent l'origine https://cfx-nui-<ressource>.
 *  2. Affiche le cadre autonome (téléphone ou ordinateur) quand le client le demande.
 */
(function () {
  'use strict';

  var host = location.hostname || '';
  var resource = host.indexOf('cfx-nui-') === 0 ? host.slice(8) : 'rs_english_campus';
  var channel = null;
  try { channel = new BroadcastChannel(resource + ':push'); } catch (e) { channel = null; }

  var device = null;
  var frame = null;
  var layout = null;
  var destroyTimer = null;

  function post(event, data) {
    return fetch('https://' + resource + '/' + event, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {})
    }).catch(function () {});
  }

  function requestClose() { post('ec:close'); }

  function build(kind) {
    if (device) device.remove();
    var closeBtn = document.querySelector('.phone-close');
    if (closeBtn) closeBtn.remove();

    device = document.createElement('div');
    device.className = 'device ' + kind;
    frame = document.createElement('iframe');
    frame.setAttribute('allow', 'autoplay; clipboard-read; clipboard-write');
    frame.src = 'index.html?host=' + kind + '&frame=standalone';

    if (kind === 'pc') {
      var bar = document.createElement('div');
      bar.className = 'titlebar';
      var dot = document.createElement('span');
      dot.className = 'dot';
      var title = document.createElement('span');
      title.className = 'grow';
      title.textContent = 'English Campus';
      var close = document.createElement('button');
      close.className = 'close';
      close.setAttribute('aria-label', 'Fermer');
      close.textContent = '✕';
      close.addEventListener('click', requestClose);
      bar.appendChild(dot);
      bar.appendChild(title);
      bar.appendChild(close);
      device.appendChild(bar);
    } else {
      var btn = document.createElement('button');
      btn.className = 'close phone-close';
      btn.setAttribute('aria-label', 'Fermer');
      btn.textContent = '✕';
      btn.addEventListener('click', requestClose);
      document.body.appendChild(btn);
    }
    device.appendChild(frame);
    document.body.appendChild(device);
    layout = kind;
  }

  function open(kind) {
    clearTimeout(destroyTimer);
    if (!device || layout !== kind) build(kind);
    requestAnimationFrame(function () { document.body.classList.add('open'); });
    try { frame.contentWindow.postMessage({ action: 'ec:host', visible: true }, '*'); } catch (e) { /* ignoré */ }
  }

  function close() {
    document.body.classList.remove('open');
    try { frame && frame.contentWindow.postMessage({ action: 'ec:host', visible: false }, '*'); } catch (e) { /* ignoré */ }
    // Le cadre est gardé une minute (réouverture instantanée), puis libéré.
    clearTimeout(destroyTimer);
    destroyTimer = setTimeout(function () {
      if (document.body.classList.contains('open')) return;
      if (device) device.remove();
      var btn = document.querySelector('.phone-close');
      if (btn) btn.remove();
      device = null;
      frame = null;
      layout = null;
    }, 60000);
  }

  window.addEventListener('message', function (event) {
    var data = event.data;
    if (!data || typeof data !== 'object') return;
    if (data.action === 'ec:push') {
      if (channel) channel.postMessage(data);
    } else if (data.action === 'ec:standalone:open') {
      open(data.layout === 'pc' ? 'pc' : 'phone');
    } else if (data.action === 'ec:standalone:close') {
      close();
    }
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && document.body.classList.contains('open')) requestClose();
  });
})();

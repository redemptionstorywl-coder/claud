/**
 * Environnement d'exécution de l'interface.
 *
 * La même page (index.html) tourne dans trois « hôtes » :
 *   phone       iframe de l'app dans sd-phone (?host=phone)
 *   pc          fenêtre de rs_pc ou fenêtre PC autonome (?host=pc)
 *   phone/pc + frame=standalone : cadre affiché par web/bridge.html (sans téléphone)
 * Hors du jeu (navigateur), l'interface se connecte au serveur de développement (tests/dev_server.py).
 */

const params = new URLSearchParams(location.search);

function detectResource() {
  // 1. L'adresse de la page : index.html est toujours servi par NOTRE ressource (https://cfx-nui-<ressource>/…),
  //    même affiché dans l'iframe de sd-phone ou de rs_pc. C'est la source la plus fiable :
  //    GetParentResourceName() pourrait désigner la ressource hôte (le téléphone, le PC).
  const host = location.hostname || '';
  if (host.indexOf('cfx-nui-') === 0) return host.slice(8);
  // 2. Ancien schéma nui://<ressource>/…
  if (location.protocol === 'nui:' && host) return host;
  // 3. Valeurs injectées par l'hôte (sd-phone pose window.resourceName après le chargement).
  if (typeof window.resourceName === 'string' && window.resourceName) return window.resourceName;
  if (typeof window.GetParentResourceName === 'function') {
    try { return window.GetParentResourceName(); } catch (e) { /* ignoré */ }
  }
  return 'rs_english_campus';
}

export const env = {
  params,
  resource: detectResource(),
  inGame: typeof window.invokeNative !== 'undefined' || (location.hostname || '').indexOf('cfx-nui-') === 0,
  host: params.get('host') === 'pc' ? 'pc' : 'phone',
  frame: params.get('frame') || 'embedded',
  devAs: params.get('as') || 'student',
};

env.isStandalone = env.frame === 'standalone';
env.isPhoneEmbed = env.inGame && env.host === 'phone' && !env.isStandalone;
env.dev = !env.inGame;

/** Attend l'injection du SDK sd-phone (évènement « componentsLoaded »), sans bloquer plus de 1,5 s. */
export function waitForPhoneSdk() {
  if (!env.isPhoneEmbed || window.componentsLoaded) return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => { window.removeEventListener('message', onMessage); resolve(); };
    const onMessage = (e) => { if (e.data === 'componentsLoaded') done(); };
    window.addEventListener('message', onMessage);
    setTimeout(done, 1500);
  });
}

/** Thème clair/sombre proposé par le téléphone (attribut data-theme posé sur <body> par sd-phone). */
export function phoneTheme() {
  const attr = document.body && document.body.getAttribute('data-theme');
  if (attr === 'dark' || attr === 'light') return attr;
  const settings = window.settings;
  const theme = settings && ((settings.display && settings.display.theme) || settings.theme);
  if (theme === 'dark' || theme === 'light') return theme;
  if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) return 'dark';
  return null;
}

/* VillageLink — mode hors ligne.
   - Fichiers de l'application (page, scripts, styles, polices) : réseau d'abord, copie de secours en cache.
   - Données Supabase en lecture (/rest/v1/) : réseau d'abord ; sans connexion, la dernière réponse
     enregistrée sur ce téléphone est renvoyée. Les écritures ne sont jamais mises en cache.
   - À la déconnexion, l'application vide le cache des données (message « vl-clear »). */
const SHELL = 'vl-shell-v1';
const DATA = 'vl-data-v1';

self.addEventListener('install', e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(['./', 'manifest.webmanifest', 'icon.svg', 'icon-192.png'])).catch(() => {}).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== SHELL && k !== DATA).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('message', e => {
  if (e.data === 'vl-clear') e.waitUntil(caches.delete(DATA));
});

// Clé de cache pour une lecture de données : l'adresse + la tranche demandée (+ le corps pour les fonctions).
async function dataKey(req) {
  let k = req.url + '#range=' + (req.headers.get('Range') || '');
  if (req.method === 'POST') k += '#body=' + (await req.clone().text());
  return new Request('https://vl-cache.invalid/' + encodeURIComponent(k));
}

async function networkFirst(req, cacheName, key) {
  try {
    const res = await fetch(req);
    if (res && (res.ok || res.type === 'opaque')) {
      const copy = res.clone();
      caches.open(cacheName).then(c => c.put(key || req, copy)).catch(() => {});
    }
    return res;
  } catch (err) {
    const hit = await caches.match(key || req, { ignoreVary: true, ignoreSearch: false });
    if (hit) return hit;
    if (req.mode === 'navigate') { const page = await caches.match('./'); if (page) return page; }
    throw err;
  }
}

self.addEventListener('fetch', e => {
  const req = e.request, url = new URL(req.url);
  const isRest = /\/rest\/v1\//.test(url.pathname);
  const isRpcRead = isRest && req.method === 'POST' && /\/rest\/v1\/rpc\/(my_memberships|poll_results)$/.test(url.pathname);
  if (isRest && (req.method === 'GET' || isRpcRead)) {
    e.respondWith(dataKey(req).then(k => networkFirst(req, DATA, k)));
    return;
  }
  if (req.method !== 'GET') return;
  const sameOrigin = url.origin === self.location.origin;
  const asset = url.hostname === 'cdn.jsdelivr.net' || url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com';
  if (sameOrigin || asset) e.respondWith(networkFirst(req, SHELL));
});

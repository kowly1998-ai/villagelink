/* Enregistre le mode hors ligne dès le chargement (détecté aussi par PWABuilder). */
if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === '127.0.0.1')) {
  navigator.serviceWorker.register('sw.js').catch(function () { /* hors ligne indisponible */ });
}

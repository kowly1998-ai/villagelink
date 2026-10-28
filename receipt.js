/* VillageLink — lecture d'un reçu Wave / Orange Money / Free Money.
   - parse(texte) : trouve le montant, la référence, les numéros de téléphone, l'opérateur et la date
     dans le SMS de confirmation ou dans le texte lu sur une capture d'écran.
   - ocr(fichier, progression) : lit le texte d'une capture d'écran SUR LE TÉLÉPHONE (Tesseract,
     chargé seulement à la première utilisation). L'image n'est envoyée à aucun serveur. */
(function (root) {
  'use strict';
  const NBSP = /[   ]/g;

  // « 5.000F », « 5 000 FCFA », « 5,000 F CFA », « 5000 XOF », « 12 500 francs »
  const AMOUNT = /(\d{1,3}(?:[ .,]\d{3})+|\d{2,9})(?:[.,]\d{1,2})?\s*(?:f\s*cfa|fcfa|xof|cfa|francs?|f)(?![a-z])/gi;
  const NOT_AMOUNT = /(solde|frais|balance|commission|fees?|taxe|nouveau|reste|disponible)[^\d]{0,22}$/i;
  const AMOUNT_KEY = /(montant|envoy[ée]|re[çc]u|pay[ée]|transf[ée]r|d[ée]p[oô]t|amount|sent|total)[^\d]{0,25}$/i;

  function toInt(s) { return Number(String(s).replace(/[ .,]/g, '')); }

  function findAmount(t) {
    const found = [];
    let m; AMOUNT.lastIndex = 0;
    while ((m = AMOUNT.exec(t))) {
      const before = t.slice(Math.max(0, m.index - 30), m.index);
      const v = toInt(m[1]);
      if (!(v > 0) || v > 100000000) continue;
      if (NOT_AMOUNT.test(before)) continue;
      found.push({ v, key: AMOUNT_KEY.test(before) });
    }
    const k = found.find(f => f.key);
    return k ? k.v : (found[0] ? found[0].v : null);
  }

  const REF_PATTERNS = [
    /\b(T_[A-Z0-9]{6,30})\b/i,                                   // Wave : T_ABCD1234EFGH
    /\b([A-Z]{2}\d{6}\.\d{4}\.[A-Z0-9]{4,12})\b/i,               // Orange Money : MP251028.1234.A12345
    /(?:id\s*(?:de\s*)?(?:la\s*)?transaction|transaction\s*id|r[ée]f[ée]rence|r[ée]f|txn?\s*id|n[°o]\s*transaction)\s*[:#.\-]?\s*([A-Z0-9][A-Z0-9._\-]{5,40})/i
  ];
  function findRef(t) {
    for (const re of REF_PATTERNS) { const m = t.match(re); if (m && /\d/.test(m[1])) return m[1].replace(/[.\-]+$/, ''); }
    return '';
  }

  // Numéros : 9 chiffres (Sénégal 7x…, Guinée 6x…), avec ou sans indicatif et séparateurs.
  function findPhones(t) {
    const out = new Set();
    const re = /(?:\+|00)?\d[\d .\-]{7,17}\d/g; let m;
    while ((m = re.exec(t))) {
      const d = m[0].replace(/\D/g, '');
      if (d.length < 8 || d.length > 13) continue;
      const last9 = d.slice(-9);
      if (/^[67]\d{8}$/.test(last9)) out.add(last9);
      else if (d.length >= 8 && d.length <= 10) out.add(d);
    }
    return [...out];
  }

  function findMethod(t) {
    if (/\bwave\b/i.test(t) || /\bT_[A-Z0-9]{6,}/i.test(t)) return 'Wave';
    if (/orange\s*money|\bom\b|\b[A-Z]{2}\d{6}\.\d{4}\./i.test(t)) return 'Orange Money';
    if (/free\s*money|\byas\b|mixx/i.test(t)) return 'Free Money';
    return '';
  }

  const MOIS = { janv: 1, jan: 1, fevr: 2, fev: 2, feb: 2, mars: 3, mar: 3, avr: 4, apr: 4, mai: 5, may: 5, juin: 6, jun: 6, juil: 7, jul: 7, aout: 8, aug: 8, sept: 9, sep: 9, oct: 10, nov: 11, dec: 12 };
  function findDate(t) {
    let m = t.match(/\b(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2,4})\b/);
    if (m) { let y = Number(m[3]); if (y < 100) y += 2000; const d = new Date(Date.UTC(y, Number(m[2]) - 1, Number(m[1]))); if (!isNaN(d)) return d.toISOString().slice(0, 10); }
    m = t.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').match(/\b(\d{1,2})\s+(janv|jan|fevr|fev|feb|mars|mar|avr|apr|mai|may|juin|jun|juil|jul|aout|aug|sept|sep|oct|nov|dec)[a-z]*\.?\s+(\d{4})\b/);
    if (m) { const d = new Date(Date.UTC(Number(m[3]), MOIS[m[2]] - 1, Number(m[1]))); if (!isNaN(d)) return d.toISOString().slice(0, 10); }
    return '';
  }

  function parse(text) {
    const t = String(text || '').replace(NBSP, ' ').replace(/[ \t]+/g, ' ');
    const reference = findRef(t);
    return { amount: findAmount(t), reference, phones: findPhones(reference ? t.split(reference).join(' ') : t), method: findMethod(t), date: findDate(t), text: t };
  }

  // Le numéro (ou le nom) de l'association apparaît-il sur le reçu ?
  function matchesDest(r, number, holder) {
    const n = String(number || '').replace(/\D/g, '').slice(-9);
    if (n.length >= 8 && r.phones.some(p => p.slice(-n.length) === n || n.slice(-p.length) === p)) return 'number';
    const norm = s => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
    const words = norm(holder).split(/[^a-z0-9]+/).filter(w => w.length >= 3);
    const txt = norm(r.text);
    if (words.length && words.filter(w => txt.includes(w)).length >= Math.min(2, words.length)) return 'name';
    return '';
  }

  // OCR sur le téléphone, avec Tesseract chargé depuis jsDelivr à la première utilisation.
  const TESS = 'https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js';
  let loading = null;
  function loadTesseract() {
    if (root.Tesseract) return Promise.resolve(root.Tesseract);
    if (!loading) loading = new Promise((res, rej) => {
      const s = document.createElement('script'); s.src = TESS; s.async = true;
      s.onload = () => root.Tesseract ? res(root.Tesseract) : rej(new Error('Lecteur indisponible'));
      s.onerror = () => { loading = null; rej(new Error('Impossible de charger le lecteur de reçus. Vérifiez la connexion internet.')); };
      document.head.appendChild(s);
    });
    return loading;
  }
  // Agrandit les petites captures et passe en niveaux de gris : la lecture est plus fiable.
  async function prepare(file) {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(2, Math.max(1, 1400 / bmp.width));
    const c = document.createElement('canvas'); c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale);
    const g = c.getContext('2d'); g.filter = 'grayscale(1) contrast(1.3)'; g.drawImage(bmp, 0, 0, c.width, c.height);
    return c;
  }
  async function ocr(file, onProgress) {
    const T = await loadTesseract();
    const img = await prepare(file).catch(() => file);
    const worker = await T.createWorker('fra', 1, { logger: m => { if (onProgress && m.status === 'recognizing text') onProgress(Math.round(m.progress * 100)); } });
    try { const r = await worker.recognize(img); return r.data.text || ''; }
    finally { worker.terminate(); }
  }

  root.VLReceipt = { parse, matchesDest, ocr };
  if (typeof module !== 'undefined') module.exports = root.VLReceipt;
})(typeof window !== 'undefined' ? window : globalThis);

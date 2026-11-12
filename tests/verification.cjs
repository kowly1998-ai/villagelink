// VillageLink — vérification automatique avant mise en ligne (lancée par GitHub Actions).
// Usage : node tests/verification.cjs   (Playwright doit être installé ; CHROME_PATH facultatif)
// Ne se connecte à aucun compte et n'écrit rien dans la base.
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const read = f => fs.readFileSync(path.join(ROOT, f), 'utf8');
let failed = 0;
const ok = msg => console.log('  ✓ ' + msg);
const ko = msg => { failed++; console.log('  ✗ ' + msg); };
const check = (cond, msg) => (cond ? ok(msg) : ko(msg));

// 1. Écriture du code : chaque fichier JavaScript doit se lire sans erreur.
function syntax() {
  console.log('1. Écriture du code');
  for (const f of fs.readdirSync(ROOT).filter(f => f.endsWith('.js'))) {
    try { execFileSync(process.execPath, ['--check', path.join(ROOT, f)], { stdio: 'pipe' }); ok(f); }
    catch (e) { ko(f + ' : ' + String(e.stderr).split('\n').slice(0, 4).join(' ')); }
  }
}

// 2. Fichiers appelés par les pages : ils existent, et chaque fichier local de index.html a son ?v=.
function references() {
  console.log('2. Fichiers appelés par les pages');
  for (const page of ['index.html', 'projet.html', 'confidentialite.html', 'conditions.html', 'suppression-compte.html']) {
    const html = read(page);
    for (const [, url] of html.matchAll(/(?:src|href)="([^"#]+)"/g)) {
      if (/^(https?:|mailto:|tel:|data:)/.test(url) || url === './') continue;
      const file = url.split('?')[0];
      check(fs.existsSync(path.join(ROOT, file)), `${page} → ${file}`);
      if (page === 'index.html' && /\.(js|css)$/.test(file) && file !== 'sw-register.js') {
        check(/\?v=\d+$/.test(url), `${page} → ${file} a un numéro ?v= (cache des téléphones)`);
      }
    }
  }
}

// 2 bis. Numéros ?v= : un fichier modifié depuis main (ou, sur main, depuis la version d'avant)
// doit avoir un nouveau numéro, sinon les téléphones gardent l'ancienne version en cache.
const git = (...args) => execFileSync('git', args, { cwd: ROOT, stdio: ['ignore', 'pipe', 'ignore'] }).toString();
function versions() {
  console.log('2 bis. Numéros de version (cache des téléphones)');
  let base = process.env.VERIF_BASE || '';
  try {
    if (!base) {
      const head = git('rev-parse', 'HEAD').trim();
      const mb = git('merge-base', 'HEAD', 'origin/main').trim();
      // Sur main sans modification en cours (GitHub après une fusion) : comparer à la version d'avant.
      const dirty = git('status', '--porcelain', '--untracked-files=no').trim() !== '';
      base = mb !== head ? mb : dirty ? head : git('rev-parse', 'HEAD^1').trim();
    }
  } catch (e) { ok('contrôle sauté : historique git indisponible (fetch-depth: 0 dans GitHub Actions)'); return; }
  const show = f => { try { return execFileSync('git', ['show', `${base}:${f}`], { cwd: ROOT, stdio: ['ignore', 'pipe', 'ignore'] }); } catch (e) { return null; } };
  for (const page of ['index.html', 'projet.html']) {
    const now = read(page), before = (show(page) || '').toString();
    for (const [, file, v] of now.matchAll(/(?:src|href)="([\w./-]+\.(?:js|css))\?v=(\d+)"/g)) {
      const old = show(file);
      if (!old) { ok(`${page} → ${file} : nouveau fichier`); continue; }
      const changed = !old.equals(fs.readFileSync(path.join(ROOT, file)));
      const oldV = (before.match(new RegExp(`${file.replace(/[.]/g, '\\.')}\\?v=(\\d+)`)) || [])[1];
      if (!changed) continue;
      check(oldV !== v, `${page} → ${file} modifié${oldV === v ? ` mais toujours ?v=${v} : passer à ?v=${Number(v) + 1}` : ` : ?v=${oldV} → ?v=${v}`}`);
    }
  }
}

// 2 ter. Aucune clé secrète dans le dépôt public (seule la clé « anon » de Supabase est permise).
function secrets() {
  console.log('2 ter. Aucune clé secrète dans le dépôt');
  let files = [];
  try { files = git('ls-files').split('\n').filter(Boolean); } catch (e) { files = fs.readdirSync(ROOT).filter(f => /\.(js|html|json|md|sql|ts|yml)$/.test(f)); }
  const found = [];
  for (const f of files) {
    if (/\.(png|jpe?g|webp|ico|woff2?)$/i.test(f)) continue;
    let s; try { s = fs.readFileSync(path.join(ROOT, f), 'utf8'); } catch (e) { continue; }
    for (const [jwt] of s.matchAll(/eyJ[\w-]{10,}\.(eyJ[\w-]{10,})\.[\w-]{10,}/g)) {
      let role = ''; try { role = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString()).role || ''; } catch (e) { /* pas un vrai jeton */ }
      if (role && role !== 'anon') found.push(`${f} : jeton Supabase « ${role} »`);
    }
    if (/sb_secret_[\w-]{10,}/.test(s)) found.push(`${f} : clé secrète Supabase (sb_secret_…)`);
    if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(s)) found.push(`${f} : clé privée`);
    if (/\b(ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})/.test(s)) found.push(`${f} : jeton GitHub`);
  }
  check(!found.length, found.length ? `clé secrète trouvée, à retirer et à changer dans Supabase : ${found.join(' ; ')}` : `${files.length} fichiers relus, aucune clé secrète`);
}

// 3. Empreintes de sécurité (SRI) des scripts venus de jsDelivr : elles correspondent au vrai fichier.
async function sri() {
  console.log('3. Empreintes des scripts externes');
  const list = [];
  for (const [, tag] of read('index.html').matchAll(/<script ([^>]*src="https:[^>]*)>/g)) {
    const src = (tag.match(/src="([^"]+)"/) || [])[1];
    const integrity = (tag.match(/integrity="([^"]+)"/) || [])[1];
    if (!integrity) { ko(`index.html → ${src} n'a pas d'empreinte`); continue; }
    list.push([src, integrity]);
  }
  const rj = read('receipt.js');
  const tess = (rj.match(/const TESS = '([^']+)'/) || [])[1];
  const tessSri = (rj.match(/const TESS_SRI = '([^']+)'/) || [])[1];
  if (tess && tessSri) list.push([tess, tessSri]); else ko('receipt.js : adresse ou empreinte de Tesseract introuvable');
  for (const [url, expected] of list) {
    try {
      const res = await fetch(url);
      const buf = Buffer.from(await res.arrayBuffer());
      const got = 'sha384-' + crypto.createHash('sha384').update(buf).digest('base64');
      check(res.ok && got === expected, `${url.split('/npm/')[1] || url}`);
    } catch (e) { ko(`${url} : téléchargement impossible (${e.message})`); }
  }
}

// 4. Tests du lecteur de reçus (sans navigateur).
function receipts() {
  console.log('4. Lecteur de reçus');
  const R = require(path.join(ROOT, 'receipt.js'));
  const wave = R.parse('Vous avez envoyé 5.000F à Mamadou Diallo (77 123 45 67). Frais: 50F. Nouveau solde: 12.350F. ID de transaction: T_ABCD1234EFGH');
  check(wave.amount === 5000, `SMS Wave : montant 5000 (lu ${wave.amount})`);
  check(wave.reference === 'T_ABCD1234EFGH', `SMS Wave : référence (lue « ${wave.reference} »)`);
  check(wave.method === 'Wave', `SMS Wave : opérateur (lu « ${wave.method} »)`);
  check(wave.phones.includes('771234567'), `SMS Wave : numéro 771234567 (lus ${wave.phones.join(', ')})`);
  const om = R.parse('Transfert de 10 000 FCFA vers 621000000 reussi le 28/10/2026. Ref: MP251028.1234.A12345. Solde 3 000 FCFA. Orange Money');
  check(om.amount === 10000, `SMS Orange Money : montant 10000 (lu ${om.amount})`);
  check(om.method === 'Orange Money', `SMS Orange Money : opérateur (lu « ${om.method} »)`);
  check(om.date === '2026-10-28', `SMS Orange Money : date (lue ${om.date})`);
  check(R.matchesDest(wave, '+221 77 123 45 67', '') === 'number', 'Le numéro de l’association est reconnu sur le reçu');
}

// 5. Les pages s'ouvrent dans un vrai navigateur, à la taille d'un petit téléphone, sans erreur.
function serve() {
  const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json', '.json': 'application/json' };
  return new Promise(res => {
    const srv = http.createServer((req, rsp) => {
      let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
      if (p.endsWith('/')) p += 'index.html';
      const f = path.join(ROOT, path.normalize(p));
      if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { rsp.writeHead(404); return rsp.end(); }
      rsp.writeHead(200, { 'Content-Type': types[path.extname(f)] || 'application/octet-stream' });
      fs.createReadStream(f).pipe(rsp);
    }).listen(8765, '127.0.0.1', () => res(srv));
  });
}

async function browser() {
  console.log('5. Ouverture des pages (téléphone 360 px)');
  const { chromium } = require('playwright');
  const srv = await serve();
  const b = await chromium.launch(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {});
  try {
    const pages = [
      ['index.html', '/', p => p.evaluate(() => !!window.supabase), 'la bibliothèque Supabase est chargée'],
      ['lien court', '/#/r/eb67bb47', async p => !!(await p.$('form[data-form=auth]')) && (await p.evaluate(() => location.hash)) === '#/r/eb67bb47', 'sans connexion, l’écran de connexion s’affiche et le lien est gardé'],
      ['projet.html', '/projet.html?p=page-de-test-inexistante', null, ''],
      ['confidentialite.html', '/confidentialite.html', null, ''],
      ['conditions.html', '/conditions.html', null, ''],
      ['suppression-compte.html', '/suppression-compte.html', null, '']
    ];
    for (const [name, url, extra, extraMsg] of pages) {
      const ctx = await b.newContext({ viewport: { width: 360, height: 740 }, serviceWorkers: 'block', locale: 'fr-FR' });
      const page = await ctx.newPage();
      const errors = [];
      page.on('pageerror', e => errors.push(e.message));
      page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
      await page.goto('http://127.0.0.1:8765' + url, { waitUntil: 'networkidle', timeout: 45000 }).catch(e => errors.push(e.message));
      await page.waitForTimeout(800);
      check(!errors.length, `${name} s'ouvre sans erreur${errors.length ? ' : ' + errors.slice(0, 3).join(' | ') : ''}`);
      const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      check(wide <= 1, `${name} tient dans la largeur du téléphone${wide > 1 ? ` (déborde de ${wide} px)` : ''}`);
      if (name === 'index.html') {
        const text = await page.textContent('body');
        check(/VillageLink/.test(text) && !/Configuration incomplète|Impossible d’afficher/.test(text), 'index.html affiche l’écran d’accueil');
      }
      if (extra) check(await extra(page), `${name} : ${extraMsg}`);
      await ctx.close();
    }
  } finally { await b.close(); srv.close(); }
}

(async () => {
  syntax();
  references();
  versions();
  secrets();
  await sri();
  receipts();
  await browser();
  console.log(failed ? `\n${failed} vérification(s) en échec. Ne pas mettre en ligne.` : '\nTout est bon.');
  process.exit(failed ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });

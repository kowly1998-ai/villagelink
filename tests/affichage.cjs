// VillageLink — test d'affichage (lancé par GitHub Actions, jamais en production).
// Ouvre l'application dans un vrai navigateur à la taille d'un petit téléphone (360 px),
// avec une FAUSSE base de données : aucune vraie donnée, aucune écriture.
// Il vérifie que l'accueil et les Paramètres s'affichent, sans erreur ni débordement,
// en thème clair et sombre, et enregistre des captures dans tests/captures/.
// Usage : node tests/affichage.cjs   (Playwright installé ; CHROME_PATH facultatif ; ROOT facultatif)
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(process.env.ROOT || path.join(__dirname, '..'));
const OUT = path.join(__dirname, 'captures');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json' };
let failed = 0;
const ok = m => console.log('  ✓ ' + m);
const ko = m => { failed++; console.log('  ✗ ' + m); };
const check = (c, m) => (c ? ok(m) : ko(m));

const b64u = o => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
const UID = '11111111-1111-4111-8111-111111111111', AID = '22222222-2222-4222-8222-222222222222', MID = '33333333-3333-4333-8333-333333333333';
const future = new Date(Date.now() + 86400e3 * 40).toISOString().slice(0, 10);
const ASSOC = { id: AID, name: 'Jeunesse de Test', origin_country: 'Guinée', region: 'Labé', prefecture: 'Labé', village: 'Test', residence_country: 'Sénégal', residence_city: 'Dakar', description: '', founded_on: null, currency: 'XOF', fee_amount: 5000, fee_due_day: 5, dues_start: '2026-01-01', invite_code: 'ABCD1234', plan: 'association', trial_ends: future, paid_until: null, blocked_at: null, blocked_reason: null, expense_approval: false, cover_path: AID + '/cover-test.jpg', created_at: '2026-01-01T00:00:00Z' };
const ME = { id: MID, association_id: AID, user_id: UID, full_name: 'Alpha Test', phone: '', role: 'president', active: true, pending: false, section_id: null, category_id: null, created_at: '2026-01-01T00:00:00Z' };
// Image 4×3 orange (PNG minuscule fabriqué ici) servie à la place de la vraie photo.
const PNG = (() => {
  const zlib = require('zlib'), crc = b => { let c, t = [], r = ~0; for (let n = 0; n < 256; n++) { c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } for (const x of b) r = t[(r ^ x) & 255] ^ (r >>> 8); return (~r) >>> 0; };
  const chunk = (type, data) => { const l = Buffer.alloc(4); l.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(4, 0); ihdr.writeUInt32BE(3, 4); ihdr[8] = 8; ihdr[9] = 2;
  const raw = Buffer.concat([0, 1, 2].map(() => Buffer.concat([Buffer.from([0]), Buffer.from([232, 111, 59, 232, 111, 59, 232, 111, 59, 232, 111, 59])])));
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
})();

function mock(route) {
  const req = route.request(), u = new URL(req.url()), p = u.pathname, accept = req.headers()['accept'] || '';
  const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
  const rows = list => {
    if (accept.includes('vnd.pgrst.object')) return list.length ? json(list[0]) : json({ code: 'PGRST116', message: 'The result contains 0 rows', details: null, hint: null }, 406);
    return json(list);
  };
  if (p.startsWith('/auth/v1/user')) return json({ id: UID, aud: 'authenticated', role: 'authenticated', email: 'test@exemple.fr', app_metadata: {}, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' });
  if (p.startsWith('/auth/v1/')) return json({});
  if (p.startsWith('/storage/v1/object/sign/') && req.method() === 'POST') return json({ signedURL: p.replace('/storage/v1', '') + '?token=test' });
  if (p.startsWith('/storage/v1/object/')) return route.fulfill({ status: 200, contentType: 'image/png', body: PNG });
  if (p.startsWith('/rest/v1/rpc/my_memberships')) return json([{ association_id: AID, name: ASSOC.name, village: ASSOC.village, residence_city: ASSOC.residence_city, pending: false, active: true }]);
  if (p.startsWith('/rest/v1/rpc/')) return json([]);
  if (p.startsWith('/rest/v1/associations')) return rows([ASSOC]);
  if (p.startsWith('/rest/v1/members')) return rows([ME]);
  if (p.startsWith('/rest/v1/v_balances')) return rows([{ association_id: AID, total_in: 0, total_out: 0 }]);
  if (p.startsWith('/rest/v1/')) return rows([]);
  return json({});
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const srv = http.createServer((req, rsp) => {
    let f = decodeURIComponent(req.url.split('?')[0]); if (f.endsWith('/')) f += 'index.html';
    const file = path.join(ROOT, f);
    if (!file.startsWith(ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { rsp.writeHead(404); return rsp.end(); }
    rsp.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' }); rsp.end(fs.readFileSync(file));
  });
  await new Promise(r => srv.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + srv.address().port + '/';
  const cfg = fs.readFileSync(path.join(ROOT, 'config.js'), 'utf8');
  const supaUrl = (cfg.match(/supabaseUrl:\s*"([^"]+)"/) || [])[1];
  const ref = new URL(supaUrl).hostname.split('.')[0];
  const exp = Math.floor(Date.now() / 1000) + 3600 * 5;
  const jwt = [b64u({ alg: 'HS256', typ: 'JWT' }), b64u({ sub: UID, role: 'authenticated', aud: 'authenticated', exp }), 'sig'].join('.');
  const session = { access_token: jwt, refresh_token: 'r', token_type: 'bearer', expires_in: 18000, expires_at: exp, user: { id: UID, aud: 'authenticated', role: 'authenticated', email: 'test@exemple.fr', app_metadata: {}, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' } };

  const { chromium } = require('playwright');
  const browser = await chromium.launch(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {});
  const hasCover = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8').includes('set_cover');

  for (const theme of ['light', 'dark']) {
    console.log(`Affichage à 360 px, thème ${theme === 'light' ? 'clair' : 'sombre'}`);
    const ctx = await browser.newContext({ viewport: { width: 360, height: 740 }, deviceScaleFactor: 2, colorScheme: theme, serviceWorkers: 'block' });
    await ctx.addInitScript(([key, val, th]) => { try { localStorage.setItem(key, val); localStorage.setItem('vl:theme', th); } catch (e) { /* ignoré */ } }, [`sb-${ref}-auth-token`, JSON.stringify(session), theme]);
    await ctx.route(url => url.hostname.endsWith('.supabase.co'), mock);
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(String(e.message || e).slice(0, 200)));
    page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource|ERR_|net::|fonts\.g/i.test(m.text())) errors.push(m.text().slice(0, 200)); });

    await page.goto(base + `#/a/${AID}`, { waitUntil: 'domcontentloaded' });
    try { await page.waitForSelector('.home-grid, .greet', { timeout: 20000 }); } catch (e) { /* vérifié plus bas */ }
    await page.waitForTimeout(600);
    const txt = await page.evaluate(() => document.body.innerText);
    check(/Bonjour/.test(txt), 'l’accueil affiche « Bonjour »');
    check(!/Impossible d’afficher/.test(txt), 'aucun message d’erreur à l’écran');
    check(await page.locator('nav, .tabbar, .bottom-nav').count() > 0, 'la barre du bas est présente');
    if (hasCover) {
      check(await page.locator('.cover img').count() === 1, 'la photo de couverture est affichée sur l’accueil');
      check(await page.evaluate(() => { const i = document.querySelector('.cover img'); return !!i && i.complete && i.naturalWidth > 0; }), 'la photo de couverture est chargée');
    }
    check(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'l’accueil ne déborde pas de l’écran');
    await page.screenshot({ path: path.join(OUT, `accueil-${theme}.png`) });

    await page.goto(base + `#/a/${AID}/parametres`, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(1200);
    const txt2 = await page.evaluate(() => document.body.innerText);
    check(/Code d’invitation/.test(txt2), 'les Paramètres s’affichent');
    if (hasCover) check(await page.locator('form[data-form=cover]').count() === 1, 'la carte « Photo de couverture » est présente dans les Paramètres');
    check(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'les Paramètres ne débordent pas de l’écran');
    await page.screenshot({ path: path.join(OUT, `parametres-${theme}.png`), fullPage: true });

    const hasLot2 = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8').includes('rapportannuel');
    if (hasLot2) {
      check(await page.locator('[data-act=exp]').count() === 2, 'les boutons d’export (membres, opérations) sont dans les Paramètres');
      await page.goto(base + `#/a/${AID}/rapportannuel`, { waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(1200);
      const txt3 = await page.evaluate(() => document.body.innerText);
      check(/Rapport de l’année/.test(txt3) && /Mois par mois/.test(txt3), 'le rapport annuel s’affiche');
      check(!/Impossible d’afficher/.test(txt3), 'le rapport annuel n’a pas d’erreur');
      check(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'le rapport annuel ne déborde pas de l’écran');
      await page.screenshot({ path: path.join(OUT, `rapport-annuel-${theme}.png`), fullPage: true });
      await page.goto(base + `#/a/${AID}/plus`, { waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(1200);
      check(await page.locator('form[data-form=pinset]').count() === 1, 'la carte « Verrou par code » est dans Mon profil');
      await page.fill('#pin-a', '1234'); await page.fill('#pin-b', '1234');
      await page.click('form[data-form=pinset] button[type=submit]');
      await page.waitForTimeout(800);
      check(await page.evaluate(() => !!localStorage.getItem('vl:pin')), 'le code PIN est enregistré');
      await page.reload({ waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(1200);
      check(await page.locator('.lock').count() === 1, 'l’écran de verrouillage s’affiche à l’ouverture');
      await page.screenshot({ path: path.join(OUT, `verrou-${theme}.png`) });
      await page.fill('.lock-in', '0000'); await page.click('.lock button[type=submit]'); await page.waitForTimeout(800);
      check(/Code incorrect/.test(await page.evaluate(() => document.body.innerText)), 'un mauvais code est refusé');
      await page.fill('.lock-in', '1234'); await page.click('.lock button[type=submit]'); await page.waitForTimeout(1200);
      check(await page.locator('.lock').count() === 0, 'le bon code déverrouille');
    }
    check(errors.length === 0, 'aucune erreur de code dans le navigateur' + (errors.length ? ' : ' + errors.slice(0, 3).join(' | ') : ''));
    await ctx.close();
  }
  await browser.close(); srv.close();
  console.log(failed ? `\n${failed} contrôle(s) en échec.` : '\nTout est bon.');
  process.exit(failed ? 1 : 0);
}
main().catch(e => { console.error(e); process.exit(1); });

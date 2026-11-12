// VillageLink — test de tous les écrans (audit B8), lancé par GitHub Actions, jamais en production.
// Ouvre chaque écran à 360 px avec une FAUSSE association « difficile » (noms très longs, montants
// au milliard en francs guinéens, lien sans espace dans une annonce), comme président en clair et
// en sombre, puis quelques écrans comme simple membre. Pour chaque écran : pas d'erreur de code,
// pas de message « Impossible d'afficher », rien qui dépasse de l'écran ni de sa carte.
// Usage : node tests/ecrans.cjs   (Playwright installé ; CHROME_PATH et ROOT facultatifs ;
//         CAPTURES=1 pour garder une capture de chaque écran, sinon seulement des écrans en échec)
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');

const ROOT = path.resolve(process.env.ROOT || path.join(__dirname, '..'));
const OUT = path.join(__dirname, 'captures', 'ecrans');
const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json' };
let failed = 0;
const ok = m => console.log('  ✓ ' + m);
const ko = m => { failed++; console.log('  ✗ ' + m); };

// ---------- Fausse association (aucune vraie donnée) ----------
const b64u = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const UID = id(1), UID2 = id(2), AID = id(10), ME = id(20), M2 = id(21), M3 = id(22);
const PID = id(30), RID = id(40), VID = id(50), O1 = id(51), O2 = id(52), CID = id(60), SID = id(70), KID = id(80), DID = id(90);
const now = new Date(), YM = now.toISOString().slice(0, 7), TODAY = now.toISOString().slice(0, 10);
const ago = d => new Date(now - d * 864e5).toISOString();
const LONG = 'Mamadou Saliou Bah Diallo de Kansaghel-Ndantari Wouri';
const BIG = 1234567890;
const ASSOC = { id: AID, name: 'Association des ressortissants et amis de Kansaghel-Ndantari pour le développement', origin_country: 'Guinée', region: 'Labé', prefecture: 'Lélouma', village: 'Kansaghel-Ndantari', residence_country: 'Sénégal', residence_city: 'Dakar-Pikine-Guédiawaye', description: 'Association de test.', founded_on: '2020-01-01', currency: 'GNF', fee_amount: 150000, fee_due_day: 5, dues_start: '2026-01-01', invite_code: 'ABCD1234', plan: 'federation', created_by: UID, created_at: '2026-01-01T00:00:00Z', expense_approval: true, trial_ends: '2099-01-01', paid_until: null, blocked_at: null, blocked_reason: null, cover_path: null };
const mem = (mid, uid, name, role, extra) => Object.assign({ id: mid, association_id: AID, user_id: uid, full_name: name, phone: '+224 620 00 00 00', email: 'membre.avec.une.adresse.tres.longue@exemple-de-domaine.org', city: 'Conakry-Ratoma-Kaloum', country: 'Guinée', role, joined_on: '2026-01-01', active: true, created_at: '2026-01-01T00:00:00Z', pending: false, created_by_join: false, section_id: SID, category_id: KID }, extra || {});
const MEMBERS = [mem(ME, UID, 'Alpha Test Président', 'president'), mem(M2, null, LONG, 'membre'), mem(M3, UID2, 'Woury Diallo Trésorière de section', 'tresorier')];
const TX = [
  { id: 1, association_id: AID, kind: 'in', category: 'Cotisations', amount: BIG, occurred_on: TODAY, description: 'Cotisation de ' + LONG + ' pour plusieurs mois de l’année', member_id: M2, period: YM, project_id: null, payment_method: 'Orange Money', comment: 'Référence MP251028.1234.A12345 très longue sans espace pour voir', proof_path: null, reversal_of: null, created_by: UID, created_at: ago(1), approved_label: null, requested_label: null, orig_amount: null, orig_currency: null, fx_rate: null, collection_id: null },
  { id: 2, association_id: AID, kind: 'out', category: 'Projets', amount: 987654321, occurred_on: TODAY, description: 'Achat de ciment et de fer pour le forage du quartier haut de Kansaghel', member_id: null, period: null, project_id: PID, payment_method: 'Virement', comment: '', proof_path: null, reversal_of: null, created_by: UID, created_at: ago(2), approved_label: 'Alpha Test Président', requested_label: 'Woury Diallo', orig_amount: null, orig_currency: null, fx_rate: null, collection_id: null }
];
const T = {
  associations: [ASSOC], members: MEMBERS, transactions: TX,
  v_balances: [{ association_id: AID, total_in: BIG * 9, total_out: 987654321 }],
  v_member_paid: [{ association_id: AID, member_id: M2, period: YM, paid: 150000 }],
  v_category_totals: [{ association_id: AID, kind: 'in', category: 'Cotisations', total: BIG * 9 }, { association_id: AID, kind: 'out', category: 'Projets', total: 987654321 }],
  v_project_totals: [{ project_id: PID, collected: BIG * 3, spent: 987654321 }],
  v_collection_totals: [{ collection_id: CID, collected: BIG, given: 500000000, contributions: 42 }],
  projects: [{ id: PID, association_id: AID, name: 'Forage et château d’eau du quartier haut de Kansaghel-Ndantari', type: 'Eau', description: 'Un forage avec pompe solaire pour 2 000 habitants.', goal: BIG * 5, lead_member_id: M2, status: 'En cours', start_on: '2026-01-01', end_on: '2026-12-31', created_by: UID, created_at: ago(30), public_slug: 'forage-kansaghel', public_contact: '+224 620 00 00 00' }],
  project_updates: [{ id: id(31), association_id: AID, project_id: PID, body: 'Les travaux ont commencé : https://exemple.org/un/lien/tres/long/sans/aucun/espace/pour/tester/le/debordement', created_by: UID, created_at: ago(3) }],
  announcements: [{ id: id(32), association_id: AID, kind: 'Nouvelles du village', title: 'Grande nouvelle pour tout le village de Kansaghel-Ndantari et ses environs', body: 'Voir https://exemple.org/un/lien/tres/long/sans/aucun/espace/pour/tester/le/debordement/de/la/page/entiere', created_by: UID, created_at: ago(1), audio_path: null, audio_seconds: null }],
  meetings: [{ id: RID, association_id: AID, title: 'Assemblée générale extraordinaire des ressortissants de Kansaghel', starts_at: new Date(now.getTime() + 3 * 864e5).toISOString(), place: 'Salle polyvalente de Pikine-Guédiawaye, à côté du marché', agenda: '1. Bilan\n2. Forage\n3. Divers', status: 'Prévue', minutes: '', created_by: UID, created_label: 'Alpha Test Président', created_at: ago(5), updated_at: ago(5) }],
  meeting_attendance: [{ meeting_id: RID, member_id: M2, association_id: AID, present: true, marked_by: 'Alpha Test', marked_at: ago(1) }],
  polls: [{ id: VID, association_id: AID, question: 'Faut-il augmenter la cotisation mensuelle pour financer le forage du quartier haut ?', description: 'Vote important.', anonymous: false, status: 'Ouvert', closes_at: null, created_by: UID, created_label: 'Alpha Test Président', created_at: ago(2), closed_at: null }],
  poll_options: [{ id: O1, poll_id: VID, association_id: AID, label: 'Oui, augmenter à 200 000 GNF par mois', position: 1 }, { id: O2, poll_id: VID, association_id: AID, label: 'Non', position: 2 }],
  poll_votes: [],
  messages: [{ id: 1, association_id: AID, kind: 'Idée', body: 'Une idée avec un lien https://exemple.org/un/lien/tres/long/sans/aucun/espace/pour/tester', author_id: UID2, author_label: LONG, hidden: false, hidden_by: null, created_at: ago(1), audio_path: null, audio_seconds: null }, { id: 2, association_id: AID, kind: 'Message', body: 'Message masqué', author_id: UID, author_label: 'Alpha Test Président', hidden: true, hidden_by: 'Alpha Test Président', created_at: ago(1), audio_path: null, audio_seconds: null }],
  documents: [{ id: DID, association_id: AID, title: 'Procès-verbal de l’assemblée générale du 10 octobre 2026 à Pikine', category: 'Procès-verbal', file_path: AID + '/pv.pdf', file_name: 'proces-verbal-assemblee-generale-2026-10-10-pikine-version-finale.pdf', mime: 'application/pdf', size: 123456, uploaded_by: UID, uploaded_label: 'Alpha Test Président', created_at: ago(10) }],
  collections: [{ id: CID, association_id: AID, kind: 'Solidarité', title: 'Soutien à la famille de notre frère hospitalisé à Conakry-Donka', beneficiary: LONG, description: 'Collecte de solidarité.', goal: BIG * 2, suggested: 100000, ends_on: '2026-12-31', status: 'Ouverte', created_by: UID, created_label: 'Alpha Test Président', created_at: ago(4), closed_at: null }],
  expense_requests: [{ id: 1, association_id: AID, category: 'Projets', amount: BIG, occurred_on: TODAY, description: 'Achat d’une pompe solaire pour le forage du quartier haut', project_id: PID, comment: '', proof_path: null, status: 'En attente', requested_by: UID2, requested_label: 'Woury Diallo Trésorière de section', decided_by: null, decided_label: null, decided_at: null, decision_note: null, tx_id: null, created_at: ago(1), orig_amount: null, orig_currency: null, fx_rate: null, collection_id: null }],
  payment_claims: [{ id: 1, association_id: AID, member_id: M3, period: YM, amount: 150000, method: 'Orange Money', sent_to: '620000000 (Association de Kansaghel)', reference: 'MP251028.1234.A12345', status: 'pending', created_by: UID2, created_at: ago(1), decided_by: null, decided_label: null, decided_at: null, reason: null, transaction_id: null }],
  sections: [{ id: SID, association_id: AID, name: 'Section de Dakar-Pikine-Guédiawaye et banlieue', city: 'Dakar', country: 'Sénégal', treasurer_member_id: M3, created_at: ago(40) }],
  member_categories: [{ id: KID, association_id: AID, name: 'Membres actifs résidant à l’étranger hors Afrique de l’Ouest', fee_amount: 150000, created_at: ago(40) }],
  member_exemptions: [], member_category_history: [], push_subscriptions: [], subscription_requests: [],
  fee_history: [{ id: 1, association_id: AID, category_id: null, from_period: '2026-01', fee_amount: 150000, created_at: ago(40) }],
  pay_numbers: [{ association_id: AID, holder: 'Association des ressortissants de Kansaghel', wave: '', orange: '620000000', free: '', updated_by: UID2, updated_at: ago(1), wave_link: '' }],
  activity_log: [{ id: 5, association_id: AID, actor_id: UID2, actor_label: LONG, message: 'a déclaré avoir payé 150 000 GNF par Orange Money pour novembre 2026.', created_at: ago(1) }]
};
const RPC = {
  my_memberships: () => [{ association_id: AID, name: ASSOC.name, village: ASSOC.village, residence_city: ASSOC.residence_city, pending: false, active: true }],
  member_contacts: () => MEMBERS.map(m => ({ id: m.id, phone: m.phone, email: m.email })),
  poll_results: () => [{ option_id: O1, votes: 12 }, { option_id: O2, votes: 3 }],
  server_now: () => new Date().toISOString(),
  assoc_status: () => 'trial', am_owner: () => false, exemption_reasons: () => []
};

// Lecture des filtres simples de l'API (col=eq.x, col=in.(a,b), limit) pour servir les fiches.
function query(table, u) {
  let list = (T[table] || []).slice();
  for (const [k, v] of u.searchParams) {
    if (k === 'select' || k === 'order' || k === 'offset') continue;
    if (k === 'limit') { list = list.slice(0, Number(v)); continue; }
    const m = /^(eq|in)\.(.*)$/.exec(v); if (!m) continue;
    const vals = m[1] === 'in' ? m[2].replace(/^\(|\)$/g, '').split(',').map(x => x.replace(/^"|"$/g, '')) : [m[2]];
    list = list.filter(r => !(k in r) || vals.includes(String(r[k])));
  }
  return list;
}
function mock(route) {
  const req = route.request(), u = new URL(req.url()), p = u.pathname, accept = req.headers()['accept'] || '';
  const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
  if (p.startsWith('/auth/v1/user')) return json({ id: route.__uid || UID, aud: 'authenticated', role: 'authenticated', email: 'test@exemple.fr', app_metadata: {}, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' });
  if (p.startsWith('/auth/v1/')) return json({});
  if (p.startsWith('/storage/v1/object/sign/')) return json({ signedURL: p.replace('/storage/v1', '') + '?token=test' });
  if (p.startsWith('/storage/v1/')) return route.fulfill({ status: 404, body: '' });
  const rpc = /^\/rest\/v1\/rpc\/(\w+)/.exec(p);
  if (rpc) return json(RPC[rpc[1]] ? RPC[rpc[1]]() : []);
  const tb = /^\/rest\/v1\/(\w+)/.exec(p);
  if (tb) {
    if (req.method() !== 'GET' && req.method() !== 'HEAD') return json({ message: 'test en lecture seule' }, 403);
    const list = query(tb[1], u);
    if (accept.includes('vnd.pgrst.object')) return list.length ? json(list[0]) : json({ code: 'PGRST116', message: '0 rows', details: null, hint: null }, 406);
    return route.fulfill({ status: 200, contentType: 'application/json', headers: { 'content-range': `0-${Math.max(list.length - 1, 0)}/${list.length}` }, body: JSON.stringify(list) });
  }
  return json({});
}

// Ce qui dépasse : de l'écran, ou de sa carte (sauf dans une zone qui défile exprès).
const OVERFLOW = () => {
  const W = window.innerWidth, out = [];
  if (document.documentElement.scrollWidth > W + 1) out.push(`la page est plus large que l’écran (${document.documentElement.scrollWidth - W} px)`);
  const scrolls = el => { for (let e = el.parentElement; e && e !== document.body; e = e.parentElement) { const ox = getComputedStyle(e).overflowX; if (ox === 'auto' || ox === 'scroll' || ox === 'hidden') return true; } return false; };
  for (const el of document.querySelectorAll('#app *, .auth *')) {
    if (!el.childNodes.length || el.closest('.no-print[hidden], [hidden], .sr-only')) continue;
    const hasText = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
    if (!hasText) continue;
    const r = el.getBoundingClientRect(); if (!r.width || !r.height) continue;
    const card = el.closest('.card, .item, .hero');
    const limit = card && card !== el ? card.getBoundingClientRect().right : W;
    if (r.right > limit + 1 && !scrolls(el)) out.push(`« ${el.textContent.trim().slice(0, 40)} » dépasse de ${Math.round(r.right - limit)} px`);
    if (out.length >= 4) break;
  }
  return out;
};

const PRES = ['', 'vie', 'caisse', 'membres', 'membres?f=late', `m/${M2}`, 'cotisations', 'cotisations?f=late', 'cotisations?f=claims', 'encaisser', `encaisser?m=${M2}`, 'abonnement', 'payer', 'finances', 'op/1', 'op/1?recu=1', 'op/2', 'sections', 'collectes', `collecte/${CID}`, 'depenses', 'depense/1', 'transparence', 'projets', `p/${PID}`, 'annonces', 'reunions', `r/${RID}`, `r/${RID}/feuille`, 'votes', `vote/${VID}`, 'documents', `rapport?m=${YM}`, 'rapportannuel', 'notifications', 'discussion', 'journal', 'plus', 'parametres'];
const MEMB = ['', 'cotisations', 'payer', 'finances', 'plus'];

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
  const ref = (fs.readFileSync(path.join(ROOT, 'config.js'), 'utf8').match(/https:\/\/(\w+)\.supabase/) || [])[1];
  const { chromium } = require('playwright');
  const browser = await chromium.launch(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {});
  const runs = [['président', UID, 'light', PRES], ['président', UID, 'dark', PRES], ['membre', UID2, 'light', MEMB]];
  for (const [who, uid, theme, screens] of runs) {
    console.log(`Écrans du ${who}, thème ${theme === 'light' ? 'clair' : 'sombre'} (360 px)`);
    if (who === 'membre') { MEMBERS[2].role = 'membre'; } else { MEMBERS[2].role = 'tresorier'; }
    const exp = Math.floor(Date.now() / 1000) + 3600 * 5;
    const jwt = [b64u({ alg: 'HS256', typ: 'JWT' }), b64u({ sub: uid, role: 'authenticated', aud: 'authenticated', exp }), 'sig'].join('.');
    const session = { access_token: jwt, refresh_token: 'r', token_type: 'bearer', expires_in: 18000, expires_at: exp, user: { id: uid, aud: 'authenticated', role: 'authenticated', email: 'test@exemple.fr', app_metadata: {}, user_metadata: {}, created_at: '2026-01-01T00:00:00Z' } };
    const ctx = await browser.newContext({ viewport: { width: 360, height: 740 }, colorScheme: theme, serviceWorkers: 'block' });
    await ctx.addInitScript(([key, val, th]) => { try { localStorage.setItem(key, val); localStorage.setItem('vl:theme', th); } catch (e) { /* ignoré */ } }, [`sb-${ref}-auth-token`, JSON.stringify(session), theme]);
    await ctx.route(url => url.hostname.endsWith('.supabase.co'), r => { r.__uid = uid; return mock(r); });
    const page = await ctx.newPage();
    let errors = [];
    page.on('pageerror', e => errors.push(String(e.message || e).slice(0, 160)));
    page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource|ERR_|net::|fonts\.g/i.test(m.text())) errors.push(m.text().slice(0, 160)); });
    for (const s of screens) {
      errors = [];
      await page.goto(base + `#/a/${AID}/${s}`, { waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(700);
      try { await page.waitForFunction(() => !document.querySelector('.loading'), null, { timeout: 8000 }); } catch (e) { /* vérifié plus bas */ }
      await page.waitForTimeout(250);
      const txt = await page.evaluate(() => document.body.innerText);
      const pb = [...errors];
      if (/Impossible d’afficher|Configuration incomplète/.test(txt)) pb.push('message d’erreur à l’écran');
      if (/Chargement…/.test(txt) && txt.length < 200) pb.push('l’écran reste sur « Chargement… »');
      pb.push(...await page.evaluate(OVERFLOW));
      const name = (s || 'accueil').replace(/[^\w-]+/g, '_').slice(0, 40);
      if (!s) {   // Alerte « numéros de paiement changés » (audit S9) : chez le président seulement
        const n = await page.locator('.pay-alert').count();
        if (who === 'président' && n !== 1) pb.push('l’alerte « Numéros de paiement changés » manque');
        if (who === 'membre' && n !== 0) pb.push('l’alerte des numéros s’affiche chez un simple membre');
        if (who === 'président' && n === 1 && theme === 'dark') {
          await page.click('.pay-alert [data-act=paynum-ok]'); await page.waitForTimeout(1200);
          if (await page.locator('.pay-alert').count() !== 0) pb.push('l’alerte des numéros ne disparaît pas après confirmation');
        }
      }
      if (pb.length || process.env.CAPTURES) await page.screenshot({ path: path.join(OUT, `${who}-${theme}-${name}.png`), fullPage: true });
      if (pb.length) ko(`${s || 'accueil'} : ${pb.join(' ; ')}`); else ok(s || 'accueil');
    }
    await ctx.close();
  }
  await browser.close(); srv.close();
  console.log(failed ? `\n${failed} écran(s) en échec (captures dans tests/captures/ecrans/).` : '\nTout est bon.');
  process.exit(failed ? 1 : 0);
}
main().catch(e => { console.error(e); process.exit(1); });

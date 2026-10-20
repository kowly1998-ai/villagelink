/* VillageLink — application web (sans compilation).
   Données : Supabase. Sécurité : règles de la base (voir supabase/schema.sql). */
'use strict';
(function () {
  const CFG = window.VILLAGELINK_CONFIG || {};
  const root = document.getElementById('root');
  const NB = ' ';

  /* ------------------------------------------------------------------
     Démarrage
  ------------------------------------------------------------------ */
  if (!window.supabase || !CFG.supabaseUrl || /COLLEZ/.test(CFG.supabaseUrl + CFG.supabaseAnonKey)) {
    root.innerHTML = `<div class="auth"><div class="brand"><div class="logo">V</div><b>VillageLink</b></div>
      <section class="card stack"><h2>Configuration incomplète</h2>
      <p class="muted" style="margin:0">${!window.supabase
        ? 'La bibliothèque Supabase n’a pas pu se charger. Vérifiez votre connexion internet puis rechargez la page.'
        : 'Ouvrez le fichier <b>config.js</b> et collez l’adresse et la clé publique de votre projet Supabase.'}</p></section></div>`;
    return;
  }
  const sb = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  const S = { session: null, user: null, ctx: null, authMode: 'login', authMsg: '' };

  /* ------------------------------------------------------------------
     Outils
  ------------------------------------------------------------------ */
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const $ = s => document.querySelector(s);
  const pad = n => String(n).padStart(2, '0');
  const MOIS = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
  const MOISL = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
  const nf = new Intl.NumberFormat('fr-FR', { maximumFractionDigits: 0 });
  const CUR_LABEL = { XOF: 'FCFA', XAF: 'FCFA', GNF: 'GNF', EUR: '€', USD: '$', CAD: '$ CA', GBP: '£' };
  const num = n => nf.format(Math.round(Number(n) || 0)).replace(/[   ]/g, NB);
  const money = (n, cur) => num(n) + NB + (CUR_LABEL[cur || (S.ctx && S.ctx.assoc.currency)] || 'FCFA');
  const moneyW = n => money(n).replace(/\u00a0(\S+)$/, ' $1');
  const todayISO = () => { const d = new Date(); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };
  const curYM = () => todayISO().slice(0, 7);
  const ym = d => String(d || '').slice(0, 7);
  const dFR = d => { if (!d) return ''; const s = String(d); if (s.length > 10) { const x = new Date(s); return `${x.getDate()}${NB}${MOIS[x.getMonth()]} ${x.getFullYear()}`; } const [y, m, da] = s.split('-').map(Number); return `${da}${NB}${MOIS[m - 1]} ${y}`; };
  const hm = ts => { const x = new Date(ts); return `${pad(x.getHours())}h${pad(x.getMinutes())}`; };
  const localDay = ts => { const x = new Date(ts); return `${x.getFullYear()}-${pad(x.getMonth() + 1)}-${pad(x.getDate())}`; };
  const whenTx = t => !t.created_at ? dFR(t.occurred_on) : (localDay(t.created_at) === String(t.occurred_on)
    ? `${dFR(t.occurred_on)} à ${hm(t.created_at)}` : `${dFR(t.occurred_on)} (saisi le ${dFR(localDay(t.created_at))} à ${hm(t.created_at)})`);
  const JOURS = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];
  const dLong = ts => { const x = new Date(ts); return `${JOURS[x.getDay()]} ${x.getDate()}${NB}${MOISL[x.getMonth()]} ${x.getFullYear()} à ${hm(ts)}`; };
  const pFR = p => { const [y, m] = String(p).split('-').map(Number); return `${MOISL[m - 1]} ${y}`; };
  const addMonth = (p, k) => { let [y, m] = p.split('-').map(Number); m += k; while (m > 12) { m -= 12; y++; } while (m < 1) { m += 12; y--; } return `${y}-${pad(m)}`; };
  const monthsBetween = (a, b) => { const out = []; let p = a; let guard = 0; while (p <= b && guard++ < 600) { out.push(p); p = addMonth(p, 1); } return out; };
  const initials = n => String(n || '?').split(/\s+/).filter(Boolean).map(w => w[0]).slice(0, 2).join('').toUpperCase();
  const txRef = id => 'TX-' + String(id).padStart(5, '0');
  const digits = s => String(s || '').replace(/\D/g, '');
  const waShare = text => 'https://wa.me/?text=' + encodeURIComponent(text);
  const waTo = (phone, text) => { const p = String(phone || '').trim(); const d = digits(p); return (p.startsWith('+') || p.startsWith('00')) && d.length >= 10 ? `https://wa.me/${d.replace(/^00/, '')}?text=${encodeURIComponent(text)}` : waShare(text); };
  const go = h => { if (location.hash === h) route(); else location.hash = h; };
  const store = { get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* stockage indisponible */ } } };

  /* Thème : clair par défaut, comme la maquette ; sombre ou automatique au choix dans Plus */
  const THEMES = [['light', 'Clair'], ['dark', 'Sombre'], ['auto', 'Auto']];
  const themeNow = () => { const t = store.get('vl:theme'); return t === 'dark' || t === 'auto' ? t : 'light'; };
  const applyTheme = () => { const t = themeNow(), el = document.documentElement; if (t === 'auto') el.removeAttribute('data-theme'); else el.setAttribute('data-theme', t);
    const dark = t === 'dark' || (t === 'auto' && window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches);
    const meta = document.querySelector('meta[name=theme-color]'); if (meta) meta.setAttribute('content', dark ? '#140C1F' : '#F5F2FA'); };
  applyTheme();

  function errMsg(e) {
    const m = (e && (e.message || e.error_description)) || String(e);
    if (/row-level security|permission denied/i.test(m)) return 'Vous n’avez pas le droit de faire cette action.';
    if (/Invalid login credentials/i.test(m)) return 'Email ou mot de passe incorrect.';
    if (/provider is not enabled|Unsupported provider/i.test(m)) return 'La connexion avec Google n’est pas encore activée. Utilisez votre email pour l’instant.';
    if (/already registered/i.test(m)) return 'Un compte existe déjà avec cet email. Connectez-vous.';
    if (/Email not confirmed/i.test(m)) return 'Confirmez d’abord votre email avec le lien reçu, puis connectez-vous.';
    if (/Password should be at least/i.test(m)) return 'Le mot de passe doit faire au moins 8 caractères.';
    if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'Pas de connexion internet. Réessayez dans un instant.';
    if (/rate limit|too many/i.test(m)) return 'Trop de tentatives. Patientez quelques minutes.';
    if (/duplicate key/i.test(m)) return 'Cet élément existe déjà.';
    return m;
  }
  function must(res) { if (res.error) throw res.error; return res.data; }
  async function fetchAll(make, size = 1000) {
    const out = [];
    for (let from = 0; from < 100000; from += size) {
      const rows = must(await make().range(from, from + size - 1));
      out.push(...rows);
      if (rows.length < size) break;
    }
    return out;
  }
  let toastT;
  function toast(t) { const el = $('#toast'); el.textContent = t; el.hidden = false; clearTimeout(toastT); toastT = setTimeout(() => { el.hidden = true; }, 2800); }

  const I = {
    plus: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>',
    home: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z"/></svg>',
    users: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.8-3.6 3.4-5.5 6.5-5.5s5.7 1.9 6.5 5.5M16 4.6a3.5 3.5 0 0 1 0 6.8M18 14.8c1.9.7 3.1 2.4 3.5 5.2"/></svg>',
    wallet: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><rect x="3" y="6" width="18" height="14" rx="2.5"/><path d="M3 10.5h18M16 15h2"/></svg>',
    drop: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><path d="M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z"/><path d="M9.5 15a2.6 2.6 0 0 0 2.5 2.5" stroke-linecap="round"/></svg>',
    more: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/></svg>',
    bell: '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><path d="M6 16v-5a6 6 0 0 1 12 0v5l2 2H4z"/><path d="M10 20.5a2 2 0 0 0 4 0" stroke-linecap="round"/></svg>',
    back: '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 5-7 7 7 7"/></svg>',
    chev: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 5 7 7-7 7"/></svg>',
    eye: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>',
    list: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01"/></svg>',
    mega: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><path d="M3 10v4h4l7 5V5L7 10z"/><path d="M18 9a4 4 0 0 1 0 6" stroke-linecap="round"/></svg>',
    clock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
    vote: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round" stroke-linecap="round"><path d="M4 13h16v7H4z"/><path d="M8 13V5h8v8"/><path d="m10 9 1.5 1.5L14 8"/></svg>',
    doc: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round" stroke-linecap="round"><path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 12h6M9 16h6"/></svg>',
    report: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round" stroke-linecap="round"><path d="M5 3h14v18H5z"/><path d="M9 16v-3M12 16V9M15 16v-5"/></svg>',
    cal: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4" stroke-linecap="round"/><path d="m9 15 2 2 4-4" stroke-linecap="round"/></svg>',
    gear: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9"><circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1" stroke-linecap="round"/></svg>',
    swap: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M7 7h12l-3-3M17 17H5l3 3"/></svg>',
    out: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3M10 17l5-5-5-5M15 12H4"/></svg>',
    chat: '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><path d="M4 5h16v11H9l-5 4z"/><path d="M8 9.5h8M8 12.5h5" stroke-linecap="round"/></svg>',
    wa: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2zm0 18.2a8.2 8.2 0 0 1-4.2-1.2l-.3-.2-3 .8.8-2.9-.2-.3A8.2 8.2 0 1 1 12 20.2zm4.5-6.1c-.2-.1-1.5-.7-1.7-.8s-.4-.1-.6.1-.6.8-.8 1-.3.2-.5.1a6.7 6.7 0 0 1-3.3-2.9c-.3-.4.2-.4.7-1.4.1-.2 0-.3 0-.4l-.8-1.8c-.2-.5-.4-.4-.6-.4h-.5a1 1 0 0 0-.7.3 3 3 0 0 0-.9 2.2 5.2 5.2 0 0 0 1.1 2.7 11.8 11.8 0 0 0 4.5 4c1.7.7 2.3.8 3.2.6a2.7 2.7 0 0 0 1.8-1.2 2.2 2.2 0 0 0 .2-1.2c-.1-.1-.3-.2-.5-.3z"/></svg>'
  };

  /* ------------------------------------------------------------------
     Rôles et droits (la base les vérifie aussi)
  ------------------------------------------------------------------ */
  const ROLES = { president: 'Président', vice_president: 'Vice-président', secretaire: 'Secrétaire général', tresorier: 'Trésorier', projets: 'Responsable des projets', membre: 'Membre' };
  const CAN = {
    members: ['president', 'vice_president', 'secretaire', 'tresorier'],
    roles: ['president'],
    collect: ['tresorier', 'president', 'vice_president'],
    spend: ['tresorier'],
    reverse: ['tresorier'],
    projects: ['president', 'vice_president', 'projets'],
    announce: ['president', 'vice_president', 'secretaire'],
    meetings: ['president', 'vice_president', 'secretaire'],
    polls: ['president', 'vice_president', 'secretaire'],
    docs: ['president', 'vice_president', 'secretaire', 'tresorier'],
    settings: ['president']
  };
  const can = a => !!(S.ctx && S.ctx.me && CAN[a].includes(S.ctx.me.role));
  const CAT_IN = ['Dons', 'Contributions exceptionnelles', 'Autres'];
  const CAT_OUT = ['Projet', 'Transport', 'Réunion', 'Communication', 'Administration', 'Autres'];
  const MODES = ['Espèces', 'Wave', 'Orange Money', 'Free Money', 'MTN Mobile Money', 'Virement', 'Autre'];
  const PROJECT_TYPES = ['École', 'Forage', 'Mosquée', 'Route', 'Électrification', 'Centre de santé', 'Matériel agricole', 'Autre'];
  const STATUSES = ['En préparation', 'En cours', 'Suspendu', 'Terminé'];
  const ANN_KINDS = ['Annonce', 'Information', 'Convocation', 'Nouvelles du village', 'Urgence'];
  const CURRENCIES = [['XOF', 'Franc CFA (XOF)'], ['GNF', 'Franc guinéen (GNF)'], ['EUR', 'Euro'], ['USD', 'Dollar US'], ['XAF', 'Franc CFA (XAF)'], ['CAD', 'Dollar canadien'], ['GBP', 'Livre sterling']];

  /* ------------------------------------------------------------------
     Contexte d'une association
  ------------------------------------------------------------------ */
  async function loadCtx(id) {
    const [a, members, paid, bal] = await Promise.all([
      sb.from('associations').select('*').eq('id', id).maybeSingle().then(must),
      fetchAll(() => sb.from('members').select('*').eq('association_id', id).order('full_name').order('id')),
      fetchAll(() => sb.from('v_member_paid').select('member_id,period,paid').eq('association_id', id).order('period').order('member_id')),
      sb.from('v_balances').select('*').eq('association_id', id).maybeSingle().then(must)
    ]);
    if (!a) { S.ctx = null; return null; }
    let lastMsg = 0;
    try { const r = await sb.from('messages').select('id').eq('association_id', id).order('id', { ascending: false }).limit(1); if (!r.error && r.data[0]) lastMsg = r.data[0].id; } catch (e) { /* discussion pas encore installée */ }
    let notif = 0, lastLog = 0;
    try {
      const r = await sb.from('activity_log').select('id').eq('association_id', id).order('id', { ascending: false }).limit(1);
      if (!r.error && r.data[0]) lastLog = r.data[0].id;
      const seenKey = 'vl:notif:' + id, seen = Number(store.get(seenKey) || 0);
      if (!store.get(seenKey)) store.set(seenKey, String(lastLog));
      else if (lastLog > seen) {
        const n = await sb.from('activity_log').select('id').eq('association_id', id).gt('id', seen).neq('actor_id', S.user.id).limit(99);
        if (!n.error) notif = n.data.length;
      }
    } catch (e) { /* pas bloquant */ }
    try { if (navigator.setAppBadge) { if (notif) navigator.setAppBadge(notif); else navigator.clearAppBadge(); } } catch (e) { /* non pris en charge */ }
    const paidMap = new Map();
    paid.forEach(r => paidMap.set(r.member_id + '|' + r.period, Number(r.paid)));
    const me = members.find(m => m.user_id === S.user.id) || null;
    S.ctx = { loadedAt: Date.now(), lastMsg, notif, lastLog, assoc: a, me, members, byId: new Map(members.map(m => [m.id, m])), paidMap,
      bal: { in: Number(bal ? bal.total_in : 0), out: Number(bal ? bal.total_out : 0) } };
    store.set('vl:last', id);
    return S.ctx;
  }
  const refresh = () => loadCtx(S.ctx.assoc.id);
  const paidFor = (mid, p) => S.ctx.paidMap.get(mid + '|' + p) || 0;
  function dues(m) {
    const a = S.ctx.assoc, fee = Number(a.fee_amount) || 0, cur = curYM();
    if (!fee || !m.active || m.pending) return { owed: [], late: [], remaining: 0, isLate: false };
    const start = [ym(a.dues_start), ym(m.joined_on)].sort().pop();
    const periods = start <= cur ? monthsBetween(start, cur) : [];
    const owed = periods.filter(p => paidFor(m.id, p) < fee);
    // Un mois est en retard quand son échéance est passée. Pour les mois suivis depuis la
    // création de l'association dans l'app, l'échéance doit aussi tomber après l'adhésion
    // et après cette création (sinon tout le monde serait en retard dès le premier jour).
    const created = String(a.created_at || '').slice(0, 10) || todayISO();
    const since = [created, String(m.joined_on || '')].sort().pop();
    const isLate = p => {
      const due = `${p}-${pad(a.fee_due_day)}`;
      if (due >= todayISO()) return false;
      if (p < ym(created)) return true;
      return due >= since;
    };
    const late = owed.filter(isLate);
    return { owed, late, remaining: owed.reduce((s, p) => s + fee - paidFor(m.id, p), 0), isLate: late.length > 0 };
  }
  const activeMembers = () => S.ctx.members.filter(m => m.active && !m.pending);
  const pendingMembers = () => S.ctx.members.filter(m => m.pending);
  const lateMembers = () => activeMembers().filter(m => dues(m).isLate);
  const memberName = id => (S.ctx.byId.get(id) || {}).full_name || 'Membre retiré';
  const statusPill = m => {
    if (m.pending) return '<span class="pill p-late">Demande en attente</span>';
    if (!m.active) return '<span class="pill p-blue">Retiré</span>';
    if (!Number(S.ctx.assoc.fee_amount)) return '';
    const d = dues(m);
    if (d.isLate) return `<span class="pill p-late">${d.late.length > 1 ? d.late.length + ' mois de retard' : 'En retard'}</span>`;
    if (d.owed.length) return '<span class="pill p-blue">À payer</span>';
    return '<span class="pill p-ok">À jour</span>';
  };

  /* ------------------------------------------------------------------
     Routeur
  ------------------------------------------------------------------ */
  function parseHash() {
    const h = location.hash.replace(/^#/, '') || '/';
    const [path, qs] = h.split('?');
    return { parts: path.split('/').filter(Boolean), q: new URLSearchParams(qs || '') };
  }

  async function route() {
    if (/^#(access_token|error)=/.test(location.hash)) {
      const p = new URLSearchParams(location.hash.slice(1));
      if (p.get('error')) { S.authMsg = 'Ce lien a expiré ou a déjà servi. Demandez-en un nouveau.'; history.replaceState(null, '', location.pathname); }
      else return;
    }
    const { parts, q } = parseHash();
    try {
      if (!S.session) { if (!document.querySelector('form[data-form=auth]')) renderAuth(); return; }
      if (parts[0] === 'mot-de-passe') return renderNewPassword();
      if (parts[0] === 'bienvenue') return await renderWelcome();
      if (parts[0] === 'a' && parts[1]) return await renderAssoc(parts[1], parts.slice(2), q);
      return await goHome();
    } catch (e) {
      console.error(e);
      root.innerHTML = `<div class="auth"><section class="card stack"><h2>Impossible d’afficher la page</h2><p class="muted" style="margin:0">${esc(errMsg(e))}</p><button class="btn primary" data-act="reload">Réessayer</button><a class="link" href="#/bienvenue">Revenir à mes associations</a></section></div>`;
    }
  }

  async function goHome() {
    const last = store.get('vl:last');
    let rows;
    try { rows = must(await sb.rpc('my_memberships')); }
    catch (e) { if (last) return go('#/a/' + last); throw e; }   // hors ligne : on rouvre la dernière association
    const list = rows.filter(a => a.active && !a.pending).map(a => ({ id: a.association_id, name: a.name }));
    if (list.length === 1) return go('#/a/' + list[0].id);
    if (last && list.some(a => a.id === last)) return go('#/a/' + last);
    return go('#/bienvenue');
  }

  /* ------------------------------------------------------------------
     Connexion
  ------------------------------------------------------------------ */
  function renderAuth() {
    const m = S.authMode;
    root.innerHTML = `<div class="auth">
      <div class="brand"><div class="logo">V</div><b>VillageLink</b></div>
      <p class="lead">L’argent de l’association, visible par tous les membres.</p>
      ${m !== 'reset' ? `<div class="seg" role="group"><button data-act="auth-mode" data-mode="login" aria-pressed="${m === 'login'}">Se connecter</button><button data-act="auth-mode" data-mode="signup" aria-pressed="${m === 'signup'}">Créer un compte</button></div>` : ''}
      ${S.authMsg ? `<p class="note">${esc(S.authMsg)}</p>` : ''}
      ${m !== 'reset' && (window.VILLAGELINK_CONFIG || {}).google !== false ? `<button class="btn ghost block google-btn" type="button" data-act="google"><svg width="20" height="20" viewBox="0 0 48 48" aria-hidden="true"><path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"/><path fill="#FF3D00" d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"/><path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"/><path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z"/></svg> Continuer avec Google</button><div class="or"><span>ou avec votre email</span></div>` : ''}
      <form class="card stack" data-form="auth" novalidate>
        <div class="field"><label for="au-email">Email</label><input id="au-email" name="email" type="email" autocomplete="email" inputmode="email" required></div>
        ${m !== 'reset' ? `<div class="field"><label for="au-pw">Mot de passe</label><input id="au-pw" name="password" type="password" autocomplete="${m === 'signup' ? 'new-password' : 'current-password'}" minlength="8" required>${m === 'signup' ? '<p class="help">8 caractères minimum.</p>' : ''}</div>` : ''}
        <p class="err" hidden></p>
        <button class="btn primary block" type="submit">${m === 'login' ? 'Se connecter' : m === 'signup' ? 'Créer mon compte' : 'Recevoir le lien'}</button>
        ${m === 'login' ? '<button class="link" type="button" data-act="auth-mode" data-mode="reset">Mot de passe oublié ?</button>' : ''}
        ${m === 'reset' ? '<button class="link" type="button" data-act="auth-mode" data-mode="login">Retour à la connexion</button>' : ''}
      </form>
      <p class="help">Les membres sans smartphone n’ont pas besoin de compte : le trésorier enregistre leurs paiements.</p>
      <p class="help">En continuant, vous acceptez les <a class="link" href="conditions.html">conditions d’utilisation</a> et la <a class="link" href="confidentialite.html">politique de confidentialité</a>.</p>
    </div>`;
  }

  function renderNewPassword() {
    root.innerHTML = `<div class="auth"><div class="brand"><div class="logo">V</div><b>VillageLink</b></div>
      <form class="card stack" data-form="newpw" novalidate><h2>Nouveau mot de passe</h2>
      <div class="field"><label for="np-pw">Mot de passe</label><input id="np-pw" name="password" type="password" autocomplete="new-password" minlength="8" required></div>
      <p class="err" hidden></p><button class="btn primary block" type="submit">Enregistrer</button></form></div>`;
  }

  /* ------------------------------------------------------------------
     Accueil sans association : créer ou rejoindre
  ------------------------------------------------------------------ */
  async function renderWelcome() {
    const list = must(await sb.rpc('my_memberships')).filter(a => a.active || a.pending);
    root.innerHTML = `<div class="auth" style="max-width:520px">
      <div class="between"><div class="brand"><div class="logo">V</div><b>VillageLink</b></div><button class="btn ghost sm" data-act="signout">Déconnexion</button></div>
      ${list.some(a => a.pending) ? '<button class="btn ghost block" data-act="reload">Actualiser : ma demande a-t-elle été validée ?</button>' : ''}
      ${list.length ? `<section class="stack"><span class="eyebrow">Mes associations</span><div class="list">${list.map(a => a.pending
        ? `<div class="item"><div class="logo" style="width:40px;height:40px;font-size:18px">${esc(initials(a.name).slice(0, 1))}</div><div class="body"><div class="t">${esc(a.name)}</div><div class="s wrap">Demande envoyée. Un membre du bureau doit la valider.</div></div><span class="pill p-late">En attente</span></div>`
        : `<a class="item" href="#/a/${a.association_id}"><div class="logo" style="width:40px;height:40px;font-size:18px">${esc(initials(a.name).slice(0, 1))}</div><div class="body"><div class="t">${esc(a.name)}</div><div class="s">${esc([a.village, a.residence_city].filter(Boolean).join(' · '))}</div></div><span class="chev">${I.chev}</span></a>`).join('')}</div></section>` : '<p class="lead">Bienvenue. Rejoignez votre association avec le code donné par le bureau, ou créez-la si vous en êtes le président.</p>'}
      <form class="card stack" data-form="join" novalidate><h2>Rejoindre une association</h2>
        <div class="field"><label for="jn-code">Code d’invitation</label><input id="jn-code" name="code" autocapitalize="characters" placeholder="Ex. 7K2P9QXA" required></div>
        <div class="field"><label for="jn-name">Votre nom complet</label><input id="jn-name" name="full_name" autocomplete="name" required></div>
        <div class="field"><label for="jn-phone">Votre téléphone</label><input id="jn-phone" name="phone" type="tel" inputmode="tel" autocomplete="tel" placeholder="+221 77 000 00 00"><p class="help">Si le trésorier vous a déjà inscrit avec ce numéro, votre historique de cotisations vous suit. Le bureau valide chaque demande.</p></div>
        <p class="err" hidden></p><button class="btn primary block" type="submit">Rejoindre</button></form>
      <form class="card stack" data-form="create" novalidate><h2>Créer une association</h2><p class="help">Vous en deviendrez le président. Vous pourrez ensuite nommer le trésorier et le reste du bureau.</p>
        <div class="field"><label for="cr-name">Nom de l’association</label><input id="cr-name" name="name" placeholder="Ex. Ressortissants de Kansaghel au Sénégal" required></div>
        <div class="field"><label for="cr-you">Votre nom complet</label><input id="cr-you" name="full_name" autocomplete="name" required></div>
        <div class="field"><label for="cr-phone">Votre téléphone</label><input id="cr-phone" name="phone" type="tel" inputmode="tel" autocomplete="tel"></div>
        <span class="eyebrow">Village d’origine</span>
        <div class="row2"><div class="field"><label for="cr-village">Village ou ville</label><input id="cr-village" name="village" required></div><div class="field"><label for="cr-ocountry">Pays</label><input id="cr-ocountry" name="origin_country" placeholder="Ex. Guinée"></div></div>
        <div class="row2"><div class="field"><label for="cr-region">Région</label><input id="cr-region" name="region"></div><div class="field"><label for="cr-pref">Préfecture</label><input id="cr-pref" name="prefecture"></div></div>
        <span class="eyebrow">Où vit l’association</span>
        <div class="row2"><div class="field"><label for="cr-rcity">Ville</label><input id="cr-rcity" name="residence_city" placeholder="Ex. Dakar"></div><div class="field"><label for="cr-rcountry">Pays</label><input id="cr-rcountry" name="residence_country" placeholder="Ex. Sénégal"></div></div>
        <span class="eyebrow">Cotisation</span>
        <div class="row2"><div class="field"><label for="cr-cur">Monnaie</label><select id="cr-cur" name="currency">${CURRENCIES.map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select></div><div class="field"><label for="cr-fee">Montant par mois</label><input id="cr-fee" name="fee" type="number" inputmode="numeric" min="0" step="1" placeholder="Ex. 5000"></div></div>
        <div class="field"><label for="cr-due">Jour d’échéance chaque mois</label><input id="cr-due" name="due_day" type="number" inputmode="numeric" min="1" max="28" value="5"></div>
        <p class="err" hidden></p><button class="btn primary block" type="submit">Créer l’association</button></form>
    </div>`;
  }

  /* ------------------------------------------------------------------
     Cadre d'une association
  ------------------------------------------------------------------ */
  const TABS = [['', 'Accueil', I.home], ['membres', 'Membres', I.users], ['cotisations', 'Cotisations', I.wallet], ['projets', 'Projets', I.drop], ['plus', 'Plus', I.more]];
  const TAB_OF = { '': '', membres: 'membres', m: 'membres', cotisations: 'cotisations', encaisser: 'cotisations', projets: 'projets', p: 'projets', plus: 'plus' };

  async function renderAssoc(id, sub, q) {
    if (!S.ctx || S.ctx.assoc.id !== id) {
      root.innerHTML = '<div class="loading">Chargement de l’association…</div>';
      await loadCtx(id);
    } else if (Date.now() - S.ctx.loadedAt > 15000) {
      // Données de plus de 15 secondes : on recharge pour voir les nouvelles demandes, paiements, etc.
      try { await loadCtx(id); } catch (e) { console.error(e); }
    }
    if (!S.ctx) {
      const mine = (must(await sb.rpc('my_memberships')) || []).find(a => a.association_id === id);
      if (mine && mine.pending) {
        root.innerHTML = `<div class="auth"><section class="card stack"><h2>Demande en attente</h2><p class="muted" style="margin:0">Votre demande pour rejoindre « ${esc(mine.name)} » doit être validée par le président, le secrétaire ou le trésorier. Prévenez-les sur WhatsApp.</p><a class="btn primary" href="#/bienvenue">Mes associations</a></section></div>`;
        return;
      }
      root.innerHTML = `<div class="auth"><section class="card stack"><h2>Association introuvable</h2><p class="muted" style="margin:0">Elle n’existe pas, ou vous n’en êtes pas membre.</p><a class="btn primary" href="#/bienvenue">Mes associations</a></section></div>`;
      return;
    }
    if (!S.ctx.me || !S.ctx.me.active) {
      root.innerHTML = `<div class="auth"><section class="card stack"><h2>Accès suspendu</h2><p class="muted" style="margin:0">Votre fiche de membre est désactivée. Contactez le bureau de l’association.</p><a class="btn primary" href="#/bienvenue">Mes associations</a></section></div>`;
      return;
    }
    const a = S.ctx.assoc, base = '#/a/' + a.id;
    const tab = TAB_OF[sub[0] || ''] ?? 'plus';
    root.innerHTML = `<div id="app">
      <header class="top"><a class="org" href="${base}"><div class="logo" aria-hidden="true">${esc(initials(a.name).slice(0, 1))}</div>
        <div style="min-width:0"><b>${esc(a.name)}</b><small>${esc([a.village, a.region, a.origin_country].filter(Boolean).join(' · '))}</small></div></a>
        <a class="iconbtn" href="${base}/discussion" aria-label="Discussion">${I.chat}${S.ctx.lastMsg > Number(store.get('vl:seen:' + a.id) || 0) ? '<span class="badge-dot">•</span>' : ''}</a>
        <a class="iconbtn" href="${base}/notifications" aria-label="Notifications${S.ctx.notif ? ' : ' + S.ctx.notif + ' nouvelle' + (S.ctx.notif > 1 ? 's' : '') : ''}">${I.bell}${S.ctx.notif ? `<span class="badge-dot num">${S.ctx.notif > 9 ? '9+' : S.ctx.notif}</span>` : ''}</a></header>
      <main id="view"><div class="loading">Chargement…</div></main>
      <nav class="tabs" aria-label="Navigation principale"><div class="tabs-in">${TABS.map(([k, l, ic]) => `<a class="tab" href="${base}${k ? '/' + k : ''}" ${tab === k ? 'aria-current="page"' : ''}><span class="ic">${ic}</span>${l}</a>`).join('')}</div></nav></div>`;
    const key = sub[0] || 'home';
    const view = Object.prototype.hasOwnProperty.call(V, key) ? V[key] : V.notfound;
    const html = await view(sub, q);
    const main = $('#view');
    if (!main) return;
    main.innerHTML = html;
    if (Object.prototype.hasOwnProperty.call(AFTER, key)) AFTER[key](sub, q);
    window.scrollTo(0, 0);
  }

  const B = () => '#/a/' + S.ctx.assoc.id;
  const effect = t => (t.kind === 'in' ? 1 : -1) * Number(t.amount);
  const subHead = (t, back) => `<div class="subhead"><a class="iconbtn" href="${back || B()}" aria-label="Retour">${I.back}</a><h1>${t}</h1></div>`;
  const pct = (a, b) => (b > 0 ? Math.max(0, Math.min(100, Math.round(a / b * 100))) : 0);
  const txItem = (t, reversedIds) => {
    const reversed = reversedIds && reversedIds.has(t.id);
    const title = t.category === 'Cotisations' && t.member_id ? 'Cotisation · ' + memberName(t.member_id) : t.description;
    const fx = effect(t);
    return `<a class="item" href="${B()}/op/${t.id}"><div class="body"><div class="t ${reversed ? 'strike' : ''}">${esc(title)}</div><div class="s wrap">${whenTx(t)} · ${esc(t.category)}${t.reversal_of ? ' · contre-écriture' : ''}${reversed ? ' · annulée' : ''}</div></div><span class="amt num ${fx >= 0 ? 'in' : 'out'}">${fx >= 0 ? '+' : '−'}${money(Math.abs(fx))}</span></a>`;
  };
  async function reversedSet(rows) {
    const ids = rows.filter(t => !t.reversal_of).map(t => t.id);
    if (!ids.length) return new Set();
    const r = must(await sb.from('transactions').select('reversal_of').in('reversal_of', ids));
    return new Set(r.map(x => x.reversal_of));
  }
  const logItem = l => `<div class="item"><div class="body"><div class="s wrap" style="color:var(--ink)"><b>${esc(l.actor_label)}</b> ${esc(l.message)}</div><div class="s">${dFR(l.created_at)}</div></div></div>`;
  const opt = (v, l, sel) => `<option value="${esc(v)}" ${String(v) === String(sel) ? 'selected' : ''}>${esc(l)}</option>`;

  /* ------------------------------------------------------------------
     Écrans
  ------------------------------------------------------------------ */
  const V = {};
  const AFTER = {};

  V.notfound = async () => `${subHead('Page introuvable')}<p class="muted">Cette page n’existe pas.</p>`;

  V.home = async () => {
    const a = S.ctx.assoc, fee = Number(a.fee_amount) || 0, cur = curYM();
    const openPolls = await sb.from('polls').select('*').eq('association_id', a.id).eq('status', 'Ouvert').order('created_at', { ascending: false }).limit(5).then(r => (r.error ? [] : r.data || []), () => []);
    const myVotes = openPolls.length && S.ctx.me ? await sb.from('poll_votes').select('poll_id').eq('member_id', S.ctx.me.id).then(r => (r.error ? [] : r.data || []), () => []) : [];
    const toVote = openPolls.filter(p => pollOpen(p) && !myVotes.some(v => v.poll_id === p.id));
    const nextMeet = await sb.from('meetings').select('*').eq('association_id', a.id).eq('status', 'Prévue').gte('starts_at', new Date(Date.now() - 6 * 3600e3).toISOString()).order('starts_at', { ascending: true }).limit(1).then(r => (r.error ? [] : r.data || []), () => []);
    const [lastOps, projects, logs] = await Promise.all([
      sb.from('transactions').select('*').eq('association_id', a.id).order('created_at', { ascending: false }).order('id', { ascending: false }).limit(5).then(must),
      sb.from('projects').select('*').eq('association_id', a.id).eq('status', 'En cours').order('created_at', { ascending: false }).limit(1).then(must),
      sb.from('activity_log').select('*').eq('association_id', a.id).order('id', { ascending: false }).limit(5).then(must)
    ]);
    const lastRev = await reversedSet(lastOps);
    let projCard = '';
    if (projects.length) {
      const p = projects[0];
      const t = must(await sb.from('v_project_totals').select('*').eq('project_id', p.id).maybeSingle()) || { collected: 0, spent: 0 };
      const c = Number(t.collected), pc = pct(c, p.goal);
      projCard = `<a class="card stack" href="${B()}/p/${p.id}"><div class="between"><span class="eyebrow">Projet en cours</span><span class="pill p-ok">${esc(p.status)}</span></div><h2>${esc(p.name)}</h2>
        <div class="between"><span class="pct num">${pc}${NB}%</span><span class="muted num" style="font-size:13px">objectif ${money(p.goal)}</span></div><div class="bar"><i style="width:${pc}%"></i></div>
        <div class="proj-num num"><div><small>Collecté</small><b>${moneyW(c)}</b></div><div><small>Dépensé</small><b>${moneyW(t.spent)}</b></div><div><small>Reste</small><b>${moneyW(Math.max(0, p.goal - c))}</b></div></div></a>`;
    } else if (can('projects')) {
      projCard = `<a class="card stack" href="${B()}/projets/nouveau"><span class="eyebrow">Projets</span><h2>Créer le premier projet du village</h2><span class="muted">Forage, école, mosquée… Chaque projet affiche sa barre de progression.</span></a>`;
    }
    const act = activeMembers(), late = lateMembers().length;
    const dueNow = act.filter(m => [ym(a.dues_start), ym(m.joined_on)].sort().pop() <= cur);
    const collected = dueNow.reduce((s, m) => s + Math.min(paidFor(m.id, cur), fee), 0), expected = dueNow.length * fee;
    const paidCount = dueNow.filter(m => paidFor(m.id, cur) >= fee).length;
    const onApp = act.filter(m => m.user_id).length;
    const bal = S.ctx.bal;
    return `
      <section class="card hero"><div class="eyebrow">Solde de la caisse</div><div class="big num">${num(bal.in - bal.out)} <span class="cur">${esc(CUR_LABEL[a.currency] || 'FCFA')}</span></div>
        <div class="boxes num"><div><small>Collecté</small><b>${money(bal.in)}</b></div><div><small>Dépensé</small><b>${money(bal.out)}</b></div></div>
        ${can('collect') ? `<a class="btn gold block" href="${B()}/encaisser">${I.plus} Encaisser une cotisation</a>` : ''}
        <div><a class="link" href="${B()}/transparence">Voir où va l’argent</a></div></section>
      ${toVote.length && S.ctx.me.user_id ? `<a class="card poll-next" href="${B()}/vote/${toVote[0].id}"><span class="ico">${I.vote}</span><span class="body"><span class="eyebrow">Vote en cours${toVote.length > 1 ? ' · ' + toVote.length + ' votes' : ''}</span><b>${esc(toVote[0].question)}</b><span class="muted">Donnez votre avis</span></span><span class="chev">${I.chev}</span></a>` : ''}
      ${nextMeet.length ? `<a class="card meet-next" href="${B()}/r/${nextMeet[0].id}">${dateBox(nextMeet[0].starts_at)}<span class="body"><span class="eyebrow">Prochaine réunion</span><b>${esc(nextMeet[0].title)}</b><span class="muted">${esc(hm(nextMeet[0].starts_at))}${nextMeet[0].place ? ' · ' + esc(nextMeet[0].place) : ''}</span></span><span class="chev">${I.chev}</span></a>` : ''}
      <div class="grid2">
        ${fee ? `<a class="stat" href="${B()}/cotisations"><div class="ring num" style="--p:${pct(paidCount, dueNow.length)}"><span>${pct(paidCount, dueNow.length)}${NB}%</span></div><span class="t">${esc(pFR(cur).replace(/^./, c => c.toUpperCase()))}</span><span class="l num">${paidCount} sur ${dueNow.length} ont payé · ${money(collected)} sur ${money(expected)}</span></a>`
          : (can('settings') ? `<a class="stat" href="${B()}/parametres"><span class="t">Cotisation</span><span class="l">Fixez le montant mensuel pour suivre qui est à jour.</span></a>` : `<a class="stat" href="${B()}/membres"><span class="l">Membres</span><span class="v num">${act.length}</span><span class="l">${onApp} sur l’application</span></a>`)}
        <a class="stat ${late ? 'warn' : ''}" href="${B()}/cotisations"><span class="v num">${late}</span><span class="l">En retard</span><span class="l">${late ? 'Relancer sur WhatsApp' : 'Tout le monde est à jour'}</span></a>
      </div>
      <section class="stack"><div class="between"><h2>Derniers mouvements</h2><a class="link" href="${B()}/finances">Tout voir</a></div>
        <div class="list">${lastOps.map(t => txItem(t, lastRev)).join('') || '<div class="empty">Aucune opération pour le moment. Elles s’afficheront ici avec leur date et leur heure.</div>'}</div></section>
      <a class="card between" href="${B()}/membres"><span><span class="t" style="font-weight:700">${act.length} membre${act.length > 1 ? 's' : ''}</span><br><span class="muted" style="font-size:13px">${onApp} sur l’application</span></span><span class="chev">${I.chev}</span></a>
      ${pendingMembers().length && can('members') ? `<a class="card stack" href="${B()}/membres?f=pending" style="border-color:var(--warn)"><span class="eyebrow">À valider</span><h2>${pendingMembers().length} demande${pendingMembers().length > 1 ? 's' : ''} d’adhésion</h2><span class="muted">Vérifiez que ce sont bien des ressortissants du village avant de valider.</span></a>` : ''}
      ${projCard}
      ${act.length <= 1 && can('members') ? `<a class="card stack" href="${B()}/membres/import"><span class="eyebrow">Pour bien démarrer</span><h2>Ajoutez la liste des membres</h2><span class="muted">Collez-la depuis votre cahier, Excel ou WhatsApp, ou partagez le code d’invitation.</span></a>` : ''}
      <div class="between"><h2>Activité récente</h2><a class="link" href="${B()}/journal">Tout voir</a></div>
      <div class="list">${logs.map(logItem).join('') || '<div class="empty">Aucune activité pour le moment.</div>'}</div>`;
  };

  /* Membres ---------------------------------------------------------- */
  V.membres = async (sub, q) => {
    if (sub[1] === 'nouveau') return memberForm(null);
    if (sub[1] === 'import') return importView();
    const f = q.get('f') || 'all';
    const late = lateMembers().length, noApp = activeMembers().filter(m => !m.user_id).length, inactive = S.ctx.members.filter(m => !m.active && !m.pending).length;
    const chips = [['all', 'Tous (' + activeMembers().length + ')'], ['bureau', 'Bureau'], ['late', 'En retard (' + late + ')'], ['noapp', 'Sans application (' + noApp + ')']];
    if (inactive) chips.push(['inactive', 'Retirés (' + inactive + ')']);
    if (pendingMembers().length) chips.unshift(['pending', 'Demandes (' + pendingMembers().length + ')']);
    return `<div class="between"><h1>Membres</h1>${can('members') ? `<a class="btn primary sm" href="${B()}/membres/nouveau">+ Ajouter</a>` : ''}</div>
      <input class="search" id="msearch" type="search" placeholder="Rechercher un nom, une ville ou un numéro" aria-label="Rechercher un membre">
      <div class="chips" role="group" aria-label="Filtrer">${chips.map(([k, l]) => `<a class="chip" href="${B()}/membres?f=${k}" aria-pressed="${f === k}" style="text-decoration:none">${l}</a>`).join('')}</div>
      <div class="list" id="mlist"></div>
      ${can('members') ? `<a class="link" href="${B()}/membres/import">Importer une liste de membres</a>` : ''}
      <p class="note">Un membre n’a pas besoin de smartphone : le trésorier enregistre ses paiements et lui envoie le reçu par WhatsApp.</p>`;
  };
  AFTER.membres = (sub, q) => {
    if (sub[1]) { if (sub[1] === 'import') afterImport(); return; }
    const f = q.get('f') || 'all';
    const input = $('#msearch');
    const draw = () => {
      const s = input.value.trim().toLowerCase();
      let l = S.ctx.members.filter(m => f === 'pending' ? m.pending : f === 'inactive' ? (!m.active && !m.pending) : (m.active && !m.pending));
      if (f === 'bureau') l = l.filter(m => m.role !== 'membre');
      if (f === 'late') l = l.filter(m => dues(m).isLate);
      if (f === 'noapp') l = l.filter(m => !m.user_id);
      if (s) l = l.filter(m => (m.full_name + ' ' + m.city + ' ' + m.phone).toLowerCase().includes(s));
      l.sort((x, y) => (x.role === 'membre') - (y.role === 'membre') || x.full_name.localeCompare(y.full_name, 'fr'));
      if (f === 'pending') {
        $('#mlist').innerHTML = l.map(m => `<div class="item"><div class="av">${esc(initials(m.full_name))}</div><div class="body"><div class="t">${esc(m.full_name)}</div><div class="s">${esc(m.phone || 'Sans numéro')} · demande du ${dFR(m.created_at)}</div>${can('members') ? `<div class="row" style="margin-top:8px;flex-wrap:wrap"><button class="btn primary sm" data-act="review" data-id="${m.id}" data-ok="1">Valider</button><button class="btn danger sm" data-act="review" data-id="${m.id}" data-ok="0">Refuser</button></div>` : ''}</div></div>`).join('') || '<div class="empty">Aucune demande en attente.</div>';
        return;
      }
      $('#mlist').innerHTML = l.slice(0, 400).map(m => `<a class="item" href="${B()}/m/${m.id}"><div class="av">${esc(initials(m.full_name))}</div><div class="body"><div class="t">${esc(m.full_name)}</div><div class="s">${m.role !== 'membre' ? esc(ROLES[m.role]) + ' · ' : ''}${esc(m.city || m.phone || '—')}${m.user_id ? '' : ' · sans application'}</div></div>${statusPill(m)}</a>`).join('') || '<div class="empty">Aucun membre ne correspond.</div>';
    };
    input.addEventListener('input', draw); draw();
  };

  V.m = async (sub) => {
    const m = S.ctx.byId.get(sub[1]);
    if (!m) return `${subHead('Membre introuvable', B() + '/membres')}`;
    if (sub[2] === 'modifier') return memberForm(m);
    const d = dues(m), fee = Number(S.ctx.assoc.fee_amount) || 0;
    const hist = must(await sb.from('transactions').select('*').eq('association_id', S.ctx.assoc.id).eq('member_id', m.id).order('occurred_on', { ascending: false }).order('id', { ascending: false }).limit(60));
    const rset = await reversedSet(hist);
    const start = [ym(S.ctx.assoc.dues_start), ym(m.joined_on)].sort().pop(), cur = curYM();
    const periods = fee && start <= cur ? monthsBetween(start, cur).reverse().slice(0, 12) : [];
    const relance = relanceText(m, d);
    return `${subHead('Fiche membre', B() + '/membres')}
      <div class="row"><div class="av lg">${esc(initials(m.full_name))}</div><div style="min-width:0"><h2 style="font-size:20px">${esc(m.full_name)}</h2><div class="row" style="flex-wrap:wrap;gap:6px;margin-top:4px"><span class="pill p-blue">${esc(ROLES[m.role])}</span>${statusPill(m)}</div></div></div>
      <section class="card"><dl class="kv num" style="margin:0"><dt>Téléphone</dt><dd>${esc(m.phone) || '<span class="muted">—</span>'}</dd><dt>Email</dt><dd>${esc(m.email) || '<span class="muted">—</span>'}</dd><dt>Résidence</dt><dd>${esc([m.city, m.country].filter(Boolean).join(', ')) || '<span class="muted">—</span>'}</dd><dt>Adhésion</dt><dd>${dFR(m.joined_on)}</dd><dt>Application</dt><dd>${m.user_id ? 'Oui' : 'Non, suivi par le trésorier'}</dd></dl></section>
      ${periods.length ? `<section class="card stack"><h2>Cotisations</h2>${periods.map(p => { const pd = paidFor(m.id, p); return `<div class="between num"><span>${pFR(p)}</span>${pd >= fee ? `<span class="pill p-ok">${money(pd)} payé</span>` : `<span class="pill ${d.late.includes(p) ? 'p-late' : 'p-blue'}">Reste ${money(fee - pd)}</span>`}</div>`; }).join('')}
        ${d.remaining ? `<div class="between num" style="border-top:1px solid var(--line);padding-top:10px"><b>Total dû</b><b style="color:var(--warn)">${money(d.remaining)}</b></div>` : ''}</section>` : ''}
      <div class="stack">
        ${can('collect') && m.active && !m.pending ? `<a class="btn primary block" href="${B()}/encaisser?m=${m.id}">Enregistrer un paiement</a>` : ''}
        ${d.owed.length ? `<a class="btn wa block" target="_blank" rel="noopener" href="${waTo(m.phone, relance)}">${I.wa} Relancer sur WhatsApp</a>` : ''}
        ${can('members') && (m.role === 'membre' || can('roles')) && !m.pending ? `<a class="btn ghost block" href="${B()}/m/${m.id}/modifier">Modifier la fiche</a>` : ''}
        ${can('members') && (m.role === 'membre' || can('roles')) && !m.pending && m.id !== S.ctx.me.id ? (m.active
          ? `<button class="btn danger block" data-act="memberactive" data-id="${m.id}" data-v="0">Retirer de l’association</button><p class="help">${esc(m.full_name)} n’aura plus accès à l’application et n’aura plus de cotisation due. Ses paiements restent dans l’historique, pour la transparence.</p>`
          : `<button class="btn ghost block" data-act="memberactive" data-id="${m.id}" data-v="1">Réintégrer dans l’association</button>`) : ''}
      </div>
      ${hist.length ? `<section class="stack"><span class="eyebrow">Historique des paiements</span><div class="list">${hist.map(t => txItem(t, rset)).join('')}</div></section>` : ''}`;
  };
  AFTER.m = () => {};

  function relanceText(m, d) {
    const a = S.ctx.assoc;
    return `Bonjour ${m.full_name}, petit rappel de l’association « ${a.name} » : votre cotisation (${d.owed.map(pFR).join(', ')}) reste à régler, soit ${money(d.remaining)}. Merci de voir le trésorier. Merci pour le village !`;
  }

  function memberForm(m) {
    const isNew = !m, r = m ? m.role : 'membre';
    if (!can('members')) return `${subHead('Membre')}<p class="note">Seul le bureau peut ajouter ou modifier un membre.</p>`;
    if (m && m.role !== 'membre' && !can('roles')) return `${subHead('Membre', B() + '/m/' + m.id)}<p class="note">Seul le président modifie la fiche d’un membre du bureau.</p>`;
    return `${subHead(isNew ? 'Ajouter un membre' : 'Modifier la fiche', isNew ? B() + '/membres' : B() + '/m/' + m.id)}
      <form class="stack" data-form="member" data-id="${m ? m.id : ''}" novalidate>
        <div class="field"><label for="mb-name">Nom complet</label><input id="mb-name" name="full_name" value="${esc(m && m.full_name)}" autocomplete="off" required></div>
        <div class="field"><label for="mb-phone">Téléphone</label><input id="mb-phone" name="phone" type="tel" inputmode="tel" value="${esc(m && m.phone)}" placeholder="+221 77 000 00 00"><p class="help">Avec l’indicatif (+221, +224, +33…) pour pouvoir relancer directement sur WhatsApp.</p></div>
        <div class="row2"><div class="field"><label for="mb-city">Ville de résidence</label><input id="mb-city" name="city" value="${esc(m && m.city)}"></div><div class="field"><label for="mb-country">Pays</label><input id="mb-country" name="country" value="${esc(m ? m.country : S.ctx.assoc.residence_country)}"></div></div>
        <div class="field"><label for="mb-email">Email (facultatif)</label><input id="mb-email" name="email" type="email" value="${esc(m && m.email)}"></div>
        <div class="field"><label for="mb-joined">Date d’adhésion</label><input id="mb-joined" name="joined_on" type="date" value="${esc(m ? m.joined_on : todayISO())}"><p class="help">Les cotisations sont dues à partir de ce mois.</p></div>
        ${can('roles') ? `<div class="field"><label for="mb-role">Fonction dans l’association</label><select id="mb-role" name="role">${Object.entries(ROLES).map(([k, l]) => opt(k, l, r)).join('')}</select></div>` : ''}
        ${!isNew ? `<div class="field"><label class="check"><input type="checkbox" name="active" ${m.active ? 'checked' : ''}> Membre actif</label><p class="help">Décocher revient à retirer le membre de l’association : il perd l’accès et n’a plus de cotisation due. Son historique est conservé.</p></div>` : ''}
        <p class="err" hidden></p><button class="btn primary block" type="submit">${isNew ? 'Ajouter' : 'Enregistrer'}</button></form>`;
  }

  function importView() {
    if (!can('members')) return `${subHead('Importer', B() + '/membres')}<p class="note">Réservé au bureau.</p>`;
    return `${subHead('Importer des membres', B() + '/membres')}
      <p class="muted" style="margin:0">Collez une ligne par membre : <b>nom</b>, puis <b>téléphone</b>, puis <b>ville</b>. Les colonnes peuvent être séparées par une tabulation (copier depuis Excel ou Google Sheets), un point-virgule ou une virgule.</p>
      <form class="stack" data-form="import" novalidate>
        <div class="field"><label for="im-text">Liste des membres</label><textarea id="im-text" name="text" class="mono" rows="10" placeholder="Mamadou Diallo; +221 77 123 45 67; Pikine&#10;Fatoumata Bah; +221 76 234 56 78; Dakar"></textarea></div>
        <div class="field"><label for="im-file">Ou choisir un fichier CSV</label><input id="im-file" type="file" accept=".csv,.txt,text/csv,text/plain"></div>
        <div class="field"><label for="im-joined">Date d’adhésion pour tous</label><input id="im-joined" name="joined_on" type="date" value="${todayISO()}"></div>
        <p class="ok-msg" id="im-preview"></p>
        <p class="err" hidden></p><button class="btn primary block" type="submit">Importer</button></form>`;
  }
  function parseImport(text) {
    const rows = [];
    String(text || '').split(/\r?\n/).forEach(line => {
      if (!line.trim()) return;
      const sep = line.includes('\t') ? '\t' : line.includes(';') ? ';' : ',';
      const c = line.split(sep).map(x => x.trim().replace(/^"|"$/g, ''));
      if (/^(nom|name|prénom)/i.test(c[0])) return;
      if (c[0] && c[0].length >= 2) rows.push({ full_name: c[0].slice(0, 120), phone: (c[1] || '').slice(0, 40), city: (c[2] || '').slice(0, 80) });
    });
    return rows;
  }
  function afterImport() {
    const ta = $('#im-text'), prev = $('#im-preview'), file = $('#im-file');
    const upd = () => { const n = parseImport(ta.value).length; prev.textContent = n ? `${n} membre${n > 1 ? 's' : ''} prêt${n > 1 ? 's' : ''} à importer.` : ''; };
    ta.addEventListener('input', upd);
    file.addEventListener('change', () => { const f = file.files[0]; if (!f) return; const r = new FileReader(); r.onload = () => { ta.value = r.result; upd(); }; r.readAsText(f); });
  }

  /* Cotisations ------------------------------------------------------ */
  V.cotisations = async (sub, q) => {
    const a = S.ctx.assoc, fee = Number(a.fee_amount) || 0, cur = curYM();
    if (!fee) return `<h1>Cotisations</h1><section class="card stack"><h2>Aucune cotisation définie</h2><p class="muted" style="margin:0">Fixez le montant mensuel et le jour d’échéance pour suivre qui est à jour.</p>${can('settings') ? `<a class="btn primary" href="${B()}/parametres">Définir la cotisation</a>` : '<p class="help">Seul le président peut la définir.</p>'}</section>`;
    const f = q.get('f') || 'late';
    const late = lateMembers().sort((x, y) => dues(y).remaining - dues(x).remaining || x.full_name.localeCompare(y.full_name, 'fr'));
    const dueNow = activeMembers().filter(m => [ym(a.dues_start), ym(m.joined_on)].sort().pop() <= cur);
    const collected = dueNow.reduce((s, m) => s + Math.min(paidFor(m.id, cur), fee), 0), expected = dueNow.length * fee;
    const paidCount = dueNow.filter(m => paidFor(m.id, cur) >= fee).length;
    let list = '';
    if (f === 'late') {
      list = `<div class="list">${late.map(m => { const d = dues(m); return `<div class="item"><div class="av">${esc(initials(m.full_name))}</div><div class="body"><a class="t" href="${B()}/m/${m.id}" style="display:block;text-decoration:none">${esc(m.full_name)}</a><div class="s wrap num">${d.late.map(pFR).join(', ')} · reste ${money(d.remaining)}</div><div class="row" style="margin-top:8px;flex-wrap:wrap">${can('collect') ? `<a class="btn primary sm" href="${B()}/encaisser?m=${m.id}">Encaisser</a>` : ''}<a class="btn wa sm" target="_blank" rel="noopener" href="${waTo(m.phone, relanceText(m, d))}">${I.wa} Relancer</a></div></div></div>`; }).join('') || '<div class="empty">Tout le monde est à jour.</div>'}</div>`;
    } else {
      const recent = must(await sb.from('transactions').select('*').eq('association_id', a.id).eq('category', 'Cotisations').order('id', { ascending: false }).limit(40));
      const rset = await reversedSet(recent);
      list = `<div class="list">${recent.map(t => txItem(t, rset)).join('') || '<div class="empty">Aucun paiement enregistré.</div>'}</div>`;
    }
    return `<div class="between"><h1>Cotisations</h1>${can('collect') ? `<a class="btn primary sm" href="${B()}/encaisser">+ Paiement</a>` : ''}</div>
      <section class="card stack"><span class="eyebrow">Règle en vigueur</span><dl class="kv num" style="margin:0"><dt>Montant</dt><dd>${money(fee)}</dd><dt>Fréquence</dt><dd>Mensuelle</dd><dt>Échéance</dt><dd>Le ${a.fee_due_day} de chaque mois</dd><dt>Suivi depuis</dt><dd>${pFR(ym(a.dues_start))}</dd></dl></section>
      <section class="card stack"><div class="between"><span class="eyebrow">${pFR(cur)}</span><span class="pill p-blue num">${paidCount}/${dueNow.length} membres</span></div>
        <div class="num" style="font-family:var(--f-display);font-size:24px;font-weight:700">${money(collected)} <span class="muted" style="font-size:14px;font-family:var(--f-body);font-weight:500">sur ${money(expected)}</span></div>
        <div class="bar"><i style="width:${pct(collected, expected)}%"></i></div>
        <span class="muted num" style="font-size:13px">Reste à encaisser, arriérés compris : ${money(activeMembers().reduce((s, m) => s + dues(m).remaining, 0))}</span></section>
      <div class="chips" role="group" aria-label="Filtrer"><a class="chip" style="text-decoration:none" href="${B()}/cotisations?f=late" aria-pressed="${f === 'late'}">En retard (${late.length})</a><a class="chip" style="text-decoration:none" href="${B()}/cotisations?f=recent" aria-pressed="${f === 'recent'}">Derniers paiements</a></div>
      ${list}`;
  };

  V.encaisser = async (sub, q) => {
    if (!can('collect')) return `${subHead('Encaisser', B() + '/cotisations')}<p class="note">Seuls le trésorier et le président enregistrent les cotisations.</p>`;
    const a = S.ctx.assoc;
    if (!Number(a.fee_amount)) return `${subHead('Encaisser', B() + '/cotisations')}<p class="note">Définissez d’abord le montant de la cotisation dans les paramètres.</p>`;
    const sel = q.get('m') || (lateMembers()[0] || activeMembers()[0] || {}).id || '';
    const list = activeMembers().slice().sort((x, y) => x.full_name.localeCompare(y.full_name, 'fr'));
    if (!list.length) return `${subHead('Encaisser', B() + '/cotisations')}<p class="note">Ajoutez d’abord des membres.</p>`;
    return `${subHead('Enregistrer un paiement', B() + '/cotisations')}
      <form class="stack" data-form="pay" novalidate>
        <div class="field"><label for="pay-m">Membre</label><select id="pay-m" name="member_id">${list.map(m => opt(m.id, m.full_name + (dues(m).isLate ? ' · en retard' : ''), sel)).join('')}</select></div>
        <div class="field"><label for="pay-p">Mois concerné</label><select id="pay-p" name="period"></select></div>
        <div class="field"><label for="pay-a">Montant (${esc(CUR_LABEL[a.currency] || a.currency)})</label><input id="pay-a" name="amount" type="number" inputmode="numeric" min="1" step="1"></div>
        <div class="field"><label for="pay-mode">Mode de paiement</label><select id="pay-mode" name="payment_method">${MODES.map(x => opt(x, x)).join('')}</select></div>
        <div class="field"><label for="pay-date">Date du paiement</label><input id="pay-date" name="occurred_on" type="date" value="${todayISO()}" max="${todayISO()}"></div>
        <div class="field"><label for="pay-c">Commentaire (facultatif)</label><input id="pay-c" name="comment" placeholder="Ex. remis en main propre à l’AG"></div>
        <p class="err" hidden></p><button class="btn primary block" type="submit">Enregistrer</button>
        <p class="help">Aucun argent ne passe par l’application : vous enregistrez un paiement déjà reçu.</p></form>`;
  };
  AFTER.encaisser = () => {
    const ms = $('#pay-m'), ps = $('#pay-p'), am = $('#pay-a');
    if (!ms) return;
    const fee = Number(S.ctx.assoc.fee_amount);
    const fill = () => {
      const m = S.ctx.byId.get(ms.value); if (!m) return;
      const d = dues(m), cur = curYM();
      const opts = [...new Set([...d.owed, cur, addMonth(cur, 1), addMonth(cur, 2)])].sort();
      ps.innerHTML = opts.map(p => opt(p, `${pFR(p)} · ${paidFor(m.id, p) >= fee ? 'déjà payé' : 'reste ' + money(fee - paidFor(m.id, p))}`)).join('');
      const first = opts.find(p => paidFor(m.id, p) < fee) || cur; ps.value = first;
      am.value = Math.max(fee - paidFor(m.id, first), 0) || fee;
    };
    ms.addEventListener('change', fill);
    ps.addEventListener('change', () => { am.value = Math.max(fee - paidFor(ms.value, ps.value), 0) || fee; });
    fill();
  };

  /* Finances --------------------------------------------------------- */
  const PAGE = 30;
  V.finances = async (sub, q) => {
    const f = ['all', 'in', 'out', 'hors'].includes(q.get('f')) ? q.get('f') : 'all', p = Math.max(0, Math.floor(Number(q.get('p'))) || 0);
    let qy = sb.from('transactions').select('*').eq('association_id', S.ctx.assoc.id);
    if (f === 'in') qy = qy.eq('kind', 'in');
    if (f === 'out') qy = qy.eq('kind', 'out');
    if (f === 'hors') qy = qy.neq('category', 'Cotisations');
    const rows = must(await qy.order('occurred_on', { ascending: false }).order('id', { ascending: false }).range(p * PAGE, p * PAGE + PAGE));
    const more = rows.length > PAGE; if (more) rows.pop();
    const rset = await reversedSet(rows);
    const link = (np) => `${B()}/finances?f=${f}&p=${np}`;
    return `${subHead('Finances', B() + '/plus')}
      <div class="row" style="flex-wrap:wrap">${can('collect') ? `<a class="btn primary sm" href="${B()}/operation?type=in">+ Recette</a>` : ''}${can('spend') ? `<a class="btn ghost sm" href="${B()}/operation?type=out">+ Dépense</a>` : ''}</div>
      <div class="chips" role="group" aria-label="Filtrer">${[['all', 'Tout'], ['hors', 'Hors cotisations'], ['in', 'Recettes'], ['out', 'Dépenses']].map(([k, l]) => `<a class="chip" style="text-decoration:none" href="${B()}/finances?f=${k}" aria-pressed="${f === k}">${l}</a>`).join('')}</div>
      <div class="list">${rows.map(t => txItem(t, rset)).join('') || '<div class="empty">Aucune opération.</div>'}</div>
      ${p || more ? `<div class="pager">${p ? `<a class="btn ghost sm" href="${link(p - 1)}">← Plus récentes</a>` : '<span></span>'}${more ? `<a class="btn ghost sm" href="${link(p + 1)}">Plus anciennes →</a>` : ''}</div>` : ''}`;
  };

  V.operation = async (sub, q) => {
    const type = q.get('type') === 'out' ? 'out' : 'in';
    if (type === 'out' && !can('spend')) return `${subHead('Dépense', B() + '/finances')}<p class="note">Seul le trésorier enregistre les dépenses.</p>`;
    if (type === 'in' && !can('collect')) return `${subHead('Recette', B() + '/finances')}<p class="note">Seuls le trésorier et le président enregistrent les recettes.</p>`;
    const projects = must(await sb.from('projects').select('id,name,status').eq('association_id', S.ctx.assoc.id).neq('status', 'Terminé').order('created_at', { ascending: false }));
    const cats = type === 'out' ? CAT_OUT : CAT_IN;
    const pre = q.get('projet') || '';
    return `${subHead(type === 'out' ? 'Nouvelle dépense' : 'Nouvelle recette', B() + '/finances')}
      ${type === 'in' ? `<p class="note">Pour une cotisation mensuelle, utilisez plutôt <a class="link" href="${B()}/encaisser">Enregistrer un paiement</a> : le membre sera marqué à jour.</p>` : ''}
      <form class="stack" data-form="op" data-type="${type}" novalidate>
        <div class="field"><label for="op-cat">Catégorie</label><select id="op-cat" name="category">${cats.map(c => opt(c, c, pre && type === 'in' ? 'Dons' : pre ? 'Projet' : '')).join('')}</select></div>
        <div class="field"><label for="op-a">Montant (${esc(CUR_LABEL[S.ctx.assoc.currency] || S.ctx.assoc.currency)})</label><input id="op-a" name="amount" type="number" inputmode="numeric" min="1" step="1" required></div>
        <div class="field"><label for="op-p">Projet lié (facultatif)</label><select id="op-p" name="project_id"><option value="">Aucun, fonds général</option>${projects.map(p => opt(p.id, p.name, pre)).join('')}</select></div>
        <div class="field"><label for="op-d">Description</label><input id="op-d" name="description" maxlength="300" placeholder="${type === 'out' ? 'Ex. achat de 20 sacs de ciment' : 'Ex. don de la famille Bah'}" required></div>
        ${type === 'in' ? `<div class="field"><label for="op-mode">Mode de paiement</label><select id="op-mode" name="payment_method">${MODES.map(x => opt(x, x)).join('')}</select></div>` : ''}
        <div class="field"><label for="op-date">Date</label><input id="op-date" name="occurred_on" type="date" value="${todayISO()}" max="${todayISO()}"></div>
        <div class="field"><label for="op-f">Justificatif (photo ou PDF, facultatif)</label><input id="op-f" name="proof" type="file" accept="image/*,application/pdf"><p class="help">La photo est réduite avant l’envoi pour économiser vos données.</p></div>
        <div class="field"><label for="op-c">Commentaire (facultatif)</label><input id="op-c" name="comment"></div>
        <p class="err" hidden></p><button class="btn primary block" type="submit">Enregistrer</button></form>`;
  };

  V.op = async (sub, q) => {
    const id = Number(sub[1]);
    const t = must(await sb.from('transactions').select('*').eq('association_id', S.ctx.assoc.id).eq('id', id).maybeSingle());
    if (!t) return `${subHead('Opération introuvable', B() + '/finances')}`;
    const [rev, orig, proj] = await Promise.all([
      sb.from('transactions').select('*').eq('reversal_of', t.id).maybeSingle().then(must),
      t.reversal_of ? sb.from('transactions').select('*').eq('id', t.reversal_of).maybeSingle().then(must) : null,
      t.project_id ? sb.from('projects').select('id,name').eq('id', t.project_id).maybeSingle().then(must) : null
    ]);
    const author = S.ctx.members.find(m => m.user_id && m.user_id === t.created_by);
    const m = t.member_id ? S.ctx.byId.get(t.member_id) : null;
    const isReceipt = q.get('recu') === '1' && m;
    const receipt = receiptText(t, m, author);
    return `${subHead(isReceipt ? 'Paiement enregistré' : 'Opération ' + txRef(t.id), m ? B() + '/m/' + m.id : B() + '/finances')}
      ${isReceipt ? `<div class="receipt stack num"><div class="between"><b>Reçu ${txRef(t.id)}</b><span class="pill p-ok">Payé</span></div><dl class="kv" style="margin:0"><dt>Membre</dt><dd>${esc(m.full_name)}</dd><dt>Objet</dt><dd>${esc(t.description)}</dd><dt>Montant</dt><dd>${money(t.amount)}</dd><dt>Mode</dt><dd>${esc(t.payment_method || '—')}</dd><dt>Date</dt><dd>${whenTx(t)}</dd></dl>
        ${t.period && paidFor(m.id, t.period) < Number(S.ctx.assoc.fee_amount) ? `<span class="pill p-late">Reste ${money(Number(S.ctx.assoc.fee_amount) - paidFor(m.id, t.period))} pour ${pFR(t.period)}</span>` : ''}</div>
        <a class="btn wa block" target="_blank" rel="noopener" href="${waTo(m.phone, receipt)}">${I.wa} Envoyer le reçu sur WhatsApp</a>
        <a class="btn ghost block" href="${B()}/encaisser">Enregistrer un autre paiement</a>` : `
      <section class="card stack num"><div class="between"><span class="pill ${t.kind === 'in' ? 'p-ok' : 'p-red'}">${t.kind === 'in' ? 'Recette' : 'Dépense'} · ${esc(t.category)}</span><span class="amt ${effect(t) >= 0 ? 'in' : 'out'}" style="font-size:18px">${effect(t) >= 0 ? '+' : '−'}${money(Math.abs(t.amount))}</span></div>
        <dl class="kv" style="margin:0"><dt>Objet</dt><dd>${esc(t.description)}</dd>${m ? `<dt>Membre</dt><dd>${esc(m.full_name)}</dd>` : ''}${t.period ? `<dt>Mois</dt><dd>${pFR(t.period)}</dd>` : ''}${proj ? `<dt>Projet</dt><dd>${esc(proj.name)}</dd>` : ''}<dt>Date</dt><dd>${dFR(t.occurred_on)}</dd>${t.payment_method ? `<dt>Mode</dt><dd>${esc(t.payment_method)}</dd>` : ''}<dt>Saisi par</dt><dd>${esc(author ? author.full_name : '—')}</dd><dt>Saisi le</dt><dd>${dFR(t.created_at)} à ${hm(t.created_at)}</dd>${t.comment ? `<dt>${t.reversal_of ? 'Motif' : 'Commentaire'}</dt><dd>${esc(t.comment)}</dd>` : ''}</dl>
        ${t.proof_path ? `<button class="btn ghost sm" data-act="proof" data-path="${esc(t.proof_path)}">Voir le justificatif</button><div id="proof-box"></div>` : '<span class="muted" style="font-size:13px">Aucun justificatif</span>'}</section>
      ${rev ? `<p class="note">Opération annulée le ${dFR(rev.occurred_on)} par la contre-écriture <a class="link" href="${B()}/op/${rev.id}">${txRef(rev.id)}</a>. Motif : ${esc(rev.comment)}</p>` : ''}
      ${orig ? `<p class="note">Cette ligne annule <a class="link" href="${B()}/op/${orig.id}">${txRef(orig.id)}</a>. Les deux restent visibles dans l’historique.</p>` : ''}
      ${m && !t.reversal_of ? `<a class="btn wa block" target="_blank" rel="noopener" href="${waTo(m.phone, receipt)}">${I.wa} Envoyer le reçu</a>` : ''}
      ${can('reverse') && !rev && !t.reversal_of ? `<form class="card stack" data-form="reverse" data-id="${t.id}" novalidate><h2>Corriger une erreur</h2><p class="muted" style="margin:0;font-size:13.5px">L’opération ne sera pas effacée. Une contre-écriture du même montant sera ajoutée, visible par tous les membres.</p><div class="field"><label for="rv-r">Motif de l’annulation</label><input id="rv-r" name="reason" placeholder="Ex. montant saisi deux fois"></div><p class="err" hidden></p><button class="btn danger block" type="submit">Annuler par contre-écriture</button></form>` : ''}`}`;
  };
  function receiptText(t, m, author) {
    const a = S.ctx.assoc;
    return `Reçu ${txRef(t.id)}\n${a.name}\n\n${m ? 'Membre : ' + m.full_name + '\n' : ''}${t.description}\nMontant : ${money(t.amount)}\nMode : ${t.payment_method || '—'}\nDate : ${whenTx(t)}\nEnregistré par : ${author ? author.full_name : S.ctx.me.full_name}\n\nMerci pour votre contribution au développement de ${a.village || 'notre village'}.`;
  }

  /* Transparence ----------------------------------------------------- */
  V.transparence = async () => {
    const a = S.ctx.assoc;
    const [cats, projects, totals, recent] = await Promise.all([
      sb.from('v_category_totals').select('*').eq('association_id', a.id).then(must),
      sb.from('projects').select('*').eq('association_id', a.id).order('created_at', { ascending: false }).then(must),
      sb.from('v_project_totals').select('*').then(must),
      sb.from('transactions').select('*').eq('association_id', a.id).neq('category', 'Cotisations').order('occurred_on', { ascending: false }).order('id', { ascending: false }).limit(10).then(must)
    ]);
    const tot = new Map(totals.map(x => [x.project_id, x]));
    const rset = await reversedSet(recent);
    const bal = S.ctx.bal;
    const bars = (kind, total) => cats.filter(c => c.kind === kind && Number(c.total) > 0).sort((x, y) => y.total - x.total).map(c => `<div class="catbar ${kind}"><span>${esc(c.category)}</span><div class="bar"><i style="width:${Math.max(2, pct(c.total, total))}%"></i></div><span class="num" style="font-weight:600">${num(c.total)}</span></div>`).join('') || '<span class="muted">Rien pour le moment.</span>';
    return `${subHead('Transparence', B() + '/plus')}
      <section class="card hero"><div class="eyebrow">Solde disponible</div><div class="big num">${money(bal.in - bal.out)}</div><div class="split num"><span>Recettes <b>${money(bal.in)}</b></span><span>Dépenses <b>${money(bal.out)}</b></span></div></section>
      <section class="card stack"><div class="between"><h2>Recettes</h2><span class="muted num">${money(bal.in)}</span></div>${bars('in', bal.in)}</section>
      <section class="card stack"><div class="between"><h2>Dépenses</h2><span class="muted num">${money(bal.out)}</span></div>${bars('out', bal.out)}</section>
      ${projects.length ? `<section class="card stack"><h2>Projets</h2>${projects.map(p => { const t = tot.get(p.id) || { collected: 0, spent: 0 }; return `<a class="item" href="${B()}/p/${p.id}" style="padding:8px 0"><div class="body"><div class="t">${esc(p.name)}</div><div class="s wrap num">Collecté ${money(t.collected)} · dépensé ${money(t.spent)}</div></div><span class="pill ${p.status === 'Terminé' ? 'p-blue' : 'p-ok'}">${esc(p.status)}</span></a>`; }).join('')}</section>` : ''}
      <p class="note">Chaque opération est datée et signée par la personne qui l’a saisie. Aucune opération ne peut être modifiée ni supprimée : une erreur se corrige par une contre-écriture, visible ici par tous les membres.</p>
      <div class="between"><h2>Dernières opérations</h2><a class="link" href="${B()}/finances?f=hors">Tout voir</a></div>
      <div class="list">${recent.map(t => txItem(t, rset)).join('') || '<div class="empty">Aucune opération hors cotisations.</div>'}</div>`;
  };

  /* Projets ---------------------------------------------------------- */
  V.projets = async (sub) => {
    if (sub[1] === 'nouveau') return projectForm(null);
    const a = S.ctx.assoc;
    const [projects, totals] = await Promise.all([
      sb.from('projects').select('*').eq('association_id', a.id).order('created_at', { ascending: false }).then(must),
      sb.from('v_project_totals').select('*').then(must)
    ]);
    const tot = new Map(totals.map(x => [x.project_id, x]));
    return `<div class="between"><h1>Projets</h1>${can('projects') ? `<a class="btn primary sm" href="${B()}/projets/nouveau">+ Projet</a>` : ''}</div>
      ${projects.map(p => { const t = tot.get(p.id) || { collected: 0 }; const pc = pct(t.collected, p.goal); return `<a class="card stack" href="${B()}/p/${p.id}"><div class="between"><span class="eyebrow">${esc(p.type)}</span><span class="pill ${p.status === 'Terminé' ? 'p-blue' : p.status === 'Suspendu' ? 'p-late' : 'p-ok'}">${esc(p.status)}</span></div><h2>${esc(p.name)}</h2>
        <div class="between"><span class="pct num">${pc}${NB}%</span><span class="muted num" style="font-size:13px">${money(t.collected)} / ${money(p.goal)}</span></div><div class="bar"><i style="width:${pc}%"></i></div>
        <span class="muted" style="font-size:13px">${p.lead_member_id ? 'Responsable : ' + esc(memberName(p.lead_member_id)) + ' · ' : ''}${p.end_on ? 'fin prévue ' + dFR(p.end_on) : 'début ' + dFR(p.start_on)}</span></a>`; }).join('') || `<div class="empty">Aucun projet pour le moment.${can('projects') ? '' : ' Le président ou le responsable des projets peut en créer un.'}</div>`}`;
  };

  function projectForm(p) {
    if (!can('projects')) return `${subHead('Projet', B() + '/projets')}<p class="note">Réservé au président et au responsable des projets.</p>`;
    const bureau = activeMembers().filter(m => m.role !== 'membre');
    return `${subHead(p ? 'Modifier le projet' : 'Nouveau projet', p ? B() + '/p/' + p.id : B() + '/projets')}
      <form class="stack" data-form="project" data-id="${p ? p.id : ''}" novalidate>
        <div class="field"><label for="pj-n">Nom du projet</label><input id="pj-n" name="name" value="${esc(p && p.name)}" placeholder="Ex. Forage du quartier haut" required></div>
        <div class="row2"><div class="field"><label for="pj-t">Type</label><select id="pj-t" name="type">${PROJECT_TYPES.map(x => opt(x, x, p && p.type)).join('')}</select></div>
        <div class="field"><label for="pj-g">Objectif (${esc(CUR_LABEL[S.ctx.assoc.currency] || '')})</label><input id="pj-g" name="goal" type="number" inputmode="numeric" min="1" step="1" value="${esc(p && p.goal)}" required></div></div>
        <div class="field"><label for="pj-l">Responsable</label><select id="pj-l" name="lead_member_id"><option value="">À désigner</option>${bureau.map(m => opt(m.id, m.full_name + ' · ' + ROLES[m.role], p ? p.lead_member_id : '')).join('')}</select></div>
        <div class="row2"><div class="field"><label for="pj-s">Début</label><input id="pj-s" name="start_on" type="date" value="${esc(p ? p.start_on : todayISO())}"></div><div class="field"><label for="pj-e">Fin prévue</label><input id="pj-e" name="end_on" type="date" value="${esc(p && p.end_on)}"></div></div>
        ${p ? `<div class="field"><label for="pj-st">Statut</label><select id="pj-st" name="status">${STATUSES.map(x => opt(x, x, p.status)).join('')}</select></div>` : ''}
        <div class="field"><label for="pj-d">Description</label><textarea id="pj-d" name="description" rows="4" placeholder="Ce que le projet va réaliser au village">${esc(p && p.description)}</textarea></div>
        <p class="err" hidden></p><button class="btn primary block" type="submit">${p ? 'Enregistrer' : 'Créer le projet'}</button></form>`;
  }

  V.p = async (sub) => {
    const a = S.ctx.assoc;
    const p = must(await sb.from('projects').select('*').eq('association_id', a.id).eq('id', sub[1]).maybeSingle());
    if (!p) return `${subHead('Projet introuvable', B() + '/projets')}`;
    if (sub[2] === 'modifier') return projectForm(p);
    const [tt, updates, ops] = await Promise.all([
      sb.from('v_project_totals').select('*').eq('project_id', p.id).maybeSingle().then(must),
      sb.from('project_updates').select('*').eq('project_id', p.id).order('created_at', { ascending: false }).limit(50).then(must),
      sb.from('transactions').select('*').eq('project_id', p.id).order('occurred_on', { ascending: false }).order('id', { ascending: false }).limit(60).then(must)
    ]);
    const t = tt || { collected: 0, spent: 0 }, c = Number(t.collected), s = Number(t.spent), pc = pct(c, p.goal);
    const rset = await reversedSet(ops);
    const by = uid => { const m = S.ctx.members.find(x => x.user_id && x.user_id === uid); return m ? m.full_name : '—'; };
    const share = `${p.name}\nObjectif : ${money(p.goal)}\nCollecté : ${money(c)} (${pc} %)\nReste : ${money(Math.max(0, p.goal - c))}\n\n${a.name}`;
    return `${subHead(esc(p.type), B() + '/projets')}
      <h2 style="font-size:22px">${esc(p.name)}</h2>${p.description ? `<p style="margin:0" class="muted">${esc(p.description)}</p>` : ''}
      <section class="card stack"><div class="between"><span class="pct num">${pc}${NB}%</span><span class="pill ${p.status === 'Terminé' ? 'p-blue' : 'p-ok'}">${esc(p.status)}</span></div><div class="bar"><i style="width:${pc}%"></i></div>
        <dl class="kv num" style="margin:0"><dt>Objectif</dt><dd>${money(p.goal)}</dd><dt>Collecté</dt><dd style="color:var(--green)">${money(c)}</dd><dt>Dépensé</dt><dd style="color:var(--danger)">${money(s)}</dd><dt>Reste à collecter</dt><dd>${money(Math.max(0, p.goal - c))}</dd><dt>En caisse pour ce projet</dt><dd>${money(c - s)}</dd></dl></section>
      <section class="card"><dl class="kv" style="margin:0"><dt>Responsable</dt><dd>${p.lead_member_id ? esc(memberName(p.lead_member_id)) : '<span class="muted">À désigner</span>'}</dd><dt>Début</dt><dd>${dFR(p.start_on)}</dd><dt>Fin prévue</dt><dd>${p.end_on ? dFR(p.end_on) : '<span class="muted">—</span>'}</dd></dl></section>
      <div class="row" style="flex-wrap:wrap">${can('collect') && p.status !== 'Terminé' ? `<a class="btn primary sm" href="${B()}/operation?type=in&projet=${p.id}">+ Contribution</a>` : ''}${can('spend') && p.status !== 'Terminé' ? `<a class="btn ghost sm" href="${B()}/operation?type=out&projet=${p.id}">+ Dépense</a>` : ''}${can('projects') ? `<a class="btn ghost sm" href="${B()}/p/${p.id}/modifier">Modifier</a>` : ''}<a class="btn wa sm" target="_blank" rel="noopener" href="${waShare(share)}">${I.wa} Partager</a></div>
      ${can('projects') ? `<form class="card stack" data-form="pupdate" data-id="${p.id}" novalidate><h2>Donner des nouvelles</h2><div class="field"><label for="pu-t">Ce qui a avancé</label><textarea id="pu-t" name="body" rows="3" placeholder="Ex. le château d’eau est monté, il reste la pompe solaire"></textarea></div><p class="err" hidden></p><button class="btn primary" type="submit">Publier</button></form>` : ''}
      <section class="stack"><span class="eyebrow">Mises à jour</span>${updates.length ? `<div class="timeline">${updates.map(u => `<div><div class="d">${dFR(u.created_at)} · ${esc(by(u.created_by))}</div><div>${esc(u.body)}</div></div>`).join('')}</div>` : '<span class="muted">Aucune mise à jour pour le moment.</span>'}</section>
      <section class="stack"><span class="eyebrow">Opérations du projet</span><div class="list">${ops.map(x => txItem(x, rset)).join('') || '<div class="empty">Aucune opération.</div>'}</div></section>`;
  };

  /* Annonces, journal, plus, paramètres ------------------------------ */
  V.annonces = async () => {
    const a = S.ctx.assoc;
    const rows = must(await sb.from('announcements').select('*').eq('association_id', a.id).order('created_at', { ascending: false }).limit(50));
    const col = { Urgence: 'p-red', Convocation: 'p-late', 'Nouvelles du village': 'p-ok', Information: 'p-blue', Annonce: 'p-blue' };
    const by = uid => { const m = S.ctx.members.find(x => x.user_id && x.user_id === uid); return m ? m.full_name : '—'; };
    return `${subHead('Annonces', B() + '/plus')}
      ${can('announce') ? `<form class="card stack" data-form="announce" novalidate><h2>Publier une annonce</h2>
        <div class="field"><label for="an-k">Type</label><select id="an-k" name="kind">${ANN_KINDS.map(k => opt(k, k)).join('')}</select></div>
        <div class="field"><label for="an-t">Titre</label><input id="an-t" name="title" maxlength="160"></div>
        <div class="field"><label for="an-b">Message</label><textarea id="an-b" name="body" rows="4"></textarea></div>
        <p class="err" hidden></p><button class="btn primary" type="submit">Publier</button><p class="help">Pensez à la partager dans le groupe WhatsApp après publication.</p></form>` : ''}
      ${rows.map(x => `<section class="card stack"><div class="between"><span class="pill ${col[x.kind] || 'p-blue'}">${esc(x.kind)}</span><span class="muted" style="font-size:13px">${dFR(x.created_at)}</span></div><h2>${esc(x.title)}</h2><p style="margin:0;white-space:pre-line">${esc(x.body)}</p><div class="between"><span class="muted" style="font-size:13px">${esc(by(x.created_by))}</span><a class="link" target="_blank" rel="noopener" href="${waShare(x.kind + ' · ' + x.title + '\n\n' + x.body + '\n\n' + a.name)}">Partager sur WhatsApp</a></div></section>`).join('') || '<div class="empty">Aucune annonce pour le moment.</div>'}`;
  };

  /* Réunions --------------------------------------------------------- */
  const MEET_PILL = { Prévue: 'p-blue', Tenue: 'p-ok', Annulée: 'p-red' };
  const dateBox = ts => { const x = new Date(ts); return `<span class="datebox" aria-hidden="true"><small>${MOIS[x.getMonth()].replace('.', '')}</small><b>${x.getDate()}</b></span>`; };
  const appLink = path => location.origin + location.pathname + '#' + path;
  const convText = m => `CONVOCATION · ${S.ctx.assoc.name}\n\n${m.title}\nDate : ${dLong(m.starts_at)}${m.place ? '\nLieu : ' + m.place : ''}${m.agenda ? '\n\nOrdre du jour :\n' + m.agenda : ''}\n\nVotre présence est importante.\n${appLink('/a/' + S.ctx.assoc.id + '/r/' + m.id)}`;
  const meetItem = m => `<a class="card meet-row" href="${B()}/r/${m.id}">${dateBox(m.starts_at)}<span class="body"><b>${esc(m.title)}</b><span class="muted">${esc(hm(m.starts_at))}${m.place ? ' · ' + esc(m.place) : ''}</span></span><span class="pill ${MEET_PILL[m.status]}">${esc(m.status)}</span></a>`;

  V.reunions = async (sub) => {
    if (sub[1] === 'nouvelle') return meetingForm(null);
    const a = S.ctx.assoc;
    const res = await sb.from('meetings').select('*').eq('association_id', a.id).order('starts_at', { ascending: false }).limit(100);
    if (res.error) return `${subHead('Réunions', B() + '/plus')}<p class="note">Les réunions ne sont pas encore installées sur la base.</p>`;
    const limit = Date.now() - 6 * 3600e3;
    const next = res.data.filter(m => m.status === 'Prévue' && new Date(m.starts_at).getTime() >= limit).reverse();
    const past = res.data.filter(m => !next.includes(m));
    return `<div class="subhead between" style="margin-left:-8px"><span class="row" style="gap:6px"><a class="iconbtn" href="${B()}/plus" aria-label="Retour">${I.back}</a><h1>Réunions</h1></span>${can('meetings') ? `<a class="btn primary sm" href="${B()}/reunions/nouvelle">+ Convoquer</a>` : ''}</div>
      <section class="stack"><h2>À venir</h2>${next.map(meetItem).join('') || `<div class="empty">Aucune réunion prévue.${can('meetings') ? ' Convoquez la prochaine avec le bouton « + Convoquer ».' : ''}</div>`}</section>
      ${past.length ? `<section class="stack"><h2>Passées</h2>${past.map(meetItem).join('')}</section>` : ''}`;
  };

  function meetingForm(m) {
    if (!can('meetings')) return `${subHead('Réunion', B() + '/reunions')}<p class="note">Réservé au président, au vice-président et au secrétaire général.</p>`;
    const d = m ? new Date(m.starts_at) : null;
    const dv = d ? `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` : '', tv = d ? `${pad(d.getHours())}:${pad(d.getMinutes())}` : '16:00';
    return `${subHead(m ? 'Modifier la convocation' : 'Convoquer une réunion', m ? B() + '/r/' + m.id : B() + '/reunions')}
      <form class="stack" data-form="meeting" data-id="${m ? m.id : ''}" novalidate>
        <div class="field"><label for="mt-t">Titre</label><input id="mt-t" name="title" maxlength="160" value="${esc(m ? m.title : 'Assemblée générale')}" required></div>
        <div class="row2"><div class="field"><label for="mt-d">Date</label><input id="mt-d" name="date" type="date" value="${esc(dv)}" required></div><div class="field"><label for="mt-h">Heure</label><input id="mt-h" name="time" type="time" value="${esc(tv)}" required></div></div>
        <div class="field"><label for="mt-p">Lieu</label><input id="mt-p" name="place" maxlength="200" value="${esc(m && m.place)}" placeholder="Ex. chez le président, à Pikine"></div>
        <div class="field"><label for="mt-a">Ordre du jour</label><textarea id="mt-a" name="agenda" rows="5" maxlength="4000" placeholder="Un point par ligne&#10;Ex. Bilan des cotisations&#10;Projet forage">${esc(m && m.agenda)}</textarea></div>
        <p class="err" hidden></p><button class="btn primary block" type="submit">${m ? 'Enregistrer' : 'Convoquer'}</button>
        ${m ? '' : '<p class="help">Après la convocation, partagez-la dans le groupe WhatsApp de l’association.</p>'}</form>`;
  }

  V.r = async (sub) => {
    const a = S.ctx.assoc;
    const m = must(await sb.from('meetings').select('*').eq('association_id', a.id).eq('id', sub[1]).maybeSingle());
    if (!m) return `${subHead('Réunion introuvable', B() + '/reunions')}`;
    if (sub[2] === 'modifier') return meetingForm(m);
    const att = must(await sb.from('meeting_attendance').select('*').eq('meeting_id', m.id));
    if (sub[2] === 'presence') return attendanceView(m, att);
    if (sub[2] === 'compte-rendu') return minutesForm(m);
    const pres = att.filter(x => x.present), abs = att.filter(x => !x.present);
    const crText = `Compte rendu · ${m.title}\n${dLong(m.starts_at)}${m.place ? ' · ' + m.place : ''}\nPrésents : ${pres.length}\n\n${m.minutes}\n\n${a.name}`;
    const mg = can('meetings');
    return `${subHead('Réunion', B() + '/reunions')}
      <section class="card stack"><div class="between"><span class="pill ${MEET_PILL[m.status]}">${esc(m.status)}</span><span class="muted" style="font-size:13px">Convoquée par ${esc(String(m.created_label || '').replace(/\s*\(.*\)$/, '') || '—')}</span></div>
        <h2 style="font-size:22px">${esc(m.title)}</h2>
        <dl class="kv" style="margin:0"><dt>Date</dt><dd>${esc(dLong(m.starts_at))}</dd>${m.place ? `<dt>Lieu</dt><dd>${esc(m.place)}</dd>` : ''}</dl>
        ${m.agenda ? `<div class="stack" style="gap:4px"><span class="eyebrow">Ordre du jour</span><p style="margin:0;white-space:pre-line">${esc(m.agenda)}</p></div>` : ''}</section>
      <div class="row" style="flex-wrap:wrap">${m.status !== 'Annulée' ? `<a class="btn wa sm" target="_blank" rel="noopener" href="${waShare(convText(m))}">${I.wa} Envoyer la convocation</a>` : ''}${mg ? `<a class="btn ghost sm" href="${B()}/r/${m.id}/modifier">Modifier</a>` : ''}</div>
      <section class="card stack"><div class="between"><h2>Présence</h2>${mg && m.status !== 'Annulée' ? `<a class="btn primary sm" href="${B()}/r/${m.id}/presence">Faire l’appel</a>` : ''}</div>
        ${att.length ? `<div class="row num" style="gap:8px;flex-wrap:wrap"><span class="pill p-ok">${pres.length} présent${pres.length > 1 ? 's' : ''}</span><span class="pill p-late">${abs.length} absent${abs.length > 1 ? 's' : ''}</span></div>
          ${pres.length ? `<p style="margin:0" class="muted">${pres.map(x => esc(memberName(x.member_id))).join(', ')}</p>` : ''}` : `<span class="muted">${m.status === 'Prévue' ? 'L’appel se fait le jour de la réunion.' : 'Aucune présence enregistrée.'}</span>`}</section>
      <section class="card stack"><div class="between"><h2>Compte rendu</h2>${mg && m.status !== 'Annulée' ? `<a class="btn ${m.minutes ? 'ghost' : 'primary'} sm" href="${B()}/r/${m.id}/compte-rendu">${m.minutes ? 'Modifier' : 'Rédiger'}</a>` : ''}</div>
        ${m.minutes ? `<p style="margin:0;white-space:pre-line">${esc(m.minutes)}</p><a class="link" target="_blank" rel="noopener" href="${waShare(crText)}">Partager le compte rendu sur WhatsApp</a>` : `<span class="muted">${m.status === 'Annulée' ? 'Réunion annulée.' : 'Pas encore de compte rendu.'}</span>`}</section>
      ${mg && m.status === 'Prévue' ? `<div class="row" style="flex-wrap:wrap"><button class="btn ghost sm" data-act="meetstatus" data-id="${m.id}" data-status="Tenue">Marquer comme tenue</button><button class="btn danger sm" data-act="meetstatus" data-id="${m.id}" data-status="Annulée">Annuler la réunion</button></div>` : ''}
      ${mg && m.status !== 'Prévue' ? `<button class="link" data-act="meetstatus" data-id="${m.id}" data-status="Prévue">Remettre en « Prévue »</button>` : ''}`;
  };

  function attendanceView(m, att) {
    if (!can('meetings')) return `${subHead('Présence', B() + '/r/' + m.id)}<p class="note">Réservé au président, au vice-président et au secrétaire général.</p>`;
    const st = new Map(att.map(x => [x.member_id, x.present]));
    const list = activeMembers().slice().sort((x, y) => x.full_name.localeCompare(y.full_name, 'fr'));
    const btn = (id, v, l) => `<button class="btn sm att ${v ? 'att-yes' : 'att-no'}" data-act="attend" data-meet="${m.id}" data-id="${id}" data-v="${v ? 1 : 0}" aria-pressed="${st.get(id) === v}">${l}</button>`;
    return `${subHead('Faire l’appel', B() + '/r/' + m.id)}
      <p class="muted" style="margin:0">${esc(m.title)} · ${esc(dLong(m.starts_at))}</p>
      <div class="row num" id="att-count" style="gap:8px;flex-wrap:wrap">${attCount(att)}</div>
      <div class="list" id="att-list">${list.map(x => `<div class="item" data-mid="${x.id}"><div class="av">${esc(initials(x.full_name))}</div><div class="body"><div class="t">${esc(x.full_name)}</div><div class="s">${esc(ROLES[x.role])}</div></div><div class="row" style="gap:6px">${btn(x.id, true, 'Présent')}${btn(x.id, false, 'Absent')}</div></div>`).join('') || '<div class="empty">Aucun membre actif.</div>'}</div>
      <a class="btn primary block" href="${B()}/r/${m.id}">Terminer</a>
      <p class="help">Chaque choix est enregistré tout de suite. Touchez à nouveau le même bouton pour l’effacer.</p>`;
  }
  const attCount = att => { const p = att.filter(x => x.present).length, n = att.length - p, tot = activeMembers().length; return `<span class="pill p-ok">${p} présent${p > 1 ? 's' : ''}</span><span class="pill p-late">${n} absent${n > 1 ? 's' : ''}</span><span class="pill p-blue">${Math.max(0, tot - att.length)} non noté${tot - att.length > 1 ? 's' : ''}</span>`; };

  function minutesForm(m) {
    if (!can('meetings')) return `${subHead('Compte rendu', B() + '/r/' + m.id)}<p class="note">Réservé au président, au vice-président et au secrétaire général.</p>`;
    return `${subHead('Compte rendu', B() + '/r/' + m.id)}
      <p class="muted" style="margin:0">${esc(m.title)} · ${esc(dLong(m.starts_at))}</p>
      <form class="stack" data-form="minutes" data-id="${m.id}" novalidate>
        <div class="field"><label for="cr-b">Ce qui a été dit et décidé</label><textarea id="cr-b" name="minutes" rows="12" maxlength="20000" placeholder="Décisions prises, montants votés, qui fait quoi et pour quand">${esc(m.minutes)}</textarea></div>
        ${m.status === 'Prévue' ? '<div class="field"><label class="check"><input type="checkbox" name="held" checked> Marquer la réunion comme tenue</label></div>' : ''}
        <p class="err" hidden></p><button class="btn primary block" type="submit">Publier le compte rendu</button>
        <p class="help">Tous les membres pourront le lire dans l’application.</p></form>`;
  }

  /* Votes ------------------------------------------------------------ */
  const pollOpen = p => p.status === 'Ouvert' && (!p.closes_at || new Date(p.closes_at).getTime() > Date.now());
  const pollItem = p => `<a class="card meet-row" href="${B()}/vote/${p.id}"><span class="ico-box">${I.vote}</span><span class="body"><b>${esc(p.question)}</b><span class="muted">${pollOpen(p) ? (p.closes_at ? 'Jusqu’au ' + esc(dLong(p.closes_at)) : 'Ouvert') : 'Clos le ' + esc(dFR(p.closed_at || p.closes_at))}${p.anonymous ? ' · secret' : ''}</span></span><span class="pill ${pollOpen(p) ? 'p-ok' : 'p-blue'}">${pollOpen(p) ? 'Ouvert' : 'Clos'}</span></a>`;

  V.votes = async (sub) => {
    if (sub[1] === 'nouveau') return pollForm();
    const res = await sb.from('polls').select('*').eq('association_id', S.ctx.assoc.id).order('created_at', { ascending: false }).limit(100);
    if (res.error) return `${subHead('Votes', B() + '/plus')}<p class="note">Les votes ne sont pas encore installés sur la base.</p>`;
    const open = res.data.filter(pollOpen), closed = res.data.filter(p => !pollOpen(p));
    return `<div class="subhead between" style="margin-left:-8px"><span class="row" style="gap:6px"><a class="iconbtn" href="${B()}/plus" aria-label="Retour">${I.back}</a><h1>Votes</h1></span>${can('polls') ? `<a class="btn primary sm" href="${B()}/votes/nouveau">+ Nouveau vote</a>` : ''}</div>
      <section class="stack"><h2>En cours</h2>${open.map(pollItem).join('') || `<div class="empty">Aucun vote en cours.${can('polls') ? ' Lancez-en un avec « + Nouveau vote ».' : ''}</div>`}</section>
      ${closed.length ? `<section class="stack"><h2>Terminés</h2>${closed.map(pollItem).join('')}</section>` : ''}`;
  };

  function pollForm() {
    if (!can('polls')) return `${subHead('Nouveau vote', B() + '/votes')}<p class="note">Réservé au président, au vice-président et au secrétaire général.</p>`;
    return `${subHead('Nouveau vote', B() + '/votes')}
      <form class="stack" data-form="poll" novalidate>
        <div class="field"><label for="pl-q">Question</label><input id="pl-q" name="question" maxlength="300" placeholder="Ex. Augmenter la cotisation à 2 000 FCFA ?" required></div>
        <div class="field"><label for="pl-o">Choix possibles (un par ligne)</label><textarea id="pl-o" name="options" rows="4">Oui
Non
Abstention</textarea><p class="help">Entre 2 et 10 choix.</p></div>
        <div class="field"><label for="pl-d">Explication (facultatif)</label><textarea id="pl-d" name="description" rows="3" maxlength="2000" placeholder="Ce qu’il faut savoir avant de voter"></textarea></div>
        <div class="row2"><div class="field"><label for="pl-cd">Fin du vote (facultatif)</label><input id="pl-cd" name="close_date" type="date"></div><div class="field"><label for="pl-ch">Heure</label><input id="pl-ch" name="close_time" type="time" value="20:00"></div></div>
        <div class="field"><label class="check"><input type="checkbox" name="anonymous" checked> Vote secret</label><p class="help">Secret : personne ne voit qui a voté quoi, seulement le total. Sinon, chaque membre voit les noms par choix.</p></div>
        <p class="err" hidden></p><button class="btn primary block" type="submit">Lancer le vote</button></form>`;
  }

  V.vote = async (sub) => {
    const a = S.ctx.assoc;
    const p = must(await sb.from('polls').select('*').eq('association_id', a.id).eq('id', sub[1]).maybeSingle());
    if (!p) return `${subHead('Vote introuvable', B() + '/votes')}`;
    const [opts, res, ballots] = await Promise.all([
      sb.from('poll_options').select('*').eq('poll_id', p.id).order('position').then(must),
      sb.rpc('poll_results', { p_poll: p.id }).then(must),
      sb.from('poll_votes').select('*').eq('poll_id', p.id).then(must)
    ]);
    const count = new Map(res.map(r => [r.option_id, Number(r.votes)])), total = res.reduce((x, r) => x + Number(r.votes), 0);
    const mine = ballots.find(v => v.member_id === S.ctx.me.id), open = pollOpen(p);
    const voters = activeMembers().filter(m => m.user_id).length;
    const showRes = !!mine || !open || can('polls');
    const best = Math.max(0, ...res.map(r => Number(r.votes)));
    const canVote = open && S.ctx.me.user_id && S.ctx.me.active && !S.ctx.me.pending;
    const link = appLink('/a/' + a.id + '/vote/' + p.id);
    const share = open ? `VOTE · ${a.name}\n\n${p.question}\nChoix : ${opts.map(o => o.label).join(' / ')}${p.closes_at ? '\nJusqu’au ' + dLong(p.closes_at) : ''}\n\nVotez dans l’application :\n${link}`
      : `RÉSULTAT DU VOTE · ${a.name}\n\n${p.question}\n${opts.map(o => `${o.label} : ${count.get(o.id) || 0}`).join('\n')}\n\n${total} votant${total > 1 ? 's' : ''}`;
    return `${subHead('Vote', B() + '/votes')}
      <section class="card stack"><div class="between"><span class="pill ${open ? 'p-ok' : 'p-blue'}">${open ? 'Ouvert' : 'Clos'}</span><span class="muted" style="font-size:13px">${p.anonymous ? 'Vote secret' : 'Vote à main levée'}</span></div>
        <h2 style="font-size:21px">${esc(p.question)}</h2>${p.description ? `<p style="margin:0;white-space:pre-line" class="muted">${esc(p.description)}</p>` : ''}
        <span class="muted" style="font-size:13px">Lancé par ${esc(String(p.created_label || '').replace(/\s*\(.*\)$/, '') || '—')} · ${open ? (p.closes_at ? 'jusqu’au ' + esc(dLong(p.closes_at)) : 'sans date de fin') : 'clos le ' + esc(dFR(p.closed_at || p.closes_at))}</span></section>
      ${canVote ? `<section class="stack"><h2>${mine ? 'Votre vote (vous pouvez changer)' : 'Votre vote'}</h2><div class="stack" style="gap:8px">${opts.map(o => `<button class="btn ghost block vote-opt" data-act="vote" data-poll="${p.id}" data-opt="${o.id}" aria-pressed="${mine && mine.option_id === o.id}">${esc(o.label)}</button>`).join('')}</div></section>` : ''}
      ${!canVote && open && !S.ctx.me.user_id ? '<p class="note">Il faut un compte sur l’application pour voter.</p>' : ''}
      <section class="card stack"><div class="between"><h2>Résultats</h2><span class="muted num" style="font-size:13px">${total} votant${total > 1 ? 's' : ''} sur ${voters}</span></div>
        ${showRes ? opts.map(o => { const n = count.get(o.id) || 0, pc = pct(n, total); const names = !p.anonymous ? ballots.filter(v => v.option_id === o.id).map(v => memberName(v.member_id)) : [];
          return `<div class="stack" style="gap:4px"><div class="between"><b>${esc(o.label)}${!open && n === best && n > 0 ? ' ✓' : ''}</b><span class="num">${n} · ${pc}${NB}%</span></div><div class="bar"><i style="width:${pc}%"></i></div>${names.length ? `<span class="muted" style="font-size:12.5px">${names.map(esc).join(', ')}</span>` : ''}</div>`; }).join('')
          : '<span class="muted">Votez pour voir les résultats.</span>'}</section>
      <div class="row" style="flex-wrap:wrap"><a class="btn wa sm" target="_blank" rel="noopener" href="${waShare(share)}">${I.wa} ${open ? 'Partager le vote' : 'Partager le résultat'}</a>
        ${open && can('polls') ? `<button class="btn danger sm" data-act="closepoll" data-id="${p.id}">Clore le vote</button>` : ''}</div>`;
  };

  /* Documents -------------------------------------------------------- */
  const DOC_CATS = ['Statuts', 'Règlement intérieur', 'Procès-verbal', 'Rapport', 'Reçu', 'Autre'];
  const DOC_ACCEPT = '.pdf,.jpg,.jpeg,.png,.webp,.heic,.doc,.docx,.xls,.xlsx';
  const fileSize = n => n >= 1048576 ? (n / 1048576).toFixed(1).replace('.', ',') + NB + 'Mo' : Math.max(1, Math.round(n / 1024)) + NB + 'Ko';
  const docKind = (mime, name) => /pdf/.test(mime) || /\.pdf$/i.test(name) ? 'PDF' : /^image\//.test(mime) ? 'Photo' : /word|\.docx?$/i.test(mime + name) ? 'Word' : /sheet|excel|\.xlsx?$/i.test(mime + name) ? 'Excel' : 'Fichier';

  V.documents = async (sub, q) => {
    const a = S.ctx.assoc;
    const f = DOC_CATS.includes(q.get('f')) ? q.get('f') : '';
    let qy = sb.from('documents').select('*').eq('association_id', a.id);
    if (f) qy = qy.eq('category', f);
    const res = await qy.order('created_at', { ascending: false }).limit(200);
    if (res.error) return `${subHead('Documents', B() + '/plus')}<p class="note">Les documents ne sont pas encore installés sur la base.</p>`;
    const mg = can('docs');
    return `${subHead('Documents', B() + '/plus')}
      <div class="chips" role="group" aria-label="Filtrer">${[['', 'Tous'], ...DOC_CATS.map(c => [c, c])].map(([k, l]) => `<a class="chip" style="text-decoration:none" href="${B()}/documents${k ? '?f=' + encodeURIComponent(k) : ''}" aria-pressed="${f === k}">${esc(l)}</a>`).join('')}</div>
      <div class="list">${res.data.map(d => `<div class="item"><span class="doc-ico" aria-hidden="true">${esc(docKind(d.mime, d.file_name))}</span><div class="body"><button class="t link-plain" data-act="opendoc" data-path="${esc(d.file_path)}">${esc(d.title)}</button><div class="s">${esc(d.category)} · ${dFR(d.created_at)} · ${fileSize(d.size)}</div></div>${mg ? `<button class="iconbtn sm-del" data-act="deldoc" data-id="${d.id}" data-path="${esc(d.file_path)}" aria-label="Retirer le document ${esc(d.title)}">✕</button>` : ''}</div>`).join('') || `<div class="empty">Aucun document${f ? ' dans cette catégorie' : ''}.${mg ? ' Ajoutez les statuts de l’association avec le formulaire ci-dessous.' : ''}</div>`}</div>
      <div id="doc-open"></div>
      ${mg ? `<form class="card stack" data-form="doc" novalidate><h2>Ajouter un document</h2>
        <div class="field"><label for="dc-t">Titre</label><input id="dc-t" name="title" maxlength="160" placeholder="Ex. PV de l’AG du 18 octobre"></div>
        <div class="field"><label for="dc-c">Catégorie</label><select id="dc-c" name="category">${DOC_CATS.map(c => opt(c, c, f || 'Procès-verbal')).join('')}</select></div>
        <div class="field"><label for="dc-f">Fichier (PDF, photo, Word ou Excel, 10 Mo maximum)</label><input id="dc-f" name="file" type="file" accept="${DOC_ACCEPT}"></div>
        <p class="err" hidden></p><button class="btn primary block" type="submit">Ajouter</button>
        <p class="help">Tous les membres validés pourront le lire. Une photo prise avec le téléphone convient très bien.</p></form>` : ''}`;
  };

  /* Rapport mensuel -------------------------------------------------- */
  const addMonthYM = (p, k) => { const [y, m] = p.split('-').map(Number); const d = new Date(y, m - 1 + k, 1); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}`; };
  V.rapport = async (sub, q) => {
    const a = S.ctx.assoc, cur = curYM();
    const M = /^\d{4}-\d{2}$/.test(q.get('m') || '') && q.get('m') <= cur ? q.get('m') : cur;
    const start = M + '-01', next = addMonthYM(M, 1) + '-01';
    const txs = await fetchAll(() => sb.from('transactions').select('id,kind,amount,category,occurred_on,member_id,period,description,project_id,reversal_of').eq('association_id', a.id).lt('occurred_on', next).order('id'));
    const fx = t => (t.kind === 'in' ? 1 : -1) * Number(t.amount);
    const before = txs.filter(t => t.occurred_on < start), during = txs.filter(t => t.occurred_on >= start);
    const open = before.reduce((x, t) => x + fx(t), 0);
    const inM = during.filter(t => t.kind === 'in').reduce((x, t) => x + Number(t.amount), 0), outM = during.filter(t => t.kind === 'out').reduce((x, t) => x + Number(t.amount), 0);
    const close = open + inM - outM;
    const byCat = kind => { const m = new Map(); during.filter(t => t.kind === kind).forEach(t => m.set(t.category, (m.get(t.category) || 0) + Number(t.amount))); return [...m.entries()].filter(e => e[1] !== 0).sort((x, y) => y[1] - x[1]); };
    const deM = x => { const l = pFR(x); return /^[aeiouâéèh]/i.test(l) ? 'd’' + l : 'de ' + l; };
    const fee = Number(a.fee_amount) || 0;
    const dueNow = activeMembers().filter(m => [ym(a.dues_start), ym(m.joined_on)].sort().pop() <= M);
    const paidN = dueNow.filter(m => paidFor(m.id, M) >= fee).length;
    const collected = dueNow.reduce((x, m) => x + Math.min(paidFor(m.id, M), fee), 0), expected = dueNow.length * fee;
    const unpaid = fee ? dueNow.filter(m => paidFor(m.id, M) < fee) : [];
    const [meets, polls, projects, ptot] = await Promise.all([
      sb.from('meetings').select('*').eq('association_id', a.id).gte('starts_at', new Date(start + 'T00:00:00').toISOString()).lt('starts_at', new Date(next + 'T00:00:00').toISOString()).order('starts_at').then(r => r.error ? [] : r.data, () => []),
      sb.from('polls').select('*').eq('association_id', a.id).eq('status', 'Clos').gte('closed_at', new Date(start + 'T00:00:00').toISOString()).lt('closed_at', new Date(next + 'T00:00:00').toISOString()).then(r => r.error ? [] : r.data, () => []),
      sb.from('projects').select('*').eq('association_id', a.id).eq('status', 'En cours').then(r => r.error ? [] : r.data, () => []),
      sb.from('v_project_totals').select('*').then(r => r.error ? [] : r.data, () => [])
    ]);
    const pollRes = await Promise.all(polls.map(p => Promise.all([sb.from('poll_options').select('*').eq('poll_id', p.id).order('position').then(must), sb.rpc('poll_results', { p_poll: p.id }).then(must)])));
    const tot = new Map(ptot.map(x => [x.project_id, x]));
    const months = []; for (let k = 0; k < 12; k++) months.push(addMonthYM(cur, -k));
    const title = `Rapport ${deM(M)}`;
    const wa = `${title.toUpperCase()} · ${a.name}\n\nSolde au début du mois : ${money(open)}\nEntrées : +${money(inM)}\nSorties : −${money(outM)}\nSolde à la fin du mois : ${money(close)}${fee ? `\n\nCotisations : ${paidN} membre${paidN > 1 ? 's' : ''} sur ${dueNow.length} à jour (${money(collected)} sur ${money(expected)})` : ''}${meets.length ? `\nRéunions : ${meets.length}` : ''}${polls.length ? `\nVotes clos : ${polls.length}` : ''}\n\nDétails dans l’application :\n${appLink('/a/' + a.id + '/rapport?m=' + M)}`;
    const catList = rows => rows.length ? `<dl class="kv num" style="margin:0">${rows.map(([c, v]) => `<dt>${esc(c)}</dt><dd>${money(v)}</dd>`).join('')}</dl>` : '<span class="muted">Aucune.</span>';
    return `<div class="no-print">${subHead('Rapport mensuel', B() + '/plus')}</div>
      <div class="field no-print"><label for="rp-m">Mois</label><select id="rp-m" data-nav="rapport">${months.map(x => opt(x, pFR(x).replace(/^./, c => c.toUpperCase()), M)).join('')}</select></div>
      <div class="row no-print" style="flex-wrap:wrap"><button class="btn primary sm" data-act="print">Télécharger en PDF</button><a class="btn wa sm" target="_blank" rel="noopener" href="${waShare(wa)}">${I.wa} Partager le résumé</a></div>
      <article class="report stack">
        <header class="report-head"><span class="eyebrow">${esc(a.name)}</span><h1>${esc(title)}</h1><span class="muted" style="font-size:13px">Établi le ${dFR(todayISO())} avec VillageLink</span></header>
        <section class="card stack"><h2>Caisse</h2><dl class="kv num" style="margin:0"><dt>Solde au début du mois</dt><dd>${money(open)}</dd><dt>Entrées du mois</dt><dd style="color:var(--green)">${inM ? '+' : ''}${money(inM)}</dd><dt>Sorties du mois</dt><dd style="color:var(--danger)">${outM ? '−' : ''}${money(outM)}</dd><dt><b>Solde à la fin du mois</b></dt><dd><b>${money(close)}</b></dd></dl></section>
        ${fee ? `<section class="card stack"><div class="between"><h2>Cotisations ${esc(deM(M))}</h2><span class="pill p-blue num">${paidN}/${dueNow.length} à jour</span></div>
          <div class="bar"><i style="width:${pct(collected, expected)}%"></i></div><span class="muted num">${money(collected)} encaissés sur ${money(expected)} attendus</span>
          ${unpaid.length ? `<span class="eyebrow">Pas encore payé (${unpaid.length})</span><p style="margin:0">${unpaid.map(m => esc(m.full_name)).join(', ')}</p>` : '<span class="ok-msg">Tout le monde a payé ce mois-ci.</span>'}</section>` : ''}
        <section class="card stack"><h2>Entrées par catégorie</h2>${catList(byCat('in'))}</section>
        <section class="card stack"><h2>Dépenses par catégorie</h2>${catList(byCat('out'))}</section>
        ${meets.length ? `<section class="card stack"><h2>Réunions</h2>${meets.map(m => `<div><b>${esc(m.title)}</b> · ${esc(dLong(m.starts_at))} · <span class="pill ${MEET_PILL[m.status]}">${esc(m.status)}</span>${m.minutes ? `<p class="muted" style="margin:4px 0 0;white-space:pre-line">${esc(m.minutes.slice(0, 600))}${m.minutes.length > 600 ? '…' : ''}</p>` : ''}</div>`).join('')}</section>` : ''}
        ${polls.length ? `<section class="card stack"><h2>Décisions votées</h2>${polls.map((p, i) => { const [opts, res] = pollRes[i]; const c = new Map(res.map(r => [r.option_id, Number(r.votes)])); return `<div><b>${esc(p.question)}</b><p class="muted" style="margin:2px 0 0">${opts.map(o => `${esc(o.label)} : ${c.get(o.id) || 0}`).join(' · ')}</p></div>`; }).join('')}</section>` : ''}
        ${projects.length ? `<section class="card stack"><h2>Projets en cours</h2>${projects.map(p => { const t = tot.get(p.id) || { collected: 0 }; const pc = pct(t.collected, p.goal); return `<div class="stack" style="gap:4px"><div class="between"><b>${esc(p.name)}</b><span class="num">${pc}${NB}%</span></div><div class="bar thin"><i style="width:${pc}%"></i></div><span class="muted num" style="font-size:13px">${money(t.collected)} sur ${money(p.goal)}</span></div>`; }).join('')}</section>` : ''}
      </article>`;
  };

  /* Notifications ---------------------------------------------------- */
  const NOTIF_LINKS = [[/annonce/i, 'annonces', I.mega], [/réunion|compte rendu|convocation/i, 'reunions', I.cal], [/vote/i, 'votes', I.vote], [/document/i, 'documents', I.doc],
    [/cotisation|recette|dépense|opération|contre-écriture/i, 'finances', I.list], [/projet|mise à jour/i, 'projets', I.drop], [/membre|adhésion|rôle|retiré|réintégré|bureau|rejoindre|demande de/i, 'membres', I.users], [/message|discussion/i, 'discussion', I.chat]];
  V.notifications = async () => {
    const a = S.ctx.assoc, seenKey = 'vl:notif:' + a.id, seen = Number(store.get(seenKey) || 0);
    const rows = must(await sb.from('activity_log').select('*').eq('association_id', a.id).order('id', { ascending: false }).limit(40));
    if (rows[0]) store.set(seenKey, String(Math.max(rows[0].id, seen)));
    S.ctx.notif = 0;
    try { if (navigator.clearAppBadge) navigator.clearAppBadge(); } catch (e) { /* non pris en charge */ }
    const item = l => { const hit = NOTIF_LINKS.find(([re]) => re.test(l.message)) || [null, 'journal', I.clock]; const fresh = l.id > seen && l.actor_id !== S.user.id;
      return `<a class="item notif ${fresh ? 'fresh' : ''}" href="${B()}/${hit[1]}"><span class="ico">${hit[2]}</span><div class="body"><div class="s wrap" style="color:var(--ink)"><b>${esc(String(l.actor_label || '').replace(/\s*\(.*\)$/, ''))}</b> ${esc(l.message)}</div><div class="s">${dFR(localDay(l.created_at))} à ${hm(l.created_at)}${fresh ? ' · <b class="new">Nouveau</b>' : ''}</div></div></a>`; };
    return `${subHead('Notifications', B())}
      <div class="row" style="flex-wrap:wrap"><a class="btn ghost sm" href="${B()}/annonces">${I.mega.replace('<svg ', '<svg width="18" height="18" ')} Annonces</a><a class="btn ghost sm" href="${B()}/journal">Tout le journal</a></div>
      <div class="list menu">${rows.map(item).join('') || '<div class="empty">Rien de nouveau pour le moment.</div>'}</div>
      <p class="help">Les nouveautés faites par les autres membres apparaissent ici : annonces, réunions, votes, documents, paiements et membres.</p>`;
  };

  const MSG_KINDS = ['Message', 'Idée', 'Réclamation'];
  V.discussion = async (sub, q) => {
    const a = S.ctx.assoc;
    const f = MSG_KINDS.includes(q.get('f')) ? q.get('f') : '';
    let qy = sb.from('messages').select('*').eq('association_id', a.id);
    if (f) qy = qy.eq('kind', f);
    const res = await qy.order('id', { ascending: false }).limit(100);
    if (res.error) return `${subHead('Discussion', B() + '/plus')}<p class="note">La discussion n’est pas encore installée sur la base. Le président doit coller le script « migration 1.2 » dans Supabase.</p>`;
    const rows = res.data.slice().reverse();
    if (rows.length) store.set('vl:seen:' + a.id, String(Math.max(...rows.map(m => m.id), S.ctx.lastMsg || 0)));
    const canHideAll = ['president', 'vice_president', 'secretaire'].includes(S.ctx.me.role);
    const pill = { Idée: 'p-ok', Réclamation: 'p-late', Message: '' };
    return `${subHead('Discussion', B() + '/plus')}
      <div class="chips" role="group" aria-label="Filtrer">${[['', 'Tout'], ['Idée', 'Idées'], ['Réclamation', 'Réclamations']].map(([k, l]) => `<a class="chip" style="text-decoration:none" href="${B()}/discussion${k ? '?f=' + encodeURIComponent(k) : ''}" aria-pressed="${f === k}">${l}</a>`).join('')}</div>
      <div class="chat" id="chat">${rows.map(m => { const mine = m.author_id === S.user.id; return `<div class="msg ${mine ? 'mine' : ''} ${m.hidden ? 'hidden-msg' : ''}">
        <div class="msg-head"><b>${esc(mine ? 'Vous' : m.author_label)}</b>${m.kind !== 'Message' ? ` <span class="pill ${pill[m.kind]}">${esc(m.kind)}</span>` : ''}</div>
        <div class="msg-body">${m.hidden ? 'Message masqué' + (m.hidden_by ? ' par ' + esc(m.hidden_by) : '') : esc(m.body)}</div>
        <div class="msg-foot"><span>${dFR(localDay(m.created_at))} à ${hm(m.created_at)}</span>${!m.hidden && (mine || canHideAll) ? `<button class="link" data-act="hidemsg" data-id="${m.id}">Masquer</button>` : ''}</div></div>`; }).join('') || `<div class="empty">Aucun message${f ? ' dans cette catégorie' : ''}. Écrivez le premier !</div>`}</div>
      <form class="card stack" data-form="message" novalidate>
        <div class="field"><label for="ms-k">Type</label><select id="ms-k" name="kind">${MSG_KINDS.map(k => opt(k, k, f || 'Message')).join('')}</select></div>
        <div class="field"><label for="ms-b">Votre message</label><textarea id="ms-b" name="body" rows="3" maxlength="1000" placeholder="Écrivez à tous les membres de l’association"></textarea></div>
        <p class="err" hidden></p><button class="btn primary block" type="submit">Envoyer</button>
        <p class="help">Visible par tous les membres validés. Le président, le vice-président et le secrétaire peuvent masquer un message déplacé.</p></form>`;
  };
  AFTER.discussion = () => { const c = $('#chat'); if (c && c.lastElementChild) c.lastElementChild.scrollIntoView({ block: 'end' }); };

  V.journal = async (sub, q) => {
    const p = Math.max(0, Math.floor(Number(q.get('p'))) || 0), size = 50;
    const rows = must(await sb.from('activity_log').select('*').eq('association_id', S.ctx.assoc.id).order('id', { ascending: false }).range(p * size, p * size + size));
    const more = rows.length > size; if (more) rows.pop();
    return `${subHead('Journal d’activité', B() + '/plus')}<p class="note">Le journal est en lecture seule. Personne, pas même le président, ne peut effacer une ligne.</p>
      <div class="list">${rows.map(logItem).join('') || '<div class="empty">Aucune activité.</div>'}</div>
      ${p || more ? `<div class="pager">${p ? `<a class="btn ghost sm" href="${B()}/journal?p=${p - 1}">← Plus récent</a>` : '<span></span>'}${more ? `<a class="btn ghost sm" href="${B()}/journal?p=${p + 1}">Plus ancien →</a>` : ''}</div>` : ''}`;
  };

  V.plus = async () => {
    const items = [['discussion', 'Discussion', 'Messages, idées et réclamations des membres', I.chat.replace('width="24" height="24" ', '')], ['transparence', 'Transparence', 'Où va l’argent, en clair', I.eye], ['finances', 'Finances', 'Recettes, dépenses et justificatifs', I.list], ['reunions', 'Réunions', 'Convocations, présence et comptes rendus', I.cal], ['votes', 'Votes', 'Décisions et sondages de l’association', I.vote], ['documents', 'Documents', 'Statuts, règlement, procès-verbaux', I.doc], ['rapport', 'Rapport mensuel', 'Le bilan du mois, en PDF ou sur WhatsApp', I.report], ['annonces', 'Annonces', 'Nouvelles du village', I.mega], ['journal', 'Journal d’activité', 'Qui a fait quoi, et quand', I.clock], ['parametres', 'Association', 'Fiche, cotisation, code d’invitation', I.gear]];
    return `<h1>Plus</h1>
      <div class="rolebar"><span>Connecté en tant que <b>${esc(S.ctx.me.full_name)}</b>, ${esc(ROLES[S.ctx.me.role].toLowerCase())}</span></div>
      <div class="list menu">${items.map(([k, t, s, ic]) => `<a class="item" href="${B()}/${k}"><span class="ico">${ic}</span><div class="body"><div class="t">${t}</div><div class="s">${s}</div></div><span class="chev">${I.chev}</span></a>`).join('')}</div>
      <div class="list menu"><a class="item" href="#/bienvenue"><span class="ico">${I.swap}</span><div class="body"><div class="t">Mes associations</div><div class="s">Changer, rejoindre ou créer une association</div></div><span class="chev">${I.chev}</span></a>
      <button class="item" data-act="signout"><span class="ico">${I.out}</span><div class="body"><div class="t">Se déconnecter</div><div class="s">${esc(S.user.email || '')}</div></div></button></div>
      <section class="card stack"><h2>Affichage</h2><div class="seg seg3" role="group" aria-label="Thème">${THEMES.map(([k, l]) => `<button data-act="theme" data-theme="${k}" aria-pressed="${themeNow() === k}">${l}</button>`).join('')}</div><p class="help">« Auto » suit le réglage clair ou sombre de votre téléphone.</p></section>
      <p class="muted" style="font-size:12.5px;text-align:center">VillageLink · version 1.10.1 · <a class="link" href="confidentialite.html">Confidentialité</a> · <a class="link" href="conditions.html">Conditions</a></p>`;
  };

  V.parametres = async () => {
    const a = S.ctx.assoc, pres = can('settings');
    const invite = `Rejoignez « ${a.name} » sur VillageLink pour suivre les cotisations et les projets du village.\n\n1. Ouvrez ${location.origin + location.pathname}\n2. Créez votre compte\n3. Entrez le code : ${a.invite_code}`;
    const ro = pres ? '' : 'disabled';
    return `${subHead('Association', B() + '/plus')}
      <section class="card stack"><h2>Code d’invitation</h2><p class="muted" style="margin:0;font-size:13.5px">Les membres créent leur compte puis entrent ce code. Ceux que le trésorier a déjà inscrits retrouvent leur historique grâce à leur numéro de téléphone.</p>
        <div class="code">${esc(a.invite_code)}</div>
        <a class="btn wa block" target="_blank" rel="noopener" href="${waShare(invite)}">${I.wa} Envoyer l’invitation sur WhatsApp</a>
        ${pres ? '<button class="btn ghost sm" data-act="newcode">Changer le code</button>' : ''}</section>
      <form class="stack" data-form="assoc" novalidate>
        ${pres ? '' : '<p class="note">Seul le président peut modifier ces informations.</p>'}
        <span class="eyebrow">Cotisation</span>
        <div class="row2"><div class="field"><label for="as-fee">Montant par mois</label><input id="as-fee" name="fee_amount" type="number" inputmode="numeric" min="0" step="1" value="${esc(a.fee_amount)}" ${ro}></div><div class="field"><label for="as-due">Jour d’échéance</label><input id="as-due" name="fee_due_day" type="number" inputmode="numeric" min="1" max="28" value="${esc(a.fee_due_day)}" ${ro}></div></div>
        <div class="field"><label for="as-start">Suivre les cotisations à partir de</label><input id="as-start" name="dues_start" type="month" value="${esc(ym(a.dues_start))}" ${ro}><p class="help">Les mois précédents ne comptent pas comme des retards.</p></div>
        <div class="field"><label for="as-cur">Monnaie</label><select id="as-cur" name="currency" ${ro}>${CURRENCIES.map(([k, l]) => opt(k, l, a.currency)).join('')}</select></div>
        <span class="eyebrow">Fiche de l’association</span>
        <div class="field"><label for="as-name">Nom</label><input id="as-name" name="name" value="${esc(a.name)}" ${ro}></div>
        <div class="row2"><div class="field"><label for="as-vil">Village d’origine</label><input id="as-vil" name="village" value="${esc(a.village)}" ${ro}></div><div class="field"><label for="as-oc">Pays d’origine</label><input id="as-oc" name="origin_country" value="${esc(a.origin_country)}" ${ro}></div></div>
        <div class="row2"><div class="field"><label for="as-reg">Région</label><input id="as-reg" name="region" value="${esc(a.region)}" ${ro}></div><div class="field"><label for="as-pre">Préfecture</label><input id="as-pre" name="prefecture" value="${esc(a.prefecture)}" ${ro}></div></div>
        <div class="row2"><div class="field"><label for="as-rc">Ville de résidence</label><input id="as-rc" name="residence_city" value="${esc(a.residence_city)}" ${ro}></div><div class="field"><label for="as-rco">Pays de résidence</label><input id="as-rco" name="residence_country" value="${esc(a.residence_country)}" ${ro}></div></div>
        <div class="field"><label for="as-fd">Date de création</label><input id="as-fd" name="founded_on" type="date" value="${esc(a.founded_on)}" ${ro}></div>
        <div class="field"><label for="as-desc">Description</label><textarea id="as-desc" name="description" rows="3" ${ro}>${esc(a.description)}</textarea></div>
        ${pres ? '<p class="err" hidden></p><button class="btn primary block" type="submit">Enregistrer</button>' : ''}
      </form>`;
  };

  /* ------------------------------------------------------------------
     Formulaires
  ------------------------------------------------------------------ */
  const val = (fd, k) => String(fd.get(k) ?? '').trim();
  const intVal = (fd, k) => { const v = val(fd, k); return v === '' ? NaN : Math.round(Number(v)); };
  const fail = m => { const e = new Error(m); e.user = true; throw e; };

  async function compress(file) {
    if (!file || !file.size) return null;
    if (file.type.startsWith('image/') && !/heic|heif/i.test(file.type) && window.createImageBitmap) {
      try {
        const bmp = await createImageBitmap(file);
        const k = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
        const c = document.createElement('canvas'); c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
        c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
        const blob = await new Promise(r => c.toBlob(r, 'image/jpeg', 0.8));
        if (blob) return new File([blob], 'justificatif.jpg', { type: 'image/jpeg' });
      } catch (e) { /* on envoie l'original */ }
    }
    return file;
  }

  const FORMS = {
    async auth(fd) {
      const email = val(fd, 'email'), pw = String(fd.get('password') || '');
      if (!/^\S+@\S+\.\S+$/.test(email)) fail('Saisissez une adresse email valide.');
      if (S.authMode === 'reset') {
        must(await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname }));
        S.authMsg = 'Si un compte existe pour cette adresse, un lien pour choisir un nouveau mot de passe vient d’être envoyé.';
        S.authMode = 'login'; return renderAuth();
      }
      if (pw.length < 8) fail('Le mot de passe doit faire au moins 8 caractères.');
      if (S.authMode === 'signup') {
        const r = must(await sb.auth.signUp({ email, password: pw, options: { emailRedirectTo: location.origin + location.pathname } }));
        if (!r.session) { S.authMsg = 'Compte créé. Ouvrez le lien reçu par email pour l’activer, puis connectez-vous.'; S.authMode = 'login'; return renderAuth(); }
      } else {
        must(await sb.auth.signInWithPassword({ email, password: pw }));
      }
      S.authMsg = '';
    },
    async newpw(fd) {
      const pw = String(fd.get('password') || '');
      if (pw.length < 8) fail('Le mot de passe doit faire au moins 8 caractères.');
      must(await sb.auth.updateUser({ password: pw }));
      toast('Mot de passe modifié'); go('#/');
    },
    async join(fd) {
      const code = val(fd, 'code'), name = val(fd, 'full_name');
      if (code.length < 4) fail('Saisissez le code d’invitation.');
      if (name.length < 2) fail('Saisissez votre nom complet.');
      const id = must(await sb.rpc('join_association', { p_code: code, p_full_name: name, p_phone: val(fd, 'phone') }));
      S.ctx = null;
      const mine = must(await sb.rpc('my_memberships')).find(a => a.association_id === id);
      if (mine && mine.pending) { toast('Demande envoyée au bureau'); return renderWelcome(); }
      toast('Bienvenue dans l’association'); go('#/a/' + id);
    },
    async create(fd) {
      const name = val(fd, 'name'), you = val(fd, 'full_name'), fee = intVal(fd, 'fee'), due = intVal(fd, 'due_day');
      if (name.length < 3) fail('Donnez un nom à l’association.');
      if (you.length < 2) fail('Saisissez votre nom complet.');
      if (!val(fd, 'village')) fail('Indiquez le village ou la ville d’origine.');
      if (!isNaN(fee) && fee < 0) fail('La cotisation ne peut pas être négative.');
      const id = must(await sb.rpc('create_association', {
        p_name: name, p_full_name: you, p_phone: val(fd, 'phone'), p_origin_country: val(fd, 'origin_country'), p_region: val(fd, 'region'),
        p_prefecture: val(fd, 'prefecture'), p_village: val(fd, 'village'), p_residence_country: val(fd, 'residence_country'),
        p_residence_city: val(fd, 'residence_city'), p_currency: val(fd, 'currency') || 'XOF', p_fee_amount: isNaN(fee) ? 0 : fee, p_fee_due_day: isNaN(due) ? 5 : due
      }));
      S.ctx = null; toast('Association créée'); go('#/a/' + id);
    },
    async member(fd, form) {
      const id = form.dataset.id, name = val(fd, 'full_name');
      if (name.length < 2) fail('Saisissez le nom complet.');
      const email = val(fd, 'email');
      if (email && !/^\S+@\S+\.\S+$/.test(email)) fail('Adresse email invalide.');
      const row = { full_name: name, phone: val(fd, 'phone'), city: val(fd, 'city'), country: val(fd, 'country'), email, joined_on: val(fd, 'joined_on') || todayISO() };
      if (can('roles') && fd.get('role')) row.role = val(fd, 'role');
      let mid = id;
      if (id) {
        row.active = fd.get('active') === 'on';
        must(await sb.from('members').update(row).eq('id', id).select('id').single());
      } else {
        const dup = S.ctx.members.find(m => m.full_name.toLowerCase() === name.toLowerCase() && digits(m.phone).slice(-9) === digits(row.phone).slice(-9));
        if (dup) fail('Ce membre existe déjà.');
        row.association_id = S.ctx.assoc.id;
        mid = must(await sb.from('members').insert(row).select('id').single()).id;
      }
      await refresh(); toast(id ? 'Fiche enregistrée' : 'Membre ajouté'); go(B() + '/m/' + mid);
    },
    async import(fd) {
      const rows = parseImport(fd.get('text'));
      if (!rows.length) fail('Aucun membre reconnu. Mettez un membre par ligne.');
      if (rows.length > 2000) fail('2 000 membres maximum par import.');
      const seen = new Set(S.ctx.members.map(m => m.full_name.toLowerCase() + '|' + digits(m.phone).slice(-9)));
      const joined = val(fd, 'joined_on') || todayISO();
      const fresh = rows.filter(r => { const k = r.full_name.toLowerCase() + '|' + digits(r.phone).slice(-9); if (seen.has(k)) return false; seen.add(k); return true; })
        .map(r => ({ ...r, association_id: S.ctx.assoc.id, joined_on: joined, country: S.ctx.assoc.residence_country || '' }));
      for (let i = 0; i < fresh.length; i += 200) must(await sb.from('members').insert(fresh.slice(i, i + 200)));
      await refresh();
      toast(`${fresh.length} membre${fresh.length > 1 ? 's' : ''} importé${fresh.length > 1 ? 's' : ''}${rows.length - fresh.length ? `, ${rows.length - fresh.length} déjà présent${rows.length - fresh.length > 1 ? 's' : ''}` : ''}`);
      go(B() + '/membres');
    },
    async pay(fd) {
      const mid = val(fd, 'member_id'), period = val(fd, 'period'), amount = intVal(fd, 'amount'), fee = Number(S.ctx.assoc.fee_amount);
      const m = S.ctx.byId.get(mid); if (!m) fail('Choisissez un membre.');
      if (!/^\d{4}-\d{2}$/.test(period)) fail('Choisissez le mois concerné.');
      if (!(amount > 0)) fail('Saisissez un montant supérieur à 0.');
      if (paidFor(mid, period) >= fee) fail(`${pFR(period)} est déjà réglé pour ce membre. Choisissez un autre mois.`);
      const t = must(await sb.from('transactions').insert({
        association_id: S.ctx.assoc.id, kind: 'in', category: 'Cotisations', amount, occurred_on: val(fd, 'occurred_on') || todayISO(),
        description: 'Cotisation de ' + pFR(period), member_id: mid, period, payment_method: val(fd, 'payment_method'), comment: val(fd, 'comment')
      }).select('*').single());
      await refresh(); toast('Paiement enregistré'); go(B() + '/op/' + t.id + '?recu=1');
    },
    async op(fd, form) {
      const kind = form.dataset.type === 'out' ? 'out' : 'in', amount = intVal(fd, 'amount'), desc = val(fd, 'description');
      if (!(amount > 0)) fail('Saisissez un montant supérieur à 0.');
      if (desc.length < 2) fail('Ajoutez une description pour que les membres comprennent l’opération.');
      if (kind === 'out' && amount > S.ctx.bal.in - S.ctx.bal.out) fail(`Le montant dépasse le solde disponible (${money(S.ctx.bal.in - S.ctx.bal.out)}).`);
      let proof_path = '';
      const file = await compress(fd.get('proof'));
      if (file) {
        if (file.size > 5 * 1024 * 1024) fail('Le justificatif dépasse 5 Mo. Prenez une photo plus légère.');
        const ext = file.type === 'application/pdf' ? 'pdf' : (file.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg');
        proof_path = `${S.ctx.assoc.id}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`;
        must(await sb.storage.from('proofs').upload(proof_path, file, { contentType: file.type, upsert: false }));
      }
      const t = must(await sb.from('transactions').insert({
        association_id: S.ctx.assoc.id, kind, category: val(fd, 'category'), amount, occurred_on: val(fd, 'occurred_on') || todayISO(),
        description: desc, project_id: val(fd, 'project_id') || null, payment_method: val(fd, 'payment_method'), comment: val(fd, 'comment'), proof_path
      }).select('*').single());
      await refresh(); toast(kind === 'out' ? 'Dépense enregistrée' : 'Recette enregistrée'); go(B() + '/op/' + t.id);
    },
    async reverse(fd, form) {
      const reason = val(fd, 'reason');
      if (reason.length < 4) fail('Indiquez le motif de l’annulation.');
      const nid = must(await sb.rpc('reverse_transaction', { p_id: Number(form.dataset.id), p_reason: reason }));
      await refresh(); toast('Contre-écriture enregistrée'); go(B() + '/op/' + nid);
    },
    async project(fd, form) {
      const id = form.dataset.id, name = val(fd, 'name'), goal = intVal(fd, 'goal'), start = val(fd, 'start_on'), end = val(fd, 'end_on');
      if (name.length < 3) fail('Donnez un nom au projet.');
      if (!(goal > 0)) fail('Indiquez l’objectif financier.');
      if (end && start && end < start) fail('La fin prévue doit être après le début.');
      const row = { name, type: val(fd, 'type'), goal, lead_member_id: val(fd, 'lead_member_id') || null, start_on: start || todayISO(), end_on: end || null, description: val(fd, 'description') };
      let pid = id;
      if (id) { row.status = val(fd, 'status'); must(await sb.from('projects').update(row).eq('id', id).select('id').single()); }
      else { row.association_id = S.ctx.assoc.id; row.status = 'En cours'; pid = must(await sb.from('projects').insert(row).select('id').single()).id; }
      toast(id ? 'Projet enregistré' : 'Projet créé'); go(B() + '/p/' + pid);
    },
    async pupdate(fd, form) {
      const body = val(fd, 'body');
      if (body.length < 2) fail('Décrivez l’avancement.');
      must(await sb.from('project_updates').insert({ association_id: S.ctx.assoc.id, project_id: form.dataset.id, body }));
      toast('Mise à jour publiée'); route();
    },
    async message(fd) {
      const body = val(fd, 'body'), kind = val(fd, 'kind');
      if (!body) fail('Écrivez votre message.');
      if (body.length > 1000) fail('1 000 caractères maximum.');
      must(await sb.from('messages').insert({ association_id: S.ctx.assoc.id, kind: MSG_KINDS.includes(kind) ? kind : 'Message', body }));
      S.ctx.loadedAt = 0; toast('Message envoyé'); route();
    },
    async meeting(fd, form) {
      const title = val(fd, 'title'), date = val(fd, 'date'), time = val(fd, 'time') || '00:00';
      if (title.length < 2) fail('Donnez un titre à la réunion.');
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !/^\d{2}:\d{2}/.test(time)) fail('Choisissez la date et l’heure.');
      const [y, mo, d] = date.split('-').map(Number), [h, mi] = time.split(':').map(Number);
      const row = { title, starts_at: new Date(y, mo - 1, d, h, mi).toISOString(), place: val(fd, 'place'), agenda: val(fd, 'agenda') };
      const id = form.dataset.id;
      if (id) { must(await sb.from('meetings').update(row).eq('id', id).select('id').single()); toast('Convocation modifiée'); go(B() + '/r/' + id); }
      else { const r = must(await sb.from('meetings').insert({ association_id: S.ctx.assoc.id, ...row }).select('id').single()); toast('Réunion convoquée'); go(B() + '/r/' + r.id); }
    },
    async minutes(fd, form) {
      const minutes = val(fd, 'minutes');
      if (minutes.length < 5) fail('Écrivez le compte rendu.');
      const row = { minutes };
      if (fd.get('held')) row.status = 'Tenue';
      must(await sb.from('meetings').update(row).eq('id', form.dataset.id).select('id').single());
      toast('Compte rendu publié'); go(B() + '/r/' + form.dataset.id);
    },
    async poll(fd) {
      const question = val(fd, 'question');
      const options = String(fd.get('options') || '').split('\n').map(x => x.trim()).filter(Boolean);
      if (question.length < 3) fail('Écrivez la question.');
      if (options.length < 2 || options.length > 10) fail('Mettez entre 2 et 10 choix, un par ligne.');
      let closes = null; const cd = val(fd, 'close_date');
      if (cd) { const [y, mo, d] = cd.split('-').map(Number), [h, mi] = (val(fd, 'close_time') || '20:00').split(':').map(Number); closes = new Date(y, mo - 1, d, h, mi); if (closes <= new Date()) fail('La fin du vote doit être dans le futur.'); closes = closes.toISOString(); }
      const id = must(await sb.rpc('create_poll', { p_assoc: S.ctx.assoc.id, p_question: question, p_description: val(fd, 'description'), p_options: options, p_closes_at: closes, p_anonymous: !!fd.get('anonymous') }));
      toast('Vote lancé'); go(B() + '/vote/' + id);
    },
    async doc(fd) {
      const title = val(fd, 'title'), category = val(fd, 'category'), file = fd.get('file');
      if (title.length < 2) fail('Donnez un titre au document.');
      if (!file || !file.size) fail('Choisissez un fichier.');
      if (file.size > 10485760) fail('Le fichier dépasse 10 Mo.');
      const ext = (String(file.name).match(/\.([a-z0-9]{1,5})$/i) || [, 'bin'])[1].toLowerCase();
      const rnd = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : Date.now() + '-' + Math.random().toString(36).slice(2);
      const path = `${S.ctx.assoc.id}/${rnd}.${ext}`;
      must(await sb.storage.from('docs').upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false }));
      must(await sb.from('documents').insert({ association_id: S.ctx.assoc.id, title, category: DOC_CATS.includes(category) ? category : 'Autre', file_path: path, file_name: String(file.name).slice(0, 200), mime: String(file.type || '').slice(0, 120), size: file.size }));
      toast('Document ajouté'); route();
    },
    async announce(fd) {
      const title = val(fd, 'title'), body = val(fd, 'body');
      if (title.length < 2 || body.length < 2) fail('Ajoutez un titre et un message.');
      must(await sb.from('announcements').insert({ association_id: S.ctx.assoc.id, kind: val(fd, 'kind'), title, body }));
      toast('Annonce publiée'); route();
    },
    async assoc(fd) {
      if (!can('settings')) fail('Réservé au président.');
      const fee = intVal(fd, 'fee_amount'), due = intVal(fd, 'fee_due_day'), start = val(fd, 'dues_start');
      if (val(fd, 'name').length < 3) fail('Le nom est trop court.');
      if (isNaN(fee) || fee < 0) fail('Montant de cotisation invalide.');
      if (isNaN(due) || due < 1 || due > 28) fail('Le jour d’échéance doit être entre 1 et 28.');
      if (!/^\d{4}-\d{2}$/.test(start)) fail('Choisissez le mois de début du suivi.');
      const row = { fee_amount: fee, fee_due_day: due, dues_start: start + '-01', currency: val(fd, 'currency'), founded_on: val(fd, 'founded_on') || null };
      ['name', 'village', 'origin_country', 'region', 'prefecture', 'residence_city', 'residence_country', 'description'].forEach(k => { row[k] = val(fd, k); });
      must(await sb.from('associations').update(row).eq('id', S.ctx.assoc.id).select('id').single());
      await refresh(); toast('Association enregistrée'); route();
    }
  };

  /* ------------------------------------------------------------------
     Événements
  ------------------------------------------------------------------ */
  document.addEventListener('submit', async e => {
    const f = e.target.closest('form[data-form]'); if (!f) return;
    e.preventDefault();
    const btn = f.querySelector('button[type=submit]'), err = f.querySelector('.err');
    if (btn) btn.disabled = true; if (err) err.hidden = true;
    try { await FORMS[f.dataset.form](new FormData(f), f); }
    catch (x) { if (x instanceof Error && !x.user) console.error(x); if (err) { err.textContent = errMsg(x); err.hidden = false; } else toast(errMsg(x)); }
    finally { if (btn && btn.isConnected) btn.disabled = false; }
  });

  document.addEventListener('click', async e => {
    const b = e.target.closest('[data-act]'); if (!b) return;
    const act = b.dataset.act;
    try {
      if (act === 'auth-mode') { S.authMode = b.dataset.mode; S.authMsg = ''; renderAuth(); }
      else if (act === 'google') {
        b.disabled = true;
        const r = await sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: location.origin + location.pathname } });
        if (r.error) { b.disabled = false; throw r.error; }
      }
      else if (act === 'signout') { clearOfflineData(); await sb.auth.signOut(); S.ctx = null; S.authMode = 'login'; S.authMsg = ''; S.session = null; S.user = null; location.hash = '#/'; renderAuth(); }
      else if (act === 'reload') location.reload();
      else if (act === 'theme') { store.set('vl:theme', b.dataset.theme); applyTheme(); document.querySelectorAll('[data-act=theme]').forEach(x => x.setAttribute('aria-pressed', String(x === b))); }
      else if (act === 'hidemsg') {
        if (b.dataset.confirm !== '1') { b.dataset.confirm = '1'; b.textContent = 'Confirmer le masquage'; return; }
        must(await sb.rpc('hide_message', { p_id: Number(b.dataset.id) }));
        toast('Message masqué'); route();
      }
      else if (act === 'meetstatus') {
        const s2 = b.dataset.status;
        if (s2 === 'Annulée' && b.dataset.confirm !== '1') { b.dataset.confirm = '1'; b.textContent = 'Confirmer l’annulation'; return; }
        must(await sb.from('meetings').update({ status: s2 }).eq('id', b.dataset.id).select('id').single());
        toast(s2 === 'Tenue' ? 'Réunion marquée comme tenue' : s2 === 'Annulée' ? 'Réunion annulée' : 'Réunion remise en prévue'); route();
      }
      else if (act === 'attend') {
        const row = b.closest('[data-mid]'), v = b.dataset.v === '1', on = b.getAttribute('aria-pressed') === 'true';
        row.querySelectorAll('[data-act=attend]').forEach(x => { x.disabled = true; });
        try {
          if (on) must(await sb.from('meeting_attendance').delete().eq('meeting_id', b.dataset.meet).eq('member_id', b.dataset.id));
          else must(await sb.from('meeting_attendance').upsert({ meeting_id: b.dataset.meet, member_id: b.dataset.id, association_id: S.ctx.assoc.id, present: v }, { onConflict: 'meeting_id,member_id' }));
          row.querySelectorAll('[data-act=attend]').forEach(x => x.setAttribute('aria-pressed', String(!on && x === b)));
          const att = must(await sb.from('meeting_attendance').select('*').eq('meeting_id', b.dataset.meet));
          const c = $('#att-count'); if (c) c.innerHTML = attCount(att);
        } finally { row.querySelectorAll('[data-act=attend]').forEach(x => { x.disabled = false; }); }
      }
      else if (act === 'memberactive') {
        const on = b.dataset.v === '1';
        if (!on && b.dataset.confirm !== '1') { b.dataset.confirm = '1'; b.textContent = 'Confirmer : retirer ce membre'; return; }
        b.disabled = true;
        must(await sb.from('members').update({ active: on }).eq('id', b.dataset.id).select('id').single());
        await refresh(); toast(on ? 'Membre réintégré' : 'Membre retiré de l’association'); go(B() + (on ? '/m/' + b.dataset.id : '/membres'));
      }
      else if (act === 'vote') {
        b.disabled = true;
        must(await sb.rpc('cast_vote', { p_poll: b.dataset.poll, p_option: b.dataset.opt }));
        toast('Vote enregistré'); route();
      }
      else if (act === 'closepoll') {
        if (b.dataset.confirm !== '1') { b.dataset.confirm = '1'; b.textContent = 'Confirmer : clore le vote'; return; }
        must(await sb.rpc('close_poll', { p_poll: b.dataset.id }));
        toast('Vote clos'); route();
      }
      else if (act === 'opendoc') {
        const box = $('#doc-open'); if (box) box.innerHTML = '<p class="muted">Ouverture du document…</p>';
        const r = must(await sb.storage.from('docs').createSignedUrl(b.dataset.path, 3600));
        if (box) box.innerHTML = `<a class="btn primary block" target="_blank" rel="noopener" href="${esc(r.signedUrl)}">Ouvrir « ${esc(b.textContent)} »</a>`;
        if (box) box.scrollIntoView({ block: 'center' });
      }
      else if (act === 'deldoc') {
        if (b.dataset.confirm !== '1') { b.dataset.confirm = '1'; b.textContent = 'Retirer ?'; b.classList.add('confirm'); return; }
        must(await sb.from('documents').delete().eq('id', b.dataset.id));
        await sb.storage.from('docs').remove([b.dataset.path]);
        toast('Document retiré'); route();
      }
      else if (act === 'print') { window.print(); }
      else if (act === 'review') {
        const ok = b.dataset.ok === '1';
        if (!ok && b.dataset.confirm !== '1') { b.dataset.confirm = '1'; b.textContent = 'Confirmer le refus'; return; }
        b.disabled = true;
        must(await sb.rpc('review_join', { p_member: b.dataset.id, p_accept: ok }));
        await refresh(); toast(ok ? 'Adhésion validée' : 'Demande refusée'); route();
      }
      else if (act === 'proof') {
        const box = $('#proof-box'); box.innerHTML = '<span class="muted">Chargement…</span>';
        const r = must(await sb.storage.from('proofs').createSignedUrl(b.dataset.path, 3600));
        box.innerHTML = /\.pdf$/i.test(b.dataset.path) ? `<a class="btn ghost sm" target="_blank" rel="noopener" href="${esc(r.signedUrl)}">Ouvrir le PDF</a>` : `<a href="${esc(r.signedUrl)}" target="_blank" rel="noopener"><img class="proof-img" src="${esc(r.signedUrl)}" alt="Justificatif"></a>`;
      } else if (act === 'newcode') {
        if (b.dataset.confirm !== '1') { b.dataset.confirm = '1'; b.textContent = 'Confirmer : l’ancien code ne marchera plus'; b.classList.add('danger'); return; }
        must(await sb.rpc('regenerate_invite_code', { p_assoc: S.ctx.assoc.id }));
        await refresh(); toast('Nouveau code créé'); route();
      }
    } catch (x) { console.error(x); toast(errMsg(x)); }
  });

  /* Mode hors ligne : un service worker garde une copie de l'application et des dernières données lues. */
  function clearOfflineData() {
    try { if (navigator.serviceWorker && navigator.serviceWorker.controller) navigator.serviceWorker.controller.postMessage('vl-clear'); } catch (e) { /* rien */ }
    try { if (window.caches) caches.delete('vl-data-v1'); } catch (e) { /* rien */ }
  }
  if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === '127.0.0.1')) {
    window.addEventListener('load', () => { navigator.serviceWorker.register('sw.js').catch(() => { /* hors ligne indisponible */ }); });
  }
  const setOnline = () => $('#offline').classList.toggle('hidden', navigator.onLine);
  window.addEventListener('online', setOnline); window.addEventListener('offline', setOnline); setOnline();
  document.addEventListener('change', e => { const el = e.target; if (el && el.dataset && el.dataset.nav === 'rapport' && /^\d{4}-\d{2}$/.test(el.value)) go(B() + '/rapport?m=' + el.value); });
  window.addEventListener('hashchange', route);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible' || !S.session) return;
    if (S.ctx) S.ctx.loadedAt = 0;
    // On ne réaffiche pas une page avec un formulaire : la saisie en cours serait perdue.
    if (!document.querySelector('#view form[data-form]')) route();
  });

  /* ------------------------------------------------------------------
     Session
  ------------------------------------------------------------------ */
  let started = false;
  sb.auth.onAuthStateChange((event, session) => {
    const had = !!S.session;
    S.session = session; S.user = session ? session.user : null;
    if (event === 'PASSWORD_RECOVERY') { location.hash = '#/mot-de-passe'; return; }
    if (!started) return;
    if (event === 'SIGNED_IN' && !had) route();
    // Ne pas réafficher l'écran de connexion s'il est déjà là : la saisie en cours serait effacée.
    if (event === 'SIGNED_OUT') { clearOfflineData(); S.ctx = null; if (!document.querySelector('form[data-form=auth]')) renderAuth(); }
  });
  (async () => {
    try {
      const { data } = await sb.auth.getSession();
      S.session = data.session; S.user = data.session ? data.session.user : null;
    } catch (e) { console.error(e); }
    if (/^#access_token=/.test(location.hash)) history.replaceState(null, '', location.pathname + (S.session ? '#/' : ''));
    started = true;
    route();
  })();

  window.__VL = { parseImport, monthsBetween, addMonth };
})();

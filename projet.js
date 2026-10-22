/* Page publique d'un projet : lit uniquement la fonction public_project (aucune donnée de membre). */
(function () {
  'use strict';
  const root = document.getElementById('root');
  const CFG = window.VILLAGELINK_CONFIG || {};
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const CUR = { XOF: 'FCFA', XAF: 'FCFA', GNF: 'GNF', EUR: '€', USD: '$', CAD: '$ CA', GBP: '£' };
  const NB = ' ';
  let cur = 'XOF';
  const num = n => new Intl.NumberFormat('fr-FR', { maximumFractionDigits: 0 }).format(Math.round(Number(n) || 0)).replace(/[   ]/g, NB);
  const money = n => num(n) + NB + (CUR[cur] || cur);
  const MOIS = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
  const dFR = s => { const d = new Date(String(s).length === 10 ? s + 'T12:00:00' : s); return isNaN(d) ? '' : `${d.getDate()}${NB}${MOIS[d.getMonth()]} ${d.getFullYear()}`; };
  const slug = new URLSearchParams(location.search).get('id') || location.hash.replace(/^#/, '');
  const fail = msg => { root.innerHTML = `<div class="top"><div class="logo">V</div><div><b>VillageLink</b><small>Projets de village, en toute transparence</small></div></div><p class="empty">${esc(msg)}</p>`; };
  if (!/^[a-zA-Z0-9]{10,24}$/.test(slug || '')) return fail('Lien de projet invalide. Demandez le bon lien à l’association.');
  fetch(CFG.supabaseUrl + '/rest/v1/rpc/public_project', {
    method: 'POST', headers: { apikey: CFG.supabaseAnonKey, Authorization: 'Bearer ' + CFG.supabaseAnonKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_slug: slug })
  }).then(r => (r.ok ? r.json() : Promise.reject(new Error('http ' + r.status)))).then(d => {
    if (!d) return fail('Ce projet n’est pas (ou plus) public.');
    const a = d.association, p = d.project; cur = a.currency || 'XOF';
    const got = Number(d.collected), spent = Number(d.spent), pc = p.goal > 0 ? Math.min(100, Math.round(got / p.goal * 100)) : 0;
    document.title = p.name + ' · ' + a.name;
    const place = [a.village, a.region, a.country].filter(Boolean).join(' · ');
    const share = `${p.name} — ${a.name}\nDéjà ${money(got)} collectés sur ${money(p.goal)} (${pc} %).\nSuivez le projet en toute transparence :\n${location.href}`;
    root.innerHTML = `
      <div class="top"><div class="logo">${esc((a.name || 'V').trim().charAt(0).toUpperCase())}</div><div><b>${esc(a.name)}</b><small>${esc(place)}</small></div></div>
      <section class="hero"><span class="eyebrow">${esc(p.type)} · ${esc(p.status)}</span><h1>${esc(p.name)}</h1>
        <div class="big">${num(got)} <small>${esc(CUR[cur] || cur)} collectés</small></div>
        <span class="goal">sur un objectif de <b>${money(p.goal)}</b></span>
        <div class="bar" role="progressbar" aria-valuenow="${pc}" aria-valuemin="0" aria-valuemax="100"><i style="width:${pc}%"></i></div>
        <div class="boxes"><div><small>Atteint</small><b>${pc}${NB}%</b></div><div><small>Dons reçus</small><b>${num(d.gifts)}</b></div></div></section>
      ${p.description ? `<section class="card"><h2>Le projet</h2><p class="desc">${esc(p.description)}</p></section>` : ''}
      ${p.contact ? `<section class="card give"><h2>Comment donner</h2><span class="contact">${esc(p.contact)}</span><span class="muted">Chaque don est enregistré par le trésorier et apparaît ici.</span></section>` : ''}
      <section class="card"><h2>Où va l’argent</h2><span class="muted">Dépensé à ce jour : <b>${money(spent)}</b> · reste en caisse pour le projet : <b>${money(Math.max(0, got - spent))}</b></span>
        ${(d.expenses || []).map(e => `<div class="row"><span>${esc(e.description)}<br><span class="muted">${dFR(e.on)}</span></span><b>−${money(e.amount)}</b></div>`).join('') || '<span class="muted">Aucune dépense pour le moment.</span>'}</section>
      <section class="card"><h2>Nouvelles du chantier</h2>
        ${(d.updates || []).map(u => `<div class="upd"><span class="muted">${dFR(u.at)}</span><p>${esc(u.body)}</p></div>`).join('') || '<span class="muted">Pas encore de nouvelles.</span>'}</section>
      <a class="btn" target="_blank" rel="noopener" href="https://wa.me/?text=${encodeURIComponent(share)}">Partager sur WhatsApp</a>
      <p class="foot">Page publiée par ${esc(a.name)} avec <a href="./">VillageLink</a>, l’application des associations de village. Les comptes ne peuvent être ni modifiés ni effacés.</p>`;
  }).catch(() => fail('Impossible de charger le projet. Vérifiez votre connexion et réessayez.'));
})();

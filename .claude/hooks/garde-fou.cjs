#!/usr/bin/env node
// Garde-fou VillageLink : lancé par Claude Code avant chaque outil (PreToolUse).
// C'est un filet contre les ERREURS, pas une serrure : la serrure est la protection de la branche
// main sur GitHub (demande de fusion + vérification verte obligatoires) et l'accord d'Alpha.
//  - vraie base Supabase (ncghmfwfnzgdddnqgnnl) : tout ce qui n'est pas une lecture sûre => on demande ;
//  - dépôt de la vraie app (kowly1998-ai/villagelink) : git push vers main => refusé ;
//    fusion, écriture par l'API GitHub, changement de protection => on demande ;
//  - modification du garde-fou lui-même ou de .claude/settings.json => on demande ;
//  - commande ambiguë (eval, bash -c, $(…), alias…) qui pousse => on demande ;
//  - erreur du script => on demande.
// La base de test (phkiovzhlmozpdoiigpf) et le dépôt villagelink-test ne sont pas concernés.
'use strict';
const { execFileSync } = require('child_process');
const path = require('path');
const os = require('os');
const fs = require('fs');

const REAL_DB = 'ncghmfwfnzgdddnqgnnl';
const REAL_NAME = /kowly1998-ai\/villagelink(?![\w-])/i;          // le nom, n'importe où dans une commande
const REAL_URL = /kowly1998-ai\/villagelink(\.git)?\/?$/i;         // la fin d'une adresse de dépôt
const SELF = /(\.claude\/hooks\/garde-fou\.cjs|\.claude\/settings(\.local)?\.json)/;

function answer(decision, reason) {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: decision, permissionDecisionReason: reason } }));
  process.exit(0);
}
const ask = r => answer('ask', r + ' Alpha doit accepter.');
const deny = r => answer('deny', r);
const ok = () => process.exit(0);
const git = args => { try { return execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 4000 }).trim(); } catch (e) { return ''; } };
const unq = s => String(s).replace(/["']/g, '');

/* ---------- 1. Supabase ---------- */
const SB_READ = ['list_tables', 'list_extensions', 'list_migrations', 'get_logs', 'query_logs', 'get_advisors', 'get_project_url',
  'get_publishable_keys', 'get_anon_key', 'list_edge_functions', 'get_edge_function', 'generate_typescript_types', 'get_project',
  'list_branches', 'search_docs', 'list_projects', 'list_organizations', 'get_organization', 'list_notebooks', 'get_notebook'];
// Fonctions permises dans une lecture sur la vraie base. Tout autre appel de fonction => on demande.
const SAFE_FN = new Set(('count sum min max avg coalesce nullif greatest least length char_length lower upper trim btrim left right substr substring '
  + 'replace regexp_replace split_part concat concat_ws format string_agg array_agg jsonb_agg json_agg jsonb_build_object json_build_object '
  + 'jsonb_object_agg to_char to_date date_trunc extract now current_date age round floor ceil abs md5 position strpos unnest '
  + 'pg_get_functiondef pg_get_function_identity_arguments pg_get_triggerdef pg_get_constraintdef pg_get_viewdef pg_get_indexdef '
  + 'pg_size_pretty pg_database_size pg_total_relation_size pg_relation_size has_function_privilege has_schema_privilege '
  + 'has_table_privilege has_column_privilege obj_description col_description format_type array_length cardinality bool_or bool_and '
  + 'row_number rank dense_rank lag lead first_value last_value').split(' '));
const SQL_WORDS = new Set('in exists filter over any all not and or as on from where values select with case when then else end join using cast array is'.split(' '));

function sqlIsSafeRead(q) {
  let s = String(q || '');
  // enlever commentaires et textes (y compris $$…$$ et E'…')
  s = s.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ')
    .replace(/\$(\w*)\$[\s\S]*?\$\1\$/g, " '' ").replace(/[eE]'(?:\\.|''|[^'\\])*'/g, " '' ").replace(/'(?:''|[^'])*'/g, " '' ")
    .replace(/"(?:""|[^"])*"/g, ' x ');
  s = s.trim().replace(/;\s*$/, '');
  if (s.includes(';') || s.includes("'") && /\\/.test(s)) return false;   // une seule requête
  if (!/^(select|with|explain|table|show)\b/i.test(s)) return false;
  if (/\bexplain\b[^)]*\banalyze\b/i.test(s)) return false;                // explain analyze exécute la requête
  if (/\b(into|insert|update|delete|merge|drop|alter|create|truncate|grant|revoke|copy|lock|call|do|prepare|execute|set|reset|listen|notify|vacuum|refresh)\b/i.test(s)) return false;
  if (/\bfor\s+(update|share|no\s+key|key)\b/i.test(s)) return false;
  for (const m of s.matchAll(/([a-z_][\w$]*(?:\s*\.\s*[a-z_][\w$]*)?)\s*\(/gi)) {
    const name = m[1].replace(/\s+/g, '').toLowerCase(), base = name.split('.').pop();
    if (SQL_WORDS.has(base)) continue;
    if (SAFE_FN.has(base) && (!name.includes('.') || name.startsWith('pg_catalog.'))) continue;
    return false;                                                           // fonction inconnue : elle peut écrire
  }
  return true;
}

function checkSupabase(tool, inp) {
  const op = tool.replace(/^.*__/, '');
  const pid = String(inp.project_id || '').trim().toLowerCase();
  if (pid && pid !== REAL_DB) return ok();                                  // base de test ou autre projet
  if (SB_READ.includes(op)) return ok();
  if (!pid) return ask(`Action Supabase « ${op} » sans projet précisé (elle peut toucher la vraie base).`);
  if (op === 'execute_sql' && sqlIsSafeRead(inp.query)) return ok();
  return ask(op === 'execute_sql' ? 'Requête sur la VRAIE base VillageLink qui n’est pas une simple lecture.' : `Action « ${op} » sur la VRAIE base VillageLink.`);
}

/* ---------- 2. Bash ---------- */
function expandDir(d, cur) {
  d = unq(d);
  if (d === '~' || d.startsWith('~/')) d = path.join(os.homedir(), d.slice(1));
  return path.resolve(cur, d);
}
const gitIn = (d, gitDir, args) => git(gitDir ? ['--git-dir', gitDir, ...args] : ['-C', d, ...args]);
const isRealDir = (d, gitDir) => gitIn(d, gitDir, ['remote', '-v']).split('\n').some(l => REAL_URL.test(l.split(/\s+/)[1] || ''));
const TO_MAIN = 'Pas d’envoi direct sur main de la vraie app : passer par une branche, une demande de fusion, la relecture par un autre agent et la vérification au vert (voir CLAUDE.md).';

// seg : un morceau de commande qui contient « git … push ». Renvoie true si on a répondu.
function checkPushSegment(seg, dir) {
  const words = seg.trim().split(/\s+/).map(unq);
  let i = 0, gitDir = '', d = dir;
  while (i < words.length && /^\w+=/.test(words[i])) { const m = words[i].match(/^GIT_DIR=(.+)$/); if (m) gitDir = expandDir(m[1], d); i++; }
  if (words[i] !== 'git') { ask('Envoi git écrit d’une façon que le garde-fou ne sait pas lire.'); return true; }
  i++;
  while (i < words.length && words[i] !== 'push') {
    if (words[i] === '-C') { d = expandDir(words[i + 1] || '.', d); i += 2; continue; }
    if (words[i] === '-c') { i += 2; continue; }
    const gd = words[i].match(/^--git-dir=(.+)$/); if (gd) { gitDir = expandDir(gd[1], d); i++; continue; }
    if (words[i] === '--git-dir') { gitDir = expandDir(words[i + 1] || '', d); i += 2; continue; }
    if (words[i].startsWith('-')) { i++; continue; }
    if (/push|send-pack/.test(gitIn(d, gitDir, ['config', '--get', 'alias.' + words[i]]))) { ask('Envoi par un alias git.'); return true; }
    return false;                                                           // autre sous-commande (stash push, log --grep…)
  }
  if (words[i] !== 'push') return false;
  const rest = words.slice(i + 1).filter(w => !/^\d?>/.test(w) && !/^&?\d$/.test(w));
  const pos = rest.filter(w => !w.startsWith('-'));
  const remote = pos[0], refs = pos.slice(1).map(r => r.replace(/^\+/, ''));
  let real;
  if (!remote) real = isRealDir(d, gitDir);
  else if (/[:/@]/.test(remote)) real = REAL_URL.test(remote);              // une adresse
  else {
    const url = gitIn(d, gitDir, ['remote', 'get-url', remote]);
    if (!url) { ask('Le garde-fou ne trouve pas le dépôt visé par cet envoi.'); return true; }
    real = REAL_URL.test(url);
  }
  if (!real) return false;
  if (rest.some(w => /^--(all|mirror)$/.test(w))) { deny('Pas d’envoi de toutes les branches dans la vraie app.'); return true; }
  const cur = gitIn(d, gitDir, ['rev-parse', '--abbrev-ref', 'HEAD']);
  let toMain;
  if (refs.length === 0) {
    const up = gitIn(d, gitDir, ['rev-parse', '--abbrev-ref', '@{push}']);
    toMain = !cur || cur === 'main' || /\/main$/.test(up);
  } else {
    toMain = refs.some(r => /(^|:)(refs\/heads\/)?main$/.test(r) || ((r === 'HEAD' || r === '@') && cur === 'main'));
  }
  if (toMain) { deny(TO_MAIN); return true; }
  return false;
}

function checkBash(cmd, cwd) {
  // modifier le garde-fou ou les réglages
  if (SELF.test(cmd) && /(sed\s+-i|>|\btee\b|\bmv\b|\bcp\b|\brm\b|\bchmod\b|\bpython|\bperl\b|\bnode\s+-e|\bgit\s+(checkout|restore|reset|apply|stash))/.test(cmd)
      && !/^\s*(cd\s+\S+\s*&&\s*)?(echo|printf)\s[\s\S]*\|\s*node\s+\S*garde-fou\.cjs\s*(;\s*echo[^;&|]*)?\s*$/.test(cmd)) {
    return ask('Modification du garde-fou ou des réglages de Claude Code.');
  }
  // la vraie base par un autre chemin (psql, curl, supabase…)
  if (cmd.includes(REAL_DB) && !/garde-fou\.cjs/.test(cmd) && !/^\s*(grep|rg|cat|less|head|tail|wc)\b/.test(cmd)) return ask('Commande qui vise la VRAIE base VillageLink.');

  // API GitHub (gh / curl) vers la vraie app : seules les lectures passent
  if (REAL_NAME.test(cmd)) {
    if (/\bgh\s+pr\s+(merge|close|reopen|edit|ready)\b|\bgh\s+(repo\s+(edit|delete|rename|archive)|release\s+(create|delete|edit)|secret|variable|workflow\s+(disable|enable))\b/.test(cmd)) return ask('Action GitHub qui modifie la vraie app.');
    if (/\bgh\s+api\b/.test(cmd)) {
      const meth = (cmd.match(/(?:-X|--method)\s*=?\s*(\w+)/i) || [])[1];
      const fields = /\s(-f|-F|--field|--raw-field|--input)\s/.test(cmd);
      const method = (meth || (fields ? 'POST' : 'GET')).toUpperCase();
      const createPr = method === 'POST' && /\/pulls(\s|$|\?|")/.test(cmd) && !/\/merge/.test(cmd);      // ouvrir une demande de fusion
      const prComment = method === 'POST' && /\/(issues|pulls)\/\d+\/(comments|reviews)\b/.test(cmd);
      if ((method !== 'GET' || /\bgraphql\b/.test(cmd)) && !createPr && !prComment) return ask('Écriture sur la vraie app par l’API GitHub (fusion, fichier, branche ou réglage).');
    }
    if (/\b(curl|wget)\b/.test(cmd) && /(-X\s*(PUT|POST|PATCH|DELETE)|--request\s+(PUT|POST|PATCH|DELETE)|\s-d\s|--data|--post|-T\s)/i.test(cmd)) return ask('Écriture sur la vraie app par une requête web.');
  }

  if (!/\bpush\b|send-pack|receive-pack/.test(cmd)) {
    // un alias git qui pousse (ex. « git p » avec alias.p = push)
    if (/\bgit\s/.test(cmd)) {
      const al = git(['-C', cwd, 'config', '--get-regexp', '^alias\\.']).split('\n')
        .filter(l => /push|send-pack/.test(l)).map(l => l.split(/\s+/)[0].replace(/^alias\./, ''));
      if (al.some(n => new RegExp('\\bgit\\b[^;&|\\n]*\\s' + n.replace(/[^\w-]/g, '') + '(\\s|$)').test(cmd))) return ask('Envoi par un alias git.');
    }
    return ok();
  }
  // formes qu'on ne sait pas lire sûrement
  if (/\beval\b|\b(bash|sh|zsh|dash)\s+(-\w*c\b|-l)|\$\(|`|\bxargs\b|send-pack|receive-pack|\balias\b|git\s+config[^;&|\n]*alias|\$[A-Za-z_{]|(^|[;&|]\s*)\(|\bpushd\b|\bpopd\b/.test(cmd)) {
    return ask('Envoi git écrit d’une façon que le garde-fou ne sait pas lire sûrement.');
  }
  let dir = cwd;
  const segs = cmd.replace(/(^|\s)#[^\n]*/g, ' ').split(/\s*(?:&&|\|\||;|\||\n)\s*/);
  for (const seg of segs) {
    const cdm = seg.match(/^\s*cd(?:\s+(\S+))?\s*$/);
    if (cdm) { const nd = expandDir(cdm[1] || '~', dir); if (!fs.existsSync(nd)) return ask('Dossier introuvable avant un envoi git.'); dir = nd; continue; }
    if (!/\bpush\b/.test(seg)) continue;
    if (/^\s*(\w+=\S+\s+)*git\b/.test(seg)) { if (checkPushSegment(seg, dir)) return; continue; }
    if (/^\s*(docker|podman|npm|pnpm|yarn|helm|hg|svn)\b/.test(seg)) continue;
    if (/^\s*[\w./-]+\s+push\b/.test(seg)) return ask('Envoi par une commande ou un alias que le garde-fou ne connaît pas.');
  }
  return ok();
}

/* ---------- 3. Édition de fichiers ---------- */
function checkEdit(inp) {
  const p = String(inp.file_path || inp.notebook_path || '');
  if (SELF.test(p)) return ask('Modification du garde-fou ou des réglages de Claude Code.');
  return ok();
}

/* ---------- Lancement ---------- */
let raw = '';
process.stdin.on('data', d => { raw += d; });
process.stdin.on('end', () => {
  try {
    const ev = JSON.parse(raw || '{}');
    const tool = ev.tool_name || '', inp = ev.tool_input || {};
    if (/^mcp__.*[Ss]upabase.*__/.test(tool)) return checkSupabase(tool, inp);
    if (tool === 'Bash') return checkBash(String(inp.command || ''), ev.cwd || process.cwd());
    if (/^(Edit|Write|MultiEdit|NotebookEdit)$/.test(tool)) return checkEdit(inp);
    if (/^mcp__.*github.*__/i.test(tool) && /merge|delete|update|create_or_update|push|write/i.test(tool) && REAL_NAME.test(JSON.stringify(inp))) return ask(`Action GitHub « ${tool} » sur la vraie app.`);
    return ok();
  } catch (e) {
    return ask('Le garde-fou n’a pas pu vérifier cette action.');
  }
});

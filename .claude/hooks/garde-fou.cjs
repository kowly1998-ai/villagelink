#!/usr/bin/env node
// Garde-fou VillageLink : lancé par Claude Code avant chaque commande (PreToolUse).
// Ce qui ne se rattrape pas passe par Alpha :
//  - toute écriture sur la VRAIE base Supabase (ncghmfwfnzgdddnqgnnl) => on demande ;
//  - fusionner une demande sur la vraie app (gh pr merge ou gh api …/pulls/N/merge) => on demande ;
//  - envoyer directement sur main dans le dépôt de la vraie app => refusé
//    (passer par une branche, une demande de fusion, la relecture et la vérification).
// La base de test et le site de test ne sont pas concernés.
// En cas d'erreur du script, on demande (jamais de laissez-passer par accident).
'use strict';
const { execFileSync } = require('child_process');
const REAL_DB = 'ncghmfwfnzgdddnqgnnl';
const REAL_REPO = /github\.com[:/]kowly1998-ai\/villagelink(\.git)?$/;

function answer(decision, reason) {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: decision, permissionDecisionReason: reason } }));
  process.exit(0);
}

function repoOf(dir) {
  try { return execFileSync('git', ['-C', dir, 'remote', 'get-url', 'origin'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch (e) { return ''; }
}
function branchOf(dir) {
  try { return execFileSync('git', ['-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch (e) { return ''; }
}

let raw = '';
process.stdin.on('data', d => { raw += d; });
process.stdin.on('end', () => {
  try {
    const ev = JSON.parse(raw || '{}');
    const tool = ev.tool_name || '', inp = ev.tool_input || {};

    // 1) Vraie base Supabase
    if (/^mcp__.*[Ss]upabase.*__/.test(tool) && inp.project_id === REAL_DB) {
      const op = tool.replace(/^.*__/, '');
      const reads = ['list_tables', 'list_extensions', 'list_migrations', 'get_logs', 'query_logs', 'get_advisors', 'get_project_url',
        'get_publishable_keys', 'get_anon_key', 'list_edge_functions', 'get_edge_function', 'generate_typescript_types', 'get_project',
        'list_branches', 'search_docs'];
      if (reads.includes(op)) process.exit(0);
      if (op === 'execute_sql') {
        const q = String(inp.query || '').replace(/'(?:[^']|'')*'/g, "''").replace(/--[^\n]*/g, '');
        if (!/\b(insert|update|delete|merge|drop|alter|create|truncate|grant|revoke|comment\s+on|do|call|vacuum|reindex|cluster|refresh|lock|copy|security\s+label|set\s+role|reset)\b/i.test(q)) process.exit(0);
        answer('ask', 'Écriture sur la VRAIE base VillageLink. Alpha doit accepter.');
      }
      answer('ask', `Action « ${op} » sur la VRAIE base VillageLink. Alpha doit accepter.`);
    }

    // 2) Dépôt de la vraie app
    if (tool === 'Bash') {
      const cmd = String(inp.command || '');
      if (!/\bgit\b[^;&|]*\bpush\b|\bgh\s+pr\s+merge\b|\bgh\s+api\b[^;&|]*(protection|pulls\/\d+\/merge|git\/refs)/.test(cmd)) process.exit(0);
      const cds = [...cmd.matchAll(/\bcd\s+("[^"]+"|'[^']+'|[^\s;&|]+)/g)].map(m => m[1].replace(/^['"]|['"]$/g, ''));
      const cMatch = cmd.match(/\bgit\s+-C\s+("[^"]+"|'[^']+'|[^\s;&|]+)/);
      const dir = cMatch ? cMatch[1].replace(/^['"]|['"]$/g, '') : (cds.length ? cds[cds.length - 1] : (ev.cwd || process.cwd()));
      if (!REAL_REPO.test(repoOf(dir))) process.exit(0);
      if (/\bgh\s+pr\s+merge\b|\bgh\s+api\b[^;&|]*pulls\/\d+\/merge/.test(cmd)) answer('ask', 'Fusionner = mettre en ligne sur la VRAIE app. Alpha doit accepter.');
      if (/\bgh\s+api\b[^;&|]*git\/refs/.test(cmd)) answer('ask', 'Changement direct d’une branche de la vraie app sur GitHub. Alpha doit accepter.');
      if (/\bgh\s+api\b[^;&|]*protection/.test(cmd)) answer('ask', 'Changement de la protection de la branche main de la vraie app. Alpha doit accepter.');
      const push = (cmd.match(/\bgit\b[^;&|]*\bpush\b([^;&|]*)/) || [])[1] || '';
      const args = push.split(/\s+/).filter(a => a && !a.startsWith('-'));
      const refs = args.slice(1);   // args[0] = le dépôt distant
      const toMain = refs.length === 0 ? branchOf(dir) === 'main' : refs.some(r => /(^|:)(refs\/heads\/)?main$/.test(r) || r === 'HEAD' && branchOf(dir) === 'main');
      if (toMain || /--all|--mirror/.test(push)) answer('deny', 'Pas d’envoi direct sur main de la vraie app : passer par une branche, une demande de fusion, la relecture par un autre agent et la vérification au vert (voir CLAUDE.md).');
    }
    process.exit(0);
  } catch (e) {
    answer('ask', 'Le garde-fou n’a pas pu vérifier cette action : Alpha doit accepter.');
  }
});

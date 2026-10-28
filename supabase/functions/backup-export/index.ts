// VillageLink — export de sauvegarde (appelé chaque semaine par GitHub Actions, dépôt privé).
// Protégé par une clé : seule son empreinte SHA-256 figure ici, la clé elle-même est dans les
// secrets du dépôt de sauvegarde. Renvoie toutes les tables du schéma public + la liste des
// comptes (sans mot de passe), en JSON compressé.
import postgres from "npm:postgres@3.4.5";

const TOKEN_SHA256 = "4befe19c069bd79b2dbff79f95945b70c6b43029addbfbde461b9f154093571a";
const SKIP = new Set(["push_subscriptions"]); // abonnements de notification : recréés par les téléphones

async function sha256(s: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Méthode non autorisée", { status: 405 });
  const tok = req.headers.get("x-backup-token") || "";
  if (tok.length < 32 || (await sha256(tok)) !== TOKEN_SHA256) return new Response("Accès refusé", { status: 401 });

  const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1 });
  try {
    const tables = await sql`select table_name from information_schema.tables
                             where table_schema = 'public' and table_type = 'BASE TABLE' order by 1`;
    const out: Record<string, unknown> = { format: "villagelink-backup-1", created_at: new Date().toISOString() };
    const data: Record<string, unknown[]> = {};
    for (const { table_name } of tables) {
      if (SKIP.has(table_name)) continue;
      data[table_name] = await sql.unsafe(`select * from public."${String(table_name).replace(/"/g, '""')}"`);
    }
    out.tables = data;
    out.accounts = await sql`select id, email, raw_user_meta_data, created_at, last_sign_in_at from auth.users order by created_at`;
    out.counts = Object.fromEntries(Object.entries(data).map(([k, v]) => [k, v.length]));
    if (req.headers.get("x-backup-check") === "1") {
      return Response.json({ ok: true, tables: Object.keys(data).length, accounts: (out.accounts as unknown[]).length, counts: out.counts });
    }
    const body = new Blob([JSON.stringify(out)]).stream().pipeThrough(new CompressionStream("gzip"));
    return new Response(body, { headers: { "Content-Type": "application/gzip", "Cache-Control": "no-store" } });
  } catch (e) {
    return new Response("Erreur : " + (e as Error).message, { status: 500 });
  } finally {
    await sql.end({ timeout: 5 });
  }
});

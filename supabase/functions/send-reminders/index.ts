// VillageLink — envoi des notifications (rappels de cotisation et notification de test).
// Appelée chaque matin par pg_cron (en-tête x-cron-secret), ou par un membre connecté
// qui veut tester les notifications sur son téléphone (en-tête Authorization).
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const ORIGINS = ["https://kowly1998-ai.github.io", "https://app.villagelinkafrica.com", "https://villagelinkafrica.com", "http://127.0.0.1:8765"];
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

type Target = { endpoint: string; p256dh: string; auth: string; title: string; body: string; url: string; tag: string };

function cors(req: Request) {
  const o = req.headers.get("origin") || "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
const json = (req: Request, data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

function todayDakar(): string {
  return new Date().toISOString().slice(0, 10); // Dakar = UTC toute l'année
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, { error: "Méthode non autorisée" }, 405);
  const cfgRes = await sb.rpc("push_config");
  const cfg = cfgRes.data as { public: string; private: string; cron: string; subject: string } | null;
  if (!cfg || !cfg.public || !cfg.private) return json(req, { error: "Notifications non configurées" }, 500);
  webpush.setVapidDetails(cfg.subject, cfg.public, cfg.private);

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* corps vide */ }
  let targets: Target[] = [];
  const cron = req.headers.get("x-cron-secret");
  if (cron && cfg.cron && cron === cfg.cron) {
    const date = typeof body.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.date) ? body.date : todayDakar();
    const r = await sb.rpc("due_reminders", { p_date: date });
    if (r.error) return json(req, { error: r.error.message }, 500);
    targets = r.data as Target[];
    if (body.dry === true) return json(req, { date, count: targets.length });
  } else {
    const jwt = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const u = jwt ? await sb.auth.getUser(jwt) : null;
    const user = u && u.data && u.data.user;
    if (!user) return json(req, { error: "Connexion requise" }, 401);
    const r = await sb.rpc("push_test_targets", { p_user: user.id });
    if (r.error) return json(req, { error: r.error.message }, 500);
    targets = r.data as Target[];
  }

  let sent = 0, failed = 0, removed = 0;
  const errors: string[] = [];
  for (const t of targets) {
    try {
      await webpush.sendNotification(
        { endpoint: t.endpoint, keys: { p256dh: t.p256dh, auth: t.auth } },
        JSON.stringify({ title: t.title, body: t.body, url: t.url, tag: t.tag }),
        { TTL: 24 * 3600, urgency: "normal" },
      );
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode || 0;
      if (code === 404 || code === 410) { await sb.rpc("drop_push_subscription", { p_endpoint: t.endpoint }); removed++; }
      else { failed++; if (errors.length < 5) errors.push(String(code || (e as Error).message).slice(0, 200)); }
    }
  }
  return json(req, { sent, failed, removed, errors });
});

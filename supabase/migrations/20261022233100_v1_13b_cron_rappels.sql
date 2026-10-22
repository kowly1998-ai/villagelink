-- Déclencheur quotidien des rappels (9 h UTC = 9 h à Dakar). Le secret est lu dans Vault.
create extension if not exists pg_net;
create extension if not exists pg_cron;
select cron.schedule('villagelink-rappels', '0 9 * * *', $c$
  select net.http_post(
    url := 'https://ncghmfwfnzgdddnqgnnl.supabase.co/functions/v1/send-reminders',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'vl_cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$c$);

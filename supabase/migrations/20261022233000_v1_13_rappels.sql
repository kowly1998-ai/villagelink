-- ---------------------------------------------------------------------
-- Rappels automatiques par notification (version 1.13)
-- Chaque téléphone qui accepte les notifications s'enregistre ici. Chaque matin
-- (9 h, heure de Dakar), la fonction « send-reminders » prévient les membres dont la
-- cotisation du mois n'est pas réglée : 3 jours avant l'échéance, le jour même, et
-- 7 jours après. Les clés de chiffrement sont dans le coffre (Vault), jamais dans le code.
-- ---------------------------------------------------------------------
create table if not exists public.push_subscriptions (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  endpoint    text not null unique check (endpoint ~ '^https://' and length(endpoint) <= 1000),
  p256dh      text not null check (length(p256dh) between 20 and 200),
  auth        text not null check (length(auth) between 10 and 100),
  user_agent  text not null default '' check (length(user_agent) <= 300),
  created_at  timestamptz not null default now()
);
create index if not exists push_user_idx on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;
create policy push_select on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
revoke all on public.push_subscriptions from anon, authenticated;
grant select on public.push_subscriptions to authenticated;

-- Enregistrer / retirer ce téléphone (un même téléphone passe au dernier compte connecté).
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_ua text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if (select count(*) from push_subscriptions where user_id = auth.uid()) >= 10 then
    delete from push_subscriptions where id = (select id from push_subscriptions where user_id = auth.uid() order by created_at limit 1);
  end if;
  insert into push_subscriptions(user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(coalesce(p_ua, ''), 300))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh,
    auth = excluded.auth, user_agent = excluded.user_agent, created_at = now();
end $$;
create or replace function public.remove_push_subscription(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;
revoke execute on function public.save_push_subscription(text, text, text, text) from public, anon;
revoke execute on function public.remove_push_subscription(text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.remove_push_subscription(text) to authenticated;

-- Les rappels du jour : un par téléphone et par cotisation à régler.
create or replace function public.due_reminders(p_date date)
returns table(endpoint text, p256dh text, auth text, title text, body text, url text, tag text)
language sql stable security definer set search_path = public as $$
  with cal as (
    select distinct on (a.id, to_char(r.ref, 'YYYY-MM')) a.*, to_char(r.ref, 'YYYY-MM') as period,
           make_date(extract(year from r.ref)::int, extract(month from r.ref)::int, a.fee_due_day) as due,
           (array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'])[extract(month from r.ref)::int] as month_fr
    from associations a cross join (values (p_date - 7), (p_date), (p_date + 3)) r(ref)
    where a.fee_amount > 0
  ), owed as (
    select c.id as assoc_id, c.name, c.currency, c.fee_amount, c.period, c.due, c.month_fr, m.id as member_id, m.user_id, m.full_name,
           c.fee_amount - coalesce((select sum(t.amount) from transactions t
              where t.member_id = m.id and t.category = 'Cotisations' and t.period = c.period), 0) as remaining
    from cal c join members m on m.association_id = c.id
    where m.active and not m.pending and m.user_id is not null
      and to_char(c.dues_start, 'YYYY-MM') <= c.period and to_char(m.joined_on, 'YYYY-MM') <= c.period
      and p_date in (c.due - 3, c.due, c.due + 7)
  )
  select s.endpoint, s.p256dh, s.auth,
         o.name,
         case when p_date = o.due - 3 then format('Votre cotisation de %s (%s) est à régler avant le %s.', o.month_fr, fmt_money(o.remaining::bigint, o.currency), to_char(o.due, 'DD/MM'))
              when p_date = o.due then format('C''est aujourd''hui l''échéance de votre cotisation : %s.', fmt_money(o.remaining::bigint, o.currency))
              else format('Votre cotisation de %s (%s) est en retard. Pensez à la régler auprès du trésorier.', o.month_fr, fmt_money(o.remaining::bigint, o.currency)) end,
         '#/a/' || o.assoc_id || '/m/' || o.member_id,
         'cotisation-' || o.assoc_id || '-' || o.period
  from owed o join push_subscriptions s on s.user_id = o.user_id
  where o.remaining > 0;
$$;

-- Notification de test pour la personne qui la demande.
create or replace function public.push_test_targets(p_user uuid)
returns table(endpoint text, p256dh text, auth text, title text, body text, url text, tag text)
language sql stable security definer set search_path = public as $$
  select s.endpoint, s.p256dh, s.auth, 'VillageLink'::text,
         'Les notifications marchent sur ce téléphone. Vous recevrez les rappels de cotisation ici.'::text, '#/'::text, 'test'::text
  from push_subscriptions s where s.user_id = p_user;
$$;

create or replace function public.drop_push_subscription(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint;
$$;

-- Réglages lus par la fonction serveur (clé de service seulement).
create or replace function public.push_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'public', (select decrypted_secret from vault.decrypted_secrets where name = 'vl_vapid_public'),
    'private', (select decrypted_secret from vault.decrypted_secrets where name = 'vl_vapid_private'),
    'cron', (select decrypted_secret from vault.decrypted_secrets where name = 'vl_cron_secret'),
    'subject', 'mailto:kowly1998@gmail.com');
$$;

revoke execute on function public.due_reminders(date) from public, anon, authenticated;
revoke execute on function public.push_test_targets(uuid) from public, anon, authenticated;
revoke execute on function public.drop_push_subscription(text) from public, anon, authenticated;
revoke execute on function public.push_config() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.due_reminders(date) to service_role;
    grant execute on function public.push_test_targets(uuid) to service_role;
    grant execute on function public.drop_push_subscription(text) to service_role;
    grant execute on function public.push_config() to service_role;
  end if;
end $$;
-- Les secrets (clés VAPID, secret du déclencheur) sont créés à part dans Vault :
--   select vault.create_secret('<valeur>', 'vl_vapid_public'); … 'vl_vapid_private', 'vl_cron_secret'
-- Le déclencheur quotidien (pg_cron + pg_net) est créé à part, voir migration 1.13b.

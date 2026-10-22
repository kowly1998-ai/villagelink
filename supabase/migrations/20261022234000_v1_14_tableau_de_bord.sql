-- ---------------------------------------------------------------------
-- Tableau de bord du propriétaire de VillageLink (version 1.14)
-- Chiffres globaux, réservés aux comptes de la table app_admins.
-- Aucun nom de membre, aucun numéro : seulement des totaux par association.
-- ---------------------------------------------------------------------
create table if not exists public.app_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.app_admins enable row level security;
revoke all on public.app_admins from anon, authenticated;

create or replace function public.am_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_admins where user_id = auth.uid());
$$;

create or replace function public.owner_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'Réservé au propriétaire de VillageLink.';
  end if;
  select jsonb_build_object(
    'generated_at', now(),
    'associations', (select count(*) from associations),
    'associations_30d', (select count(*) from associations where created_at > now() - interval '30 days'),
    'members', (select count(*) from members where active and not pending),
    'members_on_app', (select count(*) from members where active and not pending and user_id is not null),
    'accounts', (select count(*) from auth.users),
    'accounts_30d', (select count(*) from auth.users where created_at > now() - interval '30 days'),
    'active_users_7d', (select count(distinct actor_id) from activity_log where created_at > now() - interval '7 days' and actor_id is not null),
    'active_users_30d', (select count(distinct actor_id) from activity_log where created_at > now() - interval '30 days' and actor_id is not null),
    'tx_30d', (select count(*) from transactions where created_at > now() - interval '30 days'),
    'push_devices', (select count(*) from push_subscriptions),
    'volume', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'total_in', total_in) order by total_in desc)
                        from (select a.currency, sum(t.amount) filter (where t.kind = 'in') as total_in
                              from transactions t join associations a on a.id = t.association_id group by a.currency) v), '[]'::jsonb),
    'weekly', coalesce((select jsonb_agg(jsonb_build_object('week', w, 'actions', n, 'users', u) order by w)
                        from (select date_trunc('week', created_at)::date as w, count(*) as n, count(distinct actor_id) as u
                              from activity_log where created_at > now() - interval '12 weeks' group by 1) x), '[]'::jsonb),
    'list', coalesce((select jsonb_agg(row_to_json(x) order by x.last_activity desc nulls last) from (
        select a.id, a.name, a.village, a.residence_city, a.currency, a.plan, a.created_at,
               (select count(*) from members m where m.association_id = a.id and m.active and not m.pending) as members,
               (select count(*) from members m where m.association_id = a.id and m.active and not m.pending and m.user_id is not null) as on_app,
               (select count(*) from members m where m.association_id = a.id and m.pending) as pending,
               (select max(l.created_at) from activity_log l where l.association_id = a.id) as last_activity,
               (select count(*) from activity_log l where l.association_id = a.id and l.created_at > now() - interval '30 days') as actions_30d,
               (select count(*) from transactions t where t.association_id = a.id) as tx,
               (select coalesce(sum(t.amount) filter (where t.kind = 'in'), 0) - coalesce(sum(t.amount) filter (where t.kind = 'out'), 0)
                  from transactions t where t.association_id = a.id) as balance
        from associations a) x), '[]'::jsonb)
  ) into r;
  return r;
end $$;

revoke execute on function public.am_owner() from public, anon;
revoke execute on function public.owner_stats() from public, anon;
grant execute on function public.am_owner() to authenticated;
grant execute on function public.owner_stats() to authenticated;
-- Le propriétaire est ajouté à part :
--   insert into app_admins(user_id) select id from auth.users where email in ('…');

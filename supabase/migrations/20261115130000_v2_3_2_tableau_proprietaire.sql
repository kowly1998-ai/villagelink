-- v2.3.2 : tableau de bord du propriétaire enrichi (lecture seule).
-- Revenus des abonnements, essais à relancer, passage essai -> payant, fonctions utilisées,
-- associations endormies, membres jamais connectés, inscriptions par semaine, alertes,
-- pays et devises, place utilisée, dernière sauvegarde.

-- Journal des exports de sauvegarde (écrit par la fonction backup-export, lu par le propriétaire seulement)
create table if not exists public.backup_runs (
  id         bigint generated always as identity primary key,
  ran_at     timestamptz not null default now(),
  tables     integer not null default 0,
  accounts   integer not null default 0,
  checked    boolean not null default false  -- true = simple vérification, pas un vrai export
);
alter table public.backup_runs enable row level security;
-- aucune politique : personne ne lit ni n'écrit par l'API ; seules les fonctions ci-dessous et backup-export y accèdent
revoke all on public.backup_runs from anon, authenticated;

create or replace function public.owner_insights() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; today date := current_date;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then
    raise exception 'Réservé au propriétaire de VillageLink.';
  end if;

  with a as (
    select x.*, assoc_status(x.id) as status,
      (select count(*) from members m where m.association_id = x.id and m.active and not m.pending)::int as n,
      (select max(l.created_at) from activity_log l where l.association_id = x.id) as last_act
    from associations x
  ), paid as (
    select * from subscription_requests where status = 'activated'
  )
  select jsonb_build_object(
    'generated_at', now(),

    -- 1. Argent
    'money', jsonb_build_object(
      'month', coalesce((select sum(amount) from paid where decided_at >= date_trunc('month', now())), 0),
      'year', coalesce((select sum(amount) from paid where decided_at >= now() - interval '12 months'), 0),
      'total', coalesce((select sum(amount) from paid), 0),
      -- revenu mensuel régulier : dernier paiement de chaque association abonnée, ramené au mois
      'mrr', coalesce((select sum(p.amount / greatest(p.months, 1)) from a
               join lateral (select amount, months from paid where paid.association_id = a.id order by decided_at desc limit 1) p on true
               where a.status = 'active'), 0),
      'monthly', coalesce((select jsonb_agg(jsonb_build_object('month', to_char(mo, 'YYYY-MM'), 'amount',
                   coalesce((select sum(amount) from paid where date_trunc('month', decided_at) = mo), 0)) order by mo)
                 from generate_series(date_trunc('month', now()) - interval '11 months', date_trunc('month', now()), interval '1 month') mo), '[]'::jsonb),
      'status', (select jsonb_object_agg(s, c) from (select status s, count(*) c from a group by status) z),
      'trials_ending', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'trial_ends', a.trial_ends,
                          'days', a.trial_ends - today, 'members', a.n,
                          'president', (select m.full_name from members m where m.association_id = a.id and m.role = 'president' and m.active and not m.pending order by m.created_at limit 1),
                          'phone', (select m.phone from members m where m.association_id = a.id and m.role = 'president' and m.active and not m.pending order by m.created_at limit 1))
                        order by a.trial_ends)
                        from a where a.paid_until is null and a.blocked_at is null and a.trial_ends between today and today + 7), '[]'::jsonb),
      'trials_done', (select count(*) from a where a.trial_ends < today),
      'converted', (select count(*) from a where a.trial_ends < today and exists (select 1 from paid where paid.association_id = a.id))
    ),

    -- 2. Usage
    'usage', jsonb_build_object(
      'features', jsonb_build_array(
        jsonb_build_object('k', 'Cotisations et opérations', 'rows', (select count(*) from transactions where created_at > now() - interval '30 days'), 'assocs', (select count(distinct association_id) from transactions where created_at > now() - interval '30 days')),
        jsonb_build_object('k', 'Paiements déclarés', 'rows', (select count(*) from payment_claims where created_at > now() - interval '30 days'), 'assocs', (select count(distinct association_id) from payment_claims where created_at > now() - interval '30 days')),
        jsonb_build_object('k', 'Dépenses à valider', 'rows', (select count(*) from expense_requests where created_at > now() - interval '30 days'), 'assocs', (select count(distinct association_id) from expense_requests where created_at > now() - interval '30 days')),
        jsonb_build_object('k', 'Discussion', 'rows', (select count(*) from messages where created_at > now() - interval '30 days'), 'assocs', (select count(distinct association_id) from messages where created_at > now() - interval '30 days')),
        jsonb_build_object('k', 'Annonces', 'rows', (select count(*) from announcements where created_at > now() - interval '30 days'), 'assocs', (select count(distinct association_id) from announcements where created_at > now() - interval '30 days')),
        jsonb_build_object('k', 'Réunions', 'rows', (select count(*) from meetings where created_at > now() - interval '30 days'), 'assocs', (select count(distinct association_id) from meetings where created_at > now() - interval '30 days')),
        jsonb_build_object('k', 'Votes', 'rows', (select count(*) from polls where created_at > now() - interval '30 days'), 'assocs', (select count(distinct association_id) from polls where created_at > now() - interval '30 days')),
        jsonb_build_object('k', 'Projets', 'rows', (select count(*) from projects where created_at > now() - interval '30 days') + (select count(*) from project_updates where created_at > now() - interval '30 days'),
                           'assocs', (select count(distinct association_id) from (select association_id from projects where created_at > now() - interval '30 days' union select p.association_id from project_updates u join projects p on p.id = u.project_id where u.created_at > now() - interval '30 days') z)),
        jsonb_build_object('k', 'Solidarité', 'rows', (select count(*) from collections where created_at > now() - interval '30 days'), 'assocs', (select count(distinct association_id) from collections where created_at > now() - interval '30 days')),
        jsonb_build_object('k', 'Documents', 'rows', (select count(*) from documents where created_at > now() - interval '30 days'), 'assocs', (select count(distinct association_id) from documents where created_at > now() - interval '30 days'))
      ),
      'dormant', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'members', a.n, 'last', a.last_act,
                   'days', case when a.last_act is null then null else (today - a.last_act::date) end) order by a.last_act nulls first)
                 from a where a.last_act is null or a.last_act < now() - interval '14 days'), '[]'::jsonb),
      'never_total', (select count(*) from members where active and not pending and user_id is null),
      'never', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'never', z.c, 'members', a.n) order by z.c desc)
                 from a join (select association_id, count(*) c from members where active and not pending and user_id is null group by 1) z on z.association_id = a.id), '[]'::jsonb),
      'signups', coalesce((select jsonb_agg(jsonb_build_object('week', w::date,
                   'assocs', (select count(*) from associations where date_trunc('week', created_at) = w),
                   'accounts', (select count(*) from auth.users where date_trunc('week', created_at) = w)) order by w)
                 from generate_series(date_trunc('week', now()) - interval '11 weeks', date_trunc('week', now()), interval '1 week') w), '[]'::jsonb)
    ),

    -- 3. Alertes
    'alerts', jsonb_build_object(
      'no_treasurer', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'members', a.n) order by a.name)
                       from a where a.blocked_at is null and not exists (select 1 from members m where m.association_id = a.id and m.role = 'tresorier' and m.active and not m.pending)), '[]'::jsonb),
      'stuck_expenses', coalesce((select jsonb_agg(jsonb_build_object('assoc', x.name, 'amount', e.amount, 'currency', x.currency, 'category', e.category,
                          'days', today - e.created_at::date) order by e.created_at)
                         from expense_requests e join associations x on x.id = e.association_id
                         where e.status = 'En attente' and e.created_at < now() - interval '7 days'), '[]'::jsonb),
      'near_tier', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'members', a.n, 'tier', tier_for(a.n),
                     'limit', case tier_for(a.n) when 'petite' then 30 when 'moyenne' then 100 when 'grande' then 300 end) order by a.n desc)
                   from a where tier_for(a.n) in ('petite','moyenne','grande')
                     and a.n >= (case tier_for(a.n) when 'petite' then 30 when 'moyenne' then 100 else 300 end) * 0.9), '[]'::jsonb),
      'unpaid', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'status', a.status, 'members', a.n) order by a.name)
                 from a where a.status in ('grace', 'readonly')), '[]'::jsonb)
    ),

    -- 4. Où sont les clients
    'where', jsonb_build_object(
      'origin', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'n', c) order by c desc, k) from
                 (select coalesce(nullif(initcap(trim(origin_country)), ''), 'Non renseigné') k, count(*) c from associations group by 1) z), '[]'::jsonb),
      'residence', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'n', c) order by c desc, k) from
                 (select coalesce(nullif(initcap(trim(residence_country)), ''), 'Non renseigné') k, count(*) c from associations group by 1) z), '[]'::jsonb),
      'city', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'n', c) order by c desc, k) from
                 (select coalesce(nullif(initcap(trim(residence_city)), ''), 'Non renseigné') k, count(*) c from associations group by 1) z), '[]'::jsonb),
      'currency', coalesce((select jsonb_agg(jsonb_build_object('k', currency, 'n', c) order by c desc) from
                 (select currency, count(*) c from associations group by 1) z), '[]'::jsonb)
    ),

    -- 5. Santé du service
    'health', jsonb_build_object(
      'db_bytes', pg_database_size(current_database()),
      'db_limit', 500 * 1024 * 1024,
      'files_bytes', coalesce((select sum((metadata->>'size')::bigint) from storage.objects), 0),
      'files_limit', 1024 * 1024 * 1024,
      'files', coalesce((select jsonb_agg(jsonb_build_object('bucket', bucket_id, 'bytes', b, 'n', c) order by b desc) from
                 (select bucket_id, sum((metadata->>'size')::bigint) b, count(*) c from storage.objects group by 1) z), '[]'::jsonb),
      'last_backup', (select max(ran_at) from backup_runs where not checked),
      'backups_30d', (select count(*) from backup_runs where not checked and ran_at > now() - interval '30 days')
    )
  ) into r;
  return r;
end $$;
revoke execute on function public.owner_insights() from public, anon;
grant execute on function public.owner_insights() to authenticated;

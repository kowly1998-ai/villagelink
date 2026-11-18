-- v2.4.1 : grille Starter / Pro / Premium (décision d'Alpha du 14-18/11/2026).
-- Les clés internes restent 'petite', 'moyenne', 'grande' (aucune donnée à migrer) ; seuls les noms affichés,
-- les tailles et les prix changent :
--   Starter (petite)  : 1 à 30 membres,   3 000 FCFA / mois,  30 000 FCFA / an
--   Pro (moyenne)     : 31 à 200 membres, 7 500 FCFA / mois,  75 000 FCFA / an
--   Premium (grande)  : 201 membres et +, 15 000 FCFA / mois, 150 000 FCFA / an (plus de devis)
-- Offre fondatrice : Pro à 50 000 FCFA / an, chaque année tant que l'association est fondatrice (prix bloqué à vie),
-- 20 places au lieu de 10. Les autres formules n'ont pas de remise fondatrice.
-- Paiement par les liens SasPay (un lien par formule et par durée) ; activation toujours par le propriétaire.
-- Toutes les fonctions restent incluses dans chaque formule (pas de limite de fonctions).

create or replace function public.plan_label(p_plan text) returns text
language sql immutable set search_path = public as $$
  select case p_plan when 'petite' then 'Starter' when 'moyenne' then 'Pro' when 'grande' then 'Premium'
                     when 'association' then 'Pro' when 'federation' then 'Premium' else initcap(coalesce(p_plan, '')) end $$;
revoke execute on function public.plan_label(text) from public, anon;
grant execute on function public.plan_label(text) to authenticated;

create or replace function public.tier_for(n int) returns text
language sql immutable set search_path = public as $$
  select case when n is null or n < 0 then null
              when n <= 30 then 'petite' when n <= 200 then 'moyenne' else 'grande' end $$;

create or replace function public.plan_price(p_plan text, p_months int, p_founder boolean default false) returns bigint
language plpgsql immutable set search_path = public as $$
declare base bigint;
begin
  base := case p_plan when 'petite' then 3000 when 'moyenne' then 7500 when 'grande' then 15000 end;
  if base is null then raise exception 'Formule invalide.'; end if;
  if p_months = 1 then return base;
  elsif p_months = 12 then
    if p_founder and p_plan = 'moyenne' then return 50000; end if;  -- offre fondatrice : Pro à 50 000 FCFA par an
    return base * 10;                                               -- 10 mois payés, 2 mois offerts
  else raise exception 'Durée invalide.'; end if;
end $$;

-- Devis : la remise fondatrice s'applique chaque année (prix bloqué à vie), seulement pour la formule Pro à l'année
create or replace function public.sub_quote(p_assoc uuid, p_months int) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a associations; n int; t text; disc boolean;
begin
  if not (has_role(p_assoc, array['president','vice_president','tresorier']) or am_owner()) then
    raise exception 'Seuls le président, le vice-président et le trésorier gèrent l’abonnement.';
  end if;
  if p_months not in (1, 12) then raise exception 'Durée invalide.'; end if;
  select * into a from associations where id = p_assoc;
  select count(*) into n from members m where m.association_id = p_assoc and m.active and not m.pending;
  t := tier_for(n);
  disc := coalesce(a.founder, false) and p_months = 12 and t = 'moyenne';
  return jsonb_build_object('members', n, 'plan', t, 'months', p_months, 'amount', plan_price(t, p_months, disc), 'discounted', disc);
end $$;
revoke execute on function public.sub_quote(uuid, int) from public, anon;
grant execute on function public.sub_quote(uuid, int) to authenticated;

-- Mêmes fonctions qu'en 2.3.0, avec les noms Starter / Pro / Premium dans le journal
create or replace function public.request_subscription(p_assoc uuid, p_plan text, p_months int, p_amount bigint, p_reference text)
returns bigint language plpgsql security definer set search_path = public as $$
declare nid bigint; ref text := trim(coalesce(p_reference, '')); q jsonb; t text;
begin
  if not has_role(p_assoc, array['president','vice_president','tresorier']) then
    raise exception 'Seuls le président, le vice-président et le trésorier gèrent l’abonnement.';
  end if;
  if p_plan not in ('association','federation','petite','moyenne','grande') or p_months not in (1, 12)
     or p_amount is null or p_amount <= 0 then
    raise exception 'Formule invalide.';
  end if;
  if length(ref) > 60 then raise exception 'Référence trop longue.'; end if;
  if exists (select 1 from subscription_requests where association_id = p_assoc and status in ('pending','verifying','confirmed')) then
    raise exception 'Une demande est déjà en attente de validation par VillageLink.';
  end if;
  q := sub_quote(p_assoc, p_months);
  t := q->>'plan';
  if t = 'devis' then
    raise exception 'Plus de 300 membres : écrivez à contact@villagelinkafrica.com pour un devis.';
  end if;
  begin
    insert into subscription_requests(association_id, plan, months, amount, reference, created_label, expected_amount, discounted)
    values (p_assoc, t, p_months, p_amount, ref, actor_label(p_assoc), (q->>'amount')::bigint, (q->>'discounted')::boolean)
    returning id into nid;
  exception when unique_violation then
    raise exception 'Ce paiement est déjà déclaré (même référence).';
  end;
  perform write_log(p_assoc, format('a déclaré avoir payé l’abonnement VillageLink (formule %s, %s) : %s%s. En attente de validation.',
    plan_label(t), case p_months when 12 then '1 an' else '1 mois' end, fmt_money(p_amount, 'XOF'),
    case when ref <> '' then ' (réf. ' || ref || ')' else '' end));
  return nid;
end $$;

create or replace function public.owner_activate(p_request bigint, p_until date default null) returns void
language plpgsql security definer set search_path = public as $$
declare r subscription_requests; a associations; st date; en date;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  select * into r from subscription_requests where id = p_request for update;
  if r.id is null or r.status not in ('pending','verifying','confirmed') then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if r.expected_amount is not null and r.amount < r.expected_amount then
    raise exception 'Montant insuffisant : % reçu, % attendu.', fmt_money(r.amount, 'XOF'), fmt_money(r.expected_amount, 'XOF');
  end if;
  select * into a from associations where id = r.association_id for update;
  -- Début : le plus tardif entre la fin de l'abonnement actuel, la fin de l'essai et aujourd'hui
  -- (renouveler avant la fin ne fait rien perdre ; payer après la fin repart d'aujourd'hui).
  st := greatest(a.paid_until, a.trial_ends, current_date);
  en := (st + make_interval(months => r.months))::date;
  perform set_config('vl.system', 'on', true);
  update associations set plan = r.plan, paid_until = en, founder_used = founder_used or r.discounted where id = r.association_id;
  update subscription_requests set status = 'activated', decided_at = now(), period_start = st, period_end = en where id = r.id;
  insert into activity_log(association_id, actor_id, actor_label, message)
  values (r.association_id, null, 'VillageLink', format('a activé l’abonnement (formule %s) jusqu’au %s. Merci !',
    plan_label(r.plan), to_char(en, 'DD/MM/YYYY')));
  perform set_config('vl.system', '', true);
end $$;

-- 20 places d'association fondatrice
create or replace function public.owner_set_founder(p_assoc uuid, p_value boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  if p_value is null then raise exception 'Valeur invalide.'; end if;
  perform pg_advisory_xact_lock(hashtext('founders'));
  if p_value and (select count(*) from associations where founder and id <> p_assoc) >= 20 then
    raise exception 'Les 20 places d’association fondatrice sont prises.';
  end if;
  perform set_config('vl.system', 'on', true);
  update associations set founder = p_value where id = p_assoc;
  perform set_config('vl.system', '', true);
end $$;

-- Tableau du propriétaire : « proche de la taille supérieure » avec les nouvelles tailles (30 et 200)
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
                     'limit', case tier_for(a.n) when 'petite' then 30 when 'moyenne' then 200 end) order by a.n desc)
                   from a where tier_for(a.n) in ('petite','moyenne')
                     and a.n >= (case tier_for(a.n) when 'petite' then 30 else 200 end) * 0.9), '[]'::jsonb),
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

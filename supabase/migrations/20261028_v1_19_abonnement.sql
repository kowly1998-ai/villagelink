-- VillageLink 1.19 — Essai gratuit et abonnement
-- Chaque association a 60 jours d'essai. Ensuite, l'abonnement se paie à VillageLink (Wave),
-- le propriétaire de VillageLink l'active. Sans abonnement : 7 jours de grâce, puis LECTURE SEULE :
-- tout reste visible (caisse, historique, membres), mais on ne peut plus rien enregistrer.
-- Rien n'est jamais supprimé. Plans : 'decouverte' = essai, 'association' = Village, 'federation' = Diaspora.

alter table public.associations add column if not exists trial_ends date not null default (current_date + 60);
alter table public.associations add column if not exists paid_until date;


-- Les dates d'essai et d'abonnement ne se changent que par VillageLink.
create or replace function public.associations_guard() returns trigger
language plpgsql as $$
begin
  if new.invite_code <> old.invite_code and coalesce(current_setting('vl.system', true), '') <> 'on' then
    raise exception 'Le code d''invitation se change avec la fonction prévue.';
  end if;
  if (new.plan <> old.plan or new.trial_ends is distinct from old.trial_ends or new.paid_until is distinct from old.paid_until)
     and coalesce(current_setting('vl.system', true), '') <> 'on' then
    raise exception 'L''offre se change par VillageLink.';
  end if;
  return new;
end $$;

-- État de l'association : trial | active | grace | readonly
create or replace function public.assoc_status(p_assoc uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when a.paid_until is not null and a.paid_until >= current_date then 'active'
    when a.paid_until is null and a.trial_ends >= current_date then 'trial'
    when greatest(coalesce(a.paid_until, a.trial_ends), a.trial_ends) + 7 >= current_date then 'grace'
    else 'readonly' end
  from associations a where a.id = p_assoc;
$$;
revoke execute on function public.assoc_status(uuid) from public, anon;
grant execute on function public.assoc_status(uuid) to authenticated;

-- Bloque les nouvelles écritures d'une association en lecture seule.
create or replace function public.enforce_subscription() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('vl.system', true), '') = 'on' then return new; end if;
  if assoc_status(new.association_id) = 'readonly' then
    raise exception 'L’essai gratuit de VillageLink est terminé : l’association est en lecture seule. Le président peut activer l’abonnement dans Plus → Abonnement.' using errcode = '42501';
  end if;
  return new;
end $$;
revoke execute on function public.enforce_subscription() from public, anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['transactions','payment_claims','expense_requests','members','projects','project_updates',
                           'announcements','meetings','polls','documents','collections','member_exemptions'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists zz_subscription on public.%I', t);
      execute format('create trigger zz_subscription before insert on public.%I for each row execute function public.enforce_subscription()', t);
    end if;
  end loop;
end $$;


-- Formule Village : sans sections, catégories de cotisation ni plusieurs monnaies, 50 membres au plus.
-- Pendant l'essai (plan 'decouverte') et en formule Diaspora ('federation') : tout est inclus.
create or replace function public.enforce_plan_features() returns trigger
language plpgsql security definer set search_path = public as $$
declare a associations;
begin
  if coalesce(current_setting('vl.system', true), '') = 'on' then return new; end if;
  select * into a from associations where id = new.association_id;
  if a.plan is distinct from 'association' then return new; end if;
  if tg_table_name in ('sections', 'member_categories') then
    raise exception 'Les sections et les catégories de cotisation sont réservées à la formule Diaspora (Plus → Abonnement).' using errcode = '42501';
  end if;
  if tg_table_name = 'members' then
    if (select count(*) from members m where m.association_id = new.association_id and m.active) >= 50 then
      raise exception 'La formule Village est limitée à 50 membres. Passez à la formule Diaspora (Plus → Abonnement).' using errcode = '42501';
    end if;
    return new;
  end if;
  if tg_table_name in ('transactions', 'expense_requests') then
    if coalesce(new.orig_currency, '') not in ('', a.currency) then
      raise exception 'Les paiements en plusieurs monnaies sont réservés à la formule Diaspora (Plus → Abonnement).' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.enforce_plan_features() from public, anon, authenticated;
do $$ declare t text; begin
  foreach t in array array['sections','member_categories','members','transactions','expense_requests'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists zz_plan_features on public.%I', t);
      execute format('create trigger zz_plan_features before insert on public.%I for each row execute function public.enforce_plan_features()', t);
    end if;
  end loop;
end $$;

-- Demandes d'abonnement (le président déclare avoir payé VillageLink ; le propriétaire active).
create table if not exists public.subscription_requests (
  id             bigint generated always as identity primary key,
  association_id uuid not null references public.associations(id) on delete cascade,
  plan           text not null check (plan in ('association','federation')),
  months         int not null check (months in (1, 12)),
  amount         bigint not null check (amount > 0 and amount <= 10000000),
  reference      text not null default '' check (length(reference) <= 60),
  status         text not null default 'pending' check (status in ('pending','activated','rejected')),
  created_by     uuid references auth.users(id) on delete set null default auth.uid(),
  created_label  text not null default '',
  created_at     timestamptz not null default now(),
  decided_at     timestamptz,
  note           text not null default '' check (length(note) <= 200)
);
create index if not exists subreq_assoc_idx on public.subscription_requests(association_id, id desc);
alter table public.subscription_requests enable row level security;
drop policy if exists subreq_select on public.subscription_requests;
create policy subreq_select on public.subscription_requests for select to authenticated
  using (is_member(association_id) or exists (select 1 from app_admins where user_id = auth.uid()));
grant select on public.subscription_requests to authenticated;

create or replace function public.request_subscription(p_assoc uuid, p_plan text, p_months int, p_amount bigint, p_reference text)
returns bigint language plpgsql security definer set search_path = public as $$
declare nid bigint; ref text := trim(coalesce(p_reference, ''));
begin
  if not has_role(p_assoc, array['president','vice_president','tresorier']) then
    raise exception 'Seuls le président, le vice-président et le trésorier gèrent l’abonnement.';
  end if;
  if p_plan not in ('association','federation') or p_months not in (1, 12) or p_amount is null or p_amount <= 0 then
    raise exception 'Formule invalide.';
  end if;
  if length(ref) > 60 then raise exception 'Référence trop longue.'; end if;
  if exists (select 1 from subscription_requests where association_id = p_assoc and status = 'pending') then
    raise exception 'Une demande est déjà en attente de validation par VillageLink.';
  end if;
  insert into subscription_requests(association_id, plan, months, amount, reference, created_label)
  values (p_assoc, p_plan, p_months, p_amount, ref, actor_label(p_assoc)) returning id into nid;
  perform write_log(p_assoc, format('a déclaré avoir payé l’abonnement VillageLink (%s, %s) : %s%s. En attente de validation.',
    case p_plan when 'association' then 'formule Village' else 'formule Diaspora' end,
    case p_months when 12 then '1 an' else '1 mois' end, fmt_money(p_amount, 'XOF'),
    case when ref <> '' then ' (réf. ' || ref || ')' else '' end));
  return nid;
end $$;
revoke execute on function public.request_subscription(uuid, text, int, bigint, text) from public, anon;
grant execute on function public.request_subscription(uuid, text, int, bigint, text) to authenticated;

-- Réservé au propriétaire de VillageLink : activer, refuser, prolonger l'essai.
create or replace function public.owner_activate(p_request bigint, p_until date) returns void
language plpgsql security definer set search_path = public as $$
declare r subscription_requests;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  select * into r from subscription_requests where id = p_request for update;
  if r.id is null or r.status <> 'pending' then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if p_until is null or p_until < current_date then raise exception 'Date de fin invalide.'; end if;
  perform set_config('vl.system', 'on', true);
  update associations set plan = r.plan, paid_until = p_until where id = r.association_id;
  update subscription_requests set status = 'activated', decided_at = now() where id = r.id;
  insert into activity_log(association_id, actor_id, actor_label, message)
  values (r.association_id, null, 'VillageLink', format('a activé l’abonnement (%s) jusqu’au %s. Merci !',
    case r.plan when 'association' then 'formule Village' else 'formule Diaspora' end, to_char(p_until, 'DD/MM/YYYY')));
  perform set_config('vl.system', '', true);
end $$;

create or replace function public.owner_reject(p_request bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare r subscription_requests; why text := trim(coalesce(p_note, ''));
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  select * into r from subscription_requests where id = p_request for update;
  if r.id is null or r.status <> 'pending' then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if length(why) < 3 then raise exception 'Indiquez le motif.'; end if;
  update subscription_requests set status = 'rejected', decided_at = now(), note = left(why, 200) where id = r.id;
  insert into activity_log(association_id, actor_id, actor_label, message)
  values (r.association_id, null, 'VillageLink', format('n’a pas pu valider le paiement de l’abonnement. Motif : %s', why));
end $$;

create or replace function public.owner_set_dates(p_assoc uuid, p_trial_ends date, p_paid_until date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  perform set_config('vl.system', 'on', true);
  update associations set trial_ends = coalesce(p_trial_ends, trial_ends), paid_until = p_paid_until where id = p_assoc;
  perform set_config('vl.system', '', true);
end $$;

create or replace function public.owner_subscriptions() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  return jsonb_build_object(
    'requests', coalesce((select jsonb_agg(row_to_json(x) order by x.id) from (
        select r.*, a.name as assoc_name from subscription_requests r join associations a on a.id = r.association_id
        where r.status = 'pending') x), '[]'::jsonb),
    'assocs', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'plan', a.plan,
        'trial_ends', a.trial_ends, 'paid_until', a.paid_until, 'status', assoc_status(a.id),
        'members', (select count(*) from members m where m.association_id = a.id and m.active and not m.pending))
        order by coalesce(a.paid_until, a.trial_ends)) from associations a), '[]'::jsonb));
end $$;

revoke execute on function public.owner_activate(bigint, date) from public, anon;
revoke execute on function public.owner_reject(bigint, text) from public, anon;
revoke execute on function public.owner_set_dates(uuid, date, date) from public, anon;
revoke execute on function public.owner_subscriptions() from public, anon;
grant execute on function public.owner_activate(bigint, date) to authenticated;
grant execute on function public.owner_reject(bigint, text) to authenticated;
grant execute on function public.owner_set_dates(uuid, date, date) to authenticated;
grant execute on function public.owner_subscriptions() to authenticated;

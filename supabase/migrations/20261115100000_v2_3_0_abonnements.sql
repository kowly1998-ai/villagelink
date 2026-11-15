-- v2.3.0 : nouvelles formules d'abonnement (base seulement).
-- Décisions d'Alpha (14-15/11/2026) : 3 formules selon la taille (petite 1-30, moyenne 31-100, grande 101-300),
-- prix calculés par le serveur, essai de 30 jours pour les nouvelles associations, offre fondatrice (-50 % la
-- 1re période de 12 mois payée, 10 associations), activation avec dates calculées par le serveur,
-- une même référence de paiement ne peut pas être déclarée deux fois, une demande traitée ne change plus.
-- Compatible avec l'app actuelle (v2.2.12) : mêmes fonctions, mêmes paramètres. Les limites de membres et de
-- fonctions de l'ancienne formule Village sont retirées en 2.3.1, pas ici.

-- 1. Essai de 30 jours pour les NOUVELLES associations (les dates existantes ne changent pas)
alter table public.associations alter column trial_ends set default (current_date + 30);

-- 2. Formules et offre fondatrice
alter table public.associations drop constraint if exists associations_plan_check;
alter table public.associations add constraint associations_plan_check
  check (plan = any (array['decouverte','association','federation','petite','moyenne','grande']));
alter table public.associations add column if not exists founder boolean not null default false;
alter table public.associations add column if not exists founder_used boolean not null default false;

-- 3. Demandes de paiement : formules, états, montant attendu, historique de période
alter table public.subscription_requests drop constraint if exists subscription_requests_plan_check;
alter table public.subscription_requests add constraint subscription_requests_plan_check
  check (plan = any (array['association','federation','petite','moyenne','grande']));
alter table public.subscription_requests drop constraint if exists subscription_requests_status_check;
-- pending = déclaré ; verifying = en vérification ; confirmed = confirmé ; activated ; rejected
alter table public.subscription_requests add constraint subscription_requests_status_check
  check (status = any (array['pending','verifying','confirmed','activated','rejected']));
alter table public.subscription_requests add column if not exists expected_amount bigint;
alter table public.subscription_requests add column if not exists discounted boolean not null default false;
alter table public.subscription_requests add column if not exists period_start date;
alter table public.subscription_requests add column if not exists period_end date;
alter table public.subscription_requests drop constraint if exists subscription_requests_expected_check;
alter table public.subscription_requests add constraint subscription_requests_expected_check
  check (expected_amount is null or expected_amount > 0);

-- Une même référence ne peut pas être déclarée deux fois pour une association (sauf si la 1re a été refusée)
create unique index if not exists subreq_ref_uniq on public.subscription_requests (association_id, lower(reference))
  where reference <> '' and status <> 'rejected';

-- Une demande activée ou refusée ne change plus et ne s'efface pas
create or replace function public.subreq_final() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('vl.system', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'DELETE' then
    if old.status in ('activated', 'rejected') then
      raise exception 'Un paiement d''abonnement traité ne s''efface pas.';
    end if;
    return old;
  end if;
  if old.status in ('activated', 'rejected') then
    -- compte du déclarant supprimé (clé étrangère « on delete set null ») : seul created_by passe à vide
    if new.created_by is null and old.created_by is not null
       and (to_jsonb(new) - 'created_by') = (to_jsonb(old) - 'created_by') then
      return new;
    end if;
    raise exception 'Un paiement d''abonnement traité ne se modifie plus.';
  end if;
  return new;
end $$;
revoke execute on function public.subreq_final() from public, anon, authenticated;
drop trigger if exists subreq_final on public.subscription_requests;
create trigger subreq_final before update or delete on public.subscription_requests
  for each row execute function public.subreq_final();

-- 4. L'offre se change par VillageLink seulement (ajout : founder, founder_used)
create or replace function public.associations_guard() returns trigger
language plpgsql set search_path = public as $$
declare sys boolean := coalesce(current_setting('vl.system', true), '') = 'on';
begin
  -- Compte du créateur supprimé (clé étrangère « on delete set null ») : seul created_by passe à vide.
  if new.created_by is null and old.created_by is not null
     and (to_jsonb(new) - 'created_by') = (to_jsonb(old) - 'created_by') then
    return new;
  end if;
  if new.invite_code <> old.invite_code and not sys then
    raise exception 'Le code d''invitation se change avec la fonction prévue.';
  end if;
  if (new.plan <> old.plan or new.trial_ends is distinct from old.trial_ends or new.paid_until is distinct from old.paid_until
      or new.blocked_at is distinct from old.blocked_at or new.blocked_reason is distinct from old.blocked_reason
      or new.founder is distinct from old.founder or new.founder_used is distinct from old.founder_used) and not sys then
    raise exception 'L''offre se change par VillageLink.';
  end if;
  if (new.cover_path is distinct from old.cover_path or new.created_by is distinct from old.created_by) and not sys then
    raise exception 'La photo de couverture et le créateur de l''association se changent avec les fonctions prévues.';
  end if;
  if old.blocked_at is not null and not sys then
    raise exception 'Association suspendue par VillageLink : elle ne peut plus être modifiée. Écrivez à contact@villagelinkafrica.com.'
      using errcode = '42501';
  end if;
  if new.currency <> old.currency and not sys
     and (exists (select 1 from transactions where association_id = old.id)
       or exists (select 1 from expense_requests where association_id = old.id)
       or exists (select 1 from payment_claims where association_id = old.id)
       or exists (select 1 from collections where association_id = old.id)
       or exists (select 1 from projects where association_id = old.id)) then
    raise exception 'La monnaie ne peut plus changer : l''association a déjà des montants enregistrés dans cette monnaie.';
  end if;
  return new;
end $$;

-- 5. Grille : un seul endroit pour les formules et les prix (FCFA)
create or replace function public.tier_for(n int) returns text
language sql immutable set search_path = public as $$
  select case when n is null or n < 0 then null
              when n <= 30 then 'petite' when n <= 100 then 'moyenne' when n <= 300 then 'grande'
              else 'devis' end $$;

create or replace function public.plan_price(p_plan text, p_months int, p_founder boolean default false) returns bigint
language plpgsql immutable set search_path = public as $$
declare base bigint;
begin
  base := case p_plan when 'petite' then 2000 when 'moyenne' then 5000 when 'grande' then 10000 end;
  if base is null then raise exception 'Formule invalide.'; end if;
  if p_months = 1 then return base;
  elsif p_months = 12 then return case when p_founder then base * 5 else base * 10 end;  -- 10 mois payés ; moitié prix si fondatrice
  else raise exception 'Durée invalide.'; end if;
end $$;
revoke execute on function public.tier_for(int) from public, anon;
revoke execute on function public.plan_price(text, int, boolean) from public, anon;
grant execute on function public.tier_for(int) to authenticated;
grant execute on function public.plan_price(text, int, boolean) to authenticated;

-- Devis calculé par le serveur : formule d'après le nombre de membres actifs et validés, prix, remise fondatrice
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
  if t = 'devis' then
    return jsonb_build_object('members', n, 'plan', 'devis', 'months', p_months, 'amount', null, 'discounted', false);
  end if;
  disc := coalesce(a.founder, false) and not coalesce(a.founder_used, false) and p_months = 12;
  return jsonb_build_object('members', n, 'plan', t, 'months', p_months, 'amount', plan_price(t, p_months, disc), 'discounted', disc);
end $$;
revoke execute on function public.sub_quote(uuid, int) from public, anon;
grant execute on function public.sub_quote(uuid, int) to authenticated;

-- 6. Déclarer un paiement : le serveur choisit la formule et calcule le montant attendu
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
    initcap(t), case p_months when 12 then '1 an' else '1 mois' end, fmt_money(p_amount, 'XOF'),
    case when ref <> '' then ' (réf. ' || ref || ')' else '' end));
  return nid;
end $$;

-- 7. Propriétaire de VillageLink : états de la demande, activation, refus, fondatrices
create or replace function public.owner_set_request_status(p_request bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare r subscription_requests;
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  if p_status not in ('verifying','confirmed') then raise exception 'État invalide.'; end if;
  select * into r from subscription_requests where id = p_request for update;
  if r.id is null or r.status not in ('pending','verifying') then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if p_status = 'verifying' and r.status <> 'pending' then raise exception 'Cette demande est déjà en vérification.'; end if;
  if p_status = 'confirmed' and r.expected_amount is not null and r.amount < r.expected_amount then
    raise exception 'Montant insuffisant : % reçu, % attendu.', fmt_money(r.amount, 'XOF'), fmt_money(r.expected_amount, 'XOF');
  end if;
  update subscription_requests set status = p_status where id = r.id;
end $$;

-- p_until est gardé pour la compatibilité avec l'app actuelle : il est ignoré. La date de fin est calculée ici.
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
    initcap(case r.plan when 'association' then 'moyenne' when 'federation' then 'grande' else r.plan end), to_char(en, 'DD/MM/YYYY')));
  perform set_config('vl.system', '', true);
end $$;

create or replace function public.owner_reject(p_request bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare r subscription_requests; why text := trim(coalesce(p_note, ''));
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  select * into r from subscription_requests where id = p_request for update;
  if r.id is null or r.status not in ('pending','verifying','confirmed') then raise exception 'Demande introuvable ou déjà traitée.'; end if;
  if length(why) < 3 then raise exception 'Indiquez le motif.'; end if;
  update subscription_requests set status = 'rejected', decided_at = now(), note = left(why, 200) where id = r.id;
  insert into activity_log(association_id, actor_id, actor_label, message)
  values (r.association_id, null, 'VillageLink', format('n’a pas pu valider le paiement de l’abonnement. Motif : %s', why));
end $$;

create or replace function public.owner_set_founder(p_assoc uuid, p_value boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  if p_value is null then raise exception 'Valeur invalide.'; end if;
  perform pg_advisory_xact_lock(hashtext('founders'));
  if p_value and (select count(*) from associations where founder and id <> p_assoc) >= 10 then
    raise exception 'Les 10 places d’association fondatrice sont prises.';
  end if;
  perform set_config('vl.system', 'on', true);
  update associations set founder = p_value where id = p_assoc;
  perform set_config('vl.system', '', true);
end $$;

create or replace function public.owner_subscriptions() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  return jsonb_build_object(
    'requests', coalesce((select jsonb_agg(row_to_json(x) order by x.id) from (
        select r.*, a.name as assoc_name from subscription_requests r join associations a on a.id = r.association_id
        where r.status in ('pending','verifying','confirmed')) x), '[]'::jsonb),
    'assocs', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'plan', a.plan,
        'trial_ends', a.trial_ends, 'paid_until', a.paid_until, 'status', assoc_status(a.id),
        'blocked_reason', a.blocked_reason, 'founder', a.founder, 'founder_used', a.founder_used,
        'members', (select count(*) from members m where m.association_id = a.id and m.active and not m.pending),
        'tier', tier_for((select count(*)::int from members m where m.association_id = a.id and m.active and not m.pending)))
        order by coalesce(a.paid_until, a.trial_ends)) from associations a), '[]'::jsonb));
end $$;

revoke execute on function public.owner_set_request_status(bigint, text) from public, anon;
revoke execute on function public.owner_set_founder(uuid, boolean) from public, anon;
revoke execute on function public.owner_activate(bigint, date) from public, anon;
grant execute on function public.owner_set_request_status(bigint, text) to authenticated;
grant execute on function public.owner_set_founder(uuid, boolean) to authenticated;
grant execute on function public.owner_activate(bigint, date) to authenticated;

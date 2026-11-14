-- v2.2.11 : quatre corrections trouvées par la relecture de l'agent database-architect (14/11/2026).
--
-- (1) Une catégorie de cotisation déjà utilisée ne peut plus être supprimée : sa suppression
--     effaçait son historique de montants et recalculait les mois déjà payés au tarif général.
-- (2) La caisse ne peut plus passer sous zéro : toute sortie (dépense directe ou dépense approuvée)
--     est refusée si elle dépasse le solde. Un verrou par association fait passer deux sorties
--     simultanées l'une après l'autre. Les contre-écritures (corrections) restent permises.
-- (3) Colonnes « système » de associations : cover_path et created_by ne changent plus que par les
--     fonctions prévues ; une association suspendue ne se modifie plus.
-- (4) Une association suspendue (ou en lecture seule) ne reçoit plus de messages, présences,
--     sections, catégories, votes ni nouveaux numéros de paiement.
-- (+) Limite de 50 membres comptée sous verrou et de la même façon partout (actifs et validés) ;
--     anciennes contraintes « NOT VALID » validées (toutes les lignes existantes les respectent).

set lock_timeout = '5s';
set statement_timeout = '60s';

-- ---------------------------------------------------------------------
-- (1) Catégorie déjà utilisée : suppression refusée
-- ---------------------------------------------------------------------
create or replace function public.member_categories_in_use() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('vl.system', true), '') = 'on' then return old; end if;
  -- Suppression de toute l'association (cascade) : l'association n'existe déjà plus, on laisse faire.
  if not exists (select 1 from associations where id = old.association_id) then return old; end if;
  if exists (select 1 from member_category_history where category_id = old.id) then
    raise exception 'La catégorie « % » a déjà servi pour des cotisations : la supprimer changerait le montant des mois passés. Laissez-la sans membres à la place.', old.name
      using errcode = '23503';
  end if;
  return old;
end $$;
revoke execute on function public.member_categories_in_use() from public, anon, authenticated;
drop trigger if exists a_member_categories_in_use on public.member_categories;
-- « a_ » : passe avant member_categories_release (les déclencheurs passent par ordre alphabétique).
create trigger a_member_categories_in_use before delete on public.member_categories
  for each row execute function public.member_categories_in_use();

-- ---------------------------------------------------------------------
-- (2) Caisse : jamais sous zéro
-- ---------------------------------------------------------------------
create or replace function public.tx_balance_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare bal bigint; cur text;
begin
  if new.kind <> 'out' or new.reversal_of is not null then return new; end if;
  perform pg_advisory_xact_lock(hashtext('caisse|' || new.association_id::text));
  select coalesce(sum(amount) filter (where kind = 'in'), 0) - coalesce(sum(amount) filter (where kind = 'out'), 0)
    into bal from transactions where association_id = new.association_id;
  if new.amount > bal then
    select currency into cur from associations where id = new.association_id;
    raise exception 'Solde insuffisant : la caisse contient %. Enregistrez d''abord les recettes.', fmt_money(bal, cur)
      using errcode = '23514';
  end if;
  return new;
end $$;
revoke execute on function public.tx_balance_check() from public, anon, authenticated;
drop trigger if exists tx_balance_check on public.transactions;
create trigger tx_balance_check before insert on public.transactions
  for each row execute function public.tx_balance_check();

-- ---------------------------------------------------------------------
-- (3) Colonnes système et association suspendue
-- ---------------------------------------------------------------------
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
      or new.blocked_at is distinct from old.blocked_at or new.blocked_reason is distinct from old.blocked_reason) and not sys then
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

create or replace function public.set_cover(p_assoc uuid, p_path text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(p_assoc, array['president','vice_president','secretaire']) then
    raise exception 'Réservé au président, au vice-président et au secrétaire.';
  end if;
  if assoc_status(p_assoc) in ('blocked','readonly') then raise exception 'L''association est en lecture seule.'; end if;
  if p_path is not null and (left(p_path, length(p_assoc::text) + 1) <> p_assoc::text || '/' or p_path like '%..%') then
    raise exception 'Chemin de photo invalide.';
  end if;
  perform set_config('vl.system', 'on', true);
  update associations set cover_path = p_path where id = p_assoc;
  perform set_config('vl.system', 'off', true);
end $$;

-- ---------------------------------------------------------------------
-- (4) Association suspendue ou en lecture seule : plus d'écriture
-- ---------------------------------------------------------------------
drop trigger if exists zz_subscription on public.messages;
create trigger zz_subscription before insert on public.messages
  for each row execute function public.enforce_subscription();
drop trigger if exists zz_subscription on public.meeting_attendance;
create trigger zz_subscription before insert on public.meeting_attendance
  for each row execute function public.enforce_subscription();
drop trigger if exists zz_subscription on public.sections;
create trigger zz_subscription before insert on public.sections
  for each row execute function public.enforce_subscription();
drop trigger if exists zz_subscription on public.member_categories;
create trigger zz_subscription before insert on public.member_categories
  for each row execute function public.enforce_subscription();

-- Message commun (mêmes textes que enforce_subscription).
create or replace function public.assert_writable(p_assoc uuid) returns void
language plpgsql stable security definer set search_path = public as $$
declare st text := assoc_status(p_assoc); why text;
begin
  if st = 'blocked' then
    select blocked_reason into why from associations where id = p_assoc;
    raise exception 'Association suspendue par VillageLink : %. Écrivez à contact@villagelinkafrica.com.', coalesce(why, 'contactez VillageLink') using errcode = '42501';
  elsif st = 'readonly' then
    raise exception 'L’essai gratuit de VillageLink est terminé : l’association est en lecture seule. Le président peut activer l’abonnement dans Plus → Abonnement.' using errcode = '42501';
  end if;
end $$;
revoke execute on function public.assert_writable(uuid) from public, anon, authenticated;

create or replace function public.cast_vote(p_poll uuid, p_option uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p polls; mid uuid;
begin
  select * into p from polls where id = p_poll;
  if p.id is null or not is_member(p.association_id) then raise exception 'Vote introuvable.'; end if;
  perform assert_writable(p.association_id);
  if p.status <> 'Ouvert' or (p.closes_at is not null and p.closes_at <= now()) then raise exception 'Ce vote est clos.'; end if;
  if not exists (select 1 from poll_options where id = p_option and poll_id = p_poll) then raise exception 'Choix inconnu.'; end if;
  select id into mid from members where association_id = p.association_id and user_id = auth.uid() and active and not pending limit 1;
  if mid is null then raise exception 'Seuls les membres validés peuvent voter.'; end if;
  insert into poll_votes(poll_id, member_id, option_id, association_id) values (p_poll, mid, p_option, p.association_id)
  on conflict (poll_id, member_id) do update set option_id = excluded.option_id, voted_at = now();
end $$;

create or replace function public.set_pay_numbers(p_assoc uuid, p_holder text, p_wave text, p_orange text, p_free text) returns void
language plpgsql security definer set search_path = public as $$
declare h text := trim(coalesce(p_holder, '')); w text := trim(coalesce(p_wave, '')); o text := trim(coalesce(p_orange, '')); f text := trim(coalesce(p_free, ''));
begin
  if not has_role(p_assoc, array['president','tresorier']) then
    raise exception 'Seuls le président et le trésorier changent les numéros de paiement.';
  end if;
  perform assert_writable(p_assoc);
  if (w <> '' or o <> '' or f <> '') and length(h) < 2 then
    raise exception 'Indiquez le nom qui s''affiche chez Wave ou Orange Money pour ces numéros.';
  end if;
  insert into pay_numbers(association_id, holder, wave, orange, free, updated_by, updated_at)
  values (p_assoc, h, w, o, f, auth.uid(), now())
  on conflict (association_id) do update set holder = excluded.holder, wave = excluded.wave, orange = excluded.orange,
    free = excluded.free, updated_by = excluded.updated_by, updated_at = now();
  perform write_log(p_assoc, format('a changé les numéros de paiement mobile money : Wave %s, Orange Money %s, Free Money %s (au nom de %s).',
    coalesce(nullif(w, ''), 'aucun'), coalesce(nullif(o, ''), 'aucun'), coalesce(nullif(f, ''), 'aucun'), coalesce(nullif(h, ''), '—')));
end $$;

-- ---------------------------------------------------------------------
-- (+) Limite de 50 membres : sous verrou, même comptage partout (actifs et validés)
-- ---------------------------------------------------------------------
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
    perform pg_advisory_xact_lock(hashtext('cap|' || new.association_id::text));
    if (select count(*) from members m where m.association_id = new.association_id and m.active and not m.pending) >= 50 then
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

create or replace function public.members_plan_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not (new.active and not new.pending and (not old.active or old.pending)) then return new; end if;
  if (select plan from associations where id = new.association_id) is distinct from 'association' then return new; end if;
  perform pg_advisory_xact_lock(hashtext('cap|' || new.association_id::text));
  if (select count(*) from members m where m.association_id = new.association_id
        and m.active and not m.pending and m.id <> new.id) >= 50 then
    raise exception 'La formule Village est limitée à 50 membres. Passez à la formule Diaspora (Plus → Abonnement).' using errcode = '42501';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- (+) Anciennes contraintes validées (vérifié avant : toutes les lignes les respectent)
-- ---------------------------------------------------------------------
alter table public.associations validate constraint associations_len;
alter table public.members validate constraint members_len;
alter table public.projects validate constraint projects_len;
alter table public.transactions validate constraint transactions_len;
alter table public.transactions validate constraint transactions_kind_category;
alter table public.transactions validate constraint transactions_fx;
alter table public.expense_requests validate constraint expense_requests_fx;

reset statement_timeout;
reset lock_timeout;

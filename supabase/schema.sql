-- =====================================================================
-- VillageLink — schéma de base de données (Supabase / PostgreSQL 15+)
-- À coller une seule fois dans Supabase > SQL Editor > New query > Run.
--
-- Principes :
--  * chaque ligne appartient à une association ; un utilisateur ne voit
--    que les associations dont il est membre (Row Level Security) ;
--  * le registre financier ne se modifie jamais : on ajoute, on n'efface
--    pas ; une erreur se corrige par une contre-écriture ;
--  * chaque action importante écrit une ligne dans le journal d'activité.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table if not exists public.associations (
  id                uuid primary key default gen_random_uuid(),
  name              text not null check (length(trim(name)) between 3 and 140),
  origin_country    text not null default '',
  region            text not null default '',
  prefecture        text not null default '',
  village           text not null default '',
  residence_country text not null default '',
  residence_city    text not null default '',
  description       text not null default '',
  founded_on        date,
  currency          text not null default 'XOF' check (currency in ('XOF','GNF','EUR','USD','XAF','CAD','GBP')),
  fee_amount        bigint not null default 0 check (fee_amount >= 0),
  fee_due_day       int not null default 5 check (fee_due_day between 1 and 28),
  dues_start        date not null default date_trunc('month', now())::date,
  invite_code       text not null unique default upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  plan              text not null default 'decouverte' check (plan in ('decouverte','association','federation')),
  created_by        uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now()
);

create table if not exists public.members (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  user_id         uuid references auth.users(id) on delete set null,
  full_name       text not null check (length(trim(full_name)) between 2 and 120),
  phone           text not null default '',
  email           text not null default '',
  city            text not null default '',
  country         text not null default '',
  role            text not null default 'membre'
                  check (role in ('president','vice_president','secretaire','tresorier','projets','membre')),
  joined_on       date not null default current_date,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);
create unique index if not exists members_assoc_user_uniq
  on public.members(association_id, user_id) where user_id is not null;
create index if not exists members_assoc_idx on public.members(association_id);

create table if not exists public.projects (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  name            text not null check (length(trim(name)) between 3 and 140),
  type            text not null default 'Autre',
  description     text not null default '',
  goal            bigint not null check (goal > 0),
  lead_member_id  uuid references public.members(id) on delete set null,
  status          text not null default 'En préparation'
                  check (status in ('En préparation','En cours','Suspendu','Terminé')),
  start_on        date not null default current_date,
  end_on          date,
  created_by      uuid references auth.users(id) on delete set null default auth.uid(),
  created_at      timestamptz not null default now()
);
create index if not exists projects_assoc_idx on public.projects(association_id);

create table if not exists public.transactions (
  id              bigint generated always as identity primary key,
  association_id  uuid not null references public.associations(id) on delete cascade,
  kind            text not null check (kind in ('in','out')),
  category        text not null check (category in (
                    'Cotisations','Dons','Contributions exceptionnelles',
                    'Projet','Transport','Réunion','Communication','Administration','Autres')),
  amount          bigint not null check (amount <> 0),
  occurred_on     date not null default current_date,
  description     text not null check (length(trim(description)) between 2 and 300),
  member_id       uuid references public.members(id) on delete restrict,
  period          text check (period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  project_id      uuid references public.projects(id) on delete restrict,
  payment_method  text not null default '',
  comment         text not null default '',
  proof_path      text not null default '',
  reversal_of     bigint unique references public.transactions(id) on delete restrict,
  created_by      uuid references auth.users(id) on delete set null default auth.uid(),
  created_at      timestamptz not null default now(),
  constraint cotisation_has_member check (category <> 'Cotisations' or (member_id is not null and period is not null))
);
create index if not exists tx_assoc_idx on public.transactions(association_id, occurred_on desc, id desc);
create index if not exists tx_member_idx on public.transactions(member_id, period);
create index if not exists tx_project_idx on public.transactions(project_id);

create table if not exists public.project_updates (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  project_id      uuid not null references public.projects(id) on delete cascade,
  body            text not null check (length(trim(body)) between 2 and 2000),
  created_by      uuid references auth.users(id) on delete set null default auth.uid(),
  created_at      timestamptz not null default now()
);

create table if not exists public.announcements (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  kind            text not null default 'Annonce'
                  check (kind in ('Annonce','Information','Convocation','Nouvelles du village','Urgence')),
  title           text not null check (length(trim(title)) between 2 and 160),
  body            text not null check (length(trim(body)) between 2 and 4000),
  created_by      uuid references auth.users(id) on delete set null default auth.uid(),
  created_at      timestamptz not null default now()
);

create table if not exists public.activity_log (
  id              bigint generated always as identity primary key,
  association_id  uuid not null references public.associations(id) on delete cascade,
  actor_id        uuid,
  actor_label     text not null default '',
  message         text not null,
  created_at      timestamptz not null default now()
);
create index if not exists log_assoc_idx on public.activity_log(association_id, id desc);

-- ---------------------------------------------------------------------
-- Durcissement (version 1.1). Rejouable sur une base déjà créée.
-- ---------------------------------------------------------------------

-- Une adhésion par code reste « en attente » jusqu'à validation par le bureau.
alter table public.members add column if not exists pending boolean not null default false;
alter table public.members add column if not exists created_by_join boolean not null default false;

-- Tailles maximales (évite qu'on remplisse la base de textes géants).
alter table public.associations drop constraint if exists associations_len;
alter table public.associations add constraint associations_len check (
  length(origin_country) <= 80 and length(region) <= 80 and length(prefecture) <= 80 and length(village) <= 120
  and length(residence_country) <= 80 and length(residence_city) <= 80 and length(description) <= 2000
  and fee_amount <= 1000000000) not valid;
alter table public.members drop constraint if exists members_len;
alter table public.members add constraint members_len check (
  length(phone) <= 40 and length(email) <= 160 and length(city) <= 80 and length(country) <= 80) not valid;
alter table public.projects drop constraint if exists projects_len;
alter table public.projects add constraint projects_len check (
  length(type) <= 60 and length(description) <= 4000 and goal <= 1000000000000) not valid;
alter table public.transactions drop constraint if exists transactions_len;
alter table public.transactions add constraint transactions_len check (
  length(payment_method) <= 40 and length(comment) <= 500 and length(proof_path) <= 300
  and abs(amount) <= 1000000000000) not valid;

-- Une recette n'a que des catégories de recette, une dépense que des catégories de dépense.
-- (Sinon une « dépense » classée Cotisations compterait comme une cotisation payée.)
alter table public.transactions drop constraint if exists transactions_kind_category;
alter table public.transactions add constraint transactions_kind_category check (
  (kind = 'in'  and category in ('Cotisations','Dons','Contributions exceptionnelles','Autres')) or
  (kind = 'out' and category in ('Projet','Transport','Réunion','Communication','Administration','Autres'))) not valid;

-- ---------------------------------------------------------------------
-- Fonctions d'aide (SECURITY DEFINER : elles lisent members sans RLS)
-- ---------------------------------------------------------------------

create or replace function public.is_member(assoc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members m
                 where m.association_id = assoc and m.user_id = auth.uid() and m.active and not m.pending);
$$;

create or replace function public.has_role(assoc uuid, roles text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members m
                 where m.association_id = assoc and m.user_id = auth.uid()
                   and m.active and not m.pending and m.role = any(roles));
$$;

create or replace function public.actor_label(assoc uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select m.full_name || ' (' || case m.role
        when 'president' then 'président'
        when 'vice_president' then 'vice-président'
        when 'secretaire' then 'secrétaire général'
        when 'tresorier' then 'trésorier'
        when 'projets' then 'responsable des projets'
        else 'membre' end || ')'
     from members m where m.association_id = assoc and m.user_id = auth.uid() limit 1),
    'Système');
$$;

create or replace function public.fmt_money(amount bigint, cur text) returns text
language sql immutable as $$
  select replace(to_char(abs(amount), 'FM999,999,999,999,990'), ',', ' ') || ' ' ||
         case cur when 'XOF' then 'FCFA' when 'XAF' then 'FCFA' when 'GNF' then 'GNF' else cur end;
$$;

create or replace function public.write_log(assoc uuid, msg text) returns void
language sql security definer set search_path = public as $$
  insert into activity_log(association_id, actor_id, actor_label, message)
  values (assoc, auth.uid(), actor_label(assoc), msg);
$$;
revoke execute on function public.write_log(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Règles d'intégrité (triggers)
-- ---------------------------------------------------------------------

-- Registre et journal : jamais de modification ni de suppression.
create or replace function public.forbid_change() returns trigger
language plpgsql as $$
begin
  raise exception 'Cette ligne est définitive. Corrigez par une contre-écriture.' using errcode = '42501';
end $$;

drop trigger if exists tx_no_update on public.transactions;
create trigger tx_no_update before update or delete on public.transactions
  for each row execute function public.forbid_change();
drop trigger if exists log_no_update on public.activity_log;
create trigger log_no_update before update or delete on public.activity_log
  for each row execute function public.forbid_change();

-- Une opération ne peut viser qu'un membre ou un projet de la même association,
-- et une contre-écriture ne passe que par reverse_transaction().
create or replace function public.tx_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.member_id is not null and not exists
     (select 1 from members where id = new.member_id and association_id = new.association_id) then
    raise exception 'Membre inconnu dans cette association.';
  end if;
  if new.project_id is not null and not exists
     (select 1 from projects where id = new.project_id and association_id = new.association_id) then
    raise exception 'Projet inconnu dans cette association.';
  end if;
  if new.proof_path <> '' and (new.proof_path not like new.association_id::text || '/%' or new.proof_path like '%..%') then
    raise exception 'Justificatif invalide.';
  end if;
  if new.reversal_of is null and new.amount <= 0 then
    raise exception 'Le montant doit être supérieur à 0.';
  end if;
  if new.reversal_of is not null and coalesce(current_setting('vl.reversing', true), '') <> 'on' then
    raise exception 'Une contre-écriture passe par la fonction prévue.';
  end if;
  new.created_by := auth.uid();
  new.created_at := now();
  return new;
end $$;
drop trigger if exists tx_check on public.transactions;
create trigger tx_check before insert on public.transactions
  for each row execute function public.tx_check();

create or replace function public.tx_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur text; who text;
begin
  select currency into cur from associations where id = new.association_id;
  if new.reversal_of is not null then
    perform write_log(new.association_id, format('a annulé l''opération TX-%s (%s) par contre-écriture. Motif : %s',
      lpad(new.reversal_of::text, 5, '0'), fmt_money(new.amount, cur), new.comment));
  elsif new.category = 'Cotisations' then
    select full_name into who from members where id = new.member_id;
    perform write_log(new.association_id, format('a enregistré une cotisation de %s de %s (%s).',
      fmt_money(new.amount, cur), who, new.period));
  else
    perform write_log(new.association_id, format('a enregistré %s de %s : %s.',
      case new.kind when 'in' then 'une recette' else 'une dépense' end,
      fmt_money(new.amount, cur), new.description));
  end if;
  return null;
end $$;
drop trigger if exists tx_log on public.transactions;
create trigger tx_log after insert on public.transactions
  for each row execute function public.tx_log();

-- Membres : seul le président attribue les rôles ; on garde toujours un président ;
-- l'association et le compte lié ne changent pas par une simple modification.
create or replace function public.members_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('vl.system', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.role <> 'membre' and not has_role(new.association_id, array['president']) then
      raise exception 'Seul le président attribue un rôle du bureau.';
    end if;
    new.user_id := null;           -- un compte se relie par le code d'invitation, pas à la main
    new.pending := false;
    new.created_by_join := false;
    return new;
  end if;
  if new.association_id <> old.association_id then
    raise exception 'Un membre ne change pas d''association.';
  end if;
  if new.user_id is distinct from old.user_id or new.pending <> old.pending
     or new.created_by_join <> old.created_by_join then
    raise exception 'Le compte lié et l''adhésion se gèrent avec les fonctions prévues.';
  end if;
  -- Seul le président touche à la fiche d'un membre du bureau ou donne un rôle.
  if (old.role <> 'membre' or new.role <> 'membre') and not has_role(new.association_id, array['president']) then
    raise exception 'Seul le président modifie la fiche d''un membre du bureau.';
  end if;
  if new.role <> old.role and old.role = 'president' and not exists (
     select 1 from members where association_id = old.association_id
       and role = 'president' and active and not pending and id <> old.id) then
    raise exception 'L''association doit garder un président. Nommez-en un autre d''abord.';
  end if;
  if old.role = 'president' and old.active and not new.active and not exists (
     select 1 from members where association_id = old.association_id
       and role = 'president' and active and not pending and id <> old.id) then
    raise exception 'L''association doit garder un président actif.';
  end if;
  return new;
end $$;
drop trigger if exists members_guard on public.members;
create trigger members_guard before insert or update on public.members
  for each row execute function public.members_guard();

create or replace function public.members_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('vl.system', true), '') = 'on' then return null; end if;
  if tg_op = 'INSERT' then
    perform write_log(new.association_id, format('a ajouté %s comme membre.', new.full_name));
  elsif new.role <> old.role then
    perform write_log(new.association_id, format('a changé le rôle de %s.', new.full_name));
  elsif new.active <> old.active then
    perform write_log(new.association_id, case when new.active
      then format('a réintégré %s dans l''association.', new.full_name)
      else format('a retiré %s de l''association.', new.full_name) end);
  end if;
  return null;
end $$;
drop trigger if exists members_log on public.members;
create trigger members_log after insert or update on public.members
  for each row execute function public.members_log();

create or replace function public.content_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur text; pname text;
begin
  if tg_table_name = 'projects' then
    select currency into cur from associations where id = new.association_id;
    if tg_op = 'INSERT' then
      perform write_log(new.association_id, format('a créé le projet « %s » (objectif %s).', new.name, fmt_money(new.goal, cur)));
    elsif new.status <> old.status then
      perform write_log(new.association_id, format('a changé le statut de « %s » : %s → %s.', new.name, old.status, new.status));
    end if;
  elsif tg_table_name = 'project_updates' then
    select name into pname from projects where id = new.project_id;
    perform write_log(new.association_id, format('a publié une mise à jour sur « %s ».', pname));
  elsif tg_table_name = 'announcements' then
    perform write_log(new.association_id, format('a publié l''annonce « %s ».', new.title));
  end if;
  return null;
end $$;
drop trigger if exists projects_log on public.projects;
create trigger projects_log after insert or update on public.projects
  for each row execute function public.content_log();
drop trigger if exists updates_log on public.project_updates;
create trigger updates_log after insert on public.project_updates
  for each row execute function public.content_log();
drop trigger if exists ann_log on public.announcements;
create trigger ann_log after insert on public.announcements
  for each row execute function public.content_log();

create or replace function public.project_update_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from projects where id = new.project_id and association_id = new.association_id) then
    raise exception 'Projet inconnu dans cette association.';
  end if;
  new.created_by := auth.uid();
  return new;
end $$;
drop trigger if exists project_update_check on public.project_updates;
create trigger project_update_check before insert on public.project_updates
  for each row execute function public.project_update_check();

create or replace function public.projects_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.association_id <> old.association_id then
    raise exception 'Un projet ne change pas d''association.';
  end if;
  if new.lead_member_id is not null and not exists
     (select 1 from members where id = new.lead_member_id and association_id = new.association_id) then
    raise exception 'Responsable inconnu dans cette association.';
  end if;
  return new;
end $$;
drop trigger if exists projects_guard on public.projects;
create trigger projects_guard before insert or update on public.projects
  for each row execute function public.projects_guard();

create or replace function public.associations_guard() returns trigger
language plpgsql as $$
begin
  if new.invite_code <> old.invite_code and coalesce(current_setting('vl.system', true), '') <> 'on' then
    raise exception 'Le code d''invitation se change avec la fonction prévue.';
  end if;
  if new.plan <> old.plan and coalesce(current_setting('vl.system', true), '') <> 'on' then
    raise exception 'L''offre se change par VillageLink.';
  end if;
  return new;
end $$;
drop trigger if exists associations_guard on public.associations;
create trigger associations_guard before update on public.associations
  for each row execute function public.associations_guard();

-- ---------------------------------------------------------------------
-- Fonctions appelées par l'application
-- ---------------------------------------------------------------------

-- Créer une association : le créateur en devient président.
create or replace function public.create_association(
  p_name text, p_full_name text, p_phone text,
  p_origin_country text, p_region text, p_prefecture text, p_village text,
  p_residence_country text, p_residence_city text,
  p_currency text, p_fee_amount bigint, p_fee_due_day int
) returns uuid
language plpgsql security definer set search_path = public as $$
declare a uuid;
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if (select count(*) from associations where created_by = auth.uid()) >= 10 then
    raise exception 'Limite de 10 associations créées par compte.';
  end if;
  insert into associations(name, origin_country, region, prefecture, village,
                           residence_country, residence_city, currency, fee_amount, fee_due_day, created_by)
  values (trim(p_name), trim(p_origin_country), trim(p_region), trim(p_prefecture), trim(p_village),
          trim(p_residence_country), trim(p_residence_city), p_currency, greatest(p_fee_amount, 0),
          least(greatest(p_fee_due_day, 1), 28), auth.uid())
  returning id into a;
  perform set_config('vl.system', 'on', true);
  insert into members(association_id, user_id, full_name, phone, city, country, role)
  values (a, auth.uid(), trim(p_full_name), trim(p_phone), trim(p_residence_city), trim(p_residence_country), 'president');
  perform set_config('vl.system', 'off', true);
  perform write_log(a, format('a créé l''association « %s ».', trim(p_name)));
  return a;
end $$;

-- Rejoindre une association avec son code. La demande reste en attente jusqu'à ce
-- qu'un membre du bureau la valide. Si le trésorier avait déjà inscrit la personne
-- (simple membre, même numéro), la fiche existante lui est proposée ; une fiche du
-- bureau n'est jamais reliée automatiquement.
create or replace function public.join_association(p_code text, p_full_name text, p_phone text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare a uuid; m uuid; digits text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if length(trim(coalesce(p_full_name,''))) < 2 then raise exception 'Saisissez votre nom complet.'; end if;
  select id into a from associations where invite_code = upper(trim(p_code));
  if a is null then raise exception 'Code d''invitation inconnu. Vérifiez-le auprès du bureau.'; end if;
  if exists (select 1 from members where association_id = a and user_id = auth.uid()) then
    return a;
  end if;
  perform set_config('vl.system', 'on', true);
  if length(digits) >= 8 then
    select id into m from members
     where association_id = a and user_id is null and role = 'membre' and active
       and right(regexp_replace(phone, '\D', '', 'g'), 9) = right(digits, 9)
     limit 1;
  end if;
  if m is not null then
    update members set user_id = auth.uid(), pending = true where id = m;
  else
    insert into members(association_id, user_id, full_name, phone, role, pending, created_by_join)
    values (a, auth.uid(), left(trim(p_full_name), 120), left(trim(p_phone), 40), 'membre', true, true);
  end if;
  perform set_config('vl.system', 'off', true);
  perform write_log(a, format('a demandé à rejoindre l''association (%s).', left(trim(p_full_name), 120)));
  return a;
end $$;

-- Valider ou refuser une demande d'adhésion (président, secrétaire, trésorier).
create or replace function public.review_join(p_member uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare m members;
begin
  select * into m from members where id = p_member;
  if m.id is null or not has_role(m.association_id, array['president','vice_president','secretaire','tresorier']) then
    raise exception 'Réservé au bureau.';
  end if;
  if not m.pending then raise exception 'Cette demande a déjà été traitée.'; end if;
  perform set_config('vl.system', 'on', true);
  if p_accept then
    update members set pending = false where id = m.id;
  elsif m.created_by_join then
    update members set pending = false, active = false, user_id = null where id = m.id;
  else
    update members set pending = false, user_id = null where id = m.id;
  end if;
  perform set_config('vl.system', 'off', true);
  perform write_log(m.association_id, format('a %s la demande d''adhésion de %s.',
    case when p_accept then 'validé' else 'refusé' end, m.full_name));
end $$;

-- Mes associations, y compris les demandes en attente.
create or replace function public.my_memberships()
returns table(association_id uuid, name text, village text, residence_city text, pending boolean, active boolean)
language sql stable security definer set search_path = public as $$
  select a.id, a.name, a.village, a.residence_city, m.pending, m.active
  from members m join associations a on a.id = m.association_id
  where m.user_id = auth.uid()
  order by a.created_at;
$$;

-- L'auteur d'une annonce ou d'un projet est toujours la personne connectée.
create or replace function public.force_creator() returns trigger
language plpgsql as $$
begin
  new.created_by := auth.uid();
  return new;
end $$;
drop trigger if exists ann_creator on public.announcements;
create trigger ann_creator before insert on public.announcements
  for each row execute function public.force_creator();
drop trigger if exists projects_creator on public.projects;
create trigger projects_creator before insert on public.projects
  for each row execute function public.force_creator();

-- Annuler une opération par contre-écriture (trésorier uniquement).
create or replace function public.reverse_transaction(p_id bigint, p_reason text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare t transactions; new_id bigint;
begin
  select * into t from transactions where id = p_id;
  if t.id is null then raise exception 'Opération introuvable.'; end if;
  if not has_role(t.association_id, array['tresorier']) then
    raise exception 'Seul le trésorier peut annuler une opération.';
  end if;
  if t.reversal_of is not null then raise exception 'Une contre-écriture ne s''annule pas.'; end if;
  if exists (select 1 from transactions where reversal_of = p_id) then
    raise exception 'Cette opération est déjà annulée.';
  end if;
  if length(trim(coalesce(p_reason,''))) < 4 then raise exception 'Indiquez le motif de l''annulation.'; end if;
  perform set_config('vl.reversing', 'on', true);
  insert into transactions(association_id, kind, category, amount, occurred_on, description,
                           member_id, period, project_id, payment_method, comment, reversal_of)
  values (t.association_id, t.kind, t.category, -t.amount, current_date,
          'Contre-écriture de TX-' || lpad(t.id::text, 5, '0'),
          t.member_id, t.period, t.project_id, '', trim(p_reason), t.id)
  returning id into new_id;
  perform set_config('vl.reversing', 'off', true);
  return new_id;
end $$;

-- Nouveau code d'invitation (président).
create or replace function public.regenerate_invite_code(p_assoc uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c text := upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
begin
  if not has_role(p_assoc, array['president']) then raise exception 'Réservé au président.'; end if;
  perform set_config('vl.system', 'on', true);
  update associations set invite_code = c where id = p_assoc;
  perform set_config('vl.system', 'off', true);
  return c;
end $$;

-- ---------------------------------------------------------------------
-- Vues de synthèse (respectent la RLS de l'utilisateur)
-- ---------------------------------------------------------------------

create or replace view public.v_balances with (security_invoker = true) as
  select association_id,
         coalesce(sum(amount) filter (where kind = 'in'), 0)  as total_in,
         coalesce(sum(amount) filter (where kind = 'out'), 0) as total_out
  from transactions group by association_id;

create or replace view public.v_member_paid with (security_invoker = true) as
  select association_id, member_id, period, sum(amount) as paid
  from transactions where category = 'Cotisations'
  group by association_id, member_id, period;

create or replace view public.v_project_totals with (security_invoker = true) as
  select project_id,
         coalesce(sum(amount) filter (where kind = 'in'), 0)  as collected,
         coalesce(sum(amount) filter (where kind = 'out'), 0) as spent
  from transactions where project_id is not null group by project_id;

create or replace view public.v_category_totals with (security_invoker = true) as
  select association_id, kind, category, sum(amount) as total
  from transactions group by association_id, kind, category;

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------

alter table public.associations    enable row level security;
alter table public.members         enable row level security;
alter table public.projects        enable row level security;
alter table public.transactions    enable row level security;
alter table public.project_updates enable row level security;
alter table public.announcements   enable row level security;
alter table public.activity_log    enable row level security;

drop policy if exists assoc_select on public.associations;
create policy assoc_select on public.associations for select to authenticated
  using (is_member(id));
drop policy if exists assoc_update on public.associations;
create policy assoc_update on public.associations for update to authenticated
  using (has_role(id, array['president'])) with check (has_role(id, array['president']));

drop policy if exists members_select on public.members;
create policy members_select on public.members for select to authenticated
  using (is_member(association_id));
drop policy if exists members_insert on public.members;
create policy members_insert on public.members for insert to authenticated
  with check (has_role(association_id, array['president','vice_president','secretaire','tresorier']));
drop policy if exists members_update on public.members;
create policy members_update on public.members for update to authenticated
  using (has_role(association_id, array['president','vice_president','secretaire','tresorier']))
  with check (has_role(association_id, array['president','vice_president','secretaire','tresorier']));

drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects for select to authenticated
  using (is_member(association_id));
drop policy if exists projects_insert on public.projects;
create policy projects_insert on public.projects for insert to authenticated
  with check (has_role(association_id, array['president','vice_president','projets']));
drop policy if exists projects_update on public.projects;
create policy projects_update on public.projects for update to authenticated
  using (has_role(association_id, array['president','vice_president','projets']))
  with check (has_role(association_id, array['president','vice_president','projets']));

drop policy if exists tx_select on public.transactions;
create policy tx_select on public.transactions for select to authenticated
  using (is_member(association_id));
drop policy if exists tx_insert on public.transactions;
create policy tx_insert on public.transactions for insert to authenticated
  with check (
    reversal_of is null and amount > 0 and (
      (kind = 'in'  and has_role(association_id, array['tresorier','president','vice_president'])) or
      (kind = 'out' and has_role(association_id, array['tresorier']))
    ));

drop policy if exists updates_select on public.project_updates;
create policy updates_select on public.project_updates for select to authenticated
  using (is_member(association_id));
drop policy if exists updates_insert on public.project_updates;
create policy updates_insert on public.project_updates for insert to authenticated
  with check (has_role(association_id, array['president','vice_president','projets']));

drop policy if exists ann_select on public.announcements;
create policy ann_select on public.announcements for select to authenticated
  using (is_member(association_id));
drop policy if exists ann_insert on public.announcements;
create policy ann_insert on public.announcements for insert to authenticated
  with check (has_role(association_id, array['president','vice_president','secretaire']));

drop policy if exists log_select on public.activity_log;
create policy log_select on public.activity_log for select to authenticated
  using (is_member(association_id));

-- Droits SQL : rien pour les visiteurs non connectés, le strict nécessaire pour les autres.
-- (Supabase accorde tout par défaut : on retire puis on redonne précisément.)
revoke all on all tables in schema public from anon, authenticated;
grant select on public.associations, public.members, public.projects, public.transactions,
                public.project_updates, public.announcements, public.activity_log,
                public.v_balances, public.v_member_paid, public.v_project_totals,
                public.v_category_totals to authenticated;
grant insert on public.members, public.projects, public.transactions,
                public.project_updates, public.announcements to authenticated;
grant update on public.associations, public.members, public.projects to authenticated;
revoke execute on function public.create_association(text,text,text,text,text,text,text,text,text,text,bigint,int) from public, anon;
revoke execute on function public.join_association(text,text,text) from public, anon;
revoke execute on function public.reverse_transaction(bigint,text) from public, anon;
revoke execute on function public.regenerate_invite_code(uuid) from public, anon;
revoke execute on function public.review_join(uuid,boolean) from public, anon;
revoke execute on function public.my_memberships() from public, anon;
grant execute on function public.review_join(uuid,boolean) to authenticated;
grant execute on function public.my_memberships() to authenticated;
grant execute on function public.create_association(text,text,text,text,text,text,text,text,text,text,bigint,int) to authenticated;
grant execute on function public.join_association(text,text,text) to authenticated;
grant execute on function public.reverse_transaction(bigint,text) to authenticated;
grant execute on function public.regenerate_invite_code(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Stockage des justificatifs (bucket privé « proofs »)
-- Chemin d'un fichier : <id de l'association>/<nom>.jpg
-- ---------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('proofs', 'proofs', false, 5242880,
            array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
    on conflict (id) do nothing;

    execute 'drop policy if exists proofs_read on storage.objects';
    execute $p$create policy proofs_read on storage.objects for select to authenticated
      using (bucket_id = 'proofs' and public.is_member(((storage.foldername(name))[1])::uuid))$p$;
    execute 'drop policy if exists proofs_write on storage.objects';
    execute $p$create policy proofs_write on storage.objects for insert to authenticated
      with check (bucket_id = 'proofs'
        and public.has_role(((storage.foldername(name))[1])::uuid, array['tresorier','president','vice_president']))$p$;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Discussion (version 1.2)
-- ---------------------------------------------------------------------
-- VillageLink 1.2 : espace Discussion (messages, idées, réclamations)
create table if not exists public.messages (
  id              bigint generated always as identity primary key,
  association_id  uuid not null references public.associations(id) on delete cascade,
  kind            text not null default 'Message' check (kind in ('Message','Idée','Réclamation')),
  body            text not null check (length(trim(body)) between 1 and 1000),
  author_id       uuid default auth.uid(),
  author_label    text not null default '',
  hidden          boolean not null default false,
  hidden_by       text not null default '',
  created_at      timestamptz not null default now()
);
create index if not exists messages_assoc_idx on public.messages(association_id, id desc);
create or replace function public.messages_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.author_id := auth.uid();
  new.author_label := actor_label(new.association_id);
  new.hidden := false;
  new.hidden_by := '';
  new.created_at := now();
  return new;
end $$;
drop trigger if exists messages_check on public.messages;
create trigger messages_check before insert on public.messages
  for each row execute function public.messages_check();
create or replace function public.hide_message(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare m messages;
begin
  select * into m from messages where id = p_id;
  if m.id is null or not is_member(m.association_id) then raise exception 'Message introuvable.'; end if;
  if m.author_id is distinct from auth.uid() and not has_role(m.association_id, array['president','vice_president','secretaire']) then
    raise exception 'Seuls l''auteur, le président, le vice-président ou le secrétaire peuvent masquer un message.';
  end if;
  update messages set hidden = true, body = 'Message masqué', hidden_by = actor_label(m.association_id) where id = p_id;
  if m.author_id is distinct from auth.uid() then
    perform write_log(m.association_id, format('a masqué un message de %s dans la discussion.', m.author_label));
  end if;
end $$;
alter table public.messages enable row level security;
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated using (is_member(association_id));
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated with check (is_member(association_id));
revoke all on public.messages from anon, authenticated;
grant select, insert on public.messages to authenticated;
revoke execute on function public.hide_message(bigint) from public, anon;
grant execute on function public.hide_message(bigint) to authenticated;

-- ---------------------------------------------------------------------
-- Réunions (version 1.4) : convocation, présence, compte rendu
-- Le président, le vice-président et le secrétaire gèrent les réunions ;
-- tous les membres validés les voient.
-- ---------------------------------------------------------------------
create table if not exists public.meetings (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  title           text not null check (length(trim(title)) between 2 and 160),
  starts_at       timestamptz not null,
  place           text not null default '' check (length(place) <= 200),
  agenda          text not null default '' check (length(agenda) <= 4000),
  status          text not null default 'Prévue' check (status in ('Prévue','Tenue','Annulée')),
  minutes         text not null default '' check (length(minutes) <= 20000),
  created_by      uuid default auth.uid(),
  created_label   text not null default '',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists meetings_assoc_idx on public.meetings(association_id, starts_at desc);

create table if not exists public.meeting_attendance (
  meeting_id      uuid not null references public.meetings(id) on delete cascade,
  member_id       uuid not null references public.members(id) on delete cascade,
  association_id  uuid not null references public.associations(id) on delete cascade,
  present         boolean not null,
  marked_by       text not null default '',
  marked_at       timestamptz not null default now(),
  primary key (meeting_id, member_id)
);
create index if not exists attendance_assoc_idx on public.meeting_attendance(association_id);

-- Auteur et dates toujours fixés par la base ; l'association d'une réunion ne change pas.
create or replace function public.meetings_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.created_label := actor_label(new.association_id);
    new.created_at := now();
  else
    new.association_id := old.association_id;
    new.created_by := old.created_by;
    new.created_label := old.created_label;
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists meetings_guard on public.meetings;
create trigger meetings_guard before insert or update on public.meetings
  for each row execute function public.meetings_guard();

create or replace function public.meetings_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare d text := to_char(new.starts_at at time zone 'UTC', 'DD/MM/YYYY');
begin
  if tg_op = 'INSERT' then
    perform write_log(new.association_id, format('a convoqué la réunion « %s » du %s.', new.title, d));
    return new;
  end if;
  if new.status <> old.status then
    perform write_log(new.association_id, format('a marqué la réunion « %s » comme %s.', new.title,
      case new.status when 'Tenue' then 'tenue' when 'Annulée' then 'annulée' else 'prévue' end));
  end if;
  if new.minutes <> old.minutes and new.minutes <> '' then
    perform write_log(new.association_id, format('a %s le compte rendu de la réunion « %s ».',
      case when old.minutes = '' then 'publié' else 'modifié' end, new.title));
  end if;
  if new.starts_at <> old.starts_at or new.place <> old.place or new.title <> old.title or new.agenda <> old.agenda then
    perform write_log(new.association_id, format('a modifié la convocation de la réunion « %s » (nouvelle date : %s).', new.title, d));
  end if;
  return new;
end $$;
drop trigger if exists meetings_log on public.meetings;
create trigger meetings_log after insert or update on public.meetings
  for each row execute function public.meetings_log();

-- Présence : le membre et la réunion doivent être de la même association.
create or replace function public.attendance_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare assoc uuid;
begin
  select association_id into assoc from meetings where id = new.meeting_id;
  if assoc is null then raise exception 'Réunion introuvable.'; end if;
  if not exists (select 1 from members where id = new.member_id and association_id = assoc) then
    raise exception 'Membre inconnu dans cette association.';
  end if;
  new.association_id := assoc;
  new.marked_by := actor_label(assoc);
  new.marked_at := now();
  return new;
end $$;
drop trigger if exists attendance_check on public.meeting_attendance;
create trigger attendance_check before insert or update on public.meeting_attendance
  for each row execute function public.attendance_check();

alter table public.meetings enable row level security;
alter table public.meeting_attendance enable row level security;

drop policy if exists meetings_select on public.meetings;
create policy meetings_select on public.meetings for select to authenticated
  using (is_member(association_id));
drop policy if exists meetings_insert on public.meetings;
create policy meetings_insert on public.meetings for insert to authenticated
  with check (has_role(association_id, array['president','vice_president','secretaire']));
drop policy if exists meetings_update on public.meetings;
create policy meetings_update on public.meetings for update to authenticated
  using (has_role(association_id, array['president','vice_president','secretaire']))
  with check (has_role(association_id, array['president','vice_president','secretaire']));

drop policy if exists attendance_select on public.meeting_attendance;
create policy attendance_select on public.meeting_attendance for select to authenticated
  using (is_member(association_id));
drop policy if exists attendance_insert on public.meeting_attendance;
create policy attendance_insert on public.meeting_attendance for insert to authenticated
  with check (has_role((select m.association_id from public.meetings m where m.id = meeting_id), array['president','vice_president','secretaire']));
drop policy if exists attendance_update on public.meeting_attendance;
create policy attendance_update on public.meeting_attendance for update to authenticated
  using (has_role(association_id, array['president','vice_president','secretaire']))
  with check (has_role((select m.association_id from public.meetings m where m.id = meeting_id), array['president','vice_president','secretaire']));
drop policy if exists attendance_delete on public.meeting_attendance;
create policy attendance_delete on public.meeting_attendance for delete to authenticated
  using (has_role(association_id, array['president','vice_president','secretaire']));

revoke all on public.meetings, public.meeting_attendance from anon, authenticated;
grant select, insert, update on public.meetings to authenticated;
grant select, insert, update, delete on public.meeting_attendance to authenticated;
revoke execute on function public.meetings_guard() from public, anon, authenticated;
revoke execute on function public.meetings_log() from public, anon, authenticated;
revoke execute on function public.attendance_check() from public, anon, authenticated;

-- VillageLink 1.4.2 : sécurité
-- 1. Chemin de recherche figé sur les 4 fonctions qui ne l'avaient pas.
alter function public.fmt_money(bigint, text) set search_path = public;
alter function public.forbid_change() set search_path = public;
alter function public.force_creator() set search_path = public;
alter function public.associations_guard() set search_path = public;

-- 2. Les fonctions de trigger et les outils internes ne s'appellent pas depuis l'API.
--    (Un trigger s'exécute même sans ce droit : il est vérifié à la création du trigger.)
revoke execute on function public.associations_guard() from public, anon, authenticated;
revoke execute on function public.content_log() from public, anon, authenticated;
revoke execute on function public.forbid_change() from public, anon, authenticated;
revoke execute on function public.force_creator() from public, anon, authenticated;
revoke execute on function public.members_guard() from public, anon, authenticated;
revoke execute on function public.members_log() from public, anon, authenticated;
revoke execute on function public.messages_check() from public, anon, authenticated;
revoke execute on function public.project_update_check() from public, anon, authenticated;
revoke execute on function public.projects_guard() from public, anon, authenticated;
revoke execute on function public.tx_check() from public, anon, authenticated;
revoke execute on function public.tx_log() from public, anon, authenticated;
revoke execute on function public.actor_label(uuid) from public, anon, authenticated;
revoke execute on function public.fmt_money(bigint, text) from public, anon, authenticated;

-- 3. is_member et has_role servent dans les règles d'accès : réservées aux comptes connectés.
revoke execute on function public.is_member(uuid) from public, anon;
revoke execute on function public.has_role(uuid, text[]) from public, anon;
grant execute on function public.is_member(uuid) to authenticated;
grant execute on function public.has_role(uuid, text[]) to authenticated;

-- ---------------------------------------------------------------------
-- Votes (version 1.5)
-- Le président, le vice-président et le secrétaire lancent et closent un vote.
-- Chaque membre validé qui a un compte vote une fois (il peut changer d'avis tant que
-- le vote est ouvert). Un vote secret ne montre à personne qui a voté quoi.
-- Tout passe par des fonctions : aucune écriture directe dans les tables.
-- ---------------------------------------------------------------------
create table if not exists public.polls (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  question        text not null check (length(trim(question)) between 3 and 300),
  description     text not null default '' check (length(description) <= 2000),
  anonymous       boolean not null default true,
  status          text not null default 'Ouvert' check (status in ('Ouvert','Clos')),
  closes_at       timestamptz,
  created_by      uuid,
  created_label   text not null default '',
  created_at      timestamptz not null default now(),
  closed_at       timestamptz
);
create index if not exists polls_assoc_idx on public.polls(association_id, created_at desc);

create table if not exists public.poll_options (
  id              uuid primary key default gen_random_uuid(),
  poll_id         uuid not null references public.polls(id) on delete cascade,
  association_id  uuid not null references public.associations(id) on delete cascade,
  label           text not null check (length(trim(label)) between 1 and 120),
  position        int not null default 0
);
create index if not exists poll_options_poll_idx on public.poll_options(poll_id, position);

create table if not exists public.poll_votes (
  poll_id         uuid not null references public.polls(id) on delete cascade,
  member_id       uuid not null references public.members(id) on delete cascade,
  option_id       uuid not null references public.poll_options(id) on delete cascade,
  association_id  uuid not null references public.associations(id) on delete cascade,
  voted_at        timestamptz not null default now(),
  primary key (poll_id, member_id)
);
create index if not exists poll_votes_assoc_idx on public.poll_votes(association_id);

alter table public.polls enable row level security;
alter table public.poll_options enable row level security;
alter table public.poll_votes enable row level security;

create policy polls_select on public.polls for select to authenticated
  using (is_member(association_id));
create policy poll_options_select on public.poll_options for select to authenticated
  using (is_member(association_id));
-- Bulletins : on voit le sien ; ceux des autres seulement si le vote n'est pas secret.
create policy poll_votes_select on public.poll_votes for select to authenticated
  using (is_member(association_id) and (
    member_id in (select m.id from public.members m where m.user_id = auth.uid())
    or exists (select 1 from public.polls p where p.id = poll_id and not p.anonymous)));

revoke all on public.polls, public.poll_options, public.poll_votes from anon, authenticated;
grant select on public.polls, public.poll_options, public.poll_votes to authenticated;

-- Lancer un vote (question + 2 à 10 choix), en une seule opération.
create or replace function public.create_poll(p_assoc uuid, p_question text, p_description text,
  p_options text[], p_closes_at timestamptz, p_anonymous boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare pid uuid; opt text; i int := 0; n int;
begin
  if not has_role(p_assoc, array['president','vice_president','secretaire']) then
    raise exception 'Réservé au président, au vice-président et au secrétaire général.';
  end if;
  select count(distinct lower(trim(x))) into n from unnest(p_options) x where length(trim(x)) > 0;
  if n < 2 or n > 10 then raise exception 'Il faut entre 2 et 10 choix différents.'; end if;
  if p_closes_at is not null and p_closes_at <= now() then raise exception 'La date de clôture doit être dans le futur.'; end if;
  insert into polls(association_id, question, description, anonymous, closes_at, created_by, created_label)
  values (p_assoc, trim(p_question), coalesce(trim(p_description), ''), coalesce(p_anonymous, true), p_closes_at,
          auth.uid(), actor_label(p_assoc))
  returning id into pid;
  foreach opt in array p_options loop
    if length(trim(opt)) > 0 and not exists (select 1 from poll_options where poll_id = pid and lower(label) = lower(trim(opt))) then
      insert into poll_options(poll_id, association_id, label, position) values (pid, p_assoc, trim(opt), i);
      i := i + 1;
    end if;
  end loop;
  perform write_log(p_assoc, format('a lancé le vote « %s ».', trim(p_question)));
  return pid;
end $$;

-- Voter (ou changer son vote tant que le vote est ouvert).
create or replace function public.cast_vote(p_poll uuid, p_option uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p polls; mid uuid;
begin
  select * into p from polls where id = p_poll;
  if p.id is null or not is_member(p.association_id) then raise exception 'Vote introuvable.'; end if;
  if p.status <> 'Ouvert' or (p.closes_at is not null and p.closes_at <= now()) then
    raise exception 'Ce vote est clos.';
  end if;
  if not exists (select 1 from poll_options where id = p_option and poll_id = p_poll) then
    raise exception 'Choix inconnu.';
  end if;
  select id into mid from members
    where association_id = p.association_id and user_id = auth.uid() and active and not pending limit 1;
  if mid is null then raise exception 'Seuls les membres validés peuvent voter.'; end if;
  insert into poll_votes(poll_id, member_id, option_id, association_id)
  values (p_poll, mid, p_option, p.association_id)
  on conflict (poll_id, member_id) do update set option_id = excluded.option_id, voted_at = now();
end $$;

-- Clore un vote.
create or replace function public.close_poll(p_poll uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p polls;
begin
  select * into p from polls where id = p_poll;
  if p.id is null or not has_role(p.association_id, array['president','vice_president','secretaire']) then
    raise exception 'Réservé au président, au vice-président et au secrétaire général.';
  end if;
  if p.status = 'Clos' then return; end if;
  update polls set status = 'Clos', closed_at = now() where id = p_poll;
  perform write_log(p.association_id, format('a clos le vote « %s ».', p.question));
end $$;

-- Résultats : nombre de voix par choix (y compris pour un vote secret).
create or replace function public.poll_results(p_poll uuid)
returns table(option_id uuid, votes int)
language sql stable security definer set search_path = public as $$
  select o.id, count(v.member_id)::int
  from poll_options o
  join polls p on p.id = o.poll_id
  left join poll_votes v on v.option_id = o.id
  where o.poll_id = p_poll and is_member(p.association_id)
  group by o.id, o.position
  order by o.position;
$$;

revoke execute on function public.create_poll(uuid, text, text, text[], timestamptz, boolean) from public, anon;
revoke execute on function public.cast_vote(uuid, uuid) from public, anon;
revoke execute on function public.close_poll(uuid) from public, anon;
revoke execute on function public.poll_results(uuid) from public, anon;
grant execute on function public.create_poll(uuid, text, text, text[], timestamptz, boolean) to authenticated;
grant execute on function public.cast_vote(uuid, uuid) to authenticated;
grant execute on function public.close_poll(uuid) to authenticated;
grant execute on function public.poll_results(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Documents (version 1.6) : statuts, règlement, procès-verbaux, rapports…
-- Le bureau (président, vice-président, secrétaire, trésorier) dépose et retire ;
-- tous les membres validés lisent. Fichiers dans le bucket privé « docs »,
-- rangés par association : <id de l'association>/<nom>.
-- ---------------------------------------------------------------------
create table if not exists public.documents (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  title           text not null check (length(trim(title)) between 2 and 160),
  category        text not null default 'Autre'
                  check (category in ('Statuts','Règlement intérieur','Procès-verbal','Rapport','Reçu','Autre')),
  file_path       text not null check (length(file_path) between 3 and 300),
  file_name       text not null default '' check (length(file_name) <= 200),
  mime            text not null default '' check (length(mime) <= 120),
  size            int not null default 0 check (size between 0 and 10485760),
  uploaded_by     uuid,
  uploaded_label  text not null default '',
  created_at      timestamptz not null default now()
);
create index if not exists documents_assoc_idx on public.documents(association_id, created_at desc);

-- Le chemin du fichier doit être dans le dossier de l'association ; l'auteur est la personne connectée.
create or replace function public.documents_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.file_path not like new.association_id::text || '/%' or new.file_path like '%..%' then
    raise exception 'Chemin de fichier invalide.';
  end if;
  new.uploaded_by := auth.uid();
  new.uploaded_label := actor_label(new.association_id);
  new.created_at := now();
  return new;
end $$;
create trigger documents_check before insert on public.documents
  for each row execute function public.documents_check();

create or replace function public.documents_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform write_log(new.association_id, format('a déposé le document « %s » (%s).', new.title, new.category));
    return new;
  end if;
  perform write_log(old.association_id, format('a retiré le document « %s ».', old.title));
  return old;
end $$;
create trigger documents_log after insert or delete on public.documents
  for each row execute function public.documents_log();

alter table public.documents enable row level security;
create policy documents_select on public.documents for select to authenticated
  using (is_member(association_id));
create policy documents_insert on public.documents for insert to authenticated
  with check (has_role(association_id, array['president','vice_president','secretaire','tresorier']));
create policy documents_delete on public.documents for delete to authenticated
  using (has_role(association_id, array['president','vice_president','secretaire','tresorier']));

revoke all on public.documents from anon, authenticated;
grant select, insert, delete on public.documents to authenticated;
revoke execute on function public.documents_check() from public, anon, authenticated;
revoke execute on function public.documents_log() from public, anon, authenticated;

-- Bucket privé « docs » (10 Mo maximum par fichier) et ses règles d'accès.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('docs', 'docs', false, 10485760,
            array['application/pdf','image/jpeg','image/png','image/webp','image/heic',
                  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                  'application/msword','application/vnd.ms-excel'])
    on conflict (id) do nothing;
    execute $p$create policy docs_read on storage.objects for select to authenticated
      using (bucket_id = 'docs' and public.is_member(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy docs_write on storage.objects for insert to authenticated
      with check (bucket_id = 'docs'
        and public.has_role(((storage.foldername(name))[1])::uuid, array['president','vice_president','secretaire','tresorier']))$p$;
    execute $p$create policy docs_delete on storage.objects for delete to authenticated
      using (bucket_id = 'docs'
        and public.has_role(((storage.foldername(name))[1])::uuid, array['president','vice_president','secretaire','tresorier']))$p$;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Double validation des dépenses (version 1.7)
-- Le trésorier propose une dépense ; le président ou le vice-président l'approuve
-- (ou la refuse). Elle n'entre dans la caisse qu'une fois approuvée.
-- Le président peut désactiver la règle (petites associations sans second signataire).
-- ---------------------------------------------------------------------
alter table public.associations add column if not exists expense_approval boolean not null default true;
alter table public.transactions add column if not exists approved_label text not null default '';
alter table public.transactions add column if not exists requested_label text not null default '';

create table if not exists public.expense_requests (
  id              bigint generated always as identity primary key,
  association_id  uuid not null references public.associations(id) on delete cascade,
  category        text not null check (category in ('Projet','Transport','Réunion','Communication','Administration','Autres')),
  amount          bigint not null check (amount > 0 and amount <= 1000000000000),
  occurred_on     date not null default current_date,
  description     text not null check (length(trim(description)) between 2 and 300),
  project_id      uuid references public.projects(id) on delete restrict,
  comment         text not null default '' check (length(comment) <= 500),
  proof_path      text not null default '' check (length(proof_path) <= 300),
  status          text not null default 'En attente' check (status in ('En attente','Approuvée','Refusée','Annulée')),
  requested_by    uuid,
  requested_label text not null default '',
  decided_by      uuid,
  decided_label   text not null default '',
  decided_at      timestamptz,
  decision_note   text not null default '' check (length(decision_note) <= 500),
  tx_id           bigint references public.transactions(id) on delete restrict,
  created_at      timestamptz not null default now()
);
create index if not exists expense_requests_assoc_idx on public.expense_requests(association_id, id desc);

create or replace function public.expense_requests_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.project_id is not null and not exists
     (select 1 from projects where id = new.project_id and association_id = new.association_id) then
    raise exception 'Projet inconnu dans cette association.';
  end if;
  if new.proof_path <> '' and (new.proof_path not like new.association_id::text || '/%' or new.proof_path like '%..%') then
    raise exception 'Justificatif invalide.';
  end if;
  new.status := 'En attente';
  new.requested_by := auth.uid();
  new.requested_label := actor_label(new.association_id);
  new.decided_by := null; new.decided_label := ''; new.decided_at := null; new.decision_note := ''; new.tx_id := null;
  new.created_at := now();
  return new;
end $$;
create trigger expense_requests_check before insert on public.expense_requests
  for each row execute function public.expense_requests_check();

create or replace function public.expense_requests_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur text;
begin
  select currency into cur from associations where id = new.association_id;
  perform write_log(new.association_id, format('a demandé l''approbation d''une dépense de %s : %s.',
    fmt_money(new.amount, cur), new.description));
  return null;
end $$;
create trigger expense_requests_log after insert on public.expense_requests
  for each row execute function public.expense_requests_log();

alter table public.expense_requests enable row level security;
create policy expense_requests_select on public.expense_requests for select to authenticated
  using (is_member(association_id));
create policy expense_requests_insert on public.expense_requests for insert to authenticated
  with check (has_role(association_id, array['tresorier']));
revoke all on public.expense_requests from anon, authenticated;
grant select, insert on public.expense_requests to authenticated;

-- Une dépense directe n'est possible que si la double validation est désactivée.
alter policy tx_insert on public.transactions with check (
  reversal_of is null and amount > 0 and (
    (kind = 'in'  and has_role(association_id, array['tresorier','president','vice_president'])) or
    (kind = 'out' and has_role(association_id, array['tresorier'])
       and not coalesce((select a.expense_approval from public.associations a where a.id = association_id), true))
  ));

-- L'auteur d'une opération est la personne connectée, sauf pour une dépense approuvée
-- (l'auteur reste le trésorier qui l'a proposée). Les signatures sont fixées par la base.
create or replace function public.tx_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.member_id is not null and not exists
     (select 1 from members where id = new.member_id and association_id = new.association_id) then
    raise exception 'Membre inconnu dans cette association.';
  end if;
  if new.project_id is not null and not exists
     (select 1 from projects where id = new.project_id and association_id = new.association_id) then
    raise exception 'Projet inconnu dans cette association.';
  end if;
  if new.proof_path <> '' and (new.proof_path not like new.association_id::text || '/%' or new.proof_path like '%..%') then
    raise exception 'Justificatif invalide.';
  end if;
  if new.reversal_of is null and new.amount <= 0 then
    raise exception 'Le montant doit être supérieur à 0.';
  end if;
  if new.reversal_of is not null and coalesce(current_setting('vl.reversing', true), '') <> 'on' then
    raise exception 'Une contre-écriture passe par la fonction prévue.';
  end if;
  if coalesce(current_setting('vl.approving', true), '') <> 'on' then
    new.created_by := auth.uid();
    new.approved_label := '';
    new.requested_label := '';
  end if;
  new.created_at := now();
  return new;
end $$;

create or replace function public.tx_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur text; who text;
begin
  if coalesce(current_setting('vl.approving', true), '') = 'on' then return null; end if;
  select currency into cur from associations where id = new.association_id;
  if new.reversal_of is not null then
    perform write_log(new.association_id, format('a annulé l''opération TX-%s (%s) par contre-écriture. Motif : %s',
      lpad(new.reversal_of::text, 5, '0'), fmt_money(new.amount, cur), new.comment));
  elsif new.category = 'Cotisations' then
    select full_name into who from members where id = new.member_id;
    perform write_log(new.association_id, format('a enregistré une cotisation de %s de %s (%s).',
      fmt_money(new.amount, cur), who, new.period));
  else
    perform write_log(new.association_id, format('a enregistré %s de %s : %s.',
      case new.kind when 'in' then 'une recette' else 'une dépense' end,
      fmt_money(new.amount, cur), new.description));
  end if;
  return null;
end $$;

-- Approuver : président ou vice-président, jamais la personne qui a proposé la dépense.
create or replace function public.approve_expense(p_id bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare r expense_requests; tid bigint; bal bigint; cur text;
begin
  select * into r from expense_requests where id = p_id for update;
  if r.id is null or not has_role(r.association_id, array['president','vice_president']) then
    raise exception 'Réservé au président et au vice-président.';
  end if;
  if r.status <> 'En attente' then raise exception 'Cette dépense a déjà été traitée.'; end if;
  if r.requested_by = auth.uid() then raise exception 'La personne qui propose une dépense ne peut pas l''approuver.'; end if;
  select coalesce(sum(amount) filter (where kind = 'in'), 0) - coalesce(sum(amount) filter (where kind = 'out'), 0)
    into bal from transactions where association_id = r.association_id;
  select currency into cur from associations where id = r.association_id;
  if r.amount > bal then
    raise exception 'Solde insuffisant : la caisse contient %.', fmt_money(bal, cur);
  end if;
  perform set_config('vl.approving', 'on', true);
  insert into transactions(association_id, kind, category, amount, occurred_on, description, project_id,
                           comment, proof_path, created_by, approved_label, requested_label)
  values (r.association_id, 'out', r.category, r.amount, r.occurred_on, r.description, r.project_id,
          r.comment, r.proof_path, r.requested_by, actor_label(r.association_id), r.requested_label)
  returning id into tid;
  perform set_config('vl.approving', 'off', true);
  update expense_requests set status = 'Approuvée', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
    decided_at = now(), tx_id = tid where id = r.id;
  perform write_log(r.association_id, format('a approuvé la dépense de %s : %s (proposée par %s).',
    fmt_money(r.amount, cur), r.description, r.requested_label));
  return tid;
end $$;

create or replace function public.reject_expense(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare r expense_requests; cur text;
begin
  select * into r from expense_requests where id = p_id for update;
  if r.id is null or not has_role(r.association_id, array['president','vice_president']) then
    raise exception 'Réservé au président et au vice-président.';
  end if;
  if r.status <> 'En attente' then raise exception 'Cette dépense a déjà été traitée.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 4 then raise exception 'Indiquez le motif du refus.'; end if;
  select currency into cur from associations where id = r.association_id;
  update expense_requests set status = 'Refusée', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
    decided_at = now(), decision_note = left(trim(p_reason), 500) where id = r.id;
  perform write_log(r.association_id, format('a refusé la dépense de %s : %s. Motif : %s',
    fmt_money(r.amount, cur), r.description, left(trim(p_reason), 500)));
end $$;

-- Retirer sa propre proposition tant qu'elle est en attente.
create or replace function public.cancel_expense(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r expense_requests;
begin
  select * into r from expense_requests where id = p_id for update;
  if r.id is null or r.requested_by is distinct from auth.uid() or not is_member(r.association_id) then
    raise exception 'Seule la personne qui a proposé la dépense peut la retirer.';
  end if;
  if r.status <> 'En attente' then raise exception 'Cette dépense a déjà été traitée.'; end if;
  update expense_requests set status = 'Annulée', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
    decided_at = now() where id = r.id;
  perform write_log(r.association_id, format('a retiré sa demande de dépense : %s.', r.description));
end $$;

-- Journal : activation / désactivation de la règle.
create or replace function public.associations_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.expense_approval <> old.expense_approval then
    perform write_log(new.id, case when new.expense_approval
      then 'a activé la double validation des dépenses.'
      else 'a désactivé la double validation des dépenses.' end);
  end if;
  return null;
end $$;
create trigger associations_log after update on public.associations
  for each row execute function public.associations_log();

revoke execute on function public.expense_requests_check() from public, anon, authenticated;
revoke execute on function public.expense_requests_log() from public, anon, authenticated;
revoke execute on function public.associations_log() from public, anon, authenticated;
revoke execute on function public.tx_check() from public, anon, authenticated;
revoke execute on function public.tx_log() from public, anon, authenticated;
revoke execute on function public.approve_expense(bigint) from public, anon;
revoke execute on function public.reject_expense(bigint, text) from public, anon;
revoke execute on function public.cancel_expense(bigint) from public, anon;
grant execute on function public.approve_expense(bigint) to authenticated;
grant execute on function public.reject_expense(bigint, text) to authenticated;
grant execute on function public.cancel_expense(bigint) to authenticated;

-- ---------------------------------------------------------------------
-- Plusieurs devises (version 1.8)
-- La caisse reste tenue dans la monnaie de l'association. Un paiement reçu dans une
-- autre monnaie garde son montant d'origine et le taux utilisé, visibles par tous.
-- ---------------------------------------------------------------------
alter table public.transactions add column if not exists orig_amount numeric(16,2);
alter table public.transactions add column if not exists orig_currency text not null default '';
alter table public.transactions add column if not exists fx_rate numeric(18,6);
alter table public.expense_requests add column if not exists orig_amount numeric(16,2);
alter table public.expense_requests add column if not exists orig_currency text not null default '';
alter table public.expense_requests add column if not exists fx_rate numeric(18,6);

alter table public.transactions add constraint transactions_fx check (
  (orig_currency = '' and orig_amount is null and fx_rate is null) or
  (orig_currency in ('XOF','GNF','EUR','USD','XAF','CAD','GBP') and orig_amount <> 0 and abs(orig_amount) <= 1000000000000
   and fx_rate > 0 and fx_rate <= 1000000)) not valid;
alter table public.expense_requests add constraint expense_requests_fx check (
  (orig_currency = '' and orig_amount is null and fx_rate is null) or
  (orig_currency in ('XOF','GNF','EUR','USD','XAF','CAD','GBP') and orig_amount > 0 and orig_amount <= 1000000000000
   and fx_rate > 0 and fx_rate <= 1000000)) not valid;

-- Le montant enregistré dans la caisse doit correspondre au montant d'origine × taux
-- (à une unité près pour l'arrondi). Une autre monnaie ne peut pas être la monnaie de l'association.
create or replace function public.fx_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur text;
begin
  if new.orig_currency = '' or coalesce(current_setting('vl.reversing', true), '') = 'on' then return new; end if;
  select currency into cur from associations where id = new.association_id;
  if new.orig_currency = cur then
    raise exception 'La monnaie d''origine est déjà celle de l''association.';
  end if;
  if abs(round(new.orig_amount * new.fx_rate) - new.amount) > 1 then
    raise exception 'Le montant converti ne correspond pas au taux indiqué.';
  end if;
  return new;
end $$;
create trigger transactions_fx_check before insert on public.transactions
  for each row execute function public.fx_check();
create trigger expense_requests_fx_check before insert on public.expense_requests
  for each row execute function public.fx_check();
revoke execute on function public.fx_check() from public, anon, authenticated;

-- Une contre-écriture reprend la monnaie d'origine (montant négatif) ; une dépense approuvée aussi.
create or replace function public.reverse_transaction(p_id bigint, p_reason text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare t transactions; new_id bigint;
begin
  select * into t from transactions where id = p_id;
  if t.id is null then raise exception 'Opération introuvable.'; end if;
  if not has_role(t.association_id, array['tresorier']) then
    raise exception 'Seul le trésorier peut annuler une opération.';
  end if;
  if t.reversal_of is not null then raise exception 'Une contre-écriture ne s''annule pas.'; end if;
  if exists (select 1 from transactions where reversal_of = p_id) then
    raise exception 'Cette opération est déjà annulée.';
  end if;
  if length(trim(coalesce(p_reason,''))) < 4 then raise exception 'Indiquez le motif de l''annulation.'; end if;
  perform set_config('vl.reversing', 'on', true);
  insert into transactions(association_id, kind, category, amount, occurred_on, description,
                           member_id, period, project_id, payment_method, comment, reversal_of,
                           orig_amount, orig_currency, fx_rate)
  values (t.association_id, t.kind, t.category, -t.amount, current_date,
          'Contre-écriture de TX-' || lpad(t.id::text, 5, '0'),
          t.member_id, t.period, t.project_id, '', trim(p_reason), t.id,
          -t.orig_amount, t.orig_currency, t.fx_rate)
  returning id into new_id;
  perform set_config('vl.reversing', 'off', true);
  return new_id;
end $$;

create or replace function public.approve_expense(p_id bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare r expense_requests; tid bigint; bal bigint; cur text;
begin
  select * into r from expense_requests where id = p_id for update;
  if r.id is null or not has_role(r.association_id, array['president','vice_president']) then
    raise exception 'Réservé au président et au vice-président.';
  end if;
  if r.status <> 'En attente' then raise exception 'Cette dépense a déjà été traitée.'; end if;
  if r.requested_by = auth.uid() then raise exception 'La personne qui propose une dépense ne peut pas l''approuver.'; end if;
  select coalesce(sum(amount) filter (where kind = 'in'), 0) - coalesce(sum(amount) filter (where kind = 'out'), 0)
    into bal from transactions where association_id = r.association_id;
  select currency into cur from associations where id = r.association_id;
  if r.amount > bal then
    raise exception 'Solde insuffisant : la caisse contient %.', fmt_money(bal, cur);
  end if;
  perform set_config('vl.approving', 'on', true);
  insert into transactions(association_id, kind, category, amount, occurred_on, description, project_id,
                           comment, proof_path, created_by, approved_label, requested_label,
                           orig_amount, orig_currency, fx_rate)
  values (r.association_id, 'out', r.category, r.amount, r.occurred_on, r.description, r.project_id,
          r.comment, r.proof_path, r.requested_by, actor_label(r.association_id), r.requested_label,
          r.orig_amount, r.orig_currency, r.fx_rate)
  returning id into tid;
  perform set_config('vl.approving', 'off', true);
  update expense_requests set status = 'Approuvée', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
    decided_at = now(), tx_id = tid where id = r.id;
  perform write_log(r.association_id, format('a approuvé la dépense de %s : %s (proposée par %s).',
    fmt_money(r.amount, cur), r.description, r.requested_label));
  return tid;
end $$;

-- ---------------------------------------------------------------------
-- Collectes d'urgence et de solidarité (version 1.9)
-- Décès, maladie, mariage… Le bureau ouvre une collecte ; le trésorier, le président
-- ou le vice-président enregistrent les contributions (recettes liées à la collecte) ;
-- la remise à la famille est une dépense liée (double validation si elle est active).
-- ---------------------------------------------------------------------
create table if not exists public.collections (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  kind            text not null default 'Autre'
                  check (kind in ('Décès','Maladie','Mariage','Naissance','Accident','Autre')),
  title           text not null check (length(trim(title)) between 3 and 160),
  beneficiary     text not null default '' check (length(beneficiary) <= 160),
  description     text not null default '' check (length(description) <= 2000),
  goal            bigint check (goal is null or (goal > 0 and goal <= 1000000000000)),
  suggested       bigint check (suggested is null or (suggested > 0 and suggested <= 1000000000)),
  ends_on         date,
  status          text not null default 'Ouverte' check (status in ('Ouverte','Close')),
  created_by      uuid,
  created_label   text not null default '',
  created_at      timestamptz not null default now(),
  closed_at       timestamptz
);
create index if not exists collections_assoc_idx on public.collections(association_id, created_at desc);

alter table public.transactions add column if not exists collection_id uuid references public.collections(id) on delete restrict;
alter table public.expense_requests add column if not exists collection_id uuid references public.collections(id) on delete restrict;
create index if not exists tx_collection_idx on public.transactions(collection_id);

create or replace function public.collections_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.created_label := actor_label(new.association_id);
    new.created_at := now();
    new.status := 'Ouverte';
    new.closed_at := null;
  else
    new.association_id := old.association_id;
    new.created_by := old.created_by;
    new.created_label := old.created_label;
    new.created_at := old.created_at;
    new.closed_at := case when new.status = 'Close' and old.status <> 'Close' then now()
                          when new.status = 'Ouverte' then null else old.closed_at end;
  end if;
  return new;
end $$;
create trigger collections_guard before insert or update on public.collections
  for each row execute function public.collections_guard();

create or replace function public.collections_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform write_log(new.association_id, format('a lancé la collecte « %s »%s.', new.title,
      case when new.beneficiary <> '' then ' pour ' || new.beneficiary else '' end));
  elsif new.status <> old.status then
    perform write_log(new.association_id, format('a %s la collecte « %s ».',
      case when new.status = 'Close' then 'clos' else 'rouvert' end, new.title));
  end if;
  return null;
end $$;
create trigger collections_log after insert or update on public.collections
  for each row execute function public.collections_log();

-- Une opération liée à une collecte : même association ; une contribution seulement si elle est ouverte.
create or replace function public.collection_link_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare c collections;
begin
  if new.collection_id is null then return new; end if;
  select * into c from collections where id = new.collection_id;
  if c.id is null or c.association_id <> new.association_id then
    raise exception 'Collecte inconnue dans cette association.';
  end if;
  if tg_table_name = 'transactions' then
    if new.kind = 'in' and new.category = 'Cotisations' then
      raise exception 'Une cotisation ne se rattache pas à une collecte.';
    end if;
    if new.kind = 'in' and new.reversal_of is null and c.status <> 'Ouverte' then
      raise exception 'Cette collecte est close.';
    end if;
  end if;
  return new;
end $$;
create trigger transactions_collection_check before insert on public.transactions
  for each row execute function public.collection_link_check();
create trigger expense_requests_collection_check before insert on public.expense_requests
  for each row execute function public.collection_link_check();

create or replace view public.v_collection_totals with (security_invoker = true) as
  select collection_id,
         coalesce(sum(amount) filter (where kind = 'in'), 0)  as collected,
         coalesce(sum(amount) filter (where kind = 'out'), 0) as given,
         count(*) filter (where kind = 'in' and reversal_of is null) as contributions
  from transactions where collection_id is not null group by collection_id;

alter table public.collections enable row level security;
create policy collections_select on public.collections for select to authenticated
  using (is_member(association_id));
create policy collections_insert on public.collections for insert to authenticated
  with check (has_role(association_id, array['president','vice_president','secretaire','tresorier']));
create policy collections_update on public.collections for update to authenticated
  using (has_role(association_id, array['president','vice_president','secretaire','tresorier']))
  with check (has_role(association_id, array['president','vice_president','secretaire','tresorier']));
revoke all on public.collections from anon, authenticated;
grant select, insert, update on public.collections to authenticated;
revoke all on public.v_collection_totals from anon, authenticated;
grant select on public.v_collection_totals to authenticated;

-- Contre-écriture et approbation reprennent le lien vers la collecte.
create or replace function public.reverse_transaction(p_id bigint, p_reason text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare t transactions; new_id bigint;
begin
  select * into t from transactions where id = p_id;
  if t.id is null then raise exception 'Opération introuvable.'; end if;
  if not has_role(t.association_id, array['tresorier']) then
    raise exception 'Seul le trésorier peut annuler une opération.';
  end if;
  if t.reversal_of is not null then raise exception 'Une contre-écriture ne s''annule pas.'; end if;
  if exists (select 1 from transactions where reversal_of = p_id) then
    raise exception 'Cette opération est déjà annulée.';
  end if;
  if length(trim(coalesce(p_reason,''))) < 4 then raise exception 'Indiquez le motif de l''annulation.'; end if;
  perform set_config('vl.reversing', 'on', true);
  insert into transactions(association_id, kind, category, amount, occurred_on, description,
                           member_id, period, project_id, payment_method, comment, reversal_of,
                           orig_amount, orig_currency, fx_rate, collection_id)
  values (t.association_id, t.kind, t.category, -t.amount, current_date,
          'Contre-écriture de TX-' || lpad(t.id::text, 5, '0'),
          t.member_id, t.period, t.project_id, '', trim(p_reason), t.id,
          -t.orig_amount, t.orig_currency, t.fx_rate, t.collection_id)
  returning id into new_id;
  perform set_config('vl.reversing', 'off', true);
  return new_id;
end $$;

create or replace function public.approve_expense(p_id bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare r expense_requests; tid bigint; bal bigint; cur text;
begin
  select * into r from expense_requests where id = p_id for update;
  if r.id is null or not has_role(r.association_id, array['president','vice_president']) then
    raise exception 'Réservé au président et au vice-président.';
  end if;
  if r.status <> 'En attente' then raise exception 'Cette dépense a déjà été traitée.'; end if;
  if r.requested_by = auth.uid() then raise exception 'La personne qui propose une dépense ne peut pas l''approuver.'; end if;
  select coalesce(sum(amount) filter (where kind = 'in'), 0) - coalesce(sum(amount) filter (where kind = 'out'), 0)
    into bal from transactions where association_id = r.association_id;
  select currency into cur from associations where id = r.association_id;
  if r.amount > bal then
    raise exception 'Solde insuffisant : la caisse contient %.', fmt_money(bal, cur);
  end if;
  perform set_config('vl.approving', 'on', true);
  insert into transactions(association_id, kind, category, amount, occurred_on, description, project_id,
                           comment, proof_path, created_by, approved_label, requested_label,
                           orig_amount, orig_currency, fx_rate, collection_id)
  values (r.association_id, 'out', r.category, r.amount, r.occurred_on, r.description, r.project_id,
          r.comment, r.proof_path, r.requested_by, actor_label(r.association_id), r.requested_label,
          r.orig_amount, r.orig_currency, r.fx_rate, r.collection_id)
  returning id into tid;
  perform set_config('vl.approving', 'off', true);
  update expense_requests set status = 'Approuvée', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
    decided_at = now(), tx_id = tid where id = r.id;
  perform write_log(r.association_id, format('a approuvé la dépense de %s : %s (proposée par %s).',
    fmt_money(r.amount, cur), r.description, r.requested_label));
  return tid;
end $$;

revoke execute on function public.collections_guard() from public, anon, authenticated;
revoke execute on function public.collections_log() from public, anon, authenticated;
revoke execute on function public.collection_link_check() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Sections (version 1.10) : une association, plusieurs groupes (Dakar, Conakry, France…)
-- Le bureau crée les sections et y range les membres. Chaque section peut avoir son
-- trésorier de section : il encaisse les cotisations des membres de SA section, et
-- rien d'autre. Le bureau central voit tout.
-- ---------------------------------------------------------------------
create table if not exists public.sections (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  name            text not null check (length(trim(name)) between 2 and 80),
  city            text not null default '' check (length(city) <= 80),
  country         text not null default '' check (length(country) <= 80),
  treasurer_member_id uuid references public.members(id) on delete set null,
  created_at      timestamptz not null default now()
);
create unique index if not exists sections_assoc_name_uniq on public.sections(association_id, lower(name));

alter table public.members add column if not exists section_id uuid references public.sections(id) on delete set null;
create index if not exists members_section_idx on public.members(section_id);

-- Une section et son trésorier appartiennent à l'association ; le trésorier est membre de la section.
create or replace function public.sections_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.association_id := old.association_id; new.created_at := old.created_at; end if;
  if new.treasurer_member_id is not null and not exists
     (select 1 from members where id = new.treasurer_member_id and association_id = new.association_id
        and (tg_op = 'INSERT' or section_id = new.id)) then
    raise exception 'Le trésorier de section doit être un membre de cette section.';
  end if;
  return new;
end $$;
create trigger sections_check before insert or update on public.sections
  for each row execute function public.sections_check();

create or replace function public.sections_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if tg_op = 'INSERT' then
    perform write_log(new.association_id, format('a créé la section « %s ».', new.name));
  elsif tg_op = 'DELETE' then
    perform write_log(old.association_id, format('a supprimé la section « %s ».', old.name));
    return old;
  elsif new.treasurer_member_id is distinct from old.treasurer_member_id then
    select full_name into who from members where id = new.treasurer_member_id;
    perform write_log(new.association_id, case when who is null
      then format('a retiré le trésorier de la section « %s ».', new.name)
      else format('a nommé %s trésorier de la section « %s ».', who, new.name) end);
  elsif new.name <> old.name then
    perform write_log(new.association_id, format('a renommé la section « %s » en « %s ».', old.name, new.name));
  end if;
  return new;
end $$;
create trigger sections_log after insert or update or delete on public.sections
  for each row execute function public.sections_log();

create or replace function public.members_section_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.section_id is not null and not exists
     (select 1 from sections where id = new.section_id and association_id = new.association_id) then
    raise exception 'Section inconnue dans cette association.';
  end if;
  -- Un trésorier de section qui change de section perd sa fonction.
  if tg_op = 'UPDATE' and new.section_id is distinct from old.section_id then
    update sections set treasurer_member_id = null where treasurer_member_id = new.id and id is distinct from new.section_id;
  end if;
  return new;
end $$;
create trigger members_section_check before insert or update on public.members
  for each row execute function public.members_section_check();

-- Supprimer une section : ses membres restent dans l'association, sans section.
create or replace function public.sections_release() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('vl.system', 'on', true);
  update members set section_id = null where section_id = old.id;
  perform set_config('vl.system', 'off', true);
  return old;
end $$;
create trigger sections_release before delete on public.sections
  for each row execute function public.sections_release();

-- La personne connectée est-elle le trésorier de la section de ce membre ?
create or replace function public.is_section_treasurer(p_member uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from members target
    join sections s on s.id = target.section_id
    join members me on me.id = s.treasurer_member_id
    where target.id = p_member and target.active and not target.pending
      and me.user_id = auth.uid() and me.active and not me.pending
      and me.association_id = target.association_id);
$$;
revoke execute on function public.is_section_treasurer(uuid) from public, anon;
grant execute on function public.is_section_treasurer(uuid) to authenticated;

alter policy tx_insert on public.transactions with check (
  reversal_of is null and amount > 0 and (
    (kind = 'in'  and has_role(association_id, array['tresorier','president','vice_president'])) or
    (kind = 'in'  and category = 'Cotisations' and member_id is not null and collection_id is null
       and public.is_section_treasurer(member_id)) or
    (kind = 'out' and has_role(association_id, array['tresorier'])
       and not coalesce((select a.expense_approval from public.associations a where a.id = association_id), true))
  ));

alter table public.sections enable row level security;
create policy sections_select on public.sections for select to authenticated
  using (is_member(association_id));
create policy sections_insert on public.sections for insert to authenticated
  with check (has_role(association_id, array['president','vice_president','secretaire']));
create policy sections_update on public.sections for update to authenticated
  using (has_role(association_id, array['president','vice_president','secretaire']))
  with check (has_role(association_id, array['president','vice_president','secretaire']));
create policy sections_delete on public.sections for delete to authenticated
  using (has_role(association_id, array['president','vice_president','secretaire']));
revoke all on public.sections from anon, authenticated;
grant select, insert, update, delete on public.sections to authenticated;

revoke execute on function public.sections_check() from public, anon, authenticated;
revoke execute on function public.sections_log() from public, anon, authenticated;
revoke execute on function public.members_section_check() from public, anon, authenticated;
revoke execute on function public.sections_release() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Messages vocaux (version 1.11) dans la discussion et les annonces.
-- Fichiers dans le bucket privé « voice » (3 Mo, 3 minutes environ),
-- rangés par association : <id de l'association>/<nom>.
-- ---------------------------------------------------------------------
alter table public.messages add column if not exists audio_path text not null default '' check (length(audio_path) <= 300);
alter table public.messages add column if not exists audio_seconds int not null default 0 check (audio_seconds between 0 and 600);
alter table public.announcements add column if not exists audio_path text not null default '' check (length(audio_path) <= 300);
alter table public.announcements add column if not exists audio_seconds int not null default 0 check (audio_seconds between 0 and 600);

create or replace function public.voice_path_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.audio_path <> '' and (new.audio_path not like new.association_id::text || '/%' or new.audio_path like '%..%') then
    raise exception 'Message vocal invalide.';
  end if;
  if new.audio_path = '' then new.audio_seconds := 0; end if;
  return new;
end $$;
create trigger messages_voice_check before insert on public.messages
  for each row execute function public.voice_path_check();
create trigger announcements_voice_check before insert on public.announcements
  for each row execute function public.voice_path_check();
revoke execute on function public.voice_path_check() from public, anon, authenticated;

-- Masquer un message efface aussi son vocal de l'affichage.
create or replace function public.hide_message(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare m messages;
begin
  select * into m from messages where id = p_id;
  if m.id is null or not is_member(m.association_id) then raise exception 'Message introuvable.'; end if;
  if m.author_id is distinct from auth.uid() and not has_role(m.association_id, array['president','vice_president','secretaire']) then
    raise exception 'Seuls l''auteur, le président, le vice-président ou le secrétaire peuvent masquer un message.';
  end if;
  update messages set hidden = true, body = 'Message masqué', audio_path = '', audio_seconds = 0,
    hidden_by = actor_label(m.association_id) where id = p_id;
  if m.author_id is distinct from auth.uid() then
    perform write_log(m.association_id, format('a masqué un message de %s dans la discussion.', m.author_label));
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('voice', 'voice', false, 3145728,
            array['audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/aac','audio/x-m4a','audio/wav'])
    on conflict (id) do nothing;
    execute $p$create policy voice_read on storage.objects for select to authenticated
      using (bucket_id = 'voice' and public.is_member(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy voice_write on storage.objects for insert to authenticated
      with check (bucket_id = 'voice' and public.is_member(((storage.foldername(name))[1])::uuid))$p$;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Page publique d'un projet (version 1.12)
-- Le bureau peut publier un projet sur une page ouverte à tous (sans compte) :
-- nom, objectif, montant collecté et dépensé, nouvelles du chantier, et le contact
-- choisi pour donner. Aucune donnée de membre n'y apparaît (ni nom, ni numéro).
-- ---------------------------------------------------------------------
alter table public.projects add column if not exists public_slug text unique
  check (public_slug is null or public_slug ~ '^[a-z0-9]{10,24}$');
alter table public.projects add column if not exists public_contact text not null default ''
  check (length(public_contact) <= 300);

create or replace function public.projects_public_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.public_slug is distinct from old.public_slug then
    perform write_log(new.association_id, format('a %s la page publique du projet « %s ».',
      case when new.public_slug is null then 'retiré' else 'publié' end, new.name));
  end if;
  return null;
end $$;
create trigger projects_public_log after update on public.projects
  for each row execute function public.projects_public_log();
revoke execute on function public.projects_public_log() from public, anon, authenticated;

-- Lecture publique, par le lien secret uniquement.
create or replace function public.public_project(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'association', jsonb_build_object('name', a.name, 'village', a.village, 'region', a.region,
                                      'country', a.origin_country, 'city', a.residence_city, 'currency', a.currency),
    'project', jsonb_build_object('name', p.name, 'type', p.type, 'description', p.description, 'goal', p.goal,
                                  'status', p.status, 'start_on', p.start_on, 'end_on', p.end_on, 'contact', p.public_contact),
    'collected', coalesce((select sum(amount) from transactions t where t.project_id = p.id and t.kind = 'in'), 0),
    'spent', coalesce((select sum(amount) from transactions t where t.project_id = p.id and t.kind = 'out'), 0),
    'gifts', (select count(*) from transactions t where t.project_id = p.id and t.kind = 'in' and t.reversal_of is null
                and not exists (select 1 from transactions r where r.reversal_of = t.id)),
    'updates', coalesce((select jsonb_agg(jsonb_build_object('body', u.body, 'at', u.created_at) order by u.created_at desc)
                         from (select * from project_updates u where u.project_id = p.id order by created_at desc limit 20) u), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('description', e.description, 'amount', e.amount, 'on', e.occurred_on) order by e.occurred_on desc)
                         from (select * from transactions t where t.project_id = p.id and t.kind = 'out' and t.reversal_of is null
                                 and not exists (select 1 from transactions r where r.reversal_of = t.id)
                               order by occurred_on desc, id desc limit 30) e), '[]'::jsonb))
  from projects p join associations a on a.id = p.association_id
  where p.public_slug is not null and p.public_slug = lower(trim(p_slug));
$$;
revoke execute on function public.public_project(text) from public;
grant execute on function public.public_project(text) to anon, authenticated;

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

-- ---------------------------------------------------------------------
-- Catégories de membres (version 1.15) : chaque catégorie a sa cotisation mensuelle.
-- Ex. « Gérant / propriétaire » 2 000, « Apprenti » 1 000. Un membre sans catégorie
-- paie la cotisation générale de l'association. Une catégorie à 0 = dispensée.
-- ---------------------------------------------------------------------
create table if not exists public.member_categories (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  name            text not null check (length(trim(name)) between 2 and 60),
  fee_amount      bigint not null default 0 check (fee_amount between 0 and 1000000000),
  created_at      timestamptz not null default now()
);
create unique index if not exists member_categories_name_uniq on public.member_categories(association_id, lower(name));

alter table public.members add column if not exists category_id uuid references public.member_categories(id) on delete set null;
create index if not exists members_category_idx on public.members(category_id);

create or replace function public.member_categories_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.association_id := old.association_id; new.created_at := old.created_at; end if;
  return new;
end $$;
create trigger member_categories_guard before insert or update on public.member_categories
  for each row execute function public.member_categories_guard();

create or replace function public.member_categories_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur text;
begin
  select currency into cur from associations where id = coalesce(new.association_id, old.association_id);
  if tg_op = 'INSERT' then
    perform write_log(new.association_id, format('a créé la catégorie « %s » (cotisation %s par mois).', new.name, fmt_money(new.fee_amount, cur)));
  elsif tg_op = 'DELETE' then
    perform write_log(old.association_id, format('a supprimé la catégorie « %s ».', old.name));
    return old;
  elsif new.fee_amount <> old.fee_amount or new.name <> old.name then
    perform write_log(new.association_id, format('a modifié la catégorie « %s » : cotisation %s par mois.', new.name, fmt_money(new.fee_amount, cur)));
  end if;
  return new;
end $$;
create trigger member_categories_log after insert or update or delete on public.member_categories
  for each row execute function public.member_categories_log();

-- Supprimer une catégorie : ses membres reviennent à la cotisation générale.
create or replace function public.member_categories_release() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('vl.system', 'on', true);
  update members set category_id = null where category_id = old.id;
  perform set_config('vl.system', 'off', true);
  return old;
end $$;
create trigger member_categories_release before delete on public.member_categories
  for each row execute function public.member_categories_release();

create or replace function public.members_category_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category_id is not null and not exists
     (select 1 from member_categories where id = new.category_id and association_id = new.association_id) then
    raise exception 'Catégorie inconnue dans cette association.';
  end if;
  return new;
end $$;
create trigger members_category_check before insert or update on public.members
  for each row execute function public.members_category_check();

alter table public.member_categories enable row level security;
create policy member_categories_select on public.member_categories for select to authenticated
  using (is_member(association_id));
create policy member_categories_insert on public.member_categories for insert to authenticated
  with check (has_role(association_id, array['president','vice_president']));
create policy member_categories_update on public.member_categories for update to authenticated
  using (has_role(association_id, array['president','vice_president']))
  with check (has_role(association_id, array['president','vice_president']));
create policy member_categories_delete on public.member_categories for delete to authenticated
  using (has_role(association_id, array['president','vice_president']));
revoke all on public.member_categories from anon, authenticated;
grant select, insert, update, delete on public.member_categories to authenticated;

revoke execute on function public.member_categories_guard() from public, anon, authenticated;
revoke execute on function public.member_categories_log() from public, anon, authenticated;
revoke execute on function public.member_categories_release() from public, anon, authenticated;
revoke execute on function public.members_category_check() from public, anon, authenticated;

-- Rappels : la cotisation de chaque membre dépend de sa catégorie.
create or replace function public.due_reminders(p_date date)
returns table(endpoint text, p256dh text, auth text, title text, body text, url text, tag text)
language sql stable security definer set search_path = public as $$
  with cal as (
    select distinct on (a.id, to_char(r.ref, 'YYYY-MM')) a.*, to_char(r.ref, 'YYYY-MM') as period,
           make_date(extract(year from r.ref)::int, extract(month from r.ref)::int, a.fee_due_day) as due,
           (array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'])[extract(month from r.ref)::int] as month_fr
    from associations a cross join (values (p_date - 7), (p_date), (p_date + 3)) r(ref)
    where a.fee_amount > 0 or exists (select 1 from member_categories x where x.association_id = a.id and x.fee_amount > 0)
  ), owed as (
    select c.id as assoc_id, c.name, c.currency, c.fee_amount, c.period, c.due, c.month_fr, m.id as member_id, m.user_id, m.full_name,
           coalesce(mc.fee_amount, c.fee_amount) - coalesce((select sum(t.amount) from transactions t
              where t.member_id = m.id and t.category = 'Cotisations' and t.period = c.period), 0) as remaining
    from cal c join members m on m.association_id = c.id
    left join member_categories mc on mc.id = m.category_id
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
-- VillageLink 1.16 — Paiement des cotisations par mobile money (sans intermédiaire)
-- Le membre envoie l'argent avec son Wave / Orange Money / Free Money au numéro de réception
-- de l'association, puis le déclare. La cotisation ne compte qu'une fois confirmée par le trésorier
-- (ou le président, le vice-président, le trésorier de section). Rien ne s'efface.

-- 1. Numéros de réception de l'association
create table if not exists public.pay_numbers (
  association_id uuid primary key references public.associations(id) on delete cascade,
  holder     text not null default '' check (length(holder) <= 80),
  wave       text not null default '' check (wave   ~ '^(\+?[0-9 ]{8,20})?$'),
  orange     text not null default '' check (orange ~ '^(\+?[0-9 ]{8,20})?$'),
  free       text not null default '' check (free   ~ '^(\+?[0-9 ]{8,20})?$'),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.pay_numbers enable row level security;
create policy pay_numbers_select on public.pay_numbers for select to authenticated
  using (is_member(association_id));
grant select on public.pay_numbers to authenticated;

-- Seuls le président et le trésorier changent les numéros ; chaque changement va au journal (visible de tous).
create or replace function public.set_pay_numbers(p_assoc uuid, p_holder text, p_wave text, p_orange text, p_free text)
returns void language plpgsql security definer set search_path = public as $$
declare h text := trim(coalesce(p_holder, '')); w text := trim(coalesce(p_wave, ''));
        o text := trim(coalesce(p_orange, '')); f text := trim(coalesce(p_free, ''));
begin
  if not has_role(p_assoc, array['president','tresorier']) then
    raise exception 'Seuls le président et le trésorier changent les numéros de paiement.';
  end if;
  if (w <> '' or o <> '' or f <> '') and length(h) < 2 then
    raise exception 'Indiquez le nom qui s''affiche chez Wave ou Orange Money pour ces numéros.';
  end if;
  insert into pay_numbers(association_id, holder, wave, orange, free, updated_by, updated_at)
  values (p_assoc, h, w, o, f, auth.uid(), now())
  on conflict (association_id) do update
    set holder = excluded.holder, wave = excluded.wave, orange = excluded.orange, free = excluded.free,
        updated_by = excluded.updated_by, updated_at = now();
  perform write_log(p_assoc, format('a changé les numéros de paiement mobile money : Wave %s, Orange Money %s, Free Money %s (au nom de %s).',
    coalesce(nullif(w, ''), 'aucun'), coalesce(nullif(o, ''), 'aucun'), coalesce(nullif(f, ''), 'aucun'), coalesce(nullif(h, ''), '—')));
end $$;
revoke execute on function public.set_pay_numbers(uuid, text, text, text, text) from public, anon;
grant execute on function public.set_pay_numbers(uuid, text, text, text, text) to authenticated;

-- 2. Déclarations de paiement
create table if not exists public.payment_claims (
  id             bigint generated always as identity primary key,
  association_id uuid not null references public.associations(id) on delete cascade,
  member_id      uuid not null references public.members(id) on delete restrict,
  period         text not null check (period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  amount         bigint not null check (amount > 0 and amount <= 100000000),
  method         text not null check (method in ('Wave','Orange Money','Free Money')),
  sent_to        text not null default '',
  reference      text not null default '' check (length(reference) <= 60),
  status         text not null default 'pending' check (status in ('pending','confirmed','rejected','cancelled')),
  created_by     uuid references auth.users(id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now(),
  decided_by     uuid references auth.users(id) on delete set null,
  decided_label  text not null default '',
  decided_at     timestamptz,
  reason         text not null default '' check (length(reason) <= 200),
  transaction_id bigint references public.transactions(id) on delete restrict
);
create unique index if not exists claims_one_pending on public.payment_claims(member_id, period) where status = 'pending';
create index if not exists claims_assoc_idx on public.payment_claims(association_id, status, id desc);
create index if not exists claims_tx_idx on public.payment_claims(transaction_id);
alter table public.payment_claims enable row level security;
create policy claims_select on public.payment_claims for select to authenticated
  using (is_member(association_id));
grant select on public.payment_claims to authenticated;
-- Aucune écriture directe : tout passe par les fonctions ci-dessous.

create or replace function public.pfr(p text) returns text language sql immutable set search_path = public as $$
  select (array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'])
         [substr(p, 6, 2)::int] || ' ' || substr(p, 1, 4);
$$;

-- Le membre déclare SON paiement (jamais celui d'un autre).
create or replace function public.declare_payment(p_member uuid, p_period text, p_amount bigint, p_method text, p_reference text)
returns bigint language plpgsql security definer set search_path = public as $$
declare m members; pn pay_numbers; dest text; cur text; nid bigint; ref text := trim(coalesce(p_reference, ''));
begin
  select * into m from members where id = p_member;
  if m.id is null or m.user_id is distinct from auth.uid() or not m.active or m.pending then
    raise exception 'Vous ne pouvez déclarer que votre propre paiement.';
  end if;
  if p_period !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Choisissez le mois concerné.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Saisissez un montant supérieur à 0.'; end if;
  if p_method not in ('Wave','Orange Money','Free Money') then raise exception 'Mode de paiement inconnu.'; end if;
  if length(ref) > 60 then raise exception 'Référence trop longue.'; end if;
  select * into pn from pay_numbers where association_id = m.association_id;
  dest := case p_method when 'Wave' then pn.wave when 'Orange Money' then pn.orange else pn.free end;
  if coalesce(dest, '') = '' then raise exception 'L''association n''a pas de numéro % pour recevoir les cotisations.', p_method; end if;
  if exists (select 1 from payment_claims where member_id = m.id and period = p_period and status = 'pending') then
    raise exception 'Un paiement pour % est déjà en attente de confirmation.', pfr(p_period);
  end if;
  insert into payment_claims(association_id, member_id, period, amount, method, sent_to, reference, created_by)
  values (m.association_id, m.id, p_period, p_amount, p_method, dest || ' (' || pn.holder || ')', ref, auth.uid())
  returning id into nid;
  select currency into cur from associations where id = m.association_id;
  perform write_log(m.association_id, format('a déclaré avoir payé %s par %s pour %s%s. À confirmer par le trésorier.',
    fmt_money(p_amount, cur), p_method, pfr(p_period), case when ref <> '' then ' (réf. ' || ref || ')' else '' end));
  return nid;
end $$;

create or replace function public.cancel_payment_claim(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r payment_claims;
begin
  select * into r from payment_claims where id = p_id for update;
  if r.id is null or r.created_by is distinct from auth.uid() then raise exception 'Déclaration introuvable.'; end if;
  if r.status <> 'pending' then raise exception 'Cette déclaration a déjà été traitée.'; end if;
  update payment_claims set status = 'cancelled', decided_by = auth.uid(), decided_at = now() where id = p_id;
  perform write_log(r.association_id, format('a annulé sa déclaration de paiement pour %s.', pfr(r.period)));
end $$;

create or replace function public.can_collect_member(p_member uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members t where t.id = p_member
                   and (has_role(t.association_id, array['tresorier','president','vice_president'])
                        or is_section_treasurer(t.id)));
$$;

-- Confirmer : après avoir vu l'argent arriver dans SON application Wave / Orange Money.
create or replace function public.confirm_payment_claim(p_id bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare r payment_claims; tid bigint;
begin
  select * into r from payment_claims where id = p_id for update;
  if r.id is null or not can_collect_member(r.member_id) then
    raise exception 'Seuls le trésorier, le président, le vice-président ou le trésorier de section confirment un paiement.';
  end if;
  if r.status <> 'pending' then raise exception 'Cette déclaration a déjà été traitée.'; end if;
  insert into transactions(association_id, kind, category, amount, occurred_on, description, member_id, period, payment_method, comment)
  values (r.association_id, 'in', 'Cotisations', r.amount, r.created_at::date, 'Cotisation de ' || pfr(r.period), r.member_id, r.period, r.method,
          'Payé par ' || r.method || ' au ' || r.sent_to || case when r.reference <> '' then ', réf. ' || r.reference else '' end || '. Déclaré par le membre.')
  returning id into tid;
  update payment_claims set status = 'confirmed', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
         decided_at = now(), transaction_id = tid where id = p_id;
  return tid;
end $$;

create or replace function public.reject_payment_claim(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare r payment_claims; why text := trim(coalesce(p_reason, '')); who text;
begin
  select * into r from payment_claims where id = p_id for update;
  if r.id is null or not can_collect_member(r.member_id) then
    raise exception 'Seuls le trésorier, le président, le vice-président ou le trésorier de section refusent un paiement.';
  end if;
  if r.status <> 'pending' then raise exception 'Cette déclaration a déjà été traitée.'; end if;
  if length(why) < 3 then raise exception 'Indiquez pourquoi (par exemple : rien reçu sur Wave).'; end if;
  if length(why) > 200 then raise exception 'Motif trop long.'; end if;
  update payment_claims set status = 'rejected', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
         decided_at = now(), reason = why where id = p_id;
  select full_name into who from members where id = r.member_id;
  perform write_log(r.association_id, format('a refusé le paiement déclaré par %s pour %s. Motif : %s', who, pfr(r.period), why));
end $$;

revoke execute on function public.declare_payment(uuid, text, bigint, text, text) from public, anon;
revoke execute on function public.cancel_payment_claim(bigint) from public, anon;
revoke execute on function public.confirm_payment_claim(bigint) from public, anon;
revoke execute on function public.reject_payment_claim(bigint, text) from public, anon;
revoke execute on function public.can_collect_member(uuid) from public, anon;
grant execute on function public.declare_payment(uuid, text, bigint, text, text) to authenticated;
grant execute on function public.cancel_payment_claim(bigint) to authenticated;
grant execute on function public.confirm_payment_claim(bigint) to authenticated;
grant execute on function public.reject_payment_claim(bigint, text) to authenticated;
grant execute on function public.can_collect_member(uuid) to authenticated;
-- VillageLink 1.16b — Lien de paiement Wave (ouvre Wave avec le montant déjà rempli)
alter table public.pay_numbers add column if not exists wave_link text not null default ''
  check (wave_link ~ '^(https://pay\.wave\.com/m/[A-Za-z0-9_-]{4,40}/c/[a-z]{2}/)?$');

create or replace function public.set_pay_numbers(p_assoc uuid, p_holder text, p_wave text, p_orange text, p_free text, p_wave_link text)
returns void language plpgsql security definer set search_path = public as $$
declare l text := trim(coalesce(p_wave_link, ''));
begin
  l := split_part(split_part(l, '?', 1), '#', 1);
  if l <> '' and right(l, 1) <> '/' then l := l || '/'; end if;
  if l <> '' and l !~ '^https://pay\.wave\.com/m/[A-Za-z0-9_-]{4,40}/c/[a-z]{2}/$' then
    raise exception 'Le lien Wave doit commencer par https://pay.wave.com/m/ (copiez-le depuis Wave : Envoi de lien).';
  end if;
  perform public.set_pay_numbers(p_assoc, p_holder, p_wave, p_orange, p_free);
  update pay_numbers set wave_link = l where association_id = p_assoc;
  if l <> '' then perform write_log(p_assoc, format('a enregistré le lien de paiement Wave %s.', l)); end if;
end $$;
revoke execute on function public.set_pay_numbers(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.set_pay_numbers(uuid, text, text, text, text, text) to authenticated;
-- VillageLink 1.17 — Dispense temporaire de cotisation
-- Règle courante : un membre sans travail (au village ou au pays) ne cotise pas pendant cette période.
-- Pendant la dispense, aucun mois n'est dû ni relancé ; avant et après, il cotise normalement.
-- Seul le bureau l'accorde ; chaque dispense va au journal. Le motif n'est lisible que par le bureau.
create table if not exists public.member_exemptions (
  id             bigint generated always as identity primary key,
  association_id uuid not null references public.associations(id) on delete cascade,
  member_id      uuid not null references public.members(id) on delete cascade,
  from_period    text not null check (from_period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  to_period      text check (to_period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  reason         text not null default '' check (length(reason) <= 120),
  created_by     uuid references auth.users(id) on delete set null default auth.uid(),
  created_label  text not null default '',
  created_at     timestamptz not null default now(),
  ended_label    text not null default '',
  constraint exemption_order check (to_period is null or to_period >= from_period)
);
create index if not exists exemptions_member_idx on public.member_exemptions(member_id, from_period);
create index if not exists exemptions_assoc_idx on public.member_exemptions(association_id);
alter table public.member_exemptions enable row level security;
create policy exemptions_select on public.member_exemptions for select to authenticated
  using (is_member(association_id));
revoke all on public.member_exemptions from anon, authenticated;
grant select (id, association_id, member_id, from_period, to_period, created_label, created_at, ended_label)
  on public.member_exemptions to authenticated;

create or replace function public.is_exempt(p_member uuid, p_period text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from member_exemptions e where e.member_id = p_member
                   and e.from_period <= p_period and (e.to_period is null or e.to_period >= p_period));
$$;

-- Motifs : réservés au bureau
create or replace function public.exemption_reasons(p_assoc uuid) returns table(id bigint, reason text)
language sql stable security definer set search_path = public as $$
  select e.id, e.reason from member_exemptions e
  where e.association_id = p_assoc and has_role(p_assoc, array['president','vice_president','secretaire','tresorier']);
$$;

create or replace function public.grant_exemption(p_member uuid, p_from text, p_to text, p_reason text) returns bigint
language plpgsql security definer set search_path = public as $$
declare m members; t text := nullif(trim(coalesce(p_to, '')), ''); why text := trim(coalesce(p_reason, '')); nid bigint;
begin
  select * into m from members where id = p_member;
  if m.id is null or not has_role(m.association_id, array['president','vice_president','secretaire','tresorier']) then
    raise exception 'Seul le bureau peut dispenser un membre de cotisation.';
  end if;
  if not m.active or m.pending then raise exception 'Ce membre n''est pas actif.'; end if;
  if p_from !~ '^\d{4}-(0[1-9]|1[0-2])$' or (t is not null and t !~ '^\d{4}-(0[1-9]|1[0-2])$') then raise exception 'Mois invalide.'; end if;
  if t is not null and t < p_from then raise exception 'Le mois de fin doit venir après le mois de début.'; end if;
  if length(why) < 3 then raise exception 'Indiquez le motif (par exemple : sans travail, au village).'; end if;
  if length(why) > 120 then raise exception 'Motif trop long.'; end if;
  if exists (select 1 from member_exemptions e where e.member_id = m.id
               and e.from_period <= coalesce(t, '9999-12') and coalesce(e.to_period, '9999-12') >= p_from) then
    raise exception 'Ce membre a déjà une dispense sur cette période.';
  end if;
  insert into member_exemptions(association_id, member_id, from_period, to_period, reason, created_by, created_label)
  values (m.association_id, m.id, p_from, t, why, auth.uid(), actor_label(m.association_id)) returning id into nid;
  perform write_log(m.association_id, format('a dispensé %s de cotisation à partir de %s%s.', m.full_name, pfr(p_from),
    case when t is null then ' (jusqu''à nouvel ordre)' else ' jusqu''à ' || pfr(t) end));
  return nid;
end $$;

-- Fin de dispense : dernier mois dispensé (le membre recotise le mois suivant)
create or replace function public.end_exemption(p_id bigint, p_last text) returns void
language plpgsql security definer set search_path = public as $$
declare e member_exemptions; who text;
begin
  select * into e from member_exemptions where id = p_id for update;
  if e.id is null or not has_role(e.association_id, array['president','vice_president','secretaire','tresorier']) then
    raise exception 'Seul le bureau peut mettre fin à une dispense.';
  end if;
  if p_last !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Mois invalide.'; end if;
  if p_last < e.from_period then raise exception 'Le dernier mois dispensé ne peut pas être avant le début de la dispense.'; end if;
  if e.to_period is not null and p_last > e.to_period then raise exception 'La dispense finit déjà avant ce mois.'; end if;
  update member_exemptions set to_period = p_last, ended_label = actor_label(e.association_id) where id = p_id;
  select full_name into who from members where id = e.member_id;
  perform write_log(e.association_id, format('a mis fin à la dispense de %s (dernier mois dispensé : %s).', who, pfr(p_last)));
end $$;

revoke execute on function public.is_exempt(uuid, text) from public, anon;
revoke execute on function public.exemption_reasons(uuid) from public, anon;
revoke execute on function public.grant_exemption(uuid, text, text, text) from public, anon;
revoke execute on function public.end_exemption(bigint, text) from public, anon;
grant execute on function public.is_exempt(uuid, text) to authenticated;
grant execute on function public.exemption_reasons(uuid) to authenticated;
grant execute on function public.grant_exemption(uuid, text, text, text) to authenticated;
grant execute on function public.end_exemption(bigint, text) to authenticated;

-- Les rappels automatiques sautent les mois dispensés
create or replace function public.due_reminders(p_date date)
returns table(endpoint text, p256dh text, auth text, title text, body text, url text, tag text)
language sql stable security definer set search_path = public as $$
  with cal as (
    select distinct on (a.id, to_char(r.ref, 'YYYY-MM')) a.*, to_char(r.ref, 'YYYY-MM') as period,
           make_date(extract(year from r.ref)::int, extract(month from r.ref)::int, a.fee_due_day) as due,
           (array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'])[extract(month from r.ref)::int] as month_fr
    from associations a cross join (values (p_date - 7), (p_date), (p_date + 3)) r(ref)
    where a.fee_amount > 0 or exists (select 1 from member_categories x where x.association_id = a.id and x.fee_amount > 0)
  ), owed as (
    select c.id as assoc_id, c.name, c.currency, c.fee_amount, c.period, c.due, c.month_fr, m.id as member_id, m.user_id, m.full_name,
           coalesce(mc.fee_amount, c.fee_amount) - coalesce((select sum(t.amount) from transactions t
              where t.member_id = m.id and t.category = 'Cotisations' and t.period = c.period), 0) as remaining
    from cal c join members m on m.association_id = c.id
    left join member_categories mc on mc.id = m.category_id
    where m.active and not m.pending and m.user_id is not null
      and to_char(c.dues_start, 'YYYY-MM') <= c.period and to_char(m.joined_on, 'YYYY-MM') <= c.period
      and p_date in (c.due - 3, c.due, c.due + 7)
      and not public.is_exempt(m.id, c.period)
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
-- VillageLink 1.18 — Supprimer son compte depuis l'application (exigence Google Play)
-- Le compte de connexion disparaît. Les écritures du registre restent (elles appartiennent à
-- l'association) : seul leur lien vers le compte est effacé. La fiche de membre reste dans
-- l'association, sans compte lié ; le bureau peut la retirer.

-- Le registre reste intouchable, sauf une chose : effacer le lien vers un compte supprimé.
create or replace function public.forbid_change() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and tg_table_name = 'transactions' then
    if old.created_by is not null and new.created_by is null
       and (to_jsonb(new) - 'created_by') = (to_jsonb(old) - 'created_by') then
      return new;
    end if;
  end if;
  raise exception 'Cette ligne est définitive. Corrigez par une contre-écriture.' using errcode = '42501';
end $$;

create or replace function public.delete_my_account(p_confirm text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); bad text;
begin
  if uid is null then raise exception 'Connectez-vous d''abord.'; end if;
  if upper(trim(coalesce(p_confirm, ''))) <> 'SUPPRIMER' then
    raise exception 'Tapez SUPPRIMER pour confirmer.';
  end if;
  -- Une association avec d'autres membres doit garder un président qui a un compte.
  select string_agg(a.name, ', ') into bad
  from members m join associations a on a.id = m.association_id
  where m.user_id = uid and m.role = 'president' and m.active and not m.pending
    and exists (select 1 from members o where o.association_id = m.association_id and o.id <> m.id and o.active and not o.pending)
    and not exists (select 1 from members p where p.association_id = m.association_id and p.id <> m.id
                      and p.role = 'president' and p.active and not p.pending and p.user_id is not null);
  if bad is not null then
    raise exception 'Vous êtes le seul président de « % ». Nommez un autre président avant de supprimer votre compte.', bad;
  end if;
  perform write_log(m.association_id, format('%s a supprimé son compte VillageLink. Sa fiche de membre et l''historique restent.', m.full_name))
  from members m where m.user_id = uid and m.active and not m.pending;
  perform set_config('vl.system', 'on', true);
  delete from members where user_id = uid and pending
    and not exists (select 1 from transactions t where t.member_id = members.id)
    and not exists (select 1 from payment_claims c where c.member_id = members.id);
  delete from push_subscriptions where user_id = uid;
  delete from auth.users where id = uid;
  perform set_config('vl.system', '', true);
end $$;
revoke execute on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;

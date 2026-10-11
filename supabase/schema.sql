-- ============================================================================
-- VillageLink : structure complète de la base Supabase
-- ============================================================================
-- Exportée le 11 octobre 2026 depuis le projet ncghmfwfnzgdddnqgnnl
-- (PostgreSQL 17), à jour après la migration v1_4_reunions.
--
-- Contenu : tables, contraintes, index, fonctions, vues, déclencheurs,
-- règles RLS, droits d'accès et stockage des justificatifs.
-- Aucune donnée, aucun secret.
--
-- À quoi sert ce fichier :
--   1. Référence : la vraie définition de chaque règle de sécurité.
--   2. Secours : recréer la base sur un projet Supabase neuf, en collant
--      ce fichier dans l'éditeur SQL (projet vide uniquement).
--
-- À tenir à jour : après chaque nouvelle migration, régénérer ce fichier.
--
-- Note : le code des fonctions a été ré-aligné à gauche (la base contenait
-- des centaines d'espaces parasites en début de ligne). Le code lui-même est
-- identique à celui de la base.
-- ============================================================================

begin;

set local check_function_bodies = off;
set local search_path = public;

-- 1. Tables

create table public.associations (
  id uuid not null default gen_random_uuid(),
  name text not null,
  origin_country text not null default ''::text,
  region text not null default ''::text,
  prefecture text not null default ''::text,
  village text not null default ''::text,
  residence_country text not null default ''::text,
  residence_city text not null default ''::text,
  description text not null default ''::text,
  founded_on date,
  currency text not null default 'XOF'::text,
  fee_amount bigint not null default 0,
  fee_due_day integer not null default 5,
  dues_start date not null default (date_trunc('month'::text, now()))::date,
  invite_code text not null default upper(substr(replace((gen_random_uuid())::text, '-'::text, ''::text), 1, 8)),
  plan text not null default 'decouverte'::text,
  created_by uuid,
  created_at timestamp with time zone not null default now(),
  constraint associations_pkey PRIMARY KEY (id),
  constraint associations_invite_code_key UNIQUE (invite_code),
  constraint associations_currency_check CHECK ((currency = ANY (ARRAY['XOF'::text, 'GNF'::text, 'EUR'::text, 'USD'::text, 'XAF'::text, 'CAD'::text, 'GBP'::text]))),
  constraint associations_fee_amount_check CHECK ((fee_amount >= 0)),
  constraint associations_fee_due_day_check CHECK (((fee_due_day >= 1) AND (fee_due_day <= 28))),
  constraint associations_len CHECK (((length(origin_country) <= 80) AND (length(region) <= 80) AND (length(prefecture) <= 80) AND (length(village) <= 120) AND (length(residence_country) <= 80) AND (length(residence_city) <= 80) AND (length(description) <= 2000) AND (fee_amount <= 1000000000))) NOT VALID,
  constraint associations_name_check CHECK (((length(TRIM(BOTH FROM name)) >= 3) AND (length(TRIM(BOTH FROM name)) <= 140))),
  constraint associations_plan_check CHECK ((plan = ANY (ARRAY['decouverte'::text, 'association'::text, 'federation'::text])))
);

create table public.members (
  id uuid not null default gen_random_uuid(),
  association_id uuid not null,
  user_id uuid,
  full_name text not null,
  phone text not null default ''::text,
  email text not null default ''::text,
  city text not null default ''::text,
  country text not null default ''::text,
  role text not null default 'membre'::text,
  joined_on date not null default CURRENT_DATE,
  active boolean not null default true,
  created_at timestamp with time zone not null default now(),
  pending boolean not null default false,
  created_by_join boolean not null default false,
  constraint members_pkey PRIMARY KEY (id),
  constraint members_full_name_check CHECK (((length(TRIM(BOTH FROM full_name)) >= 2) AND (length(TRIM(BOTH FROM full_name)) <= 120))),
  constraint members_len CHECK (((length(phone) <= 40) AND (length(email) <= 160) AND (length(city) <= 80) AND (length(country) <= 80))) NOT VALID,
  constraint members_role_check CHECK ((role = ANY (ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text, 'tresorier'::text, 'projets'::text, 'membre'::text])))
);

create table public.projects (
  id uuid not null default gen_random_uuid(),
  association_id uuid not null,
  name text not null,
  type text not null default 'Autre'::text,
  description text not null default ''::text,
  goal bigint not null,
  lead_member_id uuid,
  status text not null default 'En préparation'::text,
  start_on date not null default CURRENT_DATE,
  end_on date,
  created_by uuid default auth.uid(),
  created_at timestamp with time zone not null default now(),
  constraint projects_pkey PRIMARY KEY (id),
  constraint projects_goal_check CHECK ((goal > 0)),
  constraint projects_len CHECK (((length(type) <= 60) AND (length(description) <= 4000) AND (goal <= '1000000000000'::bigint))) NOT VALID,
  constraint projects_name_check CHECK (((length(TRIM(BOTH FROM name)) >= 3) AND (length(TRIM(BOTH FROM name)) <= 140))),
  constraint projects_status_check CHECK ((status = ANY (ARRAY['En préparation'::text, 'En cours'::text, 'Suspendu'::text, 'Terminé'::text])))
);

create table public.transactions (
  id bigint generated always as identity not null,
  association_id uuid not null,
  kind text not null,
  category text not null,
  amount bigint not null,
  occurred_on date not null default CURRENT_DATE,
  description text not null,
  member_id uuid,
  period text,
  project_id uuid,
  payment_method text not null default ''::text,
  comment text not null default ''::text,
  proof_path text not null default ''::text,
  reversal_of bigint,
  created_by uuid default auth.uid(),
  created_at timestamp with time zone not null default now(),
  constraint transactions_pkey PRIMARY KEY (id),
  constraint transactions_reversal_of_key UNIQUE (reversal_of),
  constraint cotisation_has_member CHECK (((category <> 'Cotisations'::text) OR ((member_id IS NOT NULL) AND (period IS NOT NULL)))),
  constraint transactions_amount_check CHECK ((amount <> 0)),
  constraint transactions_category_check CHECK ((category = ANY (ARRAY['Cotisations'::text, 'Dons'::text, 'Contributions exceptionnelles'::text, 'Projet'::text, 'Transport'::text, 'Réunion'::text, 'Communication'::text, 'Administration'::text, 'Autres'::text]))),
  constraint transactions_description_check CHECK (((length(TRIM(BOTH FROM description)) >= 2) AND (length(TRIM(BOTH FROM description)) <= 300))),
  constraint transactions_kind_category CHECK ((((kind = 'in'::text) AND (category = ANY (ARRAY['Cotisations'::text, 'Dons'::text, 'Contributions exceptionnelles'::text, 'Autres'::text]))) OR ((kind = 'out'::text) AND (category = ANY (ARRAY['Projet'::text, 'Transport'::text, 'Réunion'::text, 'Communication'::text, 'Administration'::text, 'Autres'::text]))))) NOT VALID,
  constraint transactions_kind_check CHECK ((kind = ANY (ARRAY['in'::text, 'out'::text]))),
  constraint transactions_len CHECK (((length(payment_method) <= 40) AND (length(comment) <= 500) AND (length(proof_path) <= 300) AND (abs(amount) <= '1000000000000'::bigint))) NOT VALID,
  constraint transactions_period_check CHECK ((period ~ '^\d{4}-(0[1-9]|1[0-2])$'::text))
);

create table public.project_updates (
  id uuid not null default gen_random_uuid(),
  association_id uuid not null,
  project_id uuid not null,
  body text not null,
  created_by uuid default auth.uid(),
  created_at timestamp with time zone not null default now(),
  constraint project_updates_pkey PRIMARY KEY (id),
  constraint project_updates_body_check CHECK (((length(TRIM(BOTH FROM body)) >= 2) AND (length(TRIM(BOTH FROM body)) <= 2000)))
);

create table public.announcements (
  id uuid not null default gen_random_uuid(),
  association_id uuid not null,
  kind text not null default 'Annonce'::text,
  title text not null,
  body text not null,
  created_by uuid default auth.uid(),
  created_at timestamp with time zone not null default now(),
  constraint announcements_pkey PRIMARY KEY (id),
  constraint announcements_body_check CHECK (((length(TRIM(BOTH FROM body)) >= 2) AND (length(TRIM(BOTH FROM body)) <= 4000))),
  constraint announcements_kind_check CHECK ((kind = ANY (ARRAY['Annonce'::text, 'Information'::text, 'Convocation'::text, 'Nouvelles du village'::text, 'Urgence'::text]))),
  constraint announcements_title_check CHECK (((length(TRIM(BOTH FROM title)) >= 2) AND (length(TRIM(BOTH FROM title)) <= 160)))
);

create table public.activity_log (
  id bigint generated always as identity not null,
  association_id uuid not null,
  actor_id uuid,
  actor_label text not null default ''::text,
  message text not null,
  created_at timestamp with time zone not null default now(),
  constraint activity_log_pkey PRIMARY KEY (id)
);

create table public.messages (
  id bigint generated always as identity not null,
  association_id uuid not null,
  kind text not null default 'Message'::text,
  body text not null,
  author_id uuid default auth.uid(),
  author_label text not null default ''::text,
  hidden boolean not null default false,
  hidden_by text not null default ''::text,
  created_at timestamp with time zone not null default now(),
  constraint messages_pkey PRIMARY KEY (id),
  constraint messages_body_check CHECK (((length(TRIM(BOTH FROM body)) >= 1) AND (length(TRIM(BOTH FROM body)) <= 1000))),
  constraint messages_kind_check CHECK ((kind = ANY (ARRAY['Message'::text, 'Idée'::text, 'Réclamation'::text])))
);

create table public.meetings (
  id uuid not null default gen_random_uuid(),
  association_id uuid not null,
  title text not null,
  starts_at timestamp with time zone not null,
  place text not null default ''::text,
  agenda text not null default ''::text,
  status text not null default 'Prévue'::text,
  minutes text not null default ''::text,
  created_by uuid default auth.uid(),
  created_label text not null default ''::text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint meetings_pkey PRIMARY KEY (id),
  constraint meetings_agenda_check CHECK ((length(agenda) <= 4000)),
  constraint meetings_minutes_check CHECK ((length(minutes) <= 20000)),
  constraint meetings_place_check CHECK ((length(place) <= 200)),
  constraint meetings_status_check CHECK ((status = ANY (ARRAY['Prévue'::text, 'Tenue'::text, 'Annulée'::text]))),
  constraint meetings_title_check CHECK (((length(TRIM(BOTH FROM title)) >= 2) AND (length(TRIM(BOTH FROM title)) <= 160)))
);

create table public.meeting_attendance (
  meeting_id uuid not null,
  member_id uuid not null,
  association_id uuid not null,
  present boolean not null,
  marked_by text not null default ''::text,
  marked_at timestamp with time zone not null default now(),
  constraint meeting_attendance_pkey PRIMARY KEY (meeting_id, member_id)
);

-- 2. Clés étrangères

alter table only public.activity_log add constraint activity_log_association_id_fkey FOREIGN KEY (association_id) REFERENCES associations(id) ON DELETE CASCADE;

alter table only public.announcements add constraint announcements_association_id_fkey FOREIGN KEY (association_id) REFERENCES associations(id) ON DELETE CASCADE;

alter table only public.announcements add constraint announcements_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

alter table only public.associations add constraint associations_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

alter table only public.meeting_attendance add constraint meeting_attendance_association_id_fkey FOREIGN KEY (association_id) REFERENCES associations(id) ON DELETE CASCADE;

alter table only public.meeting_attendance add constraint meeting_attendance_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES meetings(id) ON DELETE CASCADE;

alter table only public.meeting_attendance add constraint meeting_attendance_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE CASCADE;

alter table only public.meetings add constraint meetings_association_id_fkey FOREIGN KEY (association_id) REFERENCES associations(id) ON DELETE CASCADE;

alter table only public.members add constraint members_association_id_fkey FOREIGN KEY (association_id) REFERENCES associations(id) ON DELETE CASCADE;

alter table only public.members add constraint members_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

alter table only public.messages add constraint messages_association_id_fkey FOREIGN KEY (association_id) REFERENCES associations(id) ON DELETE CASCADE;

alter table only public.project_updates add constraint project_updates_association_id_fkey FOREIGN KEY (association_id) REFERENCES associations(id) ON DELETE CASCADE;

alter table only public.project_updates add constraint project_updates_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

alter table only public.project_updates add constraint project_updates_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE;

alter table only public.projects add constraint projects_association_id_fkey FOREIGN KEY (association_id) REFERENCES associations(id) ON DELETE CASCADE;

alter table only public.projects add constraint projects_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

alter table only public.projects add constraint projects_lead_member_id_fkey FOREIGN KEY (lead_member_id) REFERENCES members(id) ON DELETE SET NULL;

alter table only public.transactions add constraint transactions_association_id_fkey FOREIGN KEY (association_id) REFERENCES associations(id) ON DELETE CASCADE;

alter table only public.transactions add constraint transactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;

alter table only public.transactions add constraint transactions_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE RESTRICT;

alter table only public.transactions add constraint transactions_project_id_fkey FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE RESTRICT;

alter table only public.transactions add constraint transactions_reversal_of_fkey FOREIGN KEY (reversal_of) REFERENCES transactions(id) ON DELETE RESTRICT;

-- 3. Index

CREATE INDEX attendance_assoc_idx ON public.meeting_attendance USING btree (association_id);

CREATE INDEX log_assoc_idx ON public.activity_log USING btree (association_id, id DESC);

CREATE INDEX meetings_assoc_idx ON public.meetings USING btree (association_id, starts_at DESC);

CREATE INDEX members_assoc_idx ON public.members USING btree (association_id);

CREATE UNIQUE INDEX members_assoc_user_uniq ON public.members USING btree (association_id, user_id) WHERE (user_id IS NOT NULL);

CREATE INDEX messages_assoc_idx ON public.messages USING btree (association_id, id DESC);

CREATE INDEX projects_assoc_idx ON public.projects USING btree (association_id);

CREATE INDEX tx_assoc_idx ON public.transactions USING btree (association_id, occurred_on DESC, id DESC);

CREATE INDEX tx_member_idx ON public.transactions USING btree (member_id, period);

CREATE INDEX tx_project_idx ON public.transactions USING btree (project_id);

-- 4. Fonctions

CREATE OR REPLACE FUNCTION public.actor_label(assoc uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.associations_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
if new.invite_code <> old.invite_code and coalesce(current_setting('vl.system', true), '') <> 'on' then
raise exception 'Le code d''invitation se change avec la fonction prévue.';
end if;
if new.plan <> old.plan and coalesce(current_setting('vl.system', true), '') <> 'on' then
raise exception 'L''offre se change par VillageLink.';
end if;
return new;
end
$function$;

CREATE OR REPLACE FUNCTION public.attendance_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.content_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.create_association(p_name text, p_full_name text, p_phone text, p_origin_country text, p_region text, p_prefecture text, p_village text, p_residence_country text, p_residence_city text, p_currency text, p_fee_amount bigint, p_fee_due_day integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.fmt_money(amount bigint, cur text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
select replace(to_char(abs(amount), 'FM999,999,999,999,990'), ',', ' ') || ' ' ||
case cur when 'XOF' then 'FCFA' when 'XAF' then 'FCFA' when 'GNF' then 'GNF' else cur end;
$function$;

CREATE OR REPLACE FUNCTION public.forbid_change()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
raise exception 'Cette ligne est définitive. Corrigez par une contre-écriture.' using errcode = '42501';
end
$function$;

CREATE OR REPLACE FUNCTION public.force_creator()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
new.created_by := auth.uid();
return new;
end
$function$;

CREATE OR REPLACE FUNCTION public.has_role(assoc uuid, roles text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
select exists (select 1 from members m
where m.association_id = assoc and m.user_id = auth.uid()
and m.active and not m.pending and m.role = any(roles));
$function$;

CREATE OR REPLACE FUNCTION public.hide_message(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.is_member(assoc uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
select exists (select 1 from members m
where m.association_id = assoc and m.user_id = auth.uid() and m.active and not m.pending);
$function$;

CREATE OR REPLACE FUNCTION public.join_association(p_code text, p_full_name text, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.meetings_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.meetings_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.members_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.members_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
if coalesce(current_setting('vl.system', true), '') = 'on' then return null; end if;
if tg_op = 'INSERT' then
perform write_log(new.association_id, format('a ajouté %s comme membre.', new.full_name));
elsif new.role <> old.role then
perform write_log(new.association_id, format('a changé le rôle de %s.', new.full_name));
elsif new.active <> old.active then
perform write_log(new.association_id, format('a %s %s.',
case when new.active then 'réactivé' else 'désactivé' end, new.full_name));
end if;
return null;
end
$function$;

CREATE OR REPLACE FUNCTION public.messages_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
new.author_id := auth.uid();
new.author_label := actor_label(new.association_id);
new.hidden := false;
new.hidden_by := '';
new.created_at := now();
return new;
end
$function$;

CREATE OR REPLACE FUNCTION public.my_memberships()
 RETURNS TABLE(association_id uuid, name text, village text, residence_city text, pending boolean, active boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
select a.id, a.name, a.village, a.residence_city, m.pending, m.active
from members m join associations a on a.id = m.association_id
where m.user_id = auth.uid()
order by a.created_at;
$function$;

CREATE OR REPLACE FUNCTION public.project_update_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
if not exists (select 1 from projects where id = new.project_id and association_id = new.association_id) then
raise exception 'Projet inconnu dans cette association.';
end if;
new.created_by := auth.uid();
return new;
end
$function$;

CREATE OR REPLACE FUNCTION public.projects_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
if tg_op = 'UPDATE' and new.association_id <> old.association_id then
raise exception 'Un projet ne change pas d''association.';
end if;
if new.lead_member_id is not null and not exists
(select 1 from members where id = new.lead_member_id and association_id = new.association_id) then
raise exception 'Responsable inconnu dans cette association.';
end if;
return new;
end
$function$;

CREATE OR REPLACE FUNCTION public.regenerate_invite_code(p_assoc uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c text := upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
begin
if not has_role(p_assoc, array['president']) then raise exception 'Réservé au président.'; end if;
perform set_config('vl.system', 'on', true);
update associations set invite_code = c where id = p_assoc;
perform set_config('vl.system', 'off', true);
return c;
end
$function$;

CREATE OR REPLACE FUNCTION public.reverse_transaction(p_id bigint, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.review_join(p_member uuid, p_accept boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.tx_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.tx_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end
$function$;

CREATE OR REPLACE FUNCTION public.write_log(assoc uuid, msg text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
insert into activity_log(association_id, actor_id, actor_label, message)
values (assoc, auth.uid(), actor_label(assoc), msg);
$function$;

-- 5. Vues

create or replace view public.v_balances with (security_invoker=true) as
SELECT association_id,
COALESCE(sum(amount) FILTER (WHERE kind = 'in'::text), 0::numeric) AS total_in,
COALESCE(sum(amount) FILTER (WHERE kind = 'out'::text), 0::numeric) AS total_out
FROM transactions
GROUP BY association_id;

create or replace view public.v_member_paid with (security_invoker=true) as
SELECT association_id,
member_id,
period,
sum(amount) AS paid
FROM transactions
WHERE category = 'Cotisations'::text
GROUP BY association_id, member_id, period;

create or replace view public.v_project_totals with (security_invoker=true) as
SELECT project_id,
COALESCE(sum(amount) FILTER (WHERE kind = 'in'::text), 0::numeric) AS collected,
COALESCE(sum(amount) FILTER (WHERE kind = 'out'::text), 0::numeric) AS spent
FROM transactions
WHERE project_id IS NOT NULL
GROUP BY project_id;

create or replace view public.v_category_totals with (security_invoker=true) as
SELECT association_id,
kind,
category,
sum(amount) AS total
FROM transactions
GROUP BY association_id, kind, category;

-- 6. Déclencheurs (triggers)

CREATE TRIGGER log_no_update BEFORE DELETE OR UPDATE ON activity_log FOR EACH ROW EXECUTE FUNCTION forbid_change();

CREATE TRIGGER ann_creator BEFORE INSERT ON announcements FOR EACH ROW EXECUTE FUNCTION force_creator();

CREATE TRIGGER ann_log AFTER INSERT ON announcements FOR EACH ROW EXECUTE FUNCTION content_log();

CREATE TRIGGER associations_guard BEFORE UPDATE ON associations FOR EACH ROW EXECUTE FUNCTION associations_guard();

CREATE TRIGGER attendance_check BEFORE INSERT OR UPDATE ON meeting_attendance FOR EACH ROW EXECUTE FUNCTION attendance_check();

CREATE TRIGGER meetings_guard BEFORE INSERT OR UPDATE ON meetings FOR EACH ROW EXECUTE FUNCTION meetings_guard();

CREATE TRIGGER meetings_log AFTER INSERT OR UPDATE ON meetings FOR EACH ROW EXECUTE FUNCTION meetings_log();

CREATE TRIGGER members_guard BEFORE INSERT OR UPDATE ON members FOR EACH ROW EXECUTE FUNCTION members_guard();

CREATE TRIGGER members_log AFTER INSERT OR UPDATE ON members FOR EACH ROW EXECUTE FUNCTION members_log();

CREATE TRIGGER messages_check BEFORE INSERT ON messages FOR EACH ROW EXECUTE FUNCTION messages_check();

CREATE TRIGGER project_update_check BEFORE INSERT ON project_updates FOR EACH ROW EXECUTE FUNCTION project_update_check();

CREATE TRIGGER updates_log AFTER INSERT ON project_updates FOR EACH ROW EXECUTE FUNCTION content_log();

CREATE TRIGGER projects_creator BEFORE INSERT ON projects FOR EACH ROW EXECUTE FUNCTION force_creator();

CREATE TRIGGER projects_guard BEFORE INSERT OR UPDATE ON projects FOR EACH ROW EXECUTE FUNCTION projects_guard();

CREATE TRIGGER projects_log AFTER INSERT OR UPDATE ON projects FOR EACH ROW EXECUTE FUNCTION content_log();

CREATE TRIGGER tx_check BEFORE INSERT ON transactions FOR EACH ROW EXECUTE FUNCTION tx_check();

CREATE TRIGGER tx_log AFTER INSERT ON transactions FOR EACH ROW EXECUTE FUNCTION tx_log();

CREATE TRIGGER tx_no_update BEFORE DELETE OR UPDATE ON transactions FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- 7. Sécurité au niveau des lignes (RLS)

alter table public.activity_log enable row level security;

alter table public.announcements enable row level security;

alter table public.associations enable row level security;

alter table public.meeting_attendance enable row level security;

alter table public.meetings enable row level security;

alter table public.members enable row level security;

alter table public.messages enable row level security;

alter table public.project_updates enable row level security;

alter table public.projects enable row level security;

alter table public.transactions enable row level security;

-- 8. Politiques RLS

create policy log_select on public.activity_log for select to authenticated
  using (is_member(association_id));

create policy ann_insert on public.announcements for insert to authenticated
  with check (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text]));

create policy ann_select on public.announcements for select to authenticated
  using (is_member(association_id));

create policy assoc_select on public.associations for select to authenticated
  using (is_member(id));

create policy assoc_update on public.associations for update to authenticated
  using (has_role(id, ARRAY['president'::text]))
  with check (has_role(id, ARRAY['president'::text]));

create policy attendance_delete on public.meeting_attendance for delete to authenticated
  using (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text]));

create policy attendance_insert on public.meeting_attendance for insert to authenticated
  with check (has_role(( SELECT m.association_id
   FROM meetings m
  WHERE (m.id = meeting_attendance.meeting_id)), ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text]));

create policy attendance_select on public.meeting_attendance for select to authenticated
  using (is_member(association_id));

create policy attendance_update on public.meeting_attendance for update to authenticated
  using (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text]))
  with check (has_role(( SELECT m.association_id
   FROM meetings m
  WHERE (m.id = meeting_attendance.meeting_id)), ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text]));

create policy meetings_insert on public.meetings for insert to authenticated
  with check (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text]));

create policy meetings_select on public.meetings for select to authenticated
  using (is_member(association_id));

create policy meetings_update on public.meetings for update to authenticated
  using (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text]))
  with check (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text]));

create policy members_insert on public.members for insert to authenticated
  with check (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text, 'tresorier'::text]));

create policy members_select on public.members for select to authenticated
  using (is_member(association_id));

create policy members_update on public.members for update to authenticated
  using (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text, 'tresorier'::text]))
  with check (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'secretaire'::text, 'tresorier'::text]));

create policy messages_insert on public.messages for insert to authenticated
  with check (is_member(association_id));

create policy messages_select on public.messages for select to authenticated
  using (is_member(association_id));

create policy updates_insert on public.project_updates for insert to authenticated
  with check (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'projets'::text]));

create policy updates_select on public.project_updates for select to authenticated
  using (is_member(association_id));

create policy projects_insert on public.projects for insert to authenticated
  with check (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'projets'::text]));

create policy projects_select on public.projects for select to authenticated
  using (is_member(association_id));

create policy projects_update on public.projects for update to authenticated
  using (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'projets'::text]))
  with check (has_role(association_id, ARRAY['president'::text, 'vice_president'::text, 'projets'::text]));

create policy tx_insert on public.transactions for insert to authenticated
  with check (((reversal_of IS NULL) AND (amount > 0) AND (((kind = 'in'::text) AND has_role(association_id, ARRAY['tresorier'::text, 'president'::text, 'vice_president'::text])) OR ((kind = 'out'::text) AND has_role(association_id, ARRAY['tresorier'::text])))));

create policy tx_select on public.transactions for select to authenticated
  using (is_member(association_id));

-- 9. Droits sur les tables et vues

revoke all on table public.activity_log from public, anon, authenticated;
grant select on table public.activity_log to authenticated;

revoke all on table public.announcements from public, anon, authenticated;
grant insert, select on table public.announcements to authenticated;

revoke all on table public.associations from public, anon, authenticated;
grant select, update on table public.associations to authenticated;

revoke all on table public.meeting_attendance from public, anon, authenticated;
grant delete, insert, select, update on table public.meeting_attendance to authenticated;

revoke all on table public.meetings from public, anon, authenticated;
grant insert, select, update on table public.meetings to authenticated;

revoke all on table public.members from public, anon, authenticated;
grant insert, select, update on table public.members to authenticated;

revoke all on table public.messages from public, anon, authenticated;
grant insert, select on table public.messages to authenticated;

revoke all on table public.project_updates from public, anon, authenticated;
grant insert, select on table public.project_updates to authenticated;

revoke all on table public.projects from public, anon, authenticated;
grant insert, select, update on table public.projects to authenticated;

revoke all on table public.transactions from public, anon, authenticated;
grant insert, select on table public.transactions to authenticated;

revoke all on table public.v_balances from public, anon, authenticated;
grant select on table public.v_balances to authenticated;

revoke all on table public.v_category_totals from public, anon, authenticated;
grant select on table public.v_category_totals to authenticated;

revoke all on table public.v_member_paid from public, anon, authenticated;
grant select on table public.v_member_paid to authenticated;

revoke all on table public.v_project_totals from public, anon, authenticated;
grant select on table public.v_project_totals to authenticated;

-- 10. Droits sur les fonctions

revoke all on function public.actor_label(assoc uuid) from public, anon, authenticated;
grant execute on function public.actor_label(assoc uuid) to public, anon, authenticated;

revoke all on function public.associations_guard() from public, anon, authenticated;
grant execute on function public.associations_guard() to public, anon, authenticated;

revoke all on function public.attendance_check() from public, anon, authenticated;

revoke all on function public.content_log() from public, anon, authenticated;
grant execute on function public.content_log() to public, anon, authenticated;

revoke all on function public.create_association(p_name text, p_full_name text, p_phone text, p_origin_country text, p_region text, p_prefecture text, p_village text, p_residence_country text, p_residence_city text, p_currency text, p_fee_amount bigint, p_fee_due_day integer) from public, anon, authenticated;
grant execute on function public.create_association(p_name text, p_full_name text, p_phone text, p_origin_country text, p_region text, p_prefecture text, p_village text, p_residence_country text, p_residence_city text, p_currency text, p_fee_amount bigint, p_fee_due_day integer) to authenticated;

revoke all on function public.fmt_money(amount bigint, cur text) from public, anon, authenticated;
grant execute on function public.fmt_money(amount bigint, cur text) to public, anon, authenticated;

revoke all on function public.forbid_change() from public, anon, authenticated;
grant execute on function public.forbid_change() to public, anon, authenticated;

revoke all on function public.force_creator() from public, anon, authenticated;
grant execute on function public.force_creator() to public, anon, authenticated;

revoke all on function public.has_role(assoc uuid, roles text[]) from public, anon, authenticated;
grant execute on function public.has_role(assoc uuid, roles text[]) to public, anon, authenticated;

revoke all on function public.hide_message(p_id bigint) from public, anon, authenticated;
grant execute on function public.hide_message(p_id bigint) to authenticated;

revoke all on function public.is_member(assoc uuid) from public, anon, authenticated;
grant execute on function public.is_member(assoc uuid) to public, anon, authenticated;

revoke all on function public.join_association(p_code text, p_full_name text, p_phone text) from public, anon, authenticated;
grant execute on function public.join_association(p_code text, p_full_name text, p_phone text) to authenticated;

revoke all on function public.meetings_guard() from public, anon, authenticated;

revoke all on function public.meetings_log() from public, anon, authenticated;

revoke all on function public.members_guard() from public, anon, authenticated;
grant execute on function public.members_guard() to public, anon, authenticated;

revoke all on function public.members_log() from public, anon, authenticated;
grant execute on function public.members_log() to public, anon, authenticated;

revoke all on function public.messages_check() from public, anon, authenticated;
grant execute on function public.messages_check() to public, anon, authenticated;

revoke all on function public.my_memberships() from public, anon, authenticated;
grant execute on function public.my_memberships() to authenticated;

revoke all on function public.project_update_check() from public, anon, authenticated;
grant execute on function public.project_update_check() to public, anon, authenticated;

revoke all on function public.projects_guard() from public, anon, authenticated;
grant execute on function public.projects_guard() to public, anon, authenticated;

revoke all on function public.regenerate_invite_code(p_assoc uuid) from public, anon, authenticated;
grant execute on function public.regenerate_invite_code(p_assoc uuid) to authenticated;

revoke all on function public.reverse_transaction(p_id bigint, p_reason text) from public, anon, authenticated;
grant execute on function public.reverse_transaction(p_id bigint, p_reason text) to authenticated;

revoke all on function public.review_join(p_member uuid, p_accept boolean) from public, anon, authenticated;
grant execute on function public.review_join(p_member uuid, p_accept boolean) to authenticated;

revoke all on function public.tx_check() from public, anon, authenticated;
grant execute on function public.tx_check() to public, anon, authenticated;

revoke all on function public.tx_log() from public, anon, authenticated;
grant execute on function public.tx_log() to public, anon, authenticated;

revoke all on function public.write_log(assoc uuid, msg text) from public, anon, authenticated;

-- 11. Stockage des justificatifs

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proofs', 'proofs', false, 5242880, '{image/jpeg,image/png,image/webp,image/heic,application/pdf}'::text[])
on conflict (id) do nothing;

create policy proofs_read on storage.objects for select to authenticated
  using (((bucket_id = 'proofs'::text) AND is_member(((storage.foldername(name))[1])::uuid)));

create policy proofs_write on storage.objects for insert to authenticated
  with check (((bucket_id = 'proofs'::text) AND has_role(((storage.foldername(name))[1])::uuid, ARRAY['tresorier'::text, 'president'::text, 'vice_president'::text])));

commit;

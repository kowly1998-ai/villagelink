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

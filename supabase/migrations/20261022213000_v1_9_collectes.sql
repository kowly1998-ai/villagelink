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

-- v2.2.3 : historique des montants de cotisation.
-- Changer le montant (association ou catégorie) ou la catégorie d'un membre ne touche plus
-- les mois passés : chaque mois garde le montant valable à ce moment-là.

create table if not exists public.fee_history (
  id bigserial primary key,
  association_id uuid not null references public.associations(id) on delete cascade,
  category_id uuid references public.member_categories(id) on delete cascade,
  from_period text not null check (from_period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  fee_amount bigint not null check (fee_amount >= 0),
  created_at timestamptz not null default now()
);
create unique index if not exists fee_history_one_per_month
  on public.fee_history (association_id, coalesce(category_id, '00000000-0000-0000-0000-000000000000'::uuid), from_period);

create table if not exists public.member_category_history (
  id bigserial primary key,
  association_id uuid not null references public.associations(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  category_id uuid references public.member_categories(id) on delete set null,
  from_period text not null check (from_period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  created_at timestamptz not null default now(),
  unique (member_id, from_period)
);

alter table public.fee_history enable row level security;
alter table public.member_category_history enable row level security;
drop policy if exists fee_history_select on public.fee_history;
create policy fee_history_select on public.fee_history for select to authenticated using (is_member(association_id));
drop policy if exists member_category_history_select on public.member_category_history;
create policy member_category_history_select on public.member_category_history for select to authenticated using (is_member(association_id));
revoke all on public.fee_history, public.member_category_history from anon, authenticated;
grant select on public.fee_history, public.member_category_history to authenticated;

-- Point de départ : les montants et catégories actuels valent pour tout le passé.
insert into public.fee_history (association_id, category_id, from_period, fee_amount)
  select id, null, '2000-01', fee_amount from public.associations
  on conflict do nothing;
insert into public.fee_history (association_id, category_id, from_period, fee_amount)
  select association_id, id, '2000-01', fee_amount from public.member_categories
  on conflict do nothing;
insert into public.member_category_history (association_id, member_id, category_id, from_period)
  select association_id, id, category_id, '2000-01' from public.members
  on conflict do nothing;

-- Enregistrement automatique, à partir du mois en cours.
create or replace function public.fee_history_track() returns trigger
language plpgsql security definer set search_path = public as $$
declare p text := to_char(now() at time zone 'utc', 'YYYY-MM'); a uuid; c uuid;
begin
  if tg_table_name = 'associations' then a := new.id; c := null;
  else a := new.association_id; c := new.id; end if;
  if tg_op = 'INSERT' then p := '2000-01';
  elsif new.fee_amount is not distinct from old.fee_amount then return new; end if;
  insert into fee_history (association_id, category_id, from_period, fee_amount) values (a, c, p, new.fee_amount)
  on conflict (association_id, (coalesce(category_id, '00000000-0000-0000-0000-000000000000'::uuid)), from_period)
  do update set fee_amount = excluded.fee_amount, created_at = now();
  return new;
end $$;

create or replace function public.member_category_track() returns trigger
language plpgsql security definer set search_path = public as $$
declare p text := to_char(now() at time zone 'utc', 'YYYY-MM');
begin
  if tg_op = 'INSERT' then p := '2000-01';
  elsif new.category_id is not distinct from old.category_id then return new; end if;
  insert into member_category_history (association_id, member_id, category_id, from_period)
  values (new.association_id, new.id, new.category_id, p)
  on conflict (member_id, from_period) do update set category_id = excluded.category_id, created_at = now();
  return new;
end $$;

revoke execute on function public.fee_history_track(), public.member_category_track() from public, anon, authenticated;

drop trigger if exists zz_fee_history on public.associations;
create trigger zz_fee_history after insert or update of fee_amount on public.associations
  for each row execute function public.fee_history_track();
drop trigger if exists zz_fee_history on public.member_categories;
create trigger zz_fee_history after insert or update of fee_amount on public.member_categories
  for each row execute function public.fee_history_track();
drop trigger if exists zz_category_history on public.members;
create trigger zz_category_history after insert or update of category_id on public.members
  for each row execute function public.member_category_track();

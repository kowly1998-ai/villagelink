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

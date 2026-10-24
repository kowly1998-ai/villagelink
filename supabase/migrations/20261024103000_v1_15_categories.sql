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

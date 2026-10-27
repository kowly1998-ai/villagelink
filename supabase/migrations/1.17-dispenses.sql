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

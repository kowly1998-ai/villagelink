-- VillageLink 2.2 — Renforcements de sécurité
-- 1. Limite d'essais du code d'invitation (8 essais ratés par 15 minutes et par compte).
-- 2. assoc_status et is_exempt ne répondent qu'aux membres de l'association (ou au propriétaire,
--    ou aux tâches du système : alertes automatiques, déclencheurs).

create table if not exists public.join_attempts (
  id      bigint generated always as identity primary key,
  user_id uuid not null,
  at      timestamptz not null default now()
);
alter table public.join_attempts enable row level security;
revoke all on public.join_attempts from anon, authenticated;
create index if not exists join_attempts_user_idx on public.join_attempts (user_id, at);

create or replace function public.join_association(p_code text, p_full_name text, p_phone text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare a uuid; m uuid; digits text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if length(trim(coalesce(p_full_name,''))) < 2 then raise exception 'Saisissez votre nom complet.'; end if;
  delete from join_attempts where at < now() - interval '1 day';
  if (select count(*) from join_attempts where user_id = auth.uid() and at > now() - interval '15 minutes') >= 8 then
    raise exception 'Trop d’essais. Réessayez dans 15 minutes.';
  end if;
  select id into a from associations where invite_code = upper(trim(p_code));
  if a is null then
    insert into join_attempts(user_id) values (auth.uid());
    return null;   -- code inconnu : l'essai est gardé, l'application affiche le message
  end if;
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

create or replace function public.assoc_status(p_assoc uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when a.blocked_at is not null then 'blocked'
    when a.paid_until is not null and a.paid_until >= current_date then 'active'
    when a.paid_until is null and a.trial_ends >= current_date then 'trial'
    when greatest(coalesce(a.paid_until, a.trial_ends), a.trial_ends) + 7 >= current_date then 'grace'
    else 'readonly' end
  from associations a
  where a.id = p_assoc
    and (auth.uid() is null or is_member(p_assoc) or am_owner()
         or coalesce(current_setting('vl.system', true), '') = 'on');
$$;

create or replace function public.is_exempt(p_member uuid, p_period text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from member_exemptions e where e.member_id = p_member
                   and e.from_period <= p_period and (e.to_period is null or e.to_period >= p_period)
                   and (auth.uid() is null or is_member(e.association_id) or am_owner()
                        or coalesce(current_setting('vl.system', true), '') = 'on'));
$$;

-- VillageLink 2.1 — Blocage d'une association par le propriétaire
-- Une association bloquée passe en LECTURE SEULE : tout reste visible, plus rien ne s'enregistre.
-- Les membres voient le motif. Le propriétaire débloque d'un clic. Rien n'est supprimé.

alter table public.associations add column if not exists blocked_at timestamptz;
alter table public.associations add column if not exists blocked_reason text;

-- Le blocage ne se change que par VillageLink (fonctions owner_block / owner_unblock).
create or replace function public.associations_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.invite_code <> old.invite_code and coalesce(current_setting('vl.system', true), '') <> 'on' then
    raise exception 'Le code d''invitation se change avec la fonction prévue.';
  end if;
  if (new.plan <> old.plan or new.trial_ends is distinct from old.trial_ends or new.paid_until is distinct from old.paid_until
      or new.blocked_at is distinct from old.blocked_at or new.blocked_reason is distinct from old.blocked_reason)
     and coalesce(current_setting('vl.system', true), '') <> 'on' then
    raise exception 'L''offre se change par VillageLink.';
  end if;
  return new;
end $$;

-- État : blocked | trial | active | grace | readonly
create or replace function public.assoc_status(p_assoc uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when a.blocked_at is not null then 'blocked'
    when a.paid_until is not null and a.paid_until >= current_date then 'active'
    when a.paid_until is null and a.trial_ends >= current_date then 'trial'
    when greatest(coalesce(a.paid_until, a.trial_ends), a.trial_ends) + 7 >= current_date then 'grace'
    else 'readonly' end
  from associations a where a.id = p_assoc;
$$;

create or replace function public.enforce_subscription() returns trigger
language plpgsql security definer set search_path = public as $$
declare st text; why text;
begin
  if coalesce(current_setting('vl.system', true), '') = 'on' then return new; end if;
  st := assoc_status(new.association_id);
  if st = 'blocked' then
    select blocked_reason into why from associations where id = new.association_id;
    raise exception 'Association suspendue par VillageLink : %. Écrivez à contact@villagelinkafrica.com.', coalesce(why, 'contactez VillageLink') using errcode = '42501';
  elsif st = 'readonly' then
    raise exception 'L’essai gratuit de VillageLink est terminé : l’association est en lecture seule. Le président peut activer l’abonnement dans Plus → Abonnement.' using errcode = '42501';
  end if;
  return new;
end $$;
revoke execute on function public.enforce_subscription() from public, anon, authenticated;

create or replace function public.owner_block(p_assoc uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare why text := trim(coalesce(p_reason, ''));
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  if length(why) < 3 then raise exception 'Indiquez le motif.'; end if;
  if not exists (select 1 from associations where id = p_assoc) then raise exception 'Association introuvable.'; end if;
  perform set_config('vl.system', 'on', true);
  update associations set blocked_at = now(), blocked_reason = left(why, 200) where id = p_assoc;
  insert into activity_log(association_id, actor_id, actor_label, message)
  values (p_assoc, null, 'VillageLink', format('a suspendu l’association. Motif : %s', left(why, 200)));
  perform set_config('vl.system', '', true);
end $$;

create or replace function public.owner_unblock(p_assoc uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  perform set_config('vl.system', 'on', true);
  update associations set blocked_at = null, blocked_reason = null where id = p_assoc and blocked_at is not null;
  if found then
    insert into activity_log(association_id, actor_id, actor_label, message)
    values (p_assoc, null, 'VillageLink', 'a levé la suspension. L’association est de nouveau active.');
  end if;
  perform set_config('vl.system', '', true);
end $$;

create or replace function public.owner_subscriptions() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from app_admins where user_id = auth.uid()) then raise exception 'Réservé au propriétaire de VillageLink.'; end if;
  return jsonb_build_object(
    'requests', coalesce((select jsonb_agg(row_to_json(x) order by x.id) from (
        select r.*, a.name as assoc_name from subscription_requests r join associations a on a.id = r.association_id
        where r.status = 'pending') x), '[]'::jsonb),
    'assocs', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'plan', a.plan,
        'trial_ends', a.trial_ends, 'paid_until', a.paid_until, 'status', assoc_status(a.id),
        'blocked_reason', a.blocked_reason,
        'members', (select count(*) from members m where m.association_id = a.id and m.active and not m.pending))
        order by coalesce(a.paid_until, a.trial_ends)) from associations a), '[]'::jsonb));
end $$;

revoke execute on function public.owner_block(uuid, text) from public, anon;
revoke execute on function public.owner_unblock(uuid) from public, anon;
grant execute on function public.owner_block(uuid, text) to authenticated;
grant execute on function public.owner_unblock(uuid) to authenticated;

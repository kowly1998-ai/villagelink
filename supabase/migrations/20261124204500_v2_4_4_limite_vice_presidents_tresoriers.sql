-- VillageLink 2.4.4 — Au plus 3 vice-présidents et 3 trésoriers actifs par association
-- (décision d'Alpha du 24/11/2026). Comme pour le président, la règle bloque seulement le fait
-- de DEVENIR vice-président ou trésorier quand la limite est atteinte (ajout, changement de rôle,
-- réintégration) ; une association déjà au-dessus garde ses membres et peut les changer de rôle.

create or replace function public.role_cap(p_role text) returns integer
language sql immutable set search_path = public as $$
  select case p_role when 'vice_president' then 3 when 'tresorier' then 3 else null end
$$;

create or replace function public.members_role_cap_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare cap integer := role_cap(new.role);
begin
  if coalesce(current_setting('vl.system', true), '') = 'on' or cap is null then
    return new;
  end if;
  if new.active and not new.pending
     and (tg_op = 'INSERT' or old.role <> new.role or not old.active or old.pending)
     and (select count(*) from members where association_id = new.association_id
            and role = new.role and active and not pending and id <> new.id) >= cap then
    raise exception 'L''association a déjà % %s. Changez d''abord le rôle de l''un d''eux.',
      cap, case new.role when 'vice_president' then 'vice-président' else 'trésorier' end;
  end if;
  return new;
end $$;
revoke execute on function public.members_role_cap_check() from public, anon, authenticated;
drop trigger if exists members_role_cap_check on public.members;
create trigger members_role_cap_check before insert or update on public.members
  for each row execute function public.members_role_cap_check();

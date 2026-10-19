-- VillageLink 1.4.1 : journal « a retiré X de l'association » / « a réintégré X »
create or replace function public.members_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('vl.system', true), '') = 'on' then return null; end if;
  if tg_op = 'INSERT' then
    perform write_log(new.association_id, format('a ajouté %s comme membre.', new.full_name));
  elsif new.role <> old.role then
    perform write_log(new.association_id, format('a changé le rôle de %s.', new.full_name));
  elsif new.active <> old.active then
    perform write_log(new.association_id, case when new.active
      then format('a réintégré %s dans l''association.', new.full_name)
      else format('a retiré %s de l''association.', new.full_name) end);
  end if;
  return null;
end $$;

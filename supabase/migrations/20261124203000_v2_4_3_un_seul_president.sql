-- VillageLink 2.4.3 — Un seul président par association, et passation de la présidence
-- Une association n'a plus qu'un président actif. On ne peut plus nommer un deuxième
-- président (ajout, changement de rôle ou réintégration). Pour céder le rôle, le président
-- appelle transfer_presidency : le nouveau devient président et l'ancien prend le rôle choisi.
-- Les associations qui ont déjà deux présidents les gardent : la règle ne bloque que
-- le fait de DEVENIR président.

create or replace function public.members_one_president_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('vl.system', true), '') = 'on'
     or coalesce(current_setting('vl.transfer', true), '') = 'on' then
    return new;
  end if;
  if new.role = 'president' and new.active and not new.pending
     and (tg_op = 'INSERT' or old.role <> 'president' or not old.active or old.pending)
     and exists (select 1 from members where association_id = new.association_id
                   and role = 'president' and active and not pending and id <> new.id) then
    raise exception 'L''association a déjà un président. Pour céder ce rôle, utilisez « Passer la présidence » sur la fiche du nouveau président.';
  end if;
  return new;
end $$;
revoke execute on function public.members_one_president_check() from public, anon, authenticated;
drop trigger if exists members_one_president_check on public.members;
create trigger members_one_president_check before insert or update on public.members
  for each row execute function public.members_one_president_check();

create or replace function public.transfer_presidency(p_member uuid, p_my_role text) returns void
language plpgsql security definer set search_path = public as $$
declare me members; t members;
begin
  select * into t from members where id = p_member;
  if t.id is null then raise exception 'Membre introuvable.'; end if;
  select * into me from members where association_id = t.association_id and user_id = auth.uid()
    and role = 'president' and active and not pending limit 1;
  if me.id is null then raise exception 'Seul le président peut passer la présidence.'; end if;
  if t.id = me.id then raise exception 'Choisissez un autre membre.'; end if;
  if not t.active or t.pending then raise exception 'Ce membre n''est pas actif dans l''association.'; end if;
  if t.user_id is null then
    raise exception '% n''a pas encore de compte VillageLink relié. Il doit d''abord rejoindre l''association avec le code d''invitation.', t.full_name;
  end if;
  if p_my_role not in ('vice_president', 'secretaire', 'tresorier', 'projets', 'membre') then
    raise exception 'Choisissez votre nouveau rôle.';
  end if;
  perform set_config('vl.transfer', 'on', true);
  update members set role = 'president' where id = t.id;
  perform set_config('vl.transfer', 'off', true);
  update members set role = p_my_role where id = me.id;
  perform write_log(t.association_id, format('a passé la présidence à %s.', t.full_name));
end $$;
revoke execute on function public.transfer_presidency(uuid, text) from public, anon;
grant execute on function public.transfer_presidency(uuid, text) to authenticated;

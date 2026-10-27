-- VillageLink 1.18 — Supprimer son compte depuis l'application (exigence Google Play)
-- Le compte de connexion disparaît. Les écritures du registre restent (elles appartiennent à
-- l'association) : seul leur lien vers le compte est effacé. La fiche de membre reste dans
-- l'association, sans compte lié ; le bureau peut la retirer.

-- Le registre reste intouchable, sauf une chose : effacer le lien vers un compte supprimé.
create or replace function public.forbid_change() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and tg_table_name = 'transactions' then
    if old.created_by is not null and new.created_by is null
       and (to_jsonb(new) - 'created_by') = (to_jsonb(old) - 'created_by') then
      return new;
    end if;
  end if;
  raise exception 'Cette ligne est définitive. Corrigez par une contre-écriture.' using errcode = '42501';
end $$;

create or replace function public.delete_my_account(p_confirm text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); bad text;
begin
  if uid is null then raise exception 'Connectez-vous d''abord.'; end if;
  if upper(trim(coalesce(p_confirm, ''))) <> 'SUPPRIMER' then
    raise exception 'Tapez SUPPRIMER pour confirmer.';
  end if;
  -- Une association avec d'autres membres doit garder un président qui a un compte.
  select string_agg(a.name, ', ') into bad
  from members m join associations a on a.id = m.association_id
  where m.user_id = uid and m.role = 'president' and m.active and not m.pending
    and exists (select 1 from members o where o.association_id = m.association_id and o.id <> m.id and o.active and not o.pending)
    and not exists (select 1 from members p where p.association_id = m.association_id and p.id <> m.id
                      and p.role = 'president' and p.active and not p.pending and p.user_id is not null);
  if bad is not null then
    raise exception 'Vous êtes le seul président de « % ». Nommez un autre président avant de supprimer votre compte.', bad;
  end if;
  perform write_log(m.association_id, format('%s a supprimé son compte VillageLink. Sa fiche de membre et l''historique restent.', m.full_name))
  from members m where m.user_id = uid and m.active and not m.pending;
  perform set_config('vl.system', 'on', true);
  delete from members where user_id = uid and pending
    and not exists (select 1 from transactions t where t.member_id = members.id)
    and not exists (select 1 from payment_claims c where c.member_id = members.id);
  delete from push_subscriptions where user_id = uid;
  delete from auth.users where id = uid;
  perform set_config('vl.system', '', true);
end $$;
revoke execute on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;

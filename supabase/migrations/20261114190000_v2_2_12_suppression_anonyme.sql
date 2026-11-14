-- v2.2.12 : suppression de compte conforme à Google Play et au droit d'effacement.
--
-- Avant : seul le compte de connexion était effacé ; la fiche de membre gardait le nom, le
-- téléphone et l'e-mail, et les messages restaient signés.
-- Maintenant, à la suppression du compte :
--   * chaque fiche de membre liée devient « Ancien membre » : nom remplacé, téléphone, e-mail,
--     ville et pays effacés, rôle remis à « membre », fiche retirée (plus de cotisation due) ;
--   * ses messages de discussion (texte et vocaux) sont supprimés. L'application efface d'abord
--     les fichiers vocaux eux-mêmes (règle voice_delete_own ci-dessous) ;
--   * restent, sans nom : montants, dates et modes de paiement (comptes de l'association),
--     votes déjà comptés, présences, et le journal d'activité (ajout seul, transparence).

set lock_timeout = '5s';
set statement_timeout = '60s';

create or replace function public.delete_my_account(p_confirm text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); bad text;
begin
  if uid is null then raise exception 'Connectez-vous d''abord.'; end if;
  if upper(trim(coalesce(p_confirm, ''))) <> 'SUPPRIMER' then raise exception 'Tapez SUPPRIMER pour confirmer.'; end if;
  select string_agg(a.name, ', ') into bad
  from members m join associations a on a.id = m.association_id
  where m.user_id = uid and m.role = 'president' and m.active and not m.pending
    and exists (select 1 from members o where o.association_id = m.association_id and o.id <> m.id and o.active and not o.pending)
    and not exists (select 1 from members p where p.association_id = m.association_id and p.id <> m.id
                      and p.role = 'president' and p.active and not p.pending and p.user_id is not null);
  if bad is not null then
    raise exception 'Vous êtes le seul président de « % ». Nommez un autre président avant de supprimer votre compte.', bad;
  end if;
  perform write_log(m.association_id, 'Un membre a supprimé son compte VillageLink. Sa fiche devient « Ancien membre » ; les montants restent dans les comptes.')
  from members m where m.user_id = uid and m.active and not m.pending;
  perform set_config('vl.system', 'on', true);
  delete from members where user_id = uid and pending
    and not exists (select 1 from transactions t where t.member_id = members.id)
    and not exists (select 1 from payment_claims c where c.member_id = members.id);
  update members set full_name = 'Ancien membre', phone = '', email = '', city = '', country = '',
         role = 'membre', active = false
   where user_id = uid;
  delete from messages where author_id = uid;
  delete from push_subscriptions where user_id = uid;
  delete from auth.users where id = uid;
  perform set_config('vl.system', '', true);
end $$;
revoke execute on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;

-- Chacun peut effacer les fichiers vocaux qu'il a lui-même envoyés (avant de supprimer son compte).
drop policy if exists voice_delete_own on storage.objects;
create policy voice_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'voice' and owner_id = (select auth.uid())::text);

reset statement_timeout;
reset lock_timeout;

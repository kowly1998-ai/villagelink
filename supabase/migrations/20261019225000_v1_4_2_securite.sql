-- VillageLink 1.4.2 : sécurité
-- 1. Chemin de recherche figé sur les 4 fonctions qui ne l'avaient pas.
alter function public.fmt_money(bigint, text) set search_path = public;
alter function public.forbid_change() set search_path = public;
alter function public.force_creator() set search_path = public;
alter function public.associations_guard() set search_path = public;

-- 2. Les fonctions de trigger et les outils internes ne s'appellent pas depuis l'API.
--    (Un trigger s'exécute même sans ce droit : il est vérifié à la création du trigger.)
revoke execute on function public.associations_guard() from public, anon, authenticated;
revoke execute on function public.content_log() from public, anon, authenticated;
revoke execute on function public.forbid_change() from public, anon, authenticated;
revoke execute on function public.force_creator() from public, anon, authenticated;
revoke execute on function public.members_guard() from public, anon, authenticated;
revoke execute on function public.members_log() from public, anon, authenticated;
revoke execute on function public.messages_check() from public, anon, authenticated;
revoke execute on function public.project_update_check() from public, anon, authenticated;
revoke execute on function public.projects_guard() from public, anon, authenticated;
revoke execute on function public.tx_check() from public, anon, authenticated;
revoke execute on function public.tx_log() from public, anon, authenticated;
revoke execute on function public.actor_label(uuid) from public, anon, authenticated;
revoke execute on function public.fmt_money(bigint, text) from public, anon, authenticated;

-- 3. is_member et has_role servent dans les règles d'accès : réservées aux comptes connectés.
revoke execute on function public.is_member(uuid) from public, anon;
revoke execute on function public.has_role(uuid, text[]) from public, anon;
grant execute on function public.is_member(uuid) to authenticated;
grant execute on function public.has_role(uuid, text[]) to authenticated;

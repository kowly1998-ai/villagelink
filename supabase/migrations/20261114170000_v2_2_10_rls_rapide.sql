-- v2.2.10 : lecture rapide malgré des années d'historique (bug 4).
--
-- Problème : les règles de lecture appelaient is_member(association_id) pour CHAQUE ligne lue.
-- Avec 38 000 opérations, une page de v_member_paid prenait environ 1 s, et loadCtx en charge
-- des dizaines toutes les 15 secondes.
--
-- Correction : une seule question par requête. my_assoc_ids() renvoie, en une fois, la liste des
-- associations où la personne connectée est membre actif et validé (même condition exacte que
-- is_member : user_id = auth.uid(), active, not pending). Chaque règle compare ensuite
-- association_id à cette liste. Écrit « (select my_assoc_ids()) », Postgres calcule la liste une
-- seule fois au début de la requête (InitPlan) au lieu d'une fois par ligne.
--
-- Les droits ne changent pas :
--   association_id = any(liste)  <=>  il existe une fiche (association_id, auth.uid(), active, not pending)
--                                <=>  is_member(association_id)
--   Sans connexion (auth.uid() nul) la liste est vide : aucune ligne, comme avant.
--   Seules les règles de LECTURE (select) changent. Les règles d'écriture (has_role, with check)
--   et les règles du stockage (fichiers) restent identiques.
--   is_member et has_role restent en place : elles servent dans les fonctions et le stockage.
--
-- Index ajoutés pour les lectures de loadCtx et les suppressions en cascade (petites tables :
-- création en quelques millisecondes ; voir le rapport pour la version CONCURRENTLY).
-- Rejouable : create or replace, alter policy (change la règle en une seule étape, sans moment
-- où la table resterait sans règle), create index if not exists.

set lock_timeout = '5s';
set statement_timeout = '60s';

-- ---------------------------------------------------------------------
-- 1. Les associations de la personne connectée, calculées une fois
-- ---------------------------------------------------------------------
create or replace function public.my_assoc_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(m.association_id), '{}'::uuid[])
  from members m
  where m.user_id = auth.uid() and m.active and not m.pending;
$$;
revoke all on function public.my_assoc_ids() from public, anon;
grant execute on function public.my_assoc_ids() to authenticated;

-- Recherche par compte (my_assoc_ids, my_memberships, cast_vote...) : members_assoc_user_uniq
-- commence par association_id et ne sert pas à chercher par user_id seul.
create index if not exists members_user_idx on public.members(user_id) where user_id is not null;

-- ---------------------------------------------------------------------
-- 2. Règles de lecture : même condition, calculée une fois
-- ---------------------------------------------------------------------
alter policy assoc_select on public.associations
  using (id = any ((select public.my_assoc_ids())::uuid[]));

alter policy members_select on public.members
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy tx_select on public.transactions
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy projects_select on public.projects
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy updates_select on public.project_updates
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy ann_select on public.announcements
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy log_select on public.activity_log
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy messages_select on public.messages
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy meetings_select on public.meetings
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy attendance_select on public.meeting_attendance
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy polls_select on public.polls
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy poll_options_select on public.poll_options
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

-- Bulletins : inchangé (on voit le sien ; ceux des autres seulement si le vote n'est pas secret).
alter policy poll_votes_select on public.poll_votes
  using (association_id = any ((select public.my_assoc_ids())::uuid[]) and (
    member_id in (select m.id from public.members m where m.user_id = (select auth.uid()))
    or exists (select 1 from public.polls p where p.id = poll_id and not p.anonymous)));

alter policy documents_select on public.documents
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy expense_requests_select on public.expense_requests
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy collections_select on public.collections
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy sections_select on public.sections
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy member_categories_select on public.member_categories
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy pay_numbers_select on public.pay_numbers
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy claims_select on public.payment_claims
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy exemptions_select on public.member_exemptions
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy subreq_select on public.subscription_requests
  using (association_id = any ((select public.my_assoc_ids())::uuid[]) or (select public.am_owner()));

alter policy fee_history_select on public.fee_history
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

alter policy member_category_history_select on public.member_category_history
  using (association_id = any ((select public.my_assoc_ids())::uuid[]));

-- messages_insert (with check is_member) reste tel quel : il ne s'applique qu'à la ligne écrite.

-- ---------------------------------------------------------------------
-- 3. Index manquants (lectures filtrées par association, suppressions en cascade)
-- ---------------------------------------------------------------------
-- v_member_paid : lit seulement les cotisations d'une association, déjà dans l'ordre de l'app.
create index if not exists tx_dues_idx on public.transactions(association_id, period, member_id)
  include (amount) where category = 'Cotisations';
create index if not exists updates_assoc_idx on public.project_updates(association_id);
create index if not exists updates_project_idx on public.project_updates(project_id, created_at desc);
create index if not exists ann_assoc_idx on public.announcements(association_id, created_at desc);
create index if not exists poll_options_assoc_idx on public.poll_options(association_id);
create index if not exists cat_history_assoc_idx on public.member_category_history(association_id);
create index if not exists claims_member_idx on public.payment_claims(member_id, id desc);

reset statement_timeout;
reset lock_timeout;

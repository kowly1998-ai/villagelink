-- VillageLink 1.19b — Corrections de l'audit de sécurité du 28 octobre 2026
-- 1. Les membres doivent pouvoir lire les demandes d'abonnement de leur association
--    (la règle interrogeait app_admins, table illisible pour eux : erreur pour tous).
drop policy if exists subreq_select on public.subscription_requests;
create policy subreq_select on public.subscription_requests for select to authenticated
  using (is_member(association_id) or am_owner());

-- 2. Aucun droit d'écriture direct sur ces tables (tout passe par les fonctions contrôlées),
--    et aucun droit pour les visiteurs non connectés.
revoke all on public.pay_numbers, public.payment_claims, public.subscription_requests from anon;
revoke insert, update, delete, truncate, references, trigger
  on public.pay_numbers, public.payment_claims, public.subscription_requests from authenticated;

-- 3. Chemin de recherche figé pour les deux fonctions de garde.
alter function public.forbid_change() set search_path = public;
alter function public.associations_guard() set search_path = public;

-- v2.3.8 : réglages de performance signalés par Supabase (aucun changement de droits)
-- 1) La règle de lecture de push_subscriptions calcule auth.uid() une seule fois par requête.
drop policy if exists push_select on public.push_subscriptions;
create policy push_select on public.push_subscriptions
  for select to authenticated
  using (user_id = (select auth.uid()));

-- 2) Index sur les clés étrangères qui n'en avaient pas.
create index if not exists announcements_created_by_idx on public.announcements (created_by);
create index if not exists associations_created_by_idx on public.associations (created_by);
create index if not exists expense_requests_collection_id_idx on public.expense_requests (collection_id);
create index if not exists expense_requests_project_id_idx on public.expense_requests (project_id);
create index if not exists expense_requests_tx_id_idx on public.expense_requests (tx_id);
create index if not exists fee_history_category_id_idx on public.fee_history (category_id);
create index if not exists meeting_attendance_member_id_idx on public.meeting_attendance (member_id);
create index if not exists member_category_history_category_id_idx on public.member_category_history (category_id);
create index if not exists member_exemptions_created_by_idx on public.member_exemptions (created_by);
create index if not exists pay_numbers_updated_by_idx on public.pay_numbers (updated_by);
create index if not exists payment_claims_created_by_idx on public.payment_claims (created_by);
create index if not exists payment_claims_decided_by_idx on public.payment_claims (decided_by);
create index if not exists poll_votes_member_id_idx on public.poll_votes (member_id);
create index if not exists poll_votes_option_id_idx on public.poll_votes (option_id);
create index if not exists project_updates_created_by_idx on public.project_updates (created_by);
create index if not exists projects_created_by_idx on public.projects (created_by);
create index if not exists projects_lead_member_id_idx on public.projects (lead_member_id);
create index if not exists sections_treasurer_member_id_idx on public.sections (treasurer_member_id);
create index if not exists subscription_requests_created_by_idx on public.subscription_requests (created_by);
create index if not exists transactions_created_by_idx on public.transactions (created_by);

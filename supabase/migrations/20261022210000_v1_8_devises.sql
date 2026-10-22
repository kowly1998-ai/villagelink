-- ---------------------------------------------------------------------
-- Plusieurs devises (version 1.8)
-- La caisse reste tenue dans la monnaie de l'association. Un paiement reçu dans une
-- autre monnaie garde son montant d'origine et le taux utilisé, visibles par tous.
-- ---------------------------------------------------------------------
alter table public.transactions add column if not exists orig_amount numeric(16,2);
alter table public.transactions add column if not exists orig_currency text not null default '';
alter table public.transactions add column if not exists fx_rate numeric(18,6);
alter table public.expense_requests add column if not exists orig_amount numeric(16,2);
alter table public.expense_requests add column if not exists orig_currency text not null default '';
alter table public.expense_requests add column if not exists fx_rate numeric(18,6);

alter table public.transactions add constraint transactions_fx check (
  (orig_currency = '' and orig_amount is null and fx_rate is null) or
  (orig_currency in ('XOF','GNF','EUR','USD','XAF','CAD','GBP') and orig_amount <> 0 and abs(orig_amount) <= 1000000000000
   and fx_rate > 0 and fx_rate <= 1000000)) not valid;
alter table public.expense_requests add constraint expense_requests_fx check (
  (orig_currency = '' and orig_amount is null and fx_rate is null) or
  (orig_currency in ('XOF','GNF','EUR','USD','XAF','CAD','GBP') and orig_amount > 0 and orig_amount <= 1000000000000
   and fx_rate > 0 and fx_rate <= 1000000)) not valid;

-- Le montant enregistré dans la caisse doit correspondre au montant d'origine × taux
-- (à une unité près pour l'arrondi). Une autre monnaie ne peut pas être la monnaie de l'association.
create or replace function public.fx_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur text;
begin
  if new.orig_currency = '' or coalesce(current_setting('vl.reversing', true), '') = 'on' then return new; end if;
  select currency into cur from associations where id = new.association_id;
  if new.orig_currency = cur then
    raise exception 'La monnaie d''origine est déjà celle de l''association.';
  end if;
  if abs(round(new.orig_amount * new.fx_rate) - new.amount) > 1 then
    raise exception 'Le montant converti ne correspond pas au taux indiqué.';
  end if;
  return new;
end $$;
create trigger transactions_fx_check before insert on public.transactions
  for each row execute function public.fx_check();
create trigger expense_requests_fx_check before insert on public.expense_requests
  for each row execute function public.fx_check();
revoke execute on function public.fx_check() from public, anon, authenticated;

-- Une contre-écriture reprend la monnaie d'origine (montant négatif) ; une dépense approuvée aussi.
create or replace function public.reverse_transaction(p_id bigint, p_reason text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare t transactions; new_id bigint;
begin
  select * into t from transactions where id = p_id;
  if t.id is null then raise exception 'Opération introuvable.'; end if;
  if not has_role(t.association_id, array['tresorier']) then
    raise exception 'Seul le trésorier peut annuler une opération.';
  end if;
  if t.reversal_of is not null then raise exception 'Une contre-écriture ne s''annule pas.'; end if;
  if exists (select 1 from transactions where reversal_of = p_id) then
    raise exception 'Cette opération est déjà annulée.';
  end if;
  if length(trim(coalesce(p_reason,''))) < 4 then raise exception 'Indiquez le motif de l''annulation.'; end if;
  perform set_config('vl.reversing', 'on', true);
  insert into transactions(association_id, kind, category, amount, occurred_on, description,
                           member_id, period, project_id, payment_method, comment, reversal_of,
                           orig_amount, orig_currency, fx_rate)
  values (t.association_id, t.kind, t.category, -t.amount, current_date,
          'Contre-écriture de TX-' || lpad(t.id::text, 5, '0'),
          t.member_id, t.period, t.project_id, '', trim(p_reason), t.id,
          -t.orig_amount, t.orig_currency, t.fx_rate)
  returning id into new_id;
  perform set_config('vl.reversing', 'off', true);
  return new_id;
end $$;

create or replace function public.approve_expense(p_id bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare r expense_requests; tid bigint; bal bigint; cur text;
begin
  select * into r from expense_requests where id = p_id for update;
  if r.id is null or not has_role(r.association_id, array['president','vice_president']) then
    raise exception 'Réservé au président et au vice-président.';
  end if;
  if r.status <> 'En attente' then raise exception 'Cette dépense a déjà été traitée.'; end if;
  if r.requested_by = auth.uid() then raise exception 'La personne qui propose une dépense ne peut pas l''approuver.'; end if;
  select coalesce(sum(amount) filter (where kind = 'in'), 0) - coalesce(sum(amount) filter (where kind = 'out'), 0)
    into bal from transactions where association_id = r.association_id;
  select currency into cur from associations where id = r.association_id;
  if r.amount > bal then
    raise exception 'Solde insuffisant : la caisse contient %.', fmt_money(bal, cur);
  end if;
  perform set_config('vl.approving', 'on', true);
  insert into transactions(association_id, kind, category, amount, occurred_on, description, project_id,
                           comment, proof_path, created_by, approved_label, requested_label,
                           orig_amount, orig_currency, fx_rate)
  values (r.association_id, 'out', r.category, r.amount, r.occurred_on, r.description, r.project_id,
          r.comment, r.proof_path, r.requested_by, actor_label(r.association_id), r.requested_label,
          r.orig_amount, r.orig_currency, r.fx_rate)
  returning id into tid;
  perform set_config('vl.approving', 'off', true);
  update expense_requests set status = 'Approuvée', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
    decided_at = now(), tx_id = tid where id = r.id;
  perform write_log(r.association_id, format('a approuvé la dépense de %s : %s (proposée par %s).',
    fmt_money(r.amount, cur), r.description, r.requested_label));
  return tid;
end $$;

-- v2.3.9 (audit du 16/11/2026)
-- 1) Un paiement déclaré plus grand que la cotisation du mois est réparti sur les mois suivants
--    à la confirmation (même règle que spread() dans app.js : 24 mois au plus, mois dispensés sautés).
--    Avant : tout le montant restait sur un seul mois et le membre paraissait en retard le mois suivant.
-- 2) Une opération ou une dépense ne peut plus porter une date future (elle manquerait dans les rapports).

create or replace function public.confirm_payment_claim(p_id bigint)
 returns bigint
 language plpgsql
 security definer
 set search_path = public
as $function$
declare r payment_claims; tid bigint; first_id bigint; rem bigint; p text; k int := 0;
        fee bigint; paid bigint; take bigint; cur text; note text;
begin
  select * into r from payment_claims where id = p_id for update;
  if r.id is null or not can_collect_member(r.member_id) then
    raise exception 'Seuls le trésorier, le président, le vice-président ou le trésorier de section confirment un paiement.';
  end if;
  if r.status <> 'pending' then raise exception 'Cette déclaration a déjà été traitée.'; end if;
  if r.created_by = auth.uid() or exists (select 1 from members m where m.id = r.member_id and m.user_id = auth.uid()) then
    raise exception 'Vous ne pouvez pas confirmer votre propre paiement. Un autre membre du bureau doit le faire.';
  end if;
  note := 'Payé par ' || r.method || ' au ' || r.sent_to || case when r.reference <> '' then ', réf. ' || r.reference else '' end || '. Déclaré par le membre.';
  fee := fee_of(r.member_id, r.period);
  select coalesce(sum(amount), 0) into paid from transactions
   where member_id = r.member_id and period = r.period and category = 'Cotisations';
  if fee <= 0 or r.amount <= fee - paid then
    -- Cas simple : le montant tient dans le mois déclaré (ou pas de cotisation fixée).
    -- Un mois déjà payé est refusé par le trigger tx_month_paid_check.
    insert into transactions(association_id, kind, category, amount, occurred_on, description, member_id, period, payment_method, comment)
    values (r.association_id, 'in', 'Cotisations', r.amount, r.created_at::date, 'Cotisation de ' || pfr(r.period), r.member_id, r.period, r.method, note)
    returning id into first_id;
  else
    if paid >= fee then
      raise exception '% est déjà payé pour ce membre. Choisissez un autre mois, ou refusez la déclaration si elle fait doublon.',
        initcap(pfr(r.period)) using errcode = '23P01';
    end if;
    select currency into cur from associations where id = r.association_id;
    note := left(note || ' Paiement de ' || fmt_money(r.amount, cur) || ' réparti sur plusieurs mois.', 500);
    rem := r.amount; p := r.period;
    while rem > 0 and k < 24 loop
      k := k + 1;
      if k = 1 or not is_exempt(r.member_id, p) then
        fee := fee_of(r.member_id, p);
        select coalesce(sum(amount), 0) into paid from transactions
         where member_id = r.member_id and period = p and category = 'Cotisations';
        if fee - paid > 0 then
          take := least(rem, fee - paid);
          insert into transactions(association_id, kind, category, amount, occurred_on, description, member_id, period, payment_method, comment)
          values (r.association_id, 'in', 'Cotisations', take, r.created_at::date, 'Cotisation de ' || pfr(p), r.member_id, p, r.method, note)
          returning id into tid;
          if first_id is null then first_id := tid; end if;
          rem := rem - take;
        end if;
      end if;
      p := to_char(to_date(p || '-01', 'YYYY-MM-DD') + interval '1 month', 'YYYY-MM');
    end loop;
    if rem > 0 then
      raise exception 'Ce montant couvre plus de 24 mois de cotisation. Vérifiez avec le membre, puis refusez la déclaration ou encaissez à la main.';
    end if;
  end if;
  update payment_claims set status = 'confirmed', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
         decided_at = now(), transaction_id = first_id where id = p_id;
  return first_id;
end $function$;

create or replace function public.tx_check()
 returns trigger
 language plpgsql
 security definer
 set search_path = public
as $function$
begin
  if new.member_id is not null and not exists
     (select 1 from members where id = new.member_id and association_id = new.association_id) then
    raise exception 'Membre inconnu dans cette association.';
  end if;
  if new.project_id is not null and not exists
     (select 1 from projects where id = new.project_id and association_id = new.association_id) then
    raise exception 'Projet inconnu dans cette association.';
  end if;
  if new.proof_path <> '' and (new.proof_path not like new.association_id::text || '/%' or new.proof_path like '%..%') then
    raise exception 'Justificatif invalide.';
  end if;
  if new.reversal_of is null and new.amount <= 0 then
    raise exception 'Le montant doit être supérieur à 0.';
  end if;
  -- Un jour de marge pour les fuseaux horaires (le serveur est à l'heure UTC).
  if new.reversal_of is null and new.occurred_on > (now() at time zone 'utc')::date + 1 then
    raise exception 'La date ne peut pas être dans le futur.';
  end if;
  if new.reversal_of is not null and coalesce(current_setting('vl.reversing', true), '') <> 'on' then
    raise exception 'Une contre-écriture passe par la fonction prévue.';
  end if;
  if coalesce(current_setting('vl.approving', true), '') <> 'on' then
    new.created_by := auth.uid();
    new.approved_label := '';
    new.requested_label := '';
  end if;
  new.created_at := now();
  return new;
end $function$;

create or replace function public.expense_requests_check()
 returns trigger
 language plpgsql
 security definer
 set search_path = public
as $function$
begin
  if new.project_id is not null and not exists
     (select 1 from projects where id = new.project_id and association_id = new.association_id) then
    raise exception 'Projet inconnu dans cette association.';
  end if;
  if new.proof_path <> '' and (new.proof_path not like new.association_id::text || '/%' or new.proof_path like '%..%') then
    raise exception 'Justificatif invalide.';
  end if;
  if new.occurred_on > (now() at time zone 'utc')::date + 1 then
    raise exception 'La date ne peut pas être dans le futur.';
  end if;
  new.status := 'En attente';
  new.requested_by := auth.uid();
  new.requested_label := actor_label(new.association_id);
  new.decided_by := null; new.decided_label := ''; new.decided_at := null; new.decision_note := ''; new.tx_id := null;
  new.created_at := now();
  return new;
end $function$;

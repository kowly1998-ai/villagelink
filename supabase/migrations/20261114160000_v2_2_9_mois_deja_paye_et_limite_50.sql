-- v2.2.9 : deux corrections trouvées par le test de résistance du 14/11/2026.
--
-- (1) Un mois déjà payé ne peut plus être encaissé une deuxième fois.
--     Avant : une déclaration Wave confirmée après un encaissement à la main (ou deux trésoriers
--     en même temps) comptait le même mois deux fois et gonflait la caisse.
--     La base refuse maintenant toute nouvelle cotisation pour un mois déjà réglé
--     (montant payé >= cotisation du membre pour ce mois), quelle que soit la façon de l'envoyer.
-- (2) La limite de 50 membres de la formule Village ne se contourne plus en réintégrant
--     un membre retiré ou en acceptant une demande d'adhésion par code.

-- Cotisation d'un membre pour un mois : même calcul que feeOf() dans app.js
-- (catégorie valable ce mois-là, puis montant valable ce mois-là pour cette catégorie).
create or replace function public.fee_of(p_member uuid, p_period text) returns bigint
language plpgsql stable security definer set search_path = public as $$
declare m members; cid uuid; cat member_categories; cur_fee bigint; hist bigint;
begin
  select * into m from members where id = p_member;
  if m.id is null then return 0; end if;
  select h.category_id into cid from member_category_history h
   where h.member_id = m.id and h.from_period <= p_period order by h.from_period desc limit 1;
  if not found then cid := m.category_id; end if;
  if cid is not null then select * into cat from member_categories where id = cid; end if;
  if cat.id is not null then cur_fee := cat.fee_amount;
  else select a.fee_amount into cur_fee from associations a where a.id = m.association_id; end if;
  select f.fee_amount into hist from fee_history f
   where f.association_id = m.association_id
     and coalesce(f.category_id, '00000000-0000-0000-0000-000000000000'::uuid)
         = coalesce(cat.id, '00000000-0000-0000-0000-000000000000'::uuid)
     and f.from_period <= p_period
   order by f.from_period desc limit 1;
  return coalesce(hist, cur_fee, 0);
end $$;
revoke execute on function public.fee_of(uuid, text) from public, anon, authenticated;

create or replace function public.tx_month_paid_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare fee bigint; paid bigint;
begin
  if new.category <> 'Cotisations' or new.kind <> 'in' or new.reversal_of is not null
     or new.member_id is null or new.period is null then
    return new;
  end if;
  -- Deux encaissements du même membre et du même mois passent l'un après l'autre.
  perform pg_advisory_xact_lock(hashtext(new.member_id::text || '|' || new.period));
  fee := fee_of(new.member_id, new.period);
  if fee <= 0 then return new; end if;
  select coalesce(sum(amount), 0) into paid from transactions
   where member_id = new.member_id and period = new.period and category = 'Cotisations';
  if paid >= fee then
    raise exception '% est déjà payé pour ce membre. Choisissez un autre mois, ou refusez la déclaration si elle fait doublon.',
      initcap(pfr(new.period)) using errcode = '23P01';
  end if;
  return new;
end $$;
revoke execute on function public.tx_month_paid_check() from public, anon, authenticated;
drop trigger if exists tx_month_paid_check on public.transactions;
create trigger tx_month_paid_check before insert on public.transactions
  for each row execute function public.tx_month_paid_check();

-- Le membre ne déclare pas un mois déjà payé.
create or replace function public.declare_payment(p_member uuid, p_period text, p_amount bigint, p_method text, p_reference text)
returns bigint language plpgsql security definer set search_path = public as $$
declare m members; pn pay_numbers; dest text; cur text; nid bigint; ref text := trim(coalesce(p_reference, '')); fee bigint;
begin
  select * into m from members where id = p_member;
  if m.id is null or m.user_id is distinct from auth.uid() or not m.active or m.pending then
    raise exception 'Vous ne pouvez déclarer que votre propre paiement.';
  end if;
  if p_period !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Choisissez le mois concerné.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Saisissez un montant supérieur à 0.'; end if;
  if p_method not in ('Wave','Orange Money','Free Money') then raise exception 'Mode de paiement inconnu.'; end if;
  if length(ref) > 60 then raise exception 'Référence trop longue.'; end if;
  fee := fee_of(m.id, p_period);
  if fee > 0 and (select coalesce(sum(amount), 0) from transactions
                   where member_id = m.id and period = p_period and category = 'Cotisations') >= fee then
    raise exception '% est déjà payé. Choisissez un autre mois.', initcap(pfr(p_period));
  end if;
  select * into pn from pay_numbers where association_id = m.association_id;
  dest := case p_method when 'Wave' then pn.wave when 'Orange Money' then pn.orange else pn.free end;
  if coalesce(dest, '') = '' then raise exception 'L''association n''a pas de numéro % pour recevoir les cotisations.', p_method; end if;
  if exists (select 1 from payment_claims where member_id = m.id and period = p_period and status = 'pending') then
    raise exception 'Un paiement pour % est déjà en attente de confirmation.', pfr(p_period);
  end if;
  insert into payment_claims(association_id, member_id, period, amount, method, sent_to, reference, created_by)
  values (m.association_id, m.id, p_period, p_amount, p_method, dest || ' (' || pn.holder || ')', ref, auth.uid())
  returning id into nid;
  select currency into cur from associations where id = m.association_id;
  perform write_log(m.association_id, format('a déclaré avoir payé %s par %s pour %s%s. À confirmer par le trésorier.',
    fmt_money(p_amount, cur), p_method, pfr(p_period), case when ref <> '' then ' (réf. ' || ref || ')' else '' end));
  return nid;
end $$;

-- (2) Limite de 50 membres actifs aussi à la réintégration et à l'acceptation d'une demande.
--     Ne dépend pas de vl.system : review_join l'active.
create or replace function public.members_plan_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not (new.active and not new.pending and (not old.active or old.pending)) then return new; end if;
  if (select plan from associations where id = new.association_id) is distinct from 'association' then return new; end if;
  if (select count(*) from members m where m.association_id = new.association_id
        and m.active and not m.pending and m.id <> new.id) >= 50 then
    raise exception 'La formule Village est limitée à 50 membres. Passez à la formule Diaspora (Plus → Abonnement).' using errcode = '42501';
  end if;
  return new;
end $$;
revoke execute on function public.members_plan_cap() from public, anon, authenticated;
drop trigger if exists zz_plan_cap on public.members;
create trigger zz_plan_cap before update on public.members
  for each row execute function public.members_plan_cap();

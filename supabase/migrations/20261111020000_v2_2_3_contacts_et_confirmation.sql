-- v2.2.3 : (1) on ne confirme pas son propre paiement déclaré ;
--          (2) téléphone et e-mail des membres réservés au bureau.

-- (1) Confirmation d'un paiement déclaré : jamais par la personne qui l'a déclaré
create or replace function public.confirm_payment_claim(p_id bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare r payment_claims; tid bigint;
begin
  select * into r from payment_claims where id = p_id for update;
  if r.id is null or not can_collect_member(r.member_id) then
    raise exception 'Seuls le trésorier, le président, le vice-président ou le trésorier de section confirment un paiement.';
  end if;
  if r.status <> 'pending' then raise exception 'Cette déclaration a déjà été traitée.'; end if;
  if r.created_by = auth.uid() or exists (select 1 from members m where m.id = r.member_id and m.user_id = auth.uid()) then
    raise exception 'Vous ne pouvez pas confirmer votre propre paiement. Un autre membre du bureau doit le faire.';
  end if;
  insert into transactions(association_id, kind, category, amount, occurred_on, description, member_id, period, payment_method, comment)
  values (r.association_id, 'in', 'Cotisations', r.amount, r.created_at::date, 'Cotisation de ' || pfr(r.period), r.member_id, r.period, r.method,
          'Payé par ' || r.method || ' au ' || r.sent_to || case when r.reference <> '' then ', réf. ' || r.reference else '' end || '. Déclaré par le membre.')
  returning id into tid;
  update payment_claims set status = 'confirmed', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
         decided_at = now(), transaction_id = tid where id = p_id;
  return tid;
end $$;

-- (2) Les colonnes phone et email ne se lisent plus directement.
--     Attention : une nouvelle colonne de members doit être ajoutée à ce grant.
revoke select on public.members from authenticated, anon;
grant select (id, association_id, user_id, full_name, city, country, role, joined_on, active, created_at,
              pending, created_by_join, section_id, category_id) on public.members to authenticated;

-- Contacts : le bureau voit tout le monde ; un membre voit sa fiche et le bureau.
create or replace function public.member_contacts(p_assoc uuid)
returns table (id uuid, phone text, email text)
language sql stable security definer set search_path = public as $$
  select m.id, m.phone, m.email from members m
  where m.association_id = p_assoc and is_member(p_assoc)
    and (has_role(p_assoc, array['president','vice_president','secretaire','tresorier'])
         or m.user_id = auth.uid()
         or (m.role in ('president','vice_president','secretaire','tresorier') and m.active and not m.pending));
$$;
revoke all on function public.member_contacts(uuid) from public, anon;
grant execute on function public.member_contacts(uuid) to authenticated;

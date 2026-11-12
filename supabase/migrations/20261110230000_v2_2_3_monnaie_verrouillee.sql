-- v2.2.3 : la monnaie d'une association ne change plus dès qu'elle a des montants enregistrés
-- (sinon 17 300 FCFA deviendraient 17 300 GNF sans conversion).
create or replace function public.associations_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.invite_code <> old.invite_code and coalesce(current_setting('vl.system', true), '') <> 'on' then
    raise exception 'Le code d''invitation se change avec la fonction prévue.';
  end if;
  if (new.plan <> old.plan or new.trial_ends is distinct from old.trial_ends or new.paid_until is distinct from old.paid_until
      or new.blocked_at is distinct from old.blocked_at or new.blocked_reason is distinct from old.blocked_reason)
     and coalesce(current_setting('vl.system', true), '') <> 'on' then
    raise exception 'L''offre se change par VillageLink.';
  end if;
  if new.currency <> old.currency and coalesce(current_setting('vl.system', true), '') <> 'on'
     and (exists (select 1 from transactions where association_id = old.id)
       or exists (select 1 from expense_requests where association_id = old.id)
       or exists (select 1 from payment_claims where association_id = old.id)
       or exists (select 1 from collections where association_id = old.id)
       or exists (select 1 from projects where association_id = old.id)) then
    raise exception 'La monnaie ne peut plus changer : l''association a déjà des montants enregistrés dans cette monnaie.';
  end if;
  return new;
end $$;

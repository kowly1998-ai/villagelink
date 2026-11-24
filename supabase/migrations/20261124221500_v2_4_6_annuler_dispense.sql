-- VillageLink 2.4.6 — « Il reprend » sur une dispense qui commence ce mois-ci (ou plus tard)
-- Avant : le dernier mois dispensé ne pouvait pas être avant le début, donc une dispense
-- commencée ce mois restait au moins pour ce mois. Maintenant, choisir le mois juste avant
-- le début ANNULE la dispense (ligne retirée, annulation écrite au journal). Permis seulement
-- si la dispense n'a encore touché aucun mois passé, pour ne jamais changer l'historique.

create or replace function public.end_exemption(p_id bigint, p_last text) returns void
language plpgsql security definer set search_path = public as $$
declare e member_exemptions; who text; cur text := to_char(now(), 'YYYY-MM');
begin
  select * into e from member_exemptions where id = p_id for update;
  if e.id is null or not has_role(e.association_id, array['president','vice_president','secretaire','tresorier']) then
    raise exception 'Seul le bureau peut mettre fin à une dispense.';
  end if;
  if p_last !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Mois invalide.'; end if;
  select full_name into who from members where id = e.member_id;
  if p_last < e.from_period then
    if e.from_period < cur then
      raise exception 'Le dernier mois dispensé ne peut pas être avant le début de la dispense.';
    end if;
    delete from member_exemptions where id = p_id;
    perform write_log(e.association_id, format('a annulé la dispense de %s (elle devait commencer en %s).', who, pfr(e.from_period)));
    return;
  end if;
  if e.to_period is not null and p_last > e.to_period then raise exception 'La dispense finit déjà avant ce mois.'; end if;
  update member_exemptions set to_period = p_last, ended_label = actor_label(e.association_id) where id = p_id;
  perform write_log(e.association_id, format('a mis fin à la dispense de %s (dernier mois dispensé : %s).', who, pfr(p_last)));
end $$;
revoke execute on function public.end_exemption(bigint, text) from public, anon;
grant execute on function public.end_exemption(bigint, text) to authenticated;

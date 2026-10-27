-- VillageLink 1.16b — Lien de paiement Wave (ouvre Wave avec le montant déjà rempli)
alter table public.pay_numbers add column if not exists wave_link text not null default ''
  check (wave_link ~ '^(https://pay\.wave\.com/m/[A-Za-z0-9_-]{4,40}/c/[a-z]{2}/)?$');

create or replace function public.set_pay_numbers(p_assoc uuid, p_holder text, p_wave text, p_orange text, p_free text, p_wave_link text)
returns void language plpgsql security definer set search_path = public as $$
declare l text := trim(coalesce(p_wave_link, ''));
begin
  l := split_part(split_part(l, '?', 1), '#', 1);
  if l <> '' and right(l, 1) <> '/' then l := l || '/'; end if;
  if l <> '' and l !~ '^https://pay\.wave\.com/m/[A-Za-z0-9_-]{4,40}/c/[a-z]{2}/$' then
    raise exception 'Le lien Wave doit commencer par https://pay.wave.com/m/ (copiez-le depuis Wave : Envoi de lien).';
  end if;
  perform public.set_pay_numbers(p_assoc, p_holder, p_wave, p_orange, p_free);
  update pay_numbers set wave_link = l where association_id = p_assoc;
  if l <> '' then perform write_log(p_assoc, format('a enregistré le lien de paiement Wave %s.', l)); end if;
end $$;
revoke execute on function public.set_pay_numbers(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.set_pay_numbers(uuid, text, text, text, text, text) to authenticated;

-- v2.2.4 (audit B6) : l'heure du serveur, pour calculer les retards de cotisation
-- avec la bonne date même si le téléphone est mal réglé. Lecture seule, rien d'autre.
create or replace function public.server_now() returns timestamptz
language sql stable security invoker set search_path = public as $$
  select now();
$$;
revoke all on function public.server_now() from public, anon;
grant execute on function public.server_now() to authenticated;

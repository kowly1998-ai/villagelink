-- v2.3.1 : plus aucune limite de membres ni de fonctions.
create or replace function public.enforce_plan_features() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  return new;
end $$;
create or replace function public.members_plan_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  return new;
end $$;

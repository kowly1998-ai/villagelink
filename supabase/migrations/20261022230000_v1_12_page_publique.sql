-- ---------------------------------------------------------------------
-- Page publique d'un projet (version 1.12)
-- Le bureau peut publier un projet sur une page ouverte à tous (sans compte) :
-- nom, objectif, montant collecté et dépensé, nouvelles du chantier, et le contact
-- choisi pour donner. Aucune donnée de membre n'y apparaît (ni nom, ni numéro).
-- ---------------------------------------------------------------------
alter table public.projects add column if not exists public_slug text unique
  check (public_slug is null or public_slug ~ '^[a-z0-9]{10,24}$');
alter table public.projects add column if not exists public_contact text not null default ''
  check (length(public_contact) <= 300);

create or replace function public.projects_public_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.public_slug is distinct from old.public_slug then
    perform write_log(new.association_id, format('a %s la page publique du projet « %s ».',
      case when new.public_slug is null then 'retiré' else 'publié' end, new.name));
  end if;
  return null;
end $$;
create trigger projects_public_log after update on public.projects
  for each row execute function public.projects_public_log();
revoke execute on function public.projects_public_log() from public, anon, authenticated;

-- Lecture publique, par le lien secret uniquement.
create or replace function public.public_project(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'association', jsonb_build_object('name', a.name, 'village', a.village, 'region', a.region,
                                      'country', a.origin_country, 'city', a.residence_city, 'currency', a.currency),
    'project', jsonb_build_object('name', p.name, 'type', p.type, 'description', p.description, 'goal', p.goal,
                                  'status', p.status, 'start_on', p.start_on, 'end_on', p.end_on, 'contact', p.public_contact),
    'collected', coalesce((select sum(amount) from transactions t where t.project_id = p.id and t.kind = 'in'), 0),
    'spent', coalesce((select sum(amount) from transactions t where t.project_id = p.id and t.kind = 'out'), 0),
    'gifts', (select count(*) from transactions t where t.project_id = p.id and t.kind = 'in' and t.reversal_of is null
                and not exists (select 1 from transactions r where r.reversal_of = t.id)),
    'updates', coalesce((select jsonb_agg(jsonb_build_object('body', u.body, 'at', u.created_at) order by u.created_at desc)
                         from (select * from project_updates u where u.project_id = p.id order by created_at desc limit 20) u), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('description', e.description, 'amount', e.amount, 'on', e.occurred_on) order by e.occurred_on desc)
                         from (select * from transactions t where t.project_id = p.id and t.kind = 'out' and t.reversal_of is null
                                 and not exists (select 1 from transactions r where r.reversal_of = t.id)
                               order by occurred_on desc, id desc limit 30) e), '[]'::jsonb))
  from projects p join associations a on a.id = p.association_id
  where p.public_slug is not null and p.public_slug = lower(trim(p_slug));
$$;
revoke execute on function public.public_project(text) from public;
grant execute on function public.public_project(text) to anon, authenticated;

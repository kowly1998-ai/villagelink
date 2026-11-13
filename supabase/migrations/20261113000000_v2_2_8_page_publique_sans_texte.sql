-- v2.2.8 : la page publique d'un projet n'affiche plus le texte libre des dépenses
-- (il pouvait contenir un nom de personne). Elle montre la catégorie (liste fixe), la date et le montant.
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
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('category', e.category, 'amount', e.amount, 'on', e.occurred_on) order by e.occurred_on desc)
                         from (select * from transactions t where t.project_id = p.id and t.kind = 'out' and t.reversal_of is null
                                 and not exists (select 1 from transactions r where r.reversal_of = t.id)
                               order by occurred_on desc, id desc limit 30) e), '[]'::jsonb))
  from projects p join associations a on a.id = p.association_id
  where p.public_slug is not null and p.public_slug = lower(trim(p_slug));
$$;
revoke execute on function public.public_project(text) from public;
grant execute on function public.public_project(text) to anon, authenticated;

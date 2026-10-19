-- ---------------------------------------------------------------------
-- Documents (version 1.6) : statuts, règlement, procès-verbaux, rapports…
-- Le bureau (président, vice-président, secrétaire, trésorier) dépose et retire ;
-- tous les membres validés lisent. Fichiers dans le bucket privé « docs »,
-- rangés par association : <id de l'association>/<nom>.
-- ---------------------------------------------------------------------
create table if not exists public.documents (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  title           text not null check (length(trim(title)) between 2 and 160),
  category        text not null default 'Autre'
                  check (category in ('Statuts','Règlement intérieur','Procès-verbal','Rapport','Reçu','Autre')),
  file_path       text not null check (length(file_path) between 3 and 300),
  file_name       text not null default '' check (length(file_name) <= 200),
  mime            text not null default '' check (length(mime) <= 120),
  size            int not null default 0 check (size between 0 and 10485760),
  uploaded_by     uuid,
  uploaded_label  text not null default '',
  created_at      timestamptz not null default now()
);
create index if not exists documents_assoc_idx on public.documents(association_id, created_at desc);

-- Le chemin du fichier doit être dans le dossier de l'association ; l'auteur est la personne connectée.
create or replace function public.documents_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.file_path not like new.association_id::text || '/%' or new.file_path like '%..%' then
    raise exception 'Chemin de fichier invalide.';
  end if;
  new.uploaded_by := auth.uid();
  new.uploaded_label := actor_label(new.association_id);
  new.created_at := now();
  return new;
end $$;
create trigger documents_check before insert on public.documents
  for each row execute function public.documents_check();

create or replace function public.documents_log() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform write_log(new.association_id, format('a déposé le document « %s » (%s).', new.title, new.category));
    return new;
  end if;
  perform write_log(old.association_id, format('a retiré le document « %s ».', old.title));
  return old;
end $$;
create trigger documents_log after insert or delete on public.documents
  for each row execute function public.documents_log();

alter table public.documents enable row level security;
create policy documents_select on public.documents for select to authenticated
  using (is_member(association_id));
create policy documents_insert on public.documents for insert to authenticated
  with check (has_role(association_id, array['president','vice_president','secretaire','tresorier']));
create policy documents_delete on public.documents for delete to authenticated
  using (has_role(association_id, array['president','vice_president','secretaire','tresorier']));

revoke all on public.documents from anon, authenticated;
grant select, insert, delete on public.documents to authenticated;
revoke execute on function public.documents_check() from public, anon, authenticated;
revoke execute on function public.documents_log() from public, anon, authenticated;

-- Bucket privé « docs » (10 Mo maximum par fichier) et ses règles d'accès.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('docs', 'docs', false, 10485760,
            array['application/pdf','image/jpeg','image/png','image/webp','image/heic',
                  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                  'application/msword','application/vnd.ms-excel'])
    on conflict (id) do nothing;
    execute $p$create policy docs_read on storage.objects for select to authenticated
      using (bucket_id = 'docs' and public.is_member(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy docs_write on storage.objects for insert to authenticated
      with check (bucket_id = 'docs'
        and public.has_role(((storage.foldername(name))[1])::uuid, array['president','vice_president','secretaire','tresorier']))$p$;
    execute $p$create policy docs_delete on storage.objects for delete to authenticated
      using (bucket_id = 'docs'
        and public.has_role(((storage.foldername(name))[1])::uuid, array['president','vice_president','secretaire','tresorier']))$p$;
  end if;
end $$;

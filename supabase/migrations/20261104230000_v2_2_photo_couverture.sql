-- VillageLink 2.2 — Photo de couverture de l'association
-- Qui peut la changer : président, vice-président, secrétaire. Tout membre la voit.

alter table public.associations add column if not exists cover_path text;

create or replace function public.set_cover(p_assoc uuid, p_path text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not has_role(p_assoc, array['president','vice_president','secretaire']) then
    raise exception 'Réservé au président, au vice-président et au secrétaire.';
  end if;
  if assoc_status(p_assoc) in ('blocked','readonly') then
    raise exception 'L''association est en lecture seule.';
  end if;
  if p_path is not null and left(p_path, length(p_assoc::text) + 1) <> p_assoc::text || '/' then
    raise exception 'Chemin de photo invalide.';
  end if;
  update associations set cover_path = p_path where id = p_assoc;
end $$;
revoke execute on function public.set_cover(uuid, text) from public, anon;
grant execute on function public.set_cover(uuid, text) to authenticated;

-- Bucket privé « covers » (2 Mo maximum, images seulement)
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('covers', 'covers', false, 2097152, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do nothing;
    execute 'drop policy if exists covers_read on storage.objects';
    execute $p$create policy covers_read on storage.objects for select to authenticated
      using (bucket_id = 'covers' and public.is_member(((storage.foldername(name))[1])::uuid))$p$;
    execute 'drop policy if exists covers_write on storage.objects';
    execute $p$create policy covers_write on storage.objects for insert to authenticated
      with check (bucket_id = 'covers'
        and public.has_role(((storage.foldername(name))[1])::uuid, array['president','vice_president','secretaire']))$p$;
    execute 'drop policy if exists covers_delete on storage.objects';
    execute $p$create policy covers_delete on storage.objects for delete to authenticated
      using (bucket_id = 'covers'
        and public.has_role(((storage.foldername(name))[1])::uuid, array['president','vice_president','secretaire']))$p$;
  end if;
end $$;

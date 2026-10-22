-- ---------------------------------------------------------------------
-- Messages vocaux (version 1.11) dans la discussion et les annonces.
-- Fichiers dans le bucket privé « voice » (3 Mo, 3 minutes environ),
-- rangés par association : <id de l'association>/<nom>.
-- ---------------------------------------------------------------------
alter table public.messages add column if not exists audio_path text not null default '' check (length(audio_path) <= 300);
alter table public.messages add column if not exists audio_seconds int not null default 0 check (audio_seconds between 0 and 600);
alter table public.announcements add column if not exists audio_path text not null default '' check (length(audio_path) <= 300);
alter table public.announcements add column if not exists audio_seconds int not null default 0 check (audio_seconds between 0 and 600);

create or replace function public.voice_path_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.audio_path <> '' and (new.audio_path not like new.association_id::text || '/%' or new.audio_path like '%..%') then
    raise exception 'Message vocal invalide.';
  end if;
  if new.audio_path = '' then new.audio_seconds := 0; end if;
  return new;
end $$;
create trigger messages_voice_check before insert on public.messages
  for each row execute function public.voice_path_check();
create trigger announcements_voice_check before insert on public.announcements
  for each row execute function public.voice_path_check();
revoke execute on function public.voice_path_check() from public, anon, authenticated;

-- Masquer un message efface aussi son vocal de l'affichage.
create or replace function public.hide_message(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare m messages;
begin
  select * into m from messages where id = p_id;
  if m.id is null or not is_member(m.association_id) then raise exception 'Message introuvable.'; end if;
  if m.author_id is distinct from auth.uid() and not has_role(m.association_id, array['president','vice_president','secretaire']) then
    raise exception 'Seuls l''auteur, le président, le vice-président ou le secrétaire peuvent masquer un message.';
  end if;
  update messages set hidden = true, body = 'Message masqué', audio_path = '', audio_seconds = 0,
    hidden_by = actor_label(m.association_id) where id = p_id;
  if m.author_id is distinct from auth.uid() then
    perform write_log(m.association_id, format('a masqué un message de %s dans la discussion.', m.author_label));
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('voice', 'voice', false, 3145728,
            array['audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/aac','audio/x-m4a','audio/wav'])
    on conflict (id) do nothing;
    execute $p$create policy voice_read on storage.objects for select to authenticated
      using (bucket_id = 'voice' and public.is_member(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy voice_write on storage.objects for insert to authenticated
      with check (bucket_id = 'voice' and public.is_member(((storage.foldername(name))[1])::uuid))$p$;
  end if;
end $$;

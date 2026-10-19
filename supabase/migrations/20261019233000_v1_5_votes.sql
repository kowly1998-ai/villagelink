-- ---------------------------------------------------------------------
-- Votes (version 1.5)
-- Le président, le vice-président et le secrétaire lancent et closent un vote.
-- Chaque membre validé qui a un compte vote une fois (il peut changer d'avis tant que
-- le vote est ouvert). Un vote secret ne montre à personne qui a voté quoi.
-- Tout passe par des fonctions : aucune écriture directe dans les tables.
-- ---------------------------------------------------------------------
create table if not exists public.polls (
  id              uuid primary key default gen_random_uuid(),
  association_id  uuid not null references public.associations(id) on delete cascade,
  question        text not null check (length(trim(question)) between 3 and 300),
  description     text not null default '' check (length(description) <= 2000),
  anonymous       boolean not null default true,
  status          text not null default 'Ouvert' check (status in ('Ouvert','Clos')),
  closes_at       timestamptz,
  created_by      uuid,
  created_label   text not null default '',
  created_at      timestamptz not null default now(),
  closed_at       timestamptz
);
create index if not exists polls_assoc_idx on public.polls(association_id, created_at desc);

create table if not exists public.poll_options (
  id              uuid primary key default gen_random_uuid(),
  poll_id         uuid not null references public.polls(id) on delete cascade,
  association_id  uuid not null references public.associations(id) on delete cascade,
  label           text not null check (length(trim(label)) between 1 and 120),
  position        int not null default 0
);
create index if not exists poll_options_poll_idx on public.poll_options(poll_id, position);

create table if not exists public.poll_votes (
  poll_id         uuid not null references public.polls(id) on delete cascade,
  member_id       uuid not null references public.members(id) on delete cascade,
  option_id       uuid not null references public.poll_options(id) on delete cascade,
  association_id  uuid not null references public.associations(id) on delete cascade,
  voted_at        timestamptz not null default now(),
  primary key (poll_id, member_id)
);
create index if not exists poll_votes_assoc_idx on public.poll_votes(association_id);

alter table public.polls enable row level security;
alter table public.poll_options enable row level security;
alter table public.poll_votes enable row level security;

create policy polls_select on public.polls for select to authenticated
  using (is_member(association_id));
create policy poll_options_select on public.poll_options for select to authenticated
  using (is_member(association_id));
-- Bulletins : on voit le sien ; ceux des autres seulement si le vote n'est pas secret.
create policy poll_votes_select on public.poll_votes for select to authenticated
  using (is_member(association_id) and (
    member_id in (select m.id from public.members m where m.user_id = auth.uid())
    or exists (select 1 from public.polls p where p.id = poll_id and not p.anonymous)));

revoke all on public.polls, public.poll_options, public.poll_votes from anon, authenticated;
grant select on public.polls, public.poll_options, public.poll_votes to authenticated;

-- Lancer un vote (question + 2 à 10 choix), en une seule opération.
create or replace function public.create_poll(p_assoc uuid, p_question text, p_description text,
  p_options text[], p_closes_at timestamptz, p_anonymous boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare pid uuid; opt text; i int := 0; n int;
begin
  if not has_role(p_assoc, array['president','vice_president','secretaire']) then
    raise exception 'Réservé au président, au vice-président et au secrétaire général.';
  end if;
  select count(distinct lower(trim(x))) into n from unnest(p_options) x where length(trim(x)) > 0;
  if n < 2 or n > 10 then raise exception 'Il faut entre 2 et 10 choix différents.'; end if;
  if p_closes_at is not null and p_closes_at <= now() then raise exception 'La date de clôture doit être dans le futur.'; end if;
  insert into polls(association_id, question, description, anonymous, closes_at, created_by, created_label)
  values (p_assoc, trim(p_question), coalesce(trim(p_description), ''), coalesce(p_anonymous, true), p_closes_at,
          auth.uid(), actor_label(p_assoc))
  returning id into pid;
  foreach opt in array p_options loop
    if length(trim(opt)) > 0 and not exists (select 1 from poll_options where poll_id = pid and lower(label) = lower(trim(opt))) then
      insert into poll_options(poll_id, association_id, label, position) values (pid, p_assoc, trim(opt), i);
      i := i + 1;
    end if;
  end loop;
  perform write_log(p_assoc, format('a lancé le vote « %s ».', trim(p_question)));
  return pid;
end $$;

-- Voter (ou changer son vote tant que le vote est ouvert).
create or replace function public.cast_vote(p_poll uuid, p_option uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p polls; mid uuid;
begin
  select * into p from polls where id = p_poll;
  if p.id is null or not is_member(p.association_id) then raise exception 'Vote introuvable.'; end if;
  if p.status <> 'Ouvert' or (p.closes_at is not null and p.closes_at <= now()) then
    raise exception 'Ce vote est clos.';
  end if;
  if not exists (select 1 from poll_options where id = p_option and poll_id = p_poll) then
    raise exception 'Choix inconnu.';
  end if;
  select id into mid from members
    where association_id = p.association_id and user_id = auth.uid() and active and not pending limit 1;
  if mid is null then raise exception 'Seuls les membres validés peuvent voter.'; end if;
  insert into poll_votes(poll_id, member_id, option_id, association_id)
  values (p_poll, mid, p_option, p.association_id)
  on conflict (poll_id, member_id) do update set option_id = excluded.option_id, voted_at = now();
end $$;

-- Clore un vote.
create or replace function public.close_poll(p_poll uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p polls;
begin
  select * into p from polls where id = p_poll;
  if p.id is null or not has_role(p.association_id, array['president','vice_president','secretaire']) then
    raise exception 'Réservé au président, au vice-président et au secrétaire général.';
  end if;
  if p.status = 'Clos' then return; end if;
  update polls set status = 'Clos', closed_at = now() where id = p_poll;
  perform write_log(p.association_id, format('a clos le vote « %s ».', p.question));
end $$;

-- Résultats : nombre de voix par choix (y compris pour un vote secret).
create or replace function public.poll_results(p_poll uuid)
returns table(option_id uuid, votes int)
language sql stable security definer set search_path = public as $$
  select o.id, count(v.member_id)::int
  from poll_options o
  join polls p on p.id = o.poll_id
  left join poll_votes v on v.option_id = o.id
  where o.poll_id = p_poll and is_member(p.association_id)
  group by o.id, o.position
  order by o.position;
$$;

revoke execute on function public.create_poll(uuid, text, text, text[], timestamptz, boolean) from public, anon;
revoke execute on function public.cast_vote(uuid, uuid) from public, anon;
revoke execute on function public.close_poll(uuid) from public, anon;
revoke execute on function public.poll_results(uuid) from public, anon;
grant execute on function public.create_poll(uuid, text, text, text[], timestamptz, boolean) to authenticated;
grant execute on function public.cast_vote(uuid, uuid) to authenticated;
grant execute on function public.close_poll(uuid) to authenticated;
grant execute on function public.poll_results(uuid) to authenticated;

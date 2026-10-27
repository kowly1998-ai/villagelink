-- VillageLink 1.16 — Paiement des cotisations par mobile money (sans intermédiaire)
-- Le membre envoie l'argent avec son Wave / Orange Money / Free Money au numéro de réception
-- de l'association, puis le déclare. La cotisation ne compte qu'une fois confirmée par le trésorier
-- (ou le président, le vice-président, le trésorier de section). Rien ne s'efface.

-- 1. Numéros de réception de l'association
create table if not exists public.pay_numbers (
  association_id uuid primary key references public.associations(id) on delete cascade,
  holder     text not null default '' check (length(holder) <= 80),
  wave       text not null default '' check (wave   ~ '^(\+?[0-9 ]{8,20})?$'),
  orange     text not null default '' check (orange ~ '^(\+?[0-9 ]{8,20})?$'),
  free       text not null default '' check (free   ~ '^(\+?[0-9 ]{8,20})?$'),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.pay_numbers enable row level security;
create policy pay_numbers_select on public.pay_numbers for select to authenticated
  using (is_member(association_id));
grant select on public.pay_numbers to authenticated;

-- Seuls le président et le trésorier changent les numéros ; chaque changement va au journal (visible de tous).
create or replace function public.set_pay_numbers(p_assoc uuid, p_holder text, p_wave text, p_orange text, p_free text)
returns void language plpgsql security definer set search_path = public as $$
declare h text := trim(coalesce(p_holder, '')); w text := trim(coalesce(p_wave, ''));
        o text := trim(coalesce(p_orange, '')); f text := trim(coalesce(p_free, ''));
begin
  if not has_role(p_assoc, array['president','tresorier']) then
    raise exception 'Seuls le président et le trésorier changent les numéros de paiement.';
  end if;
  if (w <> '' or o <> '' or f <> '') and length(h) < 2 then
    raise exception 'Indiquez le nom qui s''affiche chez Wave ou Orange Money pour ces numéros.';
  end if;
  insert into pay_numbers(association_id, holder, wave, orange, free, updated_by, updated_at)
  values (p_assoc, h, w, o, f, auth.uid(), now())
  on conflict (association_id) do update
    set holder = excluded.holder, wave = excluded.wave, orange = excluded.orange, free = excluded.free,
        updated_by = excluded.updated_by, updated_at = now();
  perform write_log(p_assoc, format('a changé les numéros de paiement mobile money : Wave %s, Orange Money %s, Free Money %s (au nom de %s).',
    coalesce(nullif(w, ''), 'aucun'), coalesce(nullif(o, ''), 'aucun'), coalesce(nullif(f, ''), 'aucun'), coalesce(nullif(h, ''), '—')));
end $$;
revoke execute on function public.set_pay_numbers(uuid, text, text, text, text) from public, anon;
grant execute on function public.set_pay_numbers(uuid, text, text, text, text) to authenticated;

-- 2. Déclarations de paiement
create table if not exists public.payment_claims (
  id             bigint generated always as identity primary key,
  association_id uuid not null references public.associations(id) on delete cascade,
  member_id      uuid not null references public.members(id) on delete restrict,
  period         text not null check (period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  amount         bigint not null check (amount > 0 and amount <= 100000000),
  method         text not null check (method in ('Wave','Orange Money','Free Money')),
  sent_to        text not null default '',
  reference      text not null default '' check (length(reference) <= 60),
  status         text not null default 'pending' check (status in ('pending','confirmed','rejected','cancelled')),
  created_by     uuid references auth.users(id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now(),
  decided_by     uuid references auth.users(id) on delete set null,
  decided_label  text not null default '',
  decided_at     timestamptz,
  reason         text not null default '' check (length(reason) <= 200),
  transaction_id bigint references public.transactions(id) on delete restrict
);
create unique index if not exists claims_one_pending on public.payment_claims(member_id, period) where status = 'pending';
create index if not exists claims_assoc_idx on public.payment_claims(association_id, status, id desc);
create index if not exists claims_tx_idx on public.payment_claims(transaction_id);
alter table public.payment_claims enable row level security;
create policy claims_select on public.payment_claims for select to authenticated
  using (is_member(association_id));
grant select on public.payment_claims to authenticated;
-- Aucune écriture directe : tout passe par les fonctions ci-dessous.

create or replace function public.pfr(p text) returns text language sql immutable set search_path = public as $$
  select (array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'])
         [substr(p, 6, 2)::int] || ' ' || substr(p, 1, 4);
$$;

-- Le membre déclare SON paiement (jamais celui d'un autre).
create or replace function public.declare_payment(p_member uuid, p_period text, p_amount bigint, p_method text, p_reference text)
returns bigint language plpgsql security definer set search_path = public as $$
declare m members; pn pay_numbers; dest text; cur text; nid bigint; ref text := trim(coalesce(p_reference, ''));
begin
  select * into m from members where id = p_member;
  if m.id is null or m.user_id is distinct from auth.uid() or not m.active or m.pending then
    raise exception 'Vous ne pouvez déclarer que votre propre paiement.';
  end if;
  if p_period !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Choisissez le mois concerné.'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Saisissez un montant supérieur à 0.'; end if;
  if p_method not in ('Wave','Orange Money','Free Money') then raise exception 'Mode de paiement inconnu.'; end if;
  if length(ref) > 60 then raise exception 'Référence trop longue.'; end if;
  select * into pn from pay_numbers where association_id = m.association_id;
  dest := case p_method when 'Wave' then pn.wave when 'Orange Money' then pn.orange else pn.free end;
  if coalesce(dest, '') = '' then raise exception 'L''association n''a pas de numéro % pour recevoir les cotisations.', p_method; end if;
  if exists (select 1 from payment_claims where member_id = m.id and period = p_period and status = 'pending') then
    raise exception 'Un paiement pour % est déjà en attente de confirmation.', pfr(p_period);
  end if;
  insert into payment_claims(association_id, member_id, period, amount, method, sent_to, reference, created_by)
  values (m.association_id, m.id, p_period, p_amount, p_method, dest || ' (' || pn.holder || ')', ref, auth.uid())
  returning id into nid;
  select currency into cur from associations where id = m.association_id;
  perform write_log(m.association_id, format('a déclaré avoir payé %s par %s pour %s%s. À confirmer par le trésorier.',
    fmt_money(p_amount, cur), p_method, pfr(p_period), case when ref <> '' then ' (réf. ' || ref || ')' else '' end));
  return nid;
end $$;

create or replace function public.cancel_payment_claim(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r payment_claims;
begin
  select * into r from payment_claims where id = p_id for update;
  if r.id is null or r.created_by is distinct from auth.uid() then raise exception 'Déclaration introuvable.'; end if;
  if r.status <> 'pending' then raise exception 'Cette déclaration a déjà été traitée.'; end if;
  update payment_claims set status = 'cancelled', decided_by = auth.uid(), decided_at = now() where id = p_id;
  perform write_log(r.association_id, format('a annulé sa déclaration de paiement pour %s.', pfr(r.period)));
end $$;

create or replace function public.can_collect_member(p_member uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members t where t.id = p_member
                   and (has_role(t.association_id, array['tresorier','president','vice_president'])
                        or is_section_treasurer(t.id)));
$$;

-- Confirmer : après avoir vu l'argent arriver dans SON application Wave / Orange Money.
create or replace function public.confirm_payment_claim(p_id bigint) returns bigint
language plpgsql security definer set search_path = public as $$
declare r payment_claims; tid bigint;
begin
  select * into r from payment_claims where id = p_id for update;
  if r.id is null or not can_collect_member(r.member_id) then
    raise exception 'Seuls le trésorier, le président, le vice-président ou le trésorier de section confirment un paiement.';
  end if;
  if r.status <> 'pending' then raise exception 'Cette déclaration a déjà été traitée.'; end if;
  insert into transactions(association_id, kind, category, amount, occurred_on, description, member_id, period, payment_method, comment)
  values (r.association_id, 'in', 'Cotisations', r.amount, r.created_at::date, 'Cotisation de ' || pfr(r.period), r.member_id, r.period, r.method,
          'Payé par ' || r.method || ' au ' || r.sent_to || case when r.reference <> '' then ', réf. ' || r.reference else '' end || '. Déclaré par le membre.')
  returning id into tid;
  update payment_claims set status = 'confirmed', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
         decided_at = now(), transaction_id = tid where id = p_id;
  return tid;
end $$;

create or replace function public.reject_payment_claim(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare r payment_claims; why text := trim(coalesce(p_reason, '')); who text;
begin
  select * into r from payment_claims where id = p_id for update;
  if r.id is null or not can_collect_member(r.member_id) then
    raise exception 'Seuls le trésorier, le président, le vice-président ou le trésorier de section refusent un paiement.';
  end if;
  if r.status <> 'pending' then raise exception 'Cette déclaration a déjà été traitée.'; end if;
  if length(why) < 3 then raise exception 'Indiquez pourquoi (par exemple : rien reçu sur Wave).'; end if;
  if length(why) > 200 then raise exception 'Motif trop long.'; end if;
  update payment_claims set status = 'rejected', decided_by = auth.uid(), decided_label = actor_label(r.association_id),
         decided_at = now(), reason = why where id = p_id;
  select full_name into who from members where id = r.member_id;
  perform write_log(r.association_id, format('a refusé le paiement déclaré par %s pour %s. Motif : %s', who, pfr(r.period), why));
end $$;

revoke execute on function public.declare_payment(uuid, text, bigint, text, text) from public, anon;
revoke execute on function public.cancel_payment_claim(bigint) from public, anon;
revoke execute on function public.confirm_payment_claim(bigint) from public, anon;
revoke execute on function public.reject_payment_claim(bigint, text) from public, anon;
revoke execute on function public.can_collect_member(uuid) from public, anon;
grant execute on function public.declare_payment(uuid, text, bigint, text, text) to authenticated;
grant execute on function public.cancel_payment_claim(bigint) to authenticated;
grant execute on function public.confirm_payment_claim(bigint) to authenticated;
grant execute on function public.reject_payment_claim(bigint, text) to authenticated;
grant execute on function public.can_collect_member(uuid) to authenticated;

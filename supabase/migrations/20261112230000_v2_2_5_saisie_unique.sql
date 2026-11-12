-- v2.2.5 (audit B7) : une saisie d'argent envoyée deux fois (connexion coupée, double appui)
-- n'est enregistrée qu'une fois. Chaque formulaire a un numéro de saisie (client_ref) tiré au hasard
-- sur le téléphone ; la base refuse un deuxième enregistrement avec le même numéro.
-- Facultatif : les anciennes lignes et les fonctions de la base (contre-écriture, validation) n'en ont pas.
alter table public.transactions add column if not exists client_ref text
  check (client_ref is null or client_ref ~ '^[A-Za-z0-9-]{16,64}(:[0-9]{1,2})?$');
create unique index if not exists transactions_client_ref_uq
  on public.transactions(association_id, client_ref) where client_ref is not null;

alter table public.expense_requests add column if not exists client_ref text
  check (client_ref is null or client_ref ~ '^[A-Za-z0-9-]{16,64}$');
create unique index if not exists expense_requests_client_ref_uq
  on public.expense_requests(association_id, client_ref) where client_ref is not null;

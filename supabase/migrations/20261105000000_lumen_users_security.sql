-- Protezione dai tentativi di accesso ripetuti (blocco temporaneo dell'account).
alter table public.lumen_users add column if not exists failed_logins integer not null default 0;
alter table public.lumen_users add column if not exists locked_until timestamptz;
-- La tabella resta accessibile solo dalla funzione lumen-auth (service role): RLS attiva, nessuna policy.
alter table public.lumen_users enable row level security;
revoke all on table public.lumen_users from anon, authenticated;

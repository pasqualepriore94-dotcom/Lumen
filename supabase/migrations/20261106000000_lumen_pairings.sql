-- Abbinamenti temporanei per l'accesso dalla TV con il telefono (codice QR, validi 10 minuti).
create table if not exists public.lumen_pairings (
  code text primary key,
  secret_hash text not null,
  status text not null default 'pending' check (status in ('pending', 'approved')),
  token text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists lumen_pairings_expires_at on public.lumen_pairings (expires_at);
-- Accessibile solo dalla funzione lumen-auth (service role): RLS attiva, nessuna policy.
alter table public.lumen_pairings enable row level security;
revoke all on table public.lumen_pairings from anon, authenticated;

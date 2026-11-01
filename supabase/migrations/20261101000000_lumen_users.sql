-- Utenti dell'app Lumen. Accesso solo tramite la funzione lumen-auth (service role):
-- RLS attiva senza policy = nessun accesso diretto con la chiave pubblica.
create table if not exists public.lumen_users (
  id             uuid primary key default gen_random_uuid(),
  username       text not null unique,
  email          text not null unique,
  password_hash  text not null,
  role           text not null default 'user' check (role in ('admin', 'user')),
  approved       boolean not null default false,
  approval_token text unique,
  created_at     timestamptz not null default now(),
  approved_at    timestamptz
);

alter table public.lumen_users enable row level security;

create index if not exists lumen_users_approval_token_idx on public.lumen_users (approval_token);

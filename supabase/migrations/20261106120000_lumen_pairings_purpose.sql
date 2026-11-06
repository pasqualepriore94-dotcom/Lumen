-- Gli abbinamenti servono anche per inviare alla TV il link della playlist dal telefono.
alter table public.lumen_pairings add column if not exists purpose text not null default 'login'
  check (purpose in ('login', 'playlist'));

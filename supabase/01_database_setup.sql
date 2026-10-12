-- MiddleAgePadel: fase 1 - sikker databaseklargoring
-- Kor kun i Supabase SQL Editor i dit eget projekt.
-- Dette script flytter IKKE eksisterende data og aendrer IKKE webappen.
-- Brugeradgang med faelles kode implementeres senere via en Edge Function.
-- Public/anon faar INGEN direkte adgang til turneringsdata.

begin;

create table if not exists public.padel_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.padel_state (
  id text primary key default 'main' check (id = 'main'),
  data jsonb not null default '{}'::jsonb,
  version bigint not null default 1 check (version > 0),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table public.padel_admins enable row level security;
alter table public.padel_state enable row level security;

revoke all on table public.padel_admins from anon, authenticated;
revoke all on table public.padel_state from anon, authenticated;

grant select on table public.padel_admins to authenticated;
grant select, insert, update on table public.padel_state to authenticated;

drop policy if exists padel_admins_self_read on public.padel_admins;
create policy padel_admins_self_read on public.padel_admins
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists padel_state_admin_read on public.padel_state;
create policy padel_state_admin_read on public.padel_state
  for select to authenticated
  using (exists (select 1 from public.padel_admins a where a.user_id = (select auth.uid())));

drop policy if exists padel_state_admin_insert on public.padel_state;
create policy padel_state_admin_insert on public.padel_state
  for insert to authenticated
  with check (exists (select 1 from public.padel_admins a where a.user_id = (select auth.uid())));

drop policy if exists padel_state_admin_update on public.padel_state;
create policy padel_state_admin_update on public.padel_state
  for update to authenticated
  using (exists (select 1 from public.padel_admins a where a.user_id = (select auth.uid())))
  with check (exists (select 1 from public.padel_admins a where a.user_id = (select auth.uid())));

-- Opdateringer kraever korrekt versionsnummer for at undgaa overskrivning
-- mellem flere enheder. Vi indforer serverfunktioner i naeste fase.
-- Ingen startdata indsaettes her: eksisterende browserdata skal eksporteres forst.

commit;

-- EFTER oprettelse af din personlige admin-bruger i Supabase Authentication:
-- Erstat UUID og kor den naeste linje SEPARAT i SQL Editor:
-- insert into public.padel_admins (user_id) values ('DIN-ADMIN-BRUGER-UUID');

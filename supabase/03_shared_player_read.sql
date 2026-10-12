-- Fase 3: faelles spillerkode (KUN laeseadgang).
-- Koer manuelt i Supabase SQL Editor efter fase 1 og 2.
-- Ingen spillerdata overskrives. Ingen resultater kan gemmes med spillerkoden.
-- Spillerkoden opbevares som en bcrypt-hash, aldrig som klartekst.
begin;

create table if not exists public.padel_player_access (
  id text primary key check (id = 'main'),
  code_hash text not null,
  updated_at timestamptz not null default now()
);
alter table public.padel_player_access enable row level security;
revoke all on public.padel_player_access from public, anon, authenticated;

create or replace function public.padel_admin_set_player_code(p_code text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.padel_admins where user_id = auth.uid()
  ) then
    raise exception 'Kun administrator kan aendre spillerkoden' using errcode = '42501';
  end if;
  if p_code is null or length(p_code) < 12 or length(p_code) > 128 then
    raise exception 'Spillerkoden skal vaere mellem 12 og 128 tegn';
  end if;
  insert into public.padel_player_access (id, code_hash, updated_at)
  values ('main', extensions.crypt(p_code, extensions.gen_salt('bf', 12)), now())
  on conflict (id) do update
  set code_hash = excluded.code_hash, updated_at = now();
end;
$$;

create or replace function public.padel_player_read(p_code text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_hash text;
  v_result jsonb;
begin
  select code_hash into v_hash from public.padel_player_access where id = 'main';
  if v_hash is null or p_code is null or
     extensions.crypt(p_code, v_hash) <> v_hash then
    raise exception 'Forkert spillerkode' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'version', version, 'updated_at', updated_at, 'data', data
  ) into v_result
  from public.padel_state where id = 'main';
  if v_result is null then
    raise exception 'Ingen turneringsdata';
  end if;
  return v_result;
end;
$$;

revoke all on function public.padel_admin_set_player_code(text) from public, anon;
grant execute on function public.padel_admin_set_player_code(text) to authenticated;
revoke all on function public.padel_player_read(text) from public;
grant execute on function public.padel_player_read(text) to anon, authenticated;
commit;

-- BEMAERK: Ingen indbygget IP-baseret rate limiting i denne SQL-fase.
-- Vaelg en lang, tilfaeldig spillerkode og del den kun med spillerne.
-- Brug en Edge Function med rate limiting inden offentlig lancering.

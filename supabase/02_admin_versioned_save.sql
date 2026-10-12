-- Fase 2: sikker, versionsstyret lagring for administrator.
-- Koer EFTER 01_database_setup.sql i Supabase SQL Editor.
-- Scriptet indsætter ingen spillerdata og ændrer ikke den aktive webapp.
begin;

-- Direkte skrivning fjernes. Kun den kontrollerede funktion nedenfor må skrive.
revoke insert, update, delete on public.padel_state from anon, authenticated;

create or replace function public.padel_admin_save_state(
  p_data jsonb,
  p_expected_version bigint
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_version bigint;
begin
  if v_user is null or not exists (
    select 1 from public.padel_admins where user_id = v_user
  ) then
    raise exception 'Administratoradgang påkrævet' using errcode = '42501';
  end if;

  if p_data is null or jsonb_typeof(p_data) <> 'object'
     or jsonb_typeof(p_data->'squad') <> 'array'
     or jsonb_typeof(p_data->'rounds') <> 'array'
     or jsonb_typeof(p_data->'tournamentHistory') <> 'array' then
    raise exception 'Ugyldig turneringsdata';
  end if;

  if p_expected_version = 0 then
    insert into public.padel_state(id, data, version, updated_at, updated_by)
    values ('main', p_data, 1, now(), v_user)
    on conflict (id) do nothing
    returning version into v_version;
  else
    update public.padel_state
    set data = p_data, version = version + 1,
        updated_at = now(), updated_by = v_user
    where id = 'main' and version = p_expected_version
    returning version into v_version;
  end if;

  if v_version is null then
    raise exception 'Data er ændret på en anden enhed. Genindlæs før du gemmer.'
      using errcode = '40001';
  end if;
  return v_version;
end;
$$;

revoke all on function public.padel_admin_save_state(jsonb, bigint) from public, anon;
grant execute on function public.padel_admin_save_state(jsonb, bigint) to authenticated;

commit;

-- Fælles brugerkode og spilleres resultatregistrering kræver separat,
-- serverside validering og bliver IKKE aktiveret af dette script.

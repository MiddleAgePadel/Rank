-- SQL 44: Keep player read access after a completed evening.
-- Replaces only the player READ function; does not modify any season data.
-- The shared player code is still required. Scoring remains locked after finish.
begin;
create or replace function public.padel_v17_player_get(p_code text)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_hash text;
  v_data jsonb;
begin
  select a.code_hash into v_hash
  from public.padel_player_access a where a.id='main';
  if v_hash is null or p_code is null
     or extensions.crypt(p_code,v_hash)<>v_hash then
    raise exception 'Forkert spillerkode' using errcode='42501';
  end if;

  select t.data into v_data
  from public.padel_v17_season t where t.id='main';

  if v_data is null then
    raise exception 'Ingen spilleaften er oprettet';
  end if;

  -- A finished evening remains readable for results and final ranking.
  -- Other states retain their existing "no active evening" behavior.
  if coalesce(v_data->>'status','') not in ('generated','finished') then
    raise exception 'Ingen aktiv spilleaften';
  end if;

  return v_data;
end;
$$;
revoke all on function public.padel_v17_player_get(text) from public,anon,authenticated;
grant execute on function public.padel_v17_player_get(text) to anon,authenticated;
commit;

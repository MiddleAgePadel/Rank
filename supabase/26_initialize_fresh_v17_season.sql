-- SQL 26: Isolated fresh-season state for 19 October 2026.
-- Does not modify padel_state, padel_realistic_test or archives.
begin;
create table if not exists public.padel_v17_season (
 id text primary key check(id='main'),
 data jsonb not null,
 version bigint not null default 1,
 updated_at timestamptz not null default now()
);
alter table public.padel_v17_season enable row level security;
revoke all on table public.padel_v17_season from public,anon,authenticated;
-- Refuse to overwrite any season already initialized.
do $$
declare v_count integer; v_roster jsonb;
begin
 select count(*) into v_count from public.padel_v17_launch_roster;
 if v_count=0 then raise exception 'Launch roster empty. Run SQL 25 first.'; end if;
 select jsonb_agg(jsonb_build_object('id',player_id,'name',player_name,'ratingPoints',500,
 'results','[]'::jsonb,'matchesPlayed',0,'wins',0,'losses',0)
 order by lower(player_name)) into v_roster from public.padel_v17_launch_roster;
 insert into public.padel_v17_season(id,data,version,updated_at)
 values('main',jsonb_build_object('status','ready','squad',v_roster,
 'rounds','[]'::jsonb,'totalRounds',5,'tonightIds','[]'::jsonb,
 'reserveIds','[]'::jsonb,'seasonStart','2026-10-19',
 'matchmaking','v17','source','fresh-roster-only'),1,now())
 on conflict(id) do nothing;
end $$;
commit;
-- Verify: select jsonb_array_length(data->'squad') as players,
-- data->>'status' as status from public.padel_v17_season where id='main';

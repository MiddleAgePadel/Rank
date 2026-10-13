-- SQL 35: One-time, immutable pre-test snapshot of the official v17 season.
-- Does not change the season, ratings, rounds, or the legacy app.
begin;
create table if not exists public.padel_v17_pretest_backup (
  backup_id text primary key,
  data jsonb not null,
  season_version bigint not null,
  backed_up_at timestamptz not null default now()
);
alter table public.padel_v17_pretest_backup enable row level security;
revoke all on table public.padel_v17_pretest_backup from public, anon, authenticated;
do $$
declare v jsonb; v_version bigint;
begin
 select data,version into v,v_version from public.padel_v17_season where id='main';
 if v is null then raise exception 'Official v17 season not found'; end if;
 if v->>'status'<>'ready'
    or (v->>'totalRounds')::integer<>4
    or jsonb_array_length(coalesce(v->'rounds','[]'::jsonb))<>0
    or jsonb_array_length(coalesce(v->'tonightIds','[]'::jsonb))<>0
    or jsonb_array_length(coalesce(v->'squad','[]'::jsonb))<>43
    or exists(select 1 from jsonb_array_elements(v->'squad') p
      where coalesce((p->>'ratingPoints')::integer,-1)<>500
         or jsonb_array_length(coalesce(p->'results','[]'::jsonb))<>0)
 then raise exception 'Season is not in the clean launch state; backup aborted'; end if;
 insert into public.padel_v17_pretest_backup(backup_id,data,season_version)
 values('launch-2026-10-19',v,v_version)
 on conflict(backup_id) do nothing;
end $$;
commit;
select backup_id,backed_up_at,
 jsonb_array_length(data->'squad') as players,
 data->>'status' as status,
 data->>'totalRounds' as rounds,
 jsonb_array_length(data->'rounds') as created_rounds
from public.padel_v17_pretest_backup where backup_id='launch-2026-10-19';

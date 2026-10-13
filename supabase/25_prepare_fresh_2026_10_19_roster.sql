-- MiddleAgePadel: fresh 2026-10-19 season preparation.
-- Safe to run: creates a separate roster snapshot. Does NOT activate live games,
-- overwrite the existing app, delete sandbox archives or change padel_state.
begin;
create table if not exists public.padel_v17_launch_roster (
 player_id text primary key,
 player_name text not null,
 starting_rating integer not null default 500 check (starting_rating=500),
 launch_date date not null default date '2026-10-19',
 prepared_at timestamptz not null default now()
);
alter table public.padel_v17_launch_roster enable row level security;
revoke all on table public.padel_v17_launch_roster from public, anon, authenticated;
insert into public.padel_v17_launch_roster(player_id,player_name,starting_rating,launch_date)
select p.item->>'id',p.item->>'name',500,date '2026-10-19'
from public.padel_state s
cross join lateral jsonb_array_elements(coalesce(s.data->'squad','[]'::jsonb)) p(item)
where s.id='main' and nullif(p.item->>'id','') is not null and nullif(p.item->>'name','') is not null
on conflict(player_id) do update set player_name=excluded.player_name;
commit;
-- Administrator verification:
-- select count(*) as players, min(starting_rating), max(starting_rating)
-- from public.padel_v17_launch_roster;

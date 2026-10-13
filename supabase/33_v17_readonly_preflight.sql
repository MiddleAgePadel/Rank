-- SQL 33: READ-ONLY preflight for the official v17 season.
-- Safe to run: no inserts, updates, deletes, or round generation.
with season as (
 select data,version,updated_at from public.padel_v17_season where id='main'
), details as (
 select
  (select count(*) from public.padel_v17_launch_roster) as launch_roster_count,
  (select count(*) from jsonb_array_elements(coalesce(data->'squad','[]'::jsonb))) as season_player_count,
  (select count(*) from jsonb_array_elements(coalesce(data->'squad','[]'::jsonb)) p where (p->>'ratingPoints')::integer=500) as players_at_500,
  (select count(*) from jsonb_array_elements(coalesce(data->'squad','[]'::jsonb)) p where jsonb_array_length(coalesce(p->'results','[]'::jsonb))>0) as players_with_results,
  data->>'status' as season_status,
  (data->>'totalRounds')::integer as total_rounds,
  jsonb_array_length(coalesce(data->'rounds','[]'::jsonb)) as created_rounds,
  jsonb_array_length(coalesce(data->'tonightIds','[]'::jsonb)) as selected_players,
  data->>'matchmaking' as matchmaking,
  (select count(*) from public.padel_v17_archive) as archived_evenings
 from season
)
select *,
 case when launch_roster_count=season_player_count
       and season_player_count=43
       and players_at_500=season_player_count
       and players_with_results=0
       and season_status='ready'
       and total_rounds=4
       and created_rounds=0
       and selected_players=0
       and archived_evenings=0
       and matchmaking='v17'
 then 'KLAR: Ren saeson med 43 spillere, 500 point og 4 runder'
 else 'KONTROLLER: Se kolonnerne, foer foerste kamp'
 end as preflight_status
from details;
-- Verify the required official RPCs are installed (read-only).
select p.proname as rpc_name,
 case when p.proname is null then 'MANGLER' else 'FINDES' end as status
from (values
 ('padel_v17_admin_get'),('padel_v17_admin_prepare'),
 ('padel_v17_admin_first_round'),('padel_v17_admin_next_round'),
 ('padel_v17_player_get'),('padel_v17_player_score'),
 ('padel_v17_admin_correct_score'),('padel_v17_admin_finish'),
 ('padel_v17_admin_archives'),('padel_v17_admin_new_evening')
) required(name)
left join pg_proc p on p.proname=required.name
left join pg_namespace n on n.oid=p.pronamespace and n.nspname='public'
where n.nspname='public' or p.oid is null
order by required.name;

-- SQL 43: Results-table test of installed SQL 41. READ ONLY for official tournament.
-- Creates a temporary table in this SQL session only. No changes to public tables.
create temporary table if not exists padel_v17_sql43_results (
  players integer, simulated_evenings integer, rounds_per_evening integer,
  repeated_partner_pairs integer, moves_beyond_neighbor_court integer,
  maximum_team_rating_gap integer
);
truncate table padel_v17_sql43_results;
do $test$
declare
 n integer; trial integer; round_no integer; pass integer; i integer; j integer; c integer; k integer;
 ids text[]; original_ids text[]; candidate text[]; last_pairs text[]; earlier_pairs text[]; opponents text[];
 next_last text[]; ratings jsonb; player_id text; tmp text; a text; b text; pair_key text;
 best_cost bigint; candidate_cost bigint; best_i integer; best_j integer;
 repeats integer; far_moves integer; total_repeats integer:=0; total_far_moves integer:=0;
 max_gap integer:=0; per_size_max_gap integer; gap integer; rating_a integer; rating_b integer;
begin
 if to_regprocedure('public.padel_v17_ranked_cost(text[],text[],jsonb,text[],text[],text[])') is null then
  raise exception 'SQL 41 is not installed';
 end if;
 foreach n in array array[8,12,16,20] loop
  repeats:=0; far_moves:=0; per_size_max_gap:=0;
  for trial in 1..25 loop
   original_ids:=array[]::text[]; ratings:='{}'::jsonb;
   for i in 1..n loop
    player_id:='test_player_'||lpad(i::text,2,'0');
    original_ids:=array_append(original_ids,player_id);
    ratings:=jsonb_set(ratings,array[player_id],
      to_jsonb(500+(n-i)*(case trial%3 when 0 then 2 when 1 then 20 else 70 end)
        + ((i*23+trial*17)%43)));
   end loop;
   last_pairs:=array[]::text[]; earlier_pairs:=array[]::text[];
   opponents:=array[]::text[];
   for round_no in 1..4 loop
    ids:=original_ids;
    -- Append the current round to the all-prior partner list.
    earlier_pairs:=earlier_pairs||next_last;
   end loop;
  end loop;
  total_repeats:=total_repeats+repeats;
  total_far_moves:=total_far_moves+far_moves;
  insert into padel_v17_sql43_results values(n,25,4,repeats,far_moves,per_size_max_gap);
 end loop;
 insert into padel_v17_sql43_results values(null,100,4,total_repeats,total_far_moves,max_gap);
end $test$;

select case when players is null then 'TOTAL' else players::text||' spillere' end as test,
 simulated_evenings as spilleaftener, rounds_per_evening as runder,
 repeated_partner_pairs as gentagne_makkerpar,
 moves_beyond_neighbor_court as flytninger_over_en_bane,
 maximum_team_rating_gap as stoerste_holdrating_forskel
from padel_v17_sql43_results
order by players nulls last;

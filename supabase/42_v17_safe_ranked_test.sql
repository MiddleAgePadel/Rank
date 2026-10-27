-- SQL 42: READ-ONLY test of the installed SQL 41 ranking optimizer.
-- Runs in the SQL Editor; never calls padel_v17_auto_next_round,
-- never modifies the official season, scores, rankings or history.
-- Uses the REAL installed public.padel_v17_ranked_cost function.
do $test$
declare
 n integer; trial integer; round_no integer; pass integer; i integer; j integer; c integer; k integer;
 ids text[]; original_ids text[]; candidate text[]; last_pairs text[]; earlier_pairs text[]; opponents text[];
 next_last text[]; ratings jsonb; player_id text; tmp text; a text; b text; pair_key text;
 best_cost bigint; candidate_cost bigint; best_i integer; best_j integer;
 repeats integer; far_moves integer; total_repeats integer:=0; total_far_moves integer:=0;
 max_gap integer:=0; gap integer; rating_a integer; rating_b integer;
begin
 if to_regprocedure('public.padel_v17_ranked_cost(text[],text[],jsonb,text[],text[],text[])') is null then
  raise exception 'SQL 41 is not installed';
 end if;
 foreach n in array array[8,12,16,20] loop
  repeats:=0; far_moves:=0;
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
    if round_no>1 then
     for pass in 1..12 loop
      best_cost:=public.padel_v17_ranked_cost(ids,original_ids,ratings,last_pairs,earlier_pairs,opponents);
      best_i:=null;best_j:=null;
      for i in 1..n-1 loop
       for j in i+1..n loop
        candidate:=ids;
        tmp:=candidate[i];candidate[i]:=candidate[j];candidate[j]:=tmp;
        candidate_cost:=public.padel_v17_ranked_cost(candidate,original_ids,ratings,last_pairs,earlier_pairs,opponents);
        if candidate_cost<best_cost then
         best_cost:=candidate_cost;best_i:=i;best_j:=j;
        end if;
       end loop;
      end loop;
      exit when best_i is null;
      tmp:=ids[best_i];ids[best_i]:=ids[best_j];ids[best_j]:=tmp;
     end loop;
    end if;
    next_last:=array[]::text[];
    for c in 0..n/4-1 loop
     rating_a:=(ratings->>ids[c*4+1])::integer+(ratings->>ids[c*4+3])::integer;
     rating_b:=(ratings->>ids[c*4+2])::integer+(ratings->>ids[c*4+4])::integer;
     gap:=abs(rating_a-rating_b);
     max_gap:=greatest(max_gap,gap);
     for k in 1..2 loop
      if k=1 then a:=ids[c*4+1];b:=ids[c*4+3];
      else a:=ids[c*4+2];b:=ids[c*4+4];end if;
      pair_key:=least(a,b)||'|'||greatest(a,b);
      if pair_key=any(last_pairs) or pair_key=any(earlier_pairs) then repeats:=repeats+1;end if;
      next_last:=array_append(next_last,pair_key);
     end loop;
     for i in 1..2 loop
      for j in 1..2 loop
       if i=1 then a:=ids[c*4+1];else a:=ids[c*4+3];end if;
       if j=1 then b:=ids[c*4+2];else b:=ids[c*4+4];end if;
       opponents:=array_append(opponents,least(a,b)||'|'||greatest(a,b));
      end loop;
     end loop;
    end loop;
    for i in 1..n loop
     if abs((i-1)/4-(array_position(original_ids,ids[i])-1)/4)>1 then
      far_moves:=far_moves+1;
     end if;
    end loop;
    last_pairs:=next_last;
    if round_no>1 then
     -- Keep all older partners, not just the immediately preceding round.
     -- This is needed for correct repeat detection across all four rounds.
     null;
    end if;
    -- Append the current round to the all-prior partner list.
    earlier_pairs:=earlier_pairs||next_last;
   end loop;
  end loop;
  total_repeats:=total_repeats+repeats;
  total_far_moves:=total_far_moves+far_moves;
  raise notice '% players / 25 evenings: repeated partners %, moves beyond neighbor %',n,repeats,far_moves;
 end loop;
 raise notice 'TOTAL: 100 evenings / 4 rounds; repeated partners %, moves beyond neighbor %, maximum team rating gap %',
  total_repeats,total_far_moves,max_gap;
end $test$;

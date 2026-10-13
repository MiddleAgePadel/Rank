-- SQL 23: Analyse af alle genererede runder i den isolerede spilleaften.
-- Skriver intet til turnering, arkiv eller rigtige data.
begin;
create or replace function public.padel_admin_realistic_evening_analysis()
returns jsonb language plpgsql security definer set search_path='' as $analysis$
declare
 evening jsonb; rounds jsonb; round_item jsonb; match_item jsonb; player_item jsonb;
 idx integer; future_idx integer; total_rounds integer; team_a integer; team_b integer;
 id_a text; id_b text; key_pair text; key_opponent text; ids text[];
 rating_map jsonb; name_map jsonb:='{}'::jsonb; baseline jsonb:='{}'::jsonb;
 seen_partners text[]:=array[]::text[]; seen_opponents text[]:=array[]::text[];
 round_repeats integer; round_opponents integer; round_gap integer; max_gap integer;
 round_data jsonb:='[]'::jsonb; match_data jsonb; round_matches jsonb;
 overall_repeats integer:=0; overall_opponents integer:=0; total_gap integer:=0;
 score_a integer; score_b integer; delta integer; player_id text;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid())
 then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 select t.data into evening from public.padel_realistic_test t where t.id='sandbox';
 if evening is null then raise exception 'Ingen isoleret spilleaften'; end if;
 rounds:=coalesce(evening->'rounds','[]'::jsonb);
 total_rounds:=jsonb_array_length(rounds);
 if total_rounds=0 then raise exception 'Ingen genererede runder'; end if;
 for player_item in select value from jsonb_array_elements(evening->'squad') loop
  player_id:=player_item->>'id';
  name_map:=name_map||jsonb_build_object(player_id,player_item->>'name');
  baseline:=baseline||jsonb_build_object(player_id,coalesce((player_item->>'ratingPoints')::integer,500));
 end loop;
 -- Start-rating for hver runde: rull rating tilbage fra nuvaerende rating
 -- ved at fortryde ALLE gemte resultater i den aktuelle og senere runder.
 for idx in 0..total_rounds-1 loop
  rating_map:=baseline;
  for future_idx in idx..total_rounds-1 loop
   for match_item in select value from jsonb_array_elements(rounds->future_idx->'matches') loop
    if coalesce((match_item->>'saved')::boolean,false) then
     score_a:=(match_item->>'scoreA')::integer;
     score_b:=(match_item->>'scoreB')::integer;
     if score_a=score_b then continue;end if;
     for player_item in select value from jsonb_array_elements(match_item->'teamA') loop
      player_id:=player_item#>>'{}';
      delta:=case when score_a>score_b then 50 else -50 end;
      rating_map:=jsonb_set(rating_map,array[player_id],
        to_jsonb(coalesce((rating_map->>player_id)::integer,500)-delta));
     end loop;
     for player_item in select value from jsonb_array_elements(match_item->'teamB') loop
      player_id:=player_item#>>'{}';
      delta:=case when score_b>score_a then 50 else -50 end;
      rating_map:=jsonb_set(rating_map,array[player_id],
        to_jsonb(coalesce((rating_map->>player_id)::integer,500)-delta));
     end loop;
    end if;
   end loop;
  end loop;
  round_matches:='[]'::jsonb;round_repeats:=0;round_opponents:=0;round_gap:=0;max_gap:=0;
  for match_item in select value from jsonb_array_elements(rounds->idx->'matches') loop
   team_a:=coalesce((rating_map->>(match_item->'teamA'->>0))::integer,500)+
           coalesce((rating_map->>(match_item->'teamA'->>1))::integer,500);
   team_b:=coalesce((rating_map->>(match_item->'teamB'->>0))::integer,500)+
           coalesce((rating_map->>(match_item->'teamB'->>1))::integer,500);
   round_gap:=round_gap+abs(team_a-team_b);
   max_gap:=greatest(max_gap,abs(team_a-team_b));
   for ids in select array[match_item->'teamA'->>0,match_item->'teamA'->>1]
              union all select array[match_item->'teamB'->>0,match_item->'teamB'->>1] loop
    key_pair:=least(ids[1],ids[2])||'|'||greatest(ids[1],ids[2]);
    if key_pair=any(seen_partners) then round_repeats:=round_repeats+1;end if;
    seen_partners:=array_append(seen_partners,key_pair);
   end loop;
   for player_item in select value from jsonb_array_elements(match_item->'teamA') loop
    for round_item in select value from jsonb_array_elements(match_item->'teamB') loop
     id_a:=player_item#>>'{}';id_b:=round_item#>>'{}';
     key_opponent:=least(id_a,id_b)||'|'||greatest(id_a,id_b);
     if key_opponent=any(seen_opponents) then round_opponents:=round_opponents+1;end if;
     seen_opponents:=array_append(seen_opponents,key_opponent);
    end loop;
   end loop;
   match_data:=jsonb_build_object('court','B'||(10+coalesce((match_item->>'court')::integer,0)),
    'teamA',jsonb_build_array(name_map->>(match_item->'teamA'->>0),name_map->>(match_item->'teamA'->>1)),
    'teamB',jsonb_build_array(name_map->>(match_item->'teamB'->>0),name_map->>(match_item->'teamB'->>1)),
    'ratingA',team_a,'ratingB',team_b,'ratingGap',abs(team_a-team_b),
    'saved',coalesce((match_item->>'saved')::boolean,false));
   round_matches:=round_matches||jsonb_build_array(match_data);
  end loop;
  overall_repeats:=overall_repeats+round_repeats;
  overall_opponents:=overall_opponents+round_opponents;
  total_gap:=total_gap+round_gap;
  round_data:=round_data||jsonb_build_array(jsonb_build_object(
   'round',idx+1,'totalRatingGap',round_gap,'maxCourtGap',max_gap,
   'repeatedPartners',round_repeats,'repeatedOpponentEncounters',round_opponents,
   'courts',round_matches));
 end loop;
 return jsonb_build_object('status',evening->>'status','rounds',round_data,
  'summary',jsonb_build_object('roundCount',total_rounds,'totalRatingGap',total_gap,
   'repeatedPartners',overall_repeats,'repeatedOpponentEncounters',overall_opponents),
  'note','Kun analyse af eksisterende v11-kampe; ingen nye v13-kampe genereret');
end;
$analysis$;
revoke all on function public.padel_admin_realistic_evening_analysis() from public;
grant execute on function public.padel_admin_realistic_evening_analysis() to authenticated;
commit;

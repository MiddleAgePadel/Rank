-- SQL 38: Speed up 8-player automatic round generation after timeout.
-- Changes function definition only; current tournament scores remain unchanged.
begin;
create or replace function public.padel_v17_auto_next_round()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v jsonb; v_round jsonb; v_match jsonb; v_sorted jsonb;
 v_matches jsonb:='[]'::jsonb; v_last text[]:=array[]::text[];
 v_earlier text[]:=array[]::text[]; v_opponents text[]:=array[]::text[]; v_ids text[]; v_original text[];
 v_candidate text[]; v_rating_map jsonb;
 v_n integer; v_r integer; i integer; j integer; pass integer;
 current_cost bigint; candidate_cost bigint; best_cost bigint;
 best_i integer; best_j integer; tmp text; a text; b text;
 v_best_total integer; v_best_repeat integer; v_best_max integer; v_best_op integer;
 v_partner_repeat integer; v_op_repeat integer; v_gap1 integer; v_gap2 integer;
 v_total integer; v_max integer; v_perm integer[]; v_best_perm integer[];
 v_min_total integer:=2147483647; v_min_partner integer:=2147483647; v_min_max integer:=2147483647; v_quality integer; v_min_quality integer:=2147483647;
begin

 select t.data into v from public.padel_v17_season t where t.id='main' for update;
 if v is null or v->>'status'<>'generated' then raise exception 'Opret spilleaften foerst'; end if;
 v_r:=jsonb_array_length(coalesce(v->'rounds','[]'::jsonb));
 if v_r=0 then raise exception 'Generer runde 1 foerst'; end if;
 if v_r>=coalesce((v->>'totalRounds')::integer,5) then raise exception 'Sidste planlagte runde er naaet'; end if;
 if v_r>=4 then raise exception 'Der spilles 4 runder'; end if;
 v_round:=v->'rounds'->(v_r-1);
 if exists(select 1 from jsonb_array_elements(v_round->'matches') m
           where not coalesce((m->>'saved')::boolean,false))
 then raise exception 'Alle kampe i den aktuelle runde skal vaere gemt'; end if;
 v_n:=jsonb_array_length(v->'tonightIds');
 if v_n<4 or v_n>20 or v_n%4<>0 then raise exception 'Der skal vaere 4, 8, 12, 16 eller 20 spillere'; end if;
 for i in 0..v_r-1 loop
  v_round:=v->'rounds'->i;
  for v_match in select value from jsonb_array_elements(v_round->'matches') loop
   a:=v_match->'teamA'->>0;b:=v_match->'teamA'->>1;
   if i=v_r-1 then v_last:=array_append(v_last,least(a,b)||'|'||greatest(a,b));
   else v_earlier:=array_append(v_earlier,least(a,b)||'|'||greatest(a,b)); end if;
   for j in 0..1 loop
    v_opponents:=array_append(v_opponents,least(v_match->'teamA'->>j,v_match->'teamB'->>0)||'|'||greatest(v_match->'teamA'->>j,v_match->'teamB'->>0));
    v_opponents:=array_append(v_opponents,least(v_match->'teamA'->>j,v_match->'teamB'->>1)||'|'||greatest(v_match->'teamA'->>j,v_match->'teamB'->>1));
   end loop;
   a:=v_match->'teamB'->>0;b:=v_match->'teamB'->>1;
   if i=v_r-1 then v_last:=array_append(v_last,least(a,b)||'|'||greatest(a,b));
   else v_earlier:=array_append(v_earlier,least(a,b)||'|'||greatest(a,b)); end if;
  end loop;
 end loop;
 -- Rangering efter aktuelle rating, derefter aftenens resultater.
 select jsonb_agg(jsonb_build_object('id',z.id,'rating',z.rating)
   order by z.rating desc,z.points_for desc,(z.points_for-z.points_against) desc,z.wins desc,z.position)
 into v_sorted from (
  select p.player->>'id' as id,coalesce((p.player->>'ratingPoints')::integer,500) as rating,
   coalesce((select sum((r->>'scoreFor')::integer)
     from jsonb_array_elements(coalesce(p.player->'results','[]'::jsonb)) r
     where r->>'tournamentId'='v17-season'),0) as points_for,
   coalesce((select sum((r->>'scoreAgainst')::integer)
     from jsonb_array_elements(coalesce(p.player->'results','[]'::jsonb)) r
     where r->>'tournamentId'='v17-season'),0) as points_against,
   coalesce((select count(*) from jsonb_array_elements(coalesce(p.player->'results','[]'::jsonb)) r
     where r->>'tournamentId'='v17-season' and r->>'won'='true'),0) as wins,
   t.position
  from jsonb_array_elements(v->'tonightIds') with ordinality as t(player_id,position)
  join lateral jsonb_array_elements(v->'squad') as p(player)
   on p.player->>'id'=t.player_id #>> '{}'
 ) z;
 if v_sorted is null or jsonb_array_length(v_sorted)<>v_n then raise exception 'Deltagerlisten er ufuldstaendig'; end if;
 v_ids:=array(select e->>'id' from jsonb_array_elements(v_sorted) e);
 v_original:=v_ids;
 select jsonb_object_agg(e->>'id',(e->>'rating')::integer)
 into v_rating_map from jsonb_array_elements(v_sorted) e;
 -- V17: exhaustive 8-player pairing/court search, using live ratings.
 -- Evaluate all 8! permutations (duplicates harmless), then choose by
 -- partner repeats, 300-point court goal, total gap tolerance and opponent variety.
 if v_n=8 then
  -- Fast bounded optimization instead of 2 x 8! exhaustive permutations.
  -- Same cost function as the 12-20 player solver: rating balance and repeats.
  for pass in 1..12 loop
   best_cost:=public.padel_v17_multi_cost(v_ids,v_rating_map,v_last,v_earlier,v_opponents);
   best_i:=null;best_j:=null;
   for i in 1..v_n-1 loop
    for j in i+1..v_n loop
     v_candidate:=v_ids;
     tmp:=v_candidate[i];v_candidate[i]:=v_candidate[j];v_candidate[j]:=tmp;
     candidate_cost:=public.padel_v17_multi_cost(v_candidate,v_rating_map,v_last,v_earlier,v_opponents);
     if candidate_cost<best_cost then
      best_cost:=candidate_cost;best_i:=i;best_j:=j;
     end if;
    end loop;
   end loop;
   exit when best_i is null;
   tmp:=v_ids[best_i];v_ids[best_i]:=v_ids[best_j];v_ids[best_j]:=tmp;
  end loop;
 elsif v_n=4 then
  -- Four-player evenings retain the already proven v11 fallback.
  for pass in 1..100 loop
   current_cost:=public.padel_test_v11_cost(v_ids,v_original,v_rating_map,v_last,v_earlier);
   best_cost:=current_cost;best_i:=null;best_j:=null;
   for i in 1..v_n-1 loop
    for j in i+1..v_n loop
     v_candidate:=v_ids;tmp:=v_candidate[i];v_candidate[i]:=v_candidate[j];v_candidate[j]:=tmp;
     candidate_cost:=public.padel_test_v11_cost(v_candidate,v_original,v_rating_map,v_last,v_earlier);
     if candidate_cost<best_cost then best_cost:=candidate_cost;best_i:=i;best_j:=j;end if;
    end loop;
   end loop;
   exit when best_i is null;
   tmp:=v_ids[best_i];v_ids[best_i]:=v_ids[best_j];v_ids[best_j]:=tmp;
  end loop;
 else
  -- Scale the v17 objectives to 12-20 players without factorial permutations.
  -- Start from rating-sorted courts, then optimize player swaps for balanced
  -- courts and fewer repeat partnerships/opponents.
  for pass in 1..12 loop
   best_cost:=public.padel_v17_multi_cost(v_ids,v_rating_map,v_last,v_earlier,v_opponents);
   best_i:=null;best_j:=null;
   for i in 1..v_n-1 loop
    for j in i+1..v_n loop
     v_candidate:=v_ids;
     tmp:=v_candidate[i];v_candidate[i]:=v_candidate[j];v_candidate[j]:=tmp;
     candidate_cost:=public.padel_v17_multi_cost(v_candidate,v_rating_map,v_last,v_earlier,v_opponents);
     if candidate_cost<best_cost then
      best_cost:=candidate_cost;best_i:=i;best_j:=j;
     end if;
    end loop;
   end loop;
   exit when best_i is null;
   tmp:=v_ids[best_i];v_ids[best_i]:=v_ids[best_j];v_ids[best_j]:=tmp;
  end loop;
 end if;
 for i in 0..(v_n/4)-1 loop
  v_matches:=v_matches||jsonb_build_array(jsonb_build_object(
   'id',coalesce(v->>'eveningId','launch-20261019')||'-r'||(v_r+1)||'-b'||(10+i),'court',i,'round',v_r+1,
   'tournamentId','v17-season',
   'teamA',jsonb_build_array(v_ids[i*4+1],v_ids[i*4+3]),
   'teamB',jsonb_build_array(v_ids[i*4+2],v_ids[i*4+4]),
   'saved',false,'applied',false));
 end loop;
 v:=jsonb_set(v,array['rounds']::text[],v->'rounds'||
  jsonb_build_array(jsonb_build_object('roundNumber',v_r+1,'matches',v_matches)));
 v:=jsonb_set(v,array['currentRound']::text[],to_jsonb(v_r+1));
 update public.padel_v17_season t set data=v,version=t.version+1,updated_at=now() where t.id='main';
 return v;
end;
$$;




revoke all on function public.padel_v17_auto_next_round() from public,anon,authenticated;
commit;

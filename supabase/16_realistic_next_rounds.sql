-- SQL 16: Realistisk test, runde 2-5 og resultatregistrering i alle runder.
-- Kun padel_realistic_test opdateres. SQL 10 og SQL 15 skal vaere koert.
begin;
create or replace function public.padel_admin_realistic_next_round()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v jsonb; v_round jsonb; v_match jsonb; v_sorted jsonb;
 v_matches jsonb:='[]'::jsonb; v_last text[]:=array[]::text[];
 v_earlier text[]:=array[]::text[]; v_ids text[]; v_original text[];
 v_candidate text[]; v_rating_map jsonb;
 v_n integer; v_r integer; i integer; j integer; pass integer;
 current_cost bigint; candidate_cost bigint; best_cost bigint;
 best_i integer; best_j integer; tmp text; a text; b text;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid())
 then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 select t.data into v from public.padel_realistic_test t where t.id='sandbox' for update;
 if v is null or v->>'status'<>'generated' then raise exception 'Opret spilleaften foerst'; end if;
 v_r:=jsonb_array_length(coalesce(v->'rounds','[]'::jsonb));
 if v_r=0 then raise exception 'Generer runde 1 foerst'; end if;
 if v_r>=coalesce((v->>'totalRounds')::integer,5) then raise exception 'Sidste planlagte runde er naaet'; end if;
 if v_r>=5 then raise exception 'Realistisk test er begraenset til 5 runder'; end if;
 v_round:=v->'rounds'->(v_r-1);
 if exists(select 1 from jsonb_array_elements(v_round->'matches') m
           where not coalesce((m->>'saved')::boolean,false))
 then raise exception 'Alle kampe i den aktuelle runde skal vaere gemt'; end if;
 v_n:=jsonb_array_length(v->'tonightIds');
 if v_n not in (4,8) then raise exception 'Version 11 understotter endnu kun 4 eller 8 spillere'; end if;
 for i in 0..v_r-1 loop
  v_round:=v->'rounds'->i;
  for v_match in select value from jsonb_array_elements(v_round->'matches') loop
   a:=v_match->'teamA'->>0;b:=v_match->'teamA'->>1;
   if i=v_r-1 then v_last:=array_append(v_last,least(a,b)||'|'||greatest(a,b));
   else v_earlier:=array_append(v_earlier,least(a,b)||'|'||greatest(a,b)); end if;
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
     where r->>'tournamentId'='realistic-sandbox'),0) as points_for,
   coalesce((select sum((r->>'scoreAgainst')::integer)
     from jsonb_array_elements(coalesce(p.player->'results','[]'::jsonb)) r
     where r->>'tournamentId'='realistic-sandbox'),0) as points_against,
   coalesce((select count(*) from jsonb_array_elements(coalesce(p.player->'results','[]'::jsonb)) r
     where r->>'tournamentId'='realistic-sandbox' and r->>'won'='true'),0) as wins,
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
 for pass in 1..100 loop
  current_cost:=public.padel_test_v11_cost(v_ids,v_original,v_rating_map,v_last,v_earlier);
  best_cost:=current_cost;best_i:=null;best_j:=null;
  for i in 1..v_n-1 loop
   for j in i+1..v_n loop
    v_candidate:=v_ids;
    tmp:=v_candidate[i];v_candidate[i]:=v_candidate[j];v_candidate[j]:=tmp;
    candidate_cost:=public.padel_test_v11_cost(v_candidate,v_original,v_rating_map,v_last,v_earlier);
    if candidate_cost<best_cost then best_cost:=candidate_cost;best_i:=i;best_j:=j; end if;
   end loop;
  end loop;
  exit when best_i is null;
  tmp:=v_ids[best_i];v_ids[best_i]:=v_ids[best_j];v_ids[best_j]:=tmp;
 end loop;
 for i in 0..(v_n/4)-1 loop
  v_matches:=v_matches||jsonb_build_array(jsonb_build_object(
   'id','realistic-r'||(v_r+1)||'-b'||(10+i),'court',i,'round',v_r+1,
   'tournamentId','realistic-sandbox',
   'teamA',jsonb_build_array(v_ids[i*4+1],v_ids[i*4+3]),
   'teamB',jsonb_build_array(v_ids[i*4+2],v_ids[i*4+4]),
   'saved',false,'applied',false));
 end loop;
 v:=jsonb_set(v,array['rounds']::text[],v->'rounds'||
  jsonb_build_array(jsonb_build_object('roundNumber',v_r+1,'matches',v_matches)));
 v:=jsonb_set(v,array['currentRound']::text[],to_jsonb(v_r+1));
 update public.padel_realistic_test t set data=v,version=t.version+1,updated_at=now() where t.id='sandbox';
 return v;
end;
$$;
-- Udvid eksisterende spillerfunktion til den aktuelle runde, ikke kun runde 1.
create or replace function public.padel_player_realistic_score(
 p_code text,p_match_id text,p_score_a integer,p_score_b integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_hash text; v_data jsonb; v_round jsonb; v_match jsonb;
 v_updated jsonb:='[]'::jsonb; v_new_matches jsonb:='[]'::jsonb;
 v_player jsonb; v_result jsonb; v_id text; v_for integer; v_against integer;
 v_win boolean; v_found boolean:=false; v_count integer:=0;
 v_member_count integer:=0; v_round_number integer; v_round_index integer;
begin
 select a.code_hash into v_hash from public.padel_player_access a where a.id='main';
 if v_hash is null or p_code is null or extensions.crypt(p_code,v_hash)<>v_hash
 then raise exception 'Forkert spillerkode' using errcode='42501'; end if;
 if p_score_a is null or p_score_b is null or p_score_a<0 or p_score_b<0
 or p_score_a>99 or p_score_b>99 or p_score_a=p_score_b
 then raise exception 'Indtast to forskellige heltal mellem 0 og 99'; end if;
 select t.data into v_data from public.padel_realistic_test t where t.id='sandbox' for update;
 if v_data is null or v_data->>'status'<>'generated' then raise exception 'Ingen aktiv testspilleaften'; end if;
 v_round_index:=jsonb_array_length(v_data->'rounds')-1;
 if v_round_index<0 then raise exception 'Ingen runde'; end if;
 v_round:=v_data->'rounds'->v_round_index;
 v_round_number:=coalesce((v_round->>'roundNumber')::integer,v_round_index+1);
 for v_match in select value from jsonb_array_elements(v_round->'matches') loop
  if v_match->>'id'=p_match_id then
   if coalesce((v_match->>'saved')::boolean,false) then raise exception 'Resultatet er allerede gemt'; end if;
   v_found:=true;v_count:=v_count+1;
   v_match:=v_match||jsonb_build_object('scoreA',p_score_a,'scoreB',p_score_b,'saved',true,'applied',true);
  end if;
  v_new_matches:=v_new_matches||jsonb_build_array(v_match);
 end loop;
 if not v_found or v_count<>1 then raise exception 'Ukendt kamp i aktuel runde'; end if;
 select m.value into v_match from jsonb_array_elements(v_new_matches) m
 where m.value->>'id'=p_match_id;
 for v_player in select value from jsonb_array_elements(v_data->'squad') loop
  v_id:=v_player->>'id';
  if v_match->'teamA' ? v_id then
   v_for:=p_score_a;v_against:=p_score_b;v_member_count:=v_member_count+1;
  elsif v_match->'teamB' ? v_id then
   v_for:=p_score_b;v_against:=p_score_a;v_member_count:=v_member_count+1;
  else v_updated:=v_updated||jsonb_build_array(v_player);continue; end if;
  v_win:=v_for>v_against;
  v_player:=jsonb_set(v_player,array['ratingPoints']::text[],
   to_jsonb(coalesce((v_player->>'ratingPoints')::integer,500)+case when v_win then 50 else -50 end));
  v_player:=jsonb_set(v_player,array['games']::text[],to_jsonb(coalesce((v_player->>'games')::integer,0)+1));
  if v_win then
   v_player:=jsonb_set(v_player,array['wins']::text[],to_jsonb(coalesce((v_player->>'wins')::integer,0)+1));
  else
   v_player:=jsonb_set(v_player,array['losses']::text[],to_jsonb(coalesce((v_player->>'losses')::integer,0)+1));
  end if;
  v_player:=jsonb_set(v_player,array['matchPointsFor']::text[],
   to_jsonb(coalesce((v_player->>'matchPointsFor')::integer,0)+v_for));
  v_player:=jsonb_set(v_player,array['matchPointsAgainst']::text[],
   to_jsonb(coalesce((v_player->>'matchPointsAgainst')::integer,0)+v_against));
  v_result:=jsonb_build_object('tournamentId','realistic-sandbox','round',v_round_number,
   'matchId',p_match_id,'scoreFor',v_for,'scoreAgainst',v_against,'won',v_win);
  v_player:=jsonb_set(v_player,array['results']::text[],
   coalesce(v_player->'results','[]'::jsonb)||jsonb_build_array(v_result));
  v_updated:=v_updated||jsonb_build_array(v_player);
 end loop;
 if v_member_count<>4 then raise exception 'Kampen har ikke fire gyldige spillere'; end if;
 v_round:=jsonb_set(v_round,array['matches']::text[],v_new_matches);
 v_data:=jsonb_set(v_data,array['rounds',v_round_index::text]::text[],v_round);
 v_data:=jsonb_set(v_data,array['squad']::text[],v_updated);
 update public.padel_realistic_test t set data=v_data,version=t.version+1,
 updated_at=now() where t.id='sandbox';
 return v_data;
end;
$$;
revoke all on function public.padel_admin_realistic_next_round() from public;
grant execute on function public.padel_admin_realistic_next_round() to authenticated;
revoke all on function public.padel_player_realistic_score(text,text,integer,integer) from public;
grant execute on function public.padel_player_realistic_score(text,text,integer,integer) to anon,authenticated;
commit;

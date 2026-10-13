-- SQL 32: Safe admin-only correction of a saved result in the current round.
-- No changes to existing data until the administrator calls the RPC.
begin;
create or replace function public.padel_v17_admin_correct_score(
 p_match_id text,p_score_a integer,p_score_b integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v jsonb; v_round jsonb; v_match jsonb; v_matches jsonb:='[]'::jsonb;
 v_squad jsonb:='[]'::jsonb; v_player jsonb; v_results jsonb;
 v_old jsonb; v_new jsonb; v_id text; v_old_for integer; v_old_against integer;
 v_new_for integer; v_new_against integer; v_old_win boolean; v_new_win boolean;
 v_index integer; v_count integer:=0; v_members integer:=0;
begin
 if auth.uid() is null or not exists(
  select 1 from public.padel_admins where user_id=auth.uid()
 ) then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 if p_score_a is null or p_score_b is null or p_score_a<0 or p_score_b<0
 or p_score_a>99 or p_score_b>99 or p_score_a=p_score_b then
  raise exception 'Indtast forskellige heltal mellem 0 og 99';
 end if;
 select t.data into v from public.padel_v17_season t where t.id='main' for update;
 if v is null or v->>'status'<>'generated' then
  raise exception 'Kun aktive spilleaftener kan rettes';
 end if;
 v_index:=jsonb_array_length(coalesce(v->'rounds','[]'::jsonb))-1;
 if v_index<0 then raise exception 'Ingen aktiv runde'; end if;
 v_round:=v->'rounds'->v_index;
 for v_match in select value from jsonb_array_elements(v_round->'matches') loop
  if v_match->>'id'=p_match_id then
   v_count:=v_count+1;
   if not coalesce((v_match->>'saved')::boolean,false)
      or not coalesce((v_match->>'applied')::boolean,false) then
    raise exception 'Kampen har ikke et gemt resultat';
   end if;
   v_old_for:=(v_match->>'scoreA')::integer;
   v_old_against:=(v_match->>'scoreB')::integer;
   if v_old_for is null or v_old_against is null then raise exception 'Gammelt resultat mangler'; end if;
   v_match:=v_match||jsonb_build_object('scoreA',p_score_a,'scoreB',p_score_b);
  end if;
  v_matches:=v_matches||jsonb_build_array(v_match);
 end loop;
 if v_count<>1 then raise exception 'Kampen findes ikke i den aktuelle runde'; end if;
 select value into v_match from jsonb_array_elements(v_matches) where value->>'id'=p_match_id;
 for v_player in select value from jsonb_array_elements(v->'squad') loop
  v_id:=v_player->>'id';
  if v_match->'teamA' ? v_id then
   v_new_for:=p_score_a;v_new_against:=p_score_b;
   v_members:=v_members+1;
   v_old_win:=v_old_for>v_old_against;
  elsif v_match->'teamB' ? v_id then
   v_new_for:=p_score_b;v_new_against:=p_score_a;
   v_members:=v_members+1;
   v_old_win:=v_old_against>v_old_for;
  else
   v_squad:=v_squad||jsonb_build_array(v_player);
   continue;
  end if;
  v_new_win:=v_new_for>v_new_against;
  if v_match->'teamA' ? v_id then
   v_old_for:=(v_match->>'scoreA')::integer;
   v_old_against:=(v_match->>'scoreB')::integer;
  else
   v_old_for:=(v_match->>'scoreB')::integer;
   v_old_against:=(v_match->>'scoreA')::integer;
  end if;
  -- Use the old score from the saved result itself, never the just-edited match.
  select value into v_old from jsonb_array_elements(coalesce(v_player->'results','[]'::jsonb))
   where value->>'matchId'=p_match_id and value->>'tournamentId'='v17-season';
  if v_old is null then raise exception 'Gammelt spillerresultat mangler for %',v_id; end if;
  if (select count(*) from jsonb_array_elements(coalesce(v_player->'results','[]'::jsonb))
    where value->>'matchId'=p_match_id and value->>'tournamentId'='v17-season')<>1
  then raise exception 'Dubleret spillerresultat for %',v_id; end if;
  v_old_for:=(v_old->>'scoreFor')::integer;
  v_old_against:=(v_old->>'scoreAgainst')::integer;
  v_old_win:=(v_old->>'won')::boolean;
  v_player:=jsonb_set(v_player,'{ratingPoints}',to_jsonb(
   coalesce((v_player->>'ratingPoints')::integer,500)
   +case when v_new_win then 50 else -50 end
   -case when v_old_win then 50 else -50 end));
  v_player:=jsonb_set(v_player,'{wins}',to_jsonb(
   coalesce((v_player->>'wins')::integer,0)
   +case when v_new_win then 1 else 0 end
   -case when v_old_win then 1 else 0 end));
  v_player:=jsonb_set(v_player,'{losses}',to_jsonb(
   coalesce((v_player->>'losses')::integer,0)
   +case when v_new_win then 0 else 1 end
   -case when v_old_win then 0 else 1 end));
  v_player:=jsonb_set(v_player,'{matchPointsFor}',to_jsonb(
   coalesce((v_player->>'matchPointsFor')::integer,0)+v_new_for-v_old_for));
  v_player:=jsonb_set(v_player,'{matchPointsAgainst}',to_jsonb(
   coalesce((v_player->>'matchPointsAgainst')::integer,0)+v_new_against-v_old_against));
  v_new:=v_old||jsonb_build_object('scoreFor',v_new_for,'scoreAgainst',v_new_against,'won',v_new_win);
  select coalesce(jsonb_agg(case when value->>'matchId'=p_match_id and
   value->>'tournamentId'='v17-season' then v_new else value end),'[]'::jsonb)
   into v_results from jsonb_array_elements(coalesce(v_player->'results','[]'::jsonb));
  v_player:=jsonb_set(v_player,'{results}',v_results);
  v_squad:=v_squad||jsonb_build_array(v_player);
 end loop;
 if v_members<>4 then raise exception 'Kampen har ikke fire gyldige spillere'; end if;
 v_round:=jsonb_set(v_round,'{matches}',v_matches);
 v:=jsonb_set(v,array['rounds',v_index::text],v_round);
 v:=jsonb_set(v,'{squad}',v_squad);
 update public.padel_v17_season t set data=v,version=t.version+1,updated_at=now() where t.id='main';
 return v;
end;
$$;
revoke all on function public.padel_v17_admin_correct_score(text,integer,integer) from public,anon;
grant execute on function public.padel_v17_admin_correct_score(text,integer,integer) to authenticated;
commit;

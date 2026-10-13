-- SQL 15: Spilleradgang og resultatregistrering for REALISTISK ISOLERET test.
-- Skriver KUN til padel_realistic_test. Aldrig til padel_state.
begin;
create or replace function public.padel_player_realistic_get(p_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_hash text; v_data jsonb;
begin
 select a.code_hash into v_hash from public.padel_player_access a where a.id='main';
 if v_hash is null or p_code is null or extensions.crypt(p_code,v_hash)<>v_hash then
  raise exception 'Forkert spillerkode' using errcode='42501';
 end if;
 select t.data into v_data from public.padel_realistic_test t where t.id='sandbox';
 if v_data is null or v_data->>'status'<>'generated' then
  raise exception 'Ingen aktiv realistisk testspilleaften';
 end if;
 return v_data;
end;
$$;

create or replace function public.padel_player_realistic_score(
 p_code text,p_match_id text,p_score_a integer,p_score_b integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_hash text; v_data jsonb; v_round jsonb; v_match jsonb;
 v_players jsonb; v_updated jsonb:='[]'::jsonb; v_new_matches jsonb:='[]'::jsonb;
 v_new_rounds jsonb:='[]'::jsonb; v_player jsonb; v_result jsonb;
 v_id text; v_for integer; v_against integer; v_win boolean;
 v_found boolean:=false; v_count integer:=0; v_member_count integer:=0;
 i integer; j integer;
begin
 select a.code_hash into v_hash from public.padel_player_access a where a.id='main';
 if v_hash is null or p_code is null or extensions.crypt(p_code,v_hash)<>v_hash then
  raise exception 'Forkert spillerkode' using errcode='42501';
 end if;
 if p_score_a is null or p_score_b is null or p_score_a<0 or p_score_b<0
 or p_score_a>99 or p_score_b>99 or p_score_a=p_score_b then
  raise exception 'Indtast to forskellige heltal mellem 0 og 99';
 end if;
 select t.data into v_data from public.padel_realistic_test t
 where t.id='sandbox' for update;
 if v_data is null or v_data->>'status'<>'generated' then
  raise exception 'Ingen aktiv testspilleaften';
 end if;
 if jsonb_array_length(v_data->'rounds')<>1 then
  raise exception 'Denne testversion kan kun registrere runde 1';
 end if;
 v_round:=v_data->'rounds'->0;
 for v_match in select value from jsonb_array_elements(v_round->'matches') loop
  if v_match->>'id'=p_match_id then
   if coalesce((v_match->>'saved')::boolean,false) then
    raise exception 'Resultatet er allerede gemt';
   end if;
   v_found:=true;v_count:=v_count+1;
   v_match:=v_match||jsonb_build_object(
    'scoreA',p_score_a,'scoreB',p_score_b,'saved',true,'applied',true);
  end if;
  v_new_matches:=v_new_matches||jsonb_build_array(v_match);
 end loop;
 if not v_found or v_count<>1 then raise exception 'Ukendt kamp'; end if;
 -- Find den opdaterede kamp fra listen, og anvend rating EN GANG.
 select value into v_match from jsonb_array_elements(v_new_matches)
 where value->>'id'=p_match_id;
 for v_player in select value from jsonb_array_elements(v_data->'squad') loop
  v_id:=v_player->>'id';
  if v_match->'teamA' ? v_id then
   v_for:=p_score_a;v_against:=p_score_b;v_member_count:=v_member_count+1;
  elsif v_match->'teamB' ? v_id then
   v_for:=p_score_b;v_against:=p_score_a;v_member_count:=v_member_count+1;
  else
   v_updated:=v_updated||jsonb_build_array(v_player);
   continue;
  end if;
  v_win:=v_for>v_against;
  v_player:=jsonb_set(v_player,array['ratingPoints']::text[],
    to_jsonb(coalesce((v_player->>'ratingPoints')::integer,500)+case when v_win then 50 else -50 end));
  v_player:=jsonb_set(v_player,array['games']::text[],
    to_jsonb(coalesce((v_player->>'games')::integer,0)+1));
  if v_win then
   v_player:=jsonb_set(v_player,array['wins']::text[],
     to_jsonb(coalesce((v_player->>'wins')::integer,0)+1));
  else
   v_player:=jsonb_set(v_player,array['losses']::text[],
     to_jsonb(coalesce((v_player->>'losses')::integer,0)+1));
  end if;
  v_player:=jsonb_set(v_player,array['matchPointsFor']::text[],
    to_jsonb(coalesce((v_player->>'matchPointsFor')::integer,0)+v_for));
  v_player:=jsonb_set(v_player,array['matchPointsAgainst']::text[],
    to_jsonb(coalesce((v_player->>'matchPointsAgainst')::integer,0)+v_against));
  v_result:=jsonb_build_object('tournamentId','realistic-sandbox','round',1,
    'matchId',p_match_id,'scoreFor',v_for,'scoreAgainst',v_against,'won',v_win);
  v_player:=jsonb_set(v_player,array['results']::text[],
    coalesce(v_player->'results','[]'::jsonb)||jsonb_build_array(v_result));
  v_updated:=v_updated||jsonb_build_array(v_player);
 end loop;
 if v_member_count<>4 then raise exception 'Kampen har ikke fire gyldige spillere'; end if;
 v_round:=jsonb_set(v_round,array['matches']::text[],v_new_matches);
 v_data:=jsonb_set(v_data,array['rounds']::text[],jsonb_build_array(v_round));
 v_data:=jsonb_set(v_data,array['squad']::text[],v_updated);
 update public.padel_realistic_test t set data=v_data,
 version=t.version+1,updated_at=now() where t.id='sandbox';
 return v_data;
end;
$$;
revoke all on function public.padel_player_realistic_get(text) from public;
revoke all on function public.padel_player_realistic_score(text,text,integer,integer) from public;
grant execute on function public.padel_player_realistic_get(text) to anon,authenticated;
grant execute on function public.padel_player_realistic_score(text,text,integer,integer) to anon,authenticated;
commit;

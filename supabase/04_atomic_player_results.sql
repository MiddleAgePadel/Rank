-- Fase 4: atomisk resultatregistrering for spillere.
-- Koer efter 03_shared_player_read.sql. Ingen eksisterende data aendres ved installation.
-- Sikkerhed: serveren laaser hele turneringsstaten, tjekker kode og kampstatus,
-- beregner ratings paa serveren og gemmer alle aendringer i samme transaktion.
begin;
create or replace function public.padel_player_save_match(
 p_code text, p_match_id text, p_score_a integer, p_score_b integer
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
 v_hash text;
 v_state jsonb;
 v_version bigint;
 v_round_idx integer;
 v_match_idx integer;
 v_round jsonb;
 v_match jsonb;
 v_players jsonb;
 v_player jsonb;
 v_player_id text;
 v_side integer;
 v_score_for integer;
 v_score_against integer;
 v_won boolean;
 v_delta integer;
 v_result jsonb;
 v_player_idx integer;
 v_player_count integer;
 v_current_round integer;
 v_now text := now()::text;
begin
 select code_hash into v_hash from public.padel_player_access where id='main';
 if v_hash is null or p_code is null or
    extensions.crypt(p_code,v_hash) <> v_hash then
   raise exception 'Forkert spillerkode' using errcode='42501';
 end if;
 if p_match_id is null or length(p_match_id) > 150 or
    p_score_a is null or p_score_b is null or
    p_score_a < 0 or p_score_b < 0 or
    p_score_a > 99 or p_score_b > 99 or p_score_a = p_score_b then
   raise exception 'Ugyldigt resultat';
 end if;
 select data,version into v_state,v_version
 from public.padel_state where id='main' for update;
 if v_state is null then raise exception 'Ingen turnering'; end if;
 v_current_round := (v_state->>'currentRound')::integer;
 if v_current_round is null or v_current_round < 1 then
   raise exception 'Ingen aktiv runde';
 end if;
 v_round_idx := null;
 v_match_idx := null;
 for v_round_idx in 0..jsonb_array_length(v_state->'rounds')-1 loop
   v_round := v_state->'rounds'->v_round_idx;
   if (v_round->>'roundNumber')::integer = v_current_round then
     for v_match_idx in 0..jsonb_array_length(v_round->'matches')-1 loop
       if v_round->'matches'->v_match_idx->>'id' = p_match_id then
         exit;
       end if;
     end loop;
     if v_match_idx < jsonb_array_length(v_round->'matches') and
        v_round->'matches'->v_match_idx->>'id' = p_match_id then
       exit;
     end if;
   end if;
 end loop;
 if v_round_idx is null or v_match_idx is null or
    v_round_idx >= jsonb_array_length(v_state->'rounds') or
    v_match_idx >= jsonb_array_length(v_state->'rounds'->v_round_idx->'matches') or
    v_state->'rounds'->v_round_idx->'matches'->v_match_idx->>'id' <> p_match_id or
    (v_state->'rounds'->v_round_idx->>'roundNumber')::integer <> v_current_round then
   raise exception 'Kampen findes ikke i den aktive runde';
 end if;
 v_match := v_state->'rounds'->v_round_idx->'matches'->v_match_idx;
 if coalesce((v_match->>'saved')::boolean,false) or
    coalesce((v_match->>'applied')::boolean,false) then
   raise exception 'Resultatet er allerede gemt' using errcode='23505';
 end if;
 if jsonb_typeof(v_match->'teamA') <> 'array' or
    jsonb_typeof(v_match->'teamB') <> 'array' or
    jsonb_array_length(v_match->'teamA') <> 2 or
    jsonb_array_length(v_match->'teamB') <> 2 then
   raise exception 'Ugyldig holdopstilling';
 end if;
 v_players := v_state->'squad';
 for v_side in 0..3 loop
   if v_side < 2 then
     v_player_id := v_match->'teamA'->>v_side;
     v_score_for := p_score_a;
     v_score_against := p_score_b;
     v_won := p_score_a > p_score_b;
   else
     v_player_id := v_match->'teamB'->>(v_side-2);
     v_score_for := p_score_b;
     v_score_against := p_score_a;
     v_won := p_score_b > p_score_a;
   end if;
   v_delta := case when v_won then 50 else -50 end;
   v_player_idx := null;
   for v_player_count in 0..jsonb_array_length(v_players)-1 loop
     if v_players->v_player_count->>'id' = v_player_id then
       v_player_idx := v_player_count;
       exit;
     end if;
   end loop;
   if v_player_idx is null then raise exception 'Spiller mangler'; end if;
   v_player := v_players->v_player_idx;
   if exists (
     select 1 from jsonb_array_elements(coalesce(v_player->'results','[]'::jsonb)) r
     where r->>'matchId' = p_match_id
   ) then
     raise exception 'Resultatet er allerede talt med';
   end if;
   v_result := jsonb_build_object(
     'id','result-'||gen_random_uuid()::text,
     'matchId',p_match_id,'tournamentId',v_match->>'tournamentId',
     'date',v_now,'round',(v_match->>'round')::integer,
     'court',(v_match->>'court')::integer,
     'result',case when v_won then 'W' else 'L' end,
     'scoreFor',v_score_for,'scoreAgainst',v_score_against,'ratingChange',v_delta
   );
   v_player := jsonb_set(v_player,'{ratingPoints}',to_jsonb(coalesce((v_player->>'ratingPoints')::integer,500)+v_delta));
   v_player := jsonb_set(v_player,'{games}',to_jsonb(coalesce((v_player->>'games')::integer,0)+1));
   v_player := jsonb_set(v_player,case when v_won then '{wins}' else '{losses}' end,
      to_jsonb(coalesce((v_player->>case when v_won then 'wins' else 'losses' end)::integer,0)+1));
   v_player := jsonb_set(v_player,'{matchPointsFor}',to_jsonb(coalesce((v_player->>'matchPointsFor')::integer,0)+v_score_for));
   v_player := jsonb_set(v_player,'{matchPointsAgainst}',to_jsonb(coalesce((v_player->>'matchPointsAgainst')::integer,0)+v_score_against));
   v_player := jsonb_set(v_player,'{results}',coalesce(v_player->'results','[]'::jsonb)||jsonb_build_array(v_result));
   v_players := jsonb_set(v_players,array[v_player_idx::text],v_player);
 end loop;
 v_match := v_match || jsonb_build_object('scoreA',p_score_a,'scoreB',p_score_b,'saved',true,'applied',true);
 v_state := jsonb_set(v_state,array['rounds',v_round_idx::text,'matches',v_match_idx::text],v_match);
 v_state := jsonb_set(v_state,'{squad}',v_players);
 update public.padel_state set data=v_state,version=v_version+1,updated_at=now()
 where id='main';
 return jsonb_build_object('version',v_version+1,'match_id',p_match_id,'score_a',p_score_a,'score_b',p_score_b);
end;
$$;
revoke all on function public.padel_player_save_match(text,text,integer,integer) from public;
grant execute on function public.padel_player_save_match(text,text,integer,integer) to anon,authenticated;
commit;

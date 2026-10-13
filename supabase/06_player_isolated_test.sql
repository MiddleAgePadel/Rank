-- Fase 6: spilleradgang til ISOLERET testturnering.
-- Koer efter 03 og 05. Berorer aldrig public.padel_state.
begin;
create or replace function public.padel_player_test_get(p_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_hash text; v jsonb;
begin
 select code_hash into v_hash from public.padel_player_access where id='main';
 if v_hash is null or p_code is null or extensions.crypt(p_code,v_hash)<>v_hash then
  raise exception 'Forkert spillerkode' using errcode='42501';
 end if;
 select data into v from public.padel_match_test where id='sandbox';
 if v is null then raise exception 'Testturnering mangler. Administrator skal nulstille testen.'; end if;
 return v;
end;
$$;
create or replace function public.padel_player_test_score(p_code text,p_match_id text,p_score_a integer,p_score_b integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_hash text; v jsonb; m jsonb; players jsonb; p jsonb; i integer; j integer; k integer; pid text; delta integer; score_for integer; score_against integer; won boolean; updated_match jsonb; found_player boolean;
begin
 select code_hash into v_hash from public.padel_player_access where id='main';
 if v_hash is null or p_code is null or extensions.crypt(p_code,v_hash)<>v_hash then
  raise exception 'Forkert spillerkode' using errcode='42501';
 end if;
 if p_score_a is null or p_score_b is null or p_score_a<0 or p_score_b<0 or p_score_a>99 or p_score_b>99 or p_score_a=p_score_b then
  raise exception 'Ugyldigt resultat';
 end if;
 if p_match_id is null or p_match_id not in ('test-b10','test-b11') then raise exception 'Ukendt testkamp'; end if;
 select data into v from public.padel_match_test where id='sandbox' for update;
 if v is null then raise exception 'Testturnering mangler'; end if;
 players:=v->'squad';
 for i in 0..jsonb_array_length(v->'rounds'->0->'matches')-1 loop
  m:=v->'rounds'->0->'matches'->i;
  if m->>'id'=p_match_id then
   if coalesce((m->>'saved')::boolean,false) then raise exception 'Kampen er allerede gemt'; end if;
   for j in 0..3 loop
    if j<2 then
     pid:=m->'teamA'->>j; score_for:=p_score_a;score_against:=p_score_b;won:=p_score_a>p_score_b;
    else
     pid:=m->'teamB'->>(j-2);score_for:=p_score_b;score_against:=p_score_a;won:=p_score_b>p_score_a;
    end if;
    delta:=case when won then 50 else -50 end;
    found_player:=false;
    for k in 0..jsonb_array_length(players)-1 loop
     if players->k->>'id'=pid then
      found_player:=true;
      p:=players->k;
      p:=jsonb_set(p,ARRAY['ratingPoints']::text[],to_jsonb((p->>'ratingPoints')::integer+delta));
      p:=jsonb_set(p,ARRAY['games']::text[],to_jsonb((p->>'games')::integer+1));
      if won then
       p:=jsonb_set(p,ARRAY['wins']::text[],to_jsonb((p->>'wins')::integer+1));
      else
       p:=jsonb_set(p,ARRAY['losses']::text[],to_jsonb((p->>'losses')::integer+1));
      end if;
      p:=jsonb_set(p,ARRAY['matchPointsFor']::text[],to_jsonb((p->>'matchPointsFor')::integer+score_for));
      p:=jsonb_set(p,ARRAY['matchPointsAgainst']::text[],to_jsonb((p->>'matchPointsAgainst')::integer+score_against));
      p:=jsonb_set(p,ARRAY['results']::text[],coalesce(p->'results','[]'::jsonb)||jsonb_build_array(jsonb_build_object('matchId',p_match_id,'ratingChange',delta,'scoreFor',score_for,'scoreAgainst',score_against)));
      players:=jsonb_set(players,ARRAY[k::text],p);
      exit;
     end if;
    end loop;
    if not found_player then raise exception 'Testspiller mangler'; end if;
   end loop;
   updated_match:=m||jsonb_build_object('scoreA',p_score_a,'scoreB',p_score_b,'saved',true,'applied',true);
   v:=jsonb_set(v,ARRAY['rounds','0','matches',i::text],updated_match);
   v:=jsonb_set(v,ARRAY['squad']::text[],players);
   update public.padel_match_test set data=v,version=version+1,updated_at=now() where id='sandbox';
   return v;
  end if;
 end loop;
 raise exception 'Ukendt testkamp';
end;
$$;
revoke all on function public.padel_player_test_get(text) from public;
revoke all on function public.padel_player_test_score(text,text,integer,integer) from public;
grant execute on function public.padel_player_test_get(text) to anon,authenticated;
grant execute on function public.padel_player_test_score(text,text,integer,integer) to anon,authenticated;
commit;

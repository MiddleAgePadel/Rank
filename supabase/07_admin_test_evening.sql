-- Fase 7: administrator kan vaelge 4 eller 8 deltagere til ISOLERET test.
-- Bevarer de otte fiktive spillere; nulstiller kun sandbox-kampe og deres test-rating.
begin;
create or replace function public.padel_admin_test_create_evening(p_player_ids text[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; v_players jsonb := '[]'::jsonb; v_matches jsonb := '[]'::jsonb; v_ids text[]; v_n integer; i integer; v_player jsonb; v_id text;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 v_n:=coalesce(array_length(p_player_ids,1),0);
 if v_n not in (4,8) then raise exception 'Vaelg praecis 4 eller 8 spillere'; end if;
 if (select count(distinct x) from unnest(p_player_ids) as x)<>v_n then raise exception 'Spillere maa ikke vaelges flere gange'; end if;
 if exists(select 1 from unnest(p_player_ids) as x where x is null or x !~ '^test-[1-8]$') then
  raise exception 'Kun de 8 fiktive testspillere kan vaelges';
 end if;
 select data into v from public.padel_match_test where id='sandbox' for update;
 if v is null then raise exception 'Opret testturneringen med nulstil-knappen foerst'; end if;
 -- Nulstil alle 8 fiktive spillere, saa ny test starter fra 500.
 for i in 1..8 loop
  v_player:=jsonb_build_object('id','test-'||i,'name','Testspiller '||i,'ratingPoints',500,'games',0,'wins',0,'losses',0,'matchPointsFor',0,'matchPointsAgainst',0,'results','[]'::jsonb);
  v_players:=v_players||jsonb_build_array(v_player);
 end loop;
 -- Sorter efter rating (alle starter paa 500) og dernaest efter valgt raekkefoelge.
 v_ids:=p_player_ids;
 for i in 0..(v_n/4)-1 loop
  v_matches:=v_matches||jsonb_build_array(jsonb_build_object(
   'id',case when i=0 then 'test-b10' else 'test-b11' end,
   'court',i,'round',1,'tournamentId','test-isolated',
   'teamA',jsonb_build_array(v_ids[i*4+1],v_ids[i*4+3]),
   'teamB',jsonb_build_array(v_ids[i*4+2],v_ids[i*4+4]),
   'saved',false,'applied',false
  ));
 end loop;
 v:=jsonb_build_object('squad',v_players,'tonightIds',to_jsonb(v_ids),
   'rounds',jsonb_build_array(jsonb_build_object('roundNumber',1,'matches',v_matches)),
   'currentRound',1,'tournamentId','test-isolated');
 update public.padel_match_test set data=v,version=version+1,updated_at=now() where id='sandbox';
 return v;
end;
$$;
revoke all on function public.padel_admin_test_create_evening(text[]) from public;
grant execute on function public.padel_admin_test_create_evening(text[]) to authenticated;
commit;

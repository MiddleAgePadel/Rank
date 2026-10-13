-- SQL 13: Generer runde 1 i isoleret realistisk test.
-- Kun public.padel_realistic_test opdateres. Rigtige data forbliver uforandrede.
begin;
create or replace function public.padel_admin_realistic_first_round()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; v_ids text[]; v_matches jsonb:='[]'::jsonb;
 n integer; i integer; v_players jsonb; v_round jsonb;
begin
 if auth.uid() is null or not exists(
  select 1 from public.padel_admins where user_id=auth.uid()
 ) then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 select t.data into v from public.padel_realistic_test t
 where t.id='sandbox' for update;
 if v is null then raise exception 'Gem foerst et testudkast'; end if;
 if v->>'status'<>'draft' or jsonb_array_length(coalesce(v->'rounds','[]'::jsonb))<>0 then
  raise exception 'Runde 1 er allerede genereret. Gem et nyt testudkast for at begynde forfra';
 end if;
 n:=jsonb_array_length(v->'tonightIds');
 if n<4 or n>40 or n%4<>0 then raise exception 'Ugyldigt antal deltagere'; end if;
 if jsonb_array_length(v->'squad')<>n then raise exception 'Spillerlisten er ufuldstaendig'; end if;
 -- Foerste runde: sortering efter rating; ved lighed behold valgt spillerorden.
 select array_agg(x.player_id order by x.rating desc,x.pos) into v_ids
 from (
  select t.player_id #>> '{}' as player_id,
         t.pos,
         coalesce((p.player->>'ratingPoints')::integer,500) as rating
  from jsonb_array_elements(v->'tonightIds') with ordinality as t(player_id,pos)
  join lateral jsonb_array_elements(v->'squad') as p(player)
    on p.player->>'id'=t.player_id #>> '{}'
 ) x;
 if coalesce(array_length(v_ids,1),0)<>n then raise exception 'Spillere mangler'; end if;
 for i in 0..(n/4)-1 loop
  v_matches:=v_matches||jsonb_build_array(jsonb_build_object(
   'id','realistic-r1-b'||(10+i),'court',i,'round',1,
   'tournamentId','realistic-sandbox',
   'teamA',jsonb_build_array(v_ids[i*4+1],v_ids[i*4+3]),
   'teamB',jsonb_build_array(v_ids[i*4+2],v_ids[i*4+4]),
   'saved',false,'applied',false
  ));
 end loop;
 v_round:=jsonb_build_object('roundNumber',1,'matches',v_matches);
 v:=jsonb_set(v,array['rounds']::text[],jsonb_build_array(v_round));
 v:=jsonb_set(v,array['currentRound']::text[],to_jsonb(1));
 v:=jsonb_set(v,array['status']::text[],to_jsonb('generated'::text));
 update public.padel_realistic_test t set data=v,version=t.version+1,
 updated_at=now() where t.id='sandbox';
 return v;
end;
$$;
revoke all on function public.padel_admin_realistic_first_round() from public;
grant execute on function public.padel_admin_realistic_first_round() to authenticated;
commit;

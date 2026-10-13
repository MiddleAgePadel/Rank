-- SQL 09: Samme matchmaking-regler som matchmaking.js + app.js.
-- KUN isoleret padel_match_test; ingen aendringer af padel_state.
-- Koer hele scriptet i SQL Editor. Eksisterende runder bevares.
begin;

create or replace function public.padel_test_partner_repeats(p_ids text[], p_used text[])
returns integer language plpgsql immutable set search_path='' as $$
declare i integer; n integer; result integer:=0; pair_key text;
begin
 n:=coalesce(array_length(p_ids,1),0);
 if n=0 or n%4<>0 then raise exception 'Ugyldig spilleliste'; end if;
 for i in 0..(n/4)-1 loop
  pair_key:=least(p_ids[i*4+1],p_ids[i*4+3])||'|'||greatest(p_ids[i*4+1],p_ids[i*4+3]);
  if pair_key=any(p_used) then result:=result+1; end if;
  pair_key:=least(p_ids[i*4+2],p_ids[i*4+4])||'|'||greatest(p_ids[i*4+2],p_ids[i*4+4]);
  if pair_key=any(p_used) then result:=result+1; end if;
 end loop;
 return result;
end;
$$;

create or replace function public.padel_admin_test_next_round()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v jsonb; v_round jsonb; v_match jsonb; v_sorted jsonb;
 v_matches jsonb:='[]'::jsonb;
 v_used text[]:=array[]::text[];
 v_ids text[]; v_candidate text[]; v_ratings integer[];
 v_n integer; v_r integer;
 i integer; j integer; k integer; start_pos integer; end_pos integer;
 best_i integer; best_j integer; best_score integer; candidate_score integer;
 current_score integer; passes integer; tmp text; p1 text; p2 text;
begin
 if auth.uid() is null or not exists(
  select 1 from public.padel_admins where user_id=auth.uid()
 ) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;

 select data into v from public.padel_match_test where id='sandbox' for update;
 if v is null or jsonb_array_length(coalesce(v->'rounds','[]'::jsonb))=0 then
  raise exception 'Opret spilleaften foerst';
 end if;
 v_r:=jsonb_array_length(v->'rounds');
 if v_r>=5 then raise exception 'Testen er begraenset til 5 runder'; end if;
 v_round:=v->'rounds'->(v_r-1);
 if exists (
  select 1 from jsonb_array_elements(v_round->'matches') as m
  where coalesce((m->>'saved')::boolean,false)=false
 ) then
  raise exception 'Alle resultater i den aktuelle runde skal gemmes foerst';
 end if;
 v_n:=jsonb_array_length(v->'tonightIds');
 if v_n not in (4,8) then raise exception 'Ugyldigt deltagerantal'; end if;

 -- Registrer alle tidligere makkere (ogsaa i runder uden gemte resultater).
 for v_round in select value from jsonb_array_elements(v->'rounds') loop
  for v_match in select value from jsonb_array_elements(v_round->'matches') loop
   p1:=v_match->'teamA'->>0; p2:=v_match->'teamA'->>1;
   v_used:=array_append(v_used,least(p1,p2)||'|'||greatest(p1,p2));
   p1:=v_match->'teamB'->>0; p2:=v_match->'teamB'->>1;
   v_used:=array_append(v_used,least(p1,p2)||'|'||greatest(p1,p2));
  end loop;
 end loop;

 -- Identisk tie-break som getLeaderboard() i app.js:
 -- rating, aftenens score for, pointdifference, sejre, oprindelig deltagerorden.
 select jsonb_agg(jsonb_build_object('id',z.id,'rating',z.rating) order by
                  z.rating desc,z.points_for desc,
                  (z.points_for-z.points_against) desc,z.wins desc,z.position)
 into v_sorted
 from (
  select p->>'id' as id,
         (p->>'ratingPoints')::integer as rating,
         coalesce((select sum((r->>'scoreFor')::integer)
                   from jsonb_array_elements(coalesce(p->'results','[]'::jsonb)) r),0) as points_for,
         coalesce((select sum((r->>'scoreAgainst')::integer)
                   from jsonb_array_elements(coalesce(p->'results','[]'::jsonb)) r),0) as points_against,
         coalesce((p->>'wins')::integer,0) as wins,
         t.position
  from jsonb_array_elements(v->'tonightIds') with ordinality as t(player_id,position)
  join lateral jsonb_array_elements(v->'squad') p on p->>'id'=t.player_id #>> '{}'
 ) z;
 if v_sorted is null or jsonb_array_length(v_sorted)<>v_n then
  raise exception 'En eller flere deltagere mangler';
 end if;
 v_ids:=array(select e->>'id' from jsonb_array_elements(v_sorted) e);
 v_ratings:=array(select (e->>'rating')::integer from jsonb_array_elements(v_sorted) e);

 -- Matchmaking.js: inden for hver sammenhaengende gruppe med praecis
 -- samme rating, find bedste ENKELTBYT, gentag indtil ingen forbedring.
 start_pos:=1;
 while start_pos<=v_n loop
  end_pos:=start_pos;
  while end_pos<v_n loop
   exit when v_ratings[end_pos+1]<>v_ratings[start_pos];
   end_pos:=end_pos+1;
  end loop;
  if end_pos>start_pos then
   passes:=0;
   loop
    passes:=passes+1;
    exit when passes>100;
    current_score:=public.padel_test_partner_repeats(v_ids,v_used);
    best_score:=current_score;best_i:=null;best_j:=null;
    for i in start_pos..end_pos loop
     for j in i+1..end_pos loop
      v_candidate:=v_ids;
      tmp:=v_candidate[i];v_candidate[i]:=v_candidate[j];v_candidate[j]:=tmp;
      candidate_score:=public.padel_test_partner_repeats(v_candidate,v_used);
      if candidate_score<best_score then
       best_score:=candidate_score;best_i:=i;best_j:=j;
      end if;
      exit when best_score=0;
     end loop;
     exit when best_score=0;
    end loop;
    exit when best_i is null;
    tmp:=v_ids[best_i];v_ids[best_i]:=v_ids[best_j];v_ids[best_j]:=tmp;
   end loop;
  end if;
  start_pos:=end_pos+1;
 end loop;

 for i in 0..(v_n/4)-1 loop
  v_matches:=v_matches||jsonb_build_array(jsonb_build_object(
   'id','test-r'||(v_r+1)||'-b1'||i,
   'court',i,'round',v_r+1,'tournamentId','test-isolated',
   'teamA',jsonb_build_array(v_ids[i*4+1],v_ids[i*4+3]),
   'teamB',jsonb_build_array(v_ids[i*4+2],v_ids[i*4+4]),
   'saved',false,'applied',false
  ));
 end loop;
 v:=jsonb_set(v,array['rounds']::text[],
              (v->'rounds')||jsonb_build_array(
               jsonb_build_object('roundNumber',v_r+1,'matches',v_matches)));
 v:=jsonb_set(v,array['currentRound']::text[],to_jsonb(v_r+1));
 update public.padel_match_test set data=v,version=version+1,updated_at=now()
 where id='sandbox';
 return v;
end;
$$;

revoke all on function public.padel_test_partner_repeats(text[],text[]) from public;
revoke all on function public.padel_admin_test_next_round() from public;
grant execute on function public.padel_admin_test_next_round() to authenticated;
commit;

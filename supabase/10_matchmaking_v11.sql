-- SQL 10: Matchmaking v11, kun ISOLERET padel_match_test.
-- Kan anvendes paa igangvaerende test. Eksisterende runder og resultater bevares.
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

create or replace function public.padel_test_v11_cost(
 p_ids text[],p_original text[],p_ratings jsonb,p_previous text[],p_earlier text[]
) returns bigint language plpgsql immutable set search_path='' as $$
declare n integer; i integer; j integer; a text; b text; pair_key text;
 ra integer; rb integer; rc integer; rd integer; total bigint:=0;
begin
 n:=coalesce(array_length(p_ids,1),0);
 if n not in (4,8) then raise exception 'Ugyldigt antal testspillere'; end if;
 for i in 0..(n/4)-1 loop
  a:=p_ids[4*i+1];b:=p_ids[4*i+3];
  pair_key:=least(a,b)||'|'||greatest(a,b);
  if pair_key=any(p_previous) then total:=total+10000;
  elsif pair_key=any(p_earlier) then total:=total+1800; end if;
  a:=p_ids[4*i+2];b:=p_ids[4*i+4];
  pair_key:=least(a,b)||'|'||greatest(a,b);
  if pair_key=any(p_previous) then total:=total+10000;
  elsif pair_key=any(p_earlier) then total:=total+1800; end if;
  ra:=(p_ratings->>p_ids[4*i+1])::integer;
  rb:=(p_ratings->>p_ids[4*i+2])::integer;
  rc:=(p_ratings->>p_ids[4*i+3])::integer;
  rd:=(p_ratings->>p_ids[4*i+4])::integer;
  -- Holdbalance (1+3 mod 2+4), og rimelig spredning paa hver bane.
  total:=total+3*abs((ra+rc)-(rb+rd));
  total:=total+(greatest(ra,rb,rc,rd)-least(ra,rb,rc,rd));
 end loop;
 -- Bevar i rimeligt omfang den ratingbaserede placering paa banerne.
 for i in 1..n loop
  for j in 1..n loop
   if p_ids[i]=p_original[j] then
    total:=total+20*abs(i-j);
    if ((i-1)/4)<>((j-1)/4) then
     total:=total+abs((p_ratings->>p_ids[i])::integer-(p_ratings->>p_original[i])::integer);
    end if;
    exit;
   end if;
  end loop;
 end loop;
 return total;
end;
$;

create or replace function public.padel_admin_test_next_round()
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

 -- Tidligere makkere: seneste runde vaegtes hoejere end aeldre runder.
 for i in 0..v_r-1 loop
  v_round:=v->'rounds'->i;
  for v_match in select value from jsonb_array_elements(v_round->'matches') loop
   a:=v_match->'teamA'->>0;b:=v_match->'teamA'->>1;
   if i=v_r-1 then
    v_last:=array_append(v_last,least(a,b)||'|'||greatest(a,b));
   else
    v_earlier:=array_append(v_earlier,least(a,b)||'|'||greatest(a,b));
   end if;
   a:=v_match->'teamB'->>0;b:=v_match->'teamB'->>1;
   if i=v_r-1 then
    v_last:=array_append(v_last,least(a,b)||'|'||greatest(a,b));
   else
    v_earlier:=array_append(v_earlier,least(a,b)||'|'||greatest(a,b));
   end if;
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
 v_original:=v_ids;
 select jsonb_object_agg(e->>'id',(e->>'rating')::integer)
 into v_rating_map from jsonb_array_elements(v_sorted) e;

 -- Global optimering: alle spillere kan bytte plads, ikke kun samme rating.
 -- Deterministisk bedste enkeltbyt gentages, indtil ingen forbedring findes.
 for pass in 1..100 loop
  current_cost:=public.padel_test_v11_cost(v_ids,v_original,v_rating_map,v_last,v_earlier);
  best_cost:=current_cost;best_i:=null;best_j:=null;
  for i in 1..v_n-1 loop
   for j in i+1..v_n loop
    v_candidate:=v_ids;
    tmp:=v_candidate[i];v_candidate[i]:=v_candidate[j];v_candidate[j]:=tmp;
    candidate_cost:=public.padel_test_v11_cost(v_candidate,v_original,v_rating_map,v_last,v_earlier);
    if candidate_cost<best_cost then
     best_cost:=candidate_cost;best_i:=i;best_j:=j;
    end if;
   end loop;
  end loop;
  exit when best_i is null;
  tmp:=v_ids[best_i];v_ids[best_i]:=v_ids[best_j];v_ids[best_j]:=tmp;
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

revoke all on function public.padel_test_v11_cost(text[],text[],jsonb,text[],text[]) from public;
revoke all on function public.padel_test_partner_repeats(text[],text[]) from public;
revoke all on function public.padel_admin_test_next_round() from public;
grant execute on function public.padel_admin_test_next_round() to authenticated;
commit;

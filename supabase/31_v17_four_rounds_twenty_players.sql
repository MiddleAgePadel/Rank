-- SQL 31: Restore original tournament capacity: 4 rounds, 4-20 players.
-- Changes only fresh v17 season functions; does not touch old production or pilots.
begin;
create or replace function public.padel_v17_multi_cost(
 p_ids text[],p_rating_map jsonb,p_last text[],p_earlier text[],p_opponents text[]
) returns bigint language plpgsql immutable set search_path='' as $$
declare c integer; i integer; j integer; a text;b text; rating_a integer;rating_b integer;
 gap integer;cost bigint:=0;pair text;
begin
 for c in 0..(cardinality(p_ids)/4)-1 loop
  rating_a:=coalesce((p_rating_map->>p_ids[c*4+1])::integer,500)+coalesce((p_rating_map->>p_ids[c*4+3])::integer,500);
  rating_b:=coalesce((p_rating_map->>p_ids[c*4+2])::integer,500)+coalesce((p_rating_map->>p_ids[c*4+4])::integer,500);
  gap:=abs(rating_a-rating_b);
  -- Strong court-balance preference; extra cost for differences over 300.
  cost:=cost+gap*10+greatest(0,gap-300)*100;
  for i in 1..2 loop
   if i=1 then a:=p_ids[c*4+1];b:=p_ids[c*4+3];
   else a:=p_ids[c*4+2];b:=p_ids[c*4+4];end if;
   pair:=least(a,b)||'|'||greatest(a,b);
   if pair=any(p_last) then cost:=cost+100000;
   elsif pair=any(p_earlier) then cost:=cost+40000;end if;
  end loop;
  for i in 1..2 loop
   for j in 1..2 loop
    a:=p_ids[c*4+(i-1)*2+1];
    b:=p_ids[c*4+j*2];
    pair:=least(a,b)||'|'||greatest(a,b);
    if pair=any(p_opponents) then cost:=cost+500;end if;
   end loop;
  end loop;
 end loop;
 return cost;
end $$;
create or replace function public.padel_v17_admin_prepare(
 p_player_ids text[],p_reserve_ids text[],p_total_rounds integer default 4
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; v_roster_ids text[]; v_id text; v_active integer;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 if p_total_rounds is distinct from 4 then raise exception 'Der skal vaere 4 runder'; end if;
 v_active:=coalesce(cardinality(p_player_ids),0);
 if v_active<4 or v_active>20 or v_active%4<>0 then raise exception 'Vaelg 4, 8, 12, 16 eller 20 deltagere'; end if;
 if (select count(distinct x) from unnest(p_player_ids) x)<>v_active then
  raise exception 'Samme deltager er valgt flere gange';
 end if;
 if coalesce(cardinality(p_reserve_ids),0)<>(select count(distinct x) from unnest(p_reserve_ids) x) then
  raise exception 'Samme reserve er valgt flere gange';
 end if;
 if exists(select 1 from unnest(p_reserve_ids) x where x=any(p_player_ids)) then
  raise exception 'En spiller kan ikke vaere baade deltager og reserve';
 end if;
 select data into v from public.padel_v17_season where id='main' for update;
 if v is null then raise exception 'Ny turnering mangler'; end if;
 if v->>'status' not in ('ready','draft') or jsonb_array_length(coalesce(v->'rounds','[]'::jsonb))>0 then
  raise exception 'Aktiv spilleaften kan ikke overskrives';
 end if;
 select array_agg(p->>'id') into v_roster_ids from jsonb_array_elements(v->'squad') p;
 foreach v_id in array (coalesce(p_player_ids,array[]::text[])||coalesce(p_reserve_ids,array[]::text[])) loop
  if not(v_id=any(coalesce(v_roster_ids,array[]::text[]))) then
   raise exception 'Ukendt spiller-id: %',v_id;
  end if;
 end loop;
 v:=jsonb_set(v,'{tonightIds}',to_jsonb(p_player_ids),true);
 v:=jsonb_set(v,'{reserveIds}',to_jsonb(coalesce(p_reserve_ids,array[]::text[])),true);
 v:=jsonb_set(v,'{totalRounds}',to_jsonb(p_total_rounds),true);
 v:=jsonb_set(v,'{status}','"draft"'::jsonb,true);
 update public.padel_v17_season set data=v,version=version+1,updated_at=now() where id='main';
 return v;
end $$;

create or replace function public.padel_v17_admin_first_round()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; v_ids text[]; v_matches jsonb:='[]'::jsonb;
 n integer; i integer; v_players jsonb; v_round jsonb;
begin
 if auth.uid() is null or not exists(
  select 1 from public.padel_admins where user_id=auth.uid()
 ) then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 select t.data into v from public.padel_v17_season t
 where t.id='main' for update;
 if v is null then raise exception 'Gem foerst et testudkast'; end if;
 if v->>'status'<>'draft' or jsonb_array_length(coalesce(v->'rounds','[]'::jsonb))<>0 then
  raise exception 'Runde 1 er allerede genereret. Gem et nyt testudkast for at begynde forfra';
 end if;
 n:=jsonb_array_length(v->'tonightIds');
 if n<4 or n>20 or n%4<>0 then raise exception 'Ugyldigt antal deltagere'; end if;
 
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
   'id','v17-r1-b'||(10+i),'court',i,'round',1,
   'tournamentId','v17-season',
   'teamA',jsonb_build_array(v_ids[i*4+1],v_ids[i*4+3]),
   'teamB',jsonb_build_array(v_ids[i*4+2],v_ids[i*4+4]),
   'saved',false,'applied',false
  ));
 end loop;
 v_round:=jsonb_build_object('roundNumber',1,'matches',v_matches);
 v:=jsonb_set(v,array['rounds']::text[],jsonb_build_array(v_round));
 v:=jsonb_set(v,array['currentRound']::text[],to_jsonb(1));
 v:=jsonb_set(v,array['status']::text[],to_jsonb('generated'::text));
 update public.padel_v17_season t set data=v,version=t.version+1,
 updated_at=now() where t.id='main';
 return v;
end;
$$;

create or replace function public.padel_v17_admin_next_round()
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
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid())
 then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
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
  for pass in 1..2 loop
   for v_perm in
    with recursive perms(p,used) as (
     select array[]::integer[],array[]::integer[]
     union all
     select p||k,used||k from perms cross join generate_series(1,8) k
     where not k=any(used) and cardinality(p)<8
    ) select p from perms where cardinality(p)=8
   loop
    v_candidate:=array(select v_ids[k] from unnest(v_perm) k);
    v_partner_repeat:=0;v_op_repeat:=0;
    for i in 0..1 loop
     a:=least(v_candidate[i*4+1],v_candidate[i*4+3])||'|'||greatest(v_candidate[i*4+1],v_candidate[i*4+3]);
     b:=least(v_candidate[i*4+2],v_candidate[i*4+4])||'|'||greatest(v_candidate[i*4+2],v_candidate[i*4+4]);
     v_partner_repeat:=v_partner_repeat+case when a=any(v_last) or a=any(v_earlier) then 1 else 0 end+case when b=any(v_last) or b=any(v_earlier) then 1 else 0 end;
     for j in 1..2 loop
      -- Cross-team opponent pairings (team A positions 1,3; team B positions 2,4).
      a:=least(v_candidate[i*4+1],v_candidate[i*4+j*2])||'|'||greatest(v_candidate[i*4+1],v_candidate[i*4+j*2]);
      b:=least(v_candidate[i*4+3],v_candidate[i*4+j*2])||'|'||greatest(v_candidate[i*4+3],v_candidate[i*4+j*2]);
      v_op_repeat:=v_op_repeat+case when a=any(v_opponents) then 1 else 0 end+case when b=any(v_opponents) then 1 else 0 end;
     end loop;
    end loop;
    v_gap1:=abs(coalesce((v_rating_map->>v_candidate[1])::integer,500)+coalesce((v_rating_map->>v_candidate[3])::integer,500)-coalesce((v_rating_map->>v_candidate[2])::integer,500)-coalesce((v_rating_map->>v_candidate[4])::integer,500));
    v_gap2:=abs(coalesce((v_rating_map->>v_candidate[5])::integer,500)+coalesce((v_rating_map->>v_candidate[7])::integer,500)-coalesce((v_rating_map->>v_candidate[6])::integer,500)-coalesce((v_rating_map->>v_candidate[8])::integer,500));
    v_total:=v_gap1+v_gap2;v_max:=greatest(v_gap1,v_gap2);
    v_quality:=case when v_max<=300 then 0 else 1 end;
    if pass=1 then
     if v_partner_repeat<v_min_partner or (v_partner_repeat=v_min_partner and v_quality<v_min_quality) then
      v_min_partner:=v_partner_repeat;v_min_quality:=v_quality;v_min_total:=v_total;v_min_max:=v_max;
     elsif v_partner_repeat=v_min_partner and v_quality=v_min_quality then
      v_min_total:=least(v_min_total,v_total);v_min_max:=least(v_min_max,v_max);
     end if;
    else
     if v_partner_repeat=v_min_partner and v_quality=v_min_quality and v_total<=v_min_total+300 then
      if v_best_perm is null or v_op_repeat<v_best_op or (v_op_repeat=v_best_op and v_total<v_best_total) then
       v_best_perm:=v_perm;v_best_op:=v_op_repeat;v_best_total:=v_total;
      end if;
     end if;
    end if;
   end loop;
  end loop;
  if v_best_perm is null then raise exception 'V17 kunne ikke finde gyldig kampfordeling'; end if;
  v_candidate:=v_ids;
  v_ids:=array(select v_candidate[k] from unnest(v_best_perm) k);
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
   'id','v17-r'||(v_r+1)||'-b'||(10+i),'court',i,'round',v_r+1,
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

-- Only adjust initial defaults when no games or drafts have been generated.
update public.padel_v17_season set data=jsonb_set(data,'{totalRounds}','4'::jsonb,true),version=version+1,updated_at=now() where id='main' and data->>'status'='ready' and jsonb_array_length(coalesce(data->'rounds','[]'::jsonb))=0;
revoke all on function public.padel_v17_multi_cost(text[],jsonb,text[],text[],text[]) from public,anon,authenticated;
revoke all on function public.padel_v17_admin_prepare(text[],text[],integer) from public,anon;
grant execute on function public.padel_v17_admin_prepare(text[],text[],integer) to authenticated;
revoke all on function public.padel_v17_admin_first_round() from public,anon;
grant execute on function public.padel_v17_admin_first_round() to authenticated;
revoke all on function public.padel_v17_admin_next_round() from public,anon;
grant execute on function public.padel_v17_admin_next_round() to authenticated;
commit;

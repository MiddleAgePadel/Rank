-- V17 isolated next-round matchmaking. Run manually in Supabase SQL Editor.
-- Does not replace v11 or modify production data. Requires SQL 16.
begin;
create or replace function public.padel_admin_realistic_next_round_v17()
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
 v_min_total integer:=2147483647; v_min_partner integer:=2147483647; v_min_max integer:=2147483647;
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
    if pass=1 then
     if v_partner_repeat<v_min_partner or (v_partner_repeat=v_min_partner and v_max<v_min_max) then
      v_min_partner:=v_partner_repeat;v_min_max:=v_max;v_min_total:=v_total;
     elsif v_partner_repeat=v_min_partner and v_max=v_min_max then
      v_min_total:=least(v_min_total,v_total);
     end if;
    else
     if v_partner_repeat=v_min_partner and v_max=v_min_max and v_total<=v_min_total+300 then
      if v_best_perm is null or v_op_repeat<v_best_op or (v_op_repeat=v_best_op and v_total<v_best_total) then
       v_best_perm:=v_perm;v_best_op:=v_op_repeat;v_best_total:=v_total;
      end if;
     end if;
    end if;
   end loop;
  end loop;
  if v_best_perm is null then raise exception 'V17 kunne ikke finde gyldig kampfordeling'; end if;
  v_ids:=array(select v_ids[k] from unnest(v_best_perm) k);
 else
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
 end if;
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

revoke all on function public.padel_admin_realistic_next_round_v17() from public;
grant execute on function public.padel_admin_realistic_next_round_v17() to authenticated;
commit;

-- SQL 28: New v17 season gameplay. Separate from old production and test tables.
-- Requires SQL 25-27 and prior tested v11 cost helper. No data migration.
begin;
create table if not exists public.padel_v17_archive(archive_id bigint generated always as identity primary key,archived_at timestamptz not null default now(),data jsonb not null);
alter table public.padel_v17_archive enable row level security;
revoke all on table public.padel_v17_archive from public,anon,authenticated;
revoke all on sequence public.padel_v17_archive_archive_id_seq from public,anon,authenticated;
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
 if n not in (4,8) then raise exception 'Ugyldigt antal deltagere'; end if;
 
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
create or replace function public.padel_v17_player_get(p_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_hash text;v_data jsonb;
begin
 select code_hash into v_hash from public.padel_player_access where id='main';
 if v_hash is null or p_code is null or extensions.crypt(p_code,v_hash)<>v_hash then raise exception 'Forkert spillerkode' using errcode='42501'; end if;
 select data into v_data from public.padel_v17_season where id='main';
 if v_data is null or v_data->>'status'<>'generated' then raise exception 'Ingen aktiv spilleaften'; end if;
 return v_data;
end $$;
create or replace function public.padel_v17_player_score(
 p_code text,p_match_id text,p_score_a integer,p_score_b integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_hash text; v_data jsonb; v_round jsonb; v_match jsonb;
 v_updated jsonb:='[]'::jsonb; v_new_matches jsonb:='[]'::jsonb;
 v_player jsonb; v_result jsonb; v_id text; v_for integer; v_against integer;
 v_win boolean; v_found boolean:=false; v_count integer:=0;
 v_member_count integer:=0; v_round_number integer; v_round_index integer;
begin
 select a.code_hash into v_hash from public.padel_player_access a where a.id='main';
 if v_hash is null or p_code is null or extensions.crypt(p_code,v_hash)<>v_hash
 then raise exception 'Forkert spillerkode' using errcode='42501'; end if;
 if p_score_a is null or p_score_b is null or p_score_a<0 or p_score_b<0
 or p_score_a>99 or p_score_b>99 or p_score_a=p_score_b
 then raise exception 'Indtast to forskellige heltal mellem 0 og 99'; end if;
 select t.data into v_data from public.padel_v17_season t where t.id='main' for update;
 if v_data is null or v_data->>'status'<>'generated' then raise exception 'Ingen aktiv testspilleaften'; end if;
 v_round_index:=jsonb_array_length(v_data->'rounds')-1;
 if v_round_index<0 then raise exception 'Ingen runde'; end if;
 v_round:=v_data->'rounds'->v_round_index;
 v_round_number:=coalesce((v_round->>'roundNumber')::integer,v_round_index+1);
 for v_match in select value from jsonb_array_elements(v_round->'matches') loop
  if v_match->>'id'=p_match_id then
   if coalesce((v_match->>'saved')::boolean,false) then raise exception 'Resultatet er allerede gemt'; end if;
   v_found:=true;v_count:=v_count+1;
   v_match:=v_match||jsonb_build_object('scoreA',p_score_a,'scoreB',p_score_b,'saved',true,'applied',true);
  end if;
  v_new_matches:=v_new_matches||jsonb_build_array(v_match);
 end loop;
 if not v_found or v_count<>1 then raise exception 'Ukendt kamp i aktuel runde'; end if;
 select m.value into v_match from jsonb_array_elements(v_new_matches) m
 where m.value->>'id'=p_match_id;
 for v_player in select value from jsonb_array_elements(v_data->'squad') loop
  v_id:=v_player->>'id';
  if v_match->'teamA' ? v_id then
   v_for:=p_score_a;v_against:=p_score_b;v_member_count:=v_member_count+1;
  elsif v_match->'teamB' ? v_id then
   v_for:=p_score_b;v_against:=p_score_a;v_member_count:=v_member_count+1;
  else v_updated:=v_updated||jsonb_build_array(v_player);continue; end if;
  v_win:=v_for>v_against;
  v_player:=jsonb_set(v_player,array['ratingPoints']::text[],
   to_jsonb(coalesce((v_player->>'ratingPoints')::integer,500)+case when v_win then 50 else -50 end));
  v_player:=jsonb_set(v_player,array['games']::text[],to_jsonb(coalesce((v_player->>'games')::integer,0)+1));
  if v_win then
   v_player:=jsonb_set(v_player,array['wins']::text[],to_jsonb(coalesce((v_player->>'wins')::integer,0)+1));
  else
   v_player:=jsonb_set(v_player,array['losses']::text[],to_jsonb(coalesce((v_player->>'losses')::integer,0)+1));
  end if;
  v_player:=jsonb_set(v_player,array['matchPointsFor']::text[],
   to_jsonb(coalesce((v_player->>'matchPointsFor')::integer,0)+v_for));
  v_player:=jsonb_set(v_player,array['matchPointsAgainst']::text[],
   to_jsonb(coalesce((v_player->>'matchPointsAgainst')::integer,0)+v_against));
  v_result:=jsonb_build_object('tournamentId','v17-season','round',v_round_number,
   'matchId',p_match_id,'scoreFor',v_for,'scoreAgainst',v_against,'won',v_win);
  v_player:=jsonb_set(v_player,array['results']::text[],
   coalesce(v_player->'results','[]'::jsonb)||jsonb_build_array(v_result));
  v_updated:=v_updated||jsonb_build_array(v_player);
 end loop;
 if v_member_count<>4 then raise exception 'Kampen har ikke fire gyldige spillere'; end if;
 v_round:=jsonb_set(v_round,array['matches']::text[],v_new_matches);
 v_data:=jsonb_set(v_data,array['rounds',v_round_index::text]::text[],v_round);
 v_data:=jsonb_set(v_data,array['squad']::text[],v_updated);
 update public.padel_v17_season t set data=v_data,version=t.version+1,
 updated_at=now() where t.id='main';
 return v_data;
end;
$$;
create or replace function public.padel_v17_admin_finish()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; v_round jsonb; v_matches integer:=0; v_expected integer;
 v_archive_id bigint; v_final jsonb;
begin
 if auth.uid() is null or not exists(
  select 1 from public.padel_admins where user_id=auth.uid()
 ) then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 select t.data into v from public.padel_v17_season t
 where t.id='main' for update;
 if v is null or v->>'status'<>'generated' then
  raise exception 'Ingen aktiv testspilleaften at afslutte';
 end if;
 if jsonb_array_length(coalesce(v->'rounds','[]'::jsonb))<>
    coalesce((v->>'totalRounds')::integer,0) then
  raise exception 'Alle planlagte runder skal vaere gennemfoert';
 end if;
 for v_round in select value from jsonb_array_elements(v->'rounds') loop
  v_expected:=coalesce(jsonb_array_length(v_round->'matches'),0);
  if v_expected=0 then raise exception 'En runde har ingen kampe'; end if;
  if exists(select 1 from jsonb_array_elements(v_round->'matches') as m(item)
   where not coalesce((m.item->>'saved')::boolean,false)
      or not coalesce((m.item->>'applied')::boolean,false)) then
   raise exception 'Alle resultater skal vaere gemt og beregnet';
  end if;
  v_matches:=v_matches+v_expected;
 end loop;
 v_final:=jsonb_set(v,array['status']::text[],to_jsonb('finished'::text));
 v_final:=jsonb_set(v_final,array['finishedAt']::text[],to_jsonb(now()));
 insert into public.padel_v17_archive(data) values(v_final)
 returning archive_id into v_archive_id;
 v_final:=jsonb_set(v_final,array['archiveId']::text[],to_jsonb(v_archive_id));
 update public.padel_v17_archive a set data=v_final where a.archive_id=v_archive_id;
 update public.padel_v17_season t set data=v_final,
  version=t.version+1,updated_at=now() where t.id='main';
 return jsonb_build_object('archiveId',v_archive_id,'status','finished',
  'rounds',jsonb_array_length(v->'rounds'),'matches',v_matches,
  'finishedAt',v_final->'finishedAt');
end;
$$;
create or replace function public.padel_v17_admin_archives()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(
  select 1 from public.padel_admins where user_id=auth.uid()
 ) then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'archiveId',a.archive_id,'archivedAt',a.archived_at,
  'data',a.data) order by a.archive_id desc)
 from public.padel_v17_archive a),'[]'::jsonb);
end;
$$;
revoke all on function public.padel_v17_admin_first_round() from public,anon; grant execute on function public.padel_v17_admin_first_round() to authenticated;
revoke all on function public.padel_v17_admin_next_round() from public,anon; grant execute on function public.padel_v17_admin_next_round() to authenticated;
revoke all on function public.padel_v17_admin_finish() from public,anon; grant execute on function public.padel_v17_admin_finish() to authenticated;
revoke all on function public.padel_v17_admin_archives() from public,anon; grant execute on function public.padel_v17_admin_archives() to authenticated;
revoke all on function public.padel_v17_player_get(text) from public,anon; grant execute on function public.padel_v17_player_get(text) to anon,authenticated;
revoke all on function public.padel_v17_player_score(text,text,integer,integer) from public,anon; grant execute on function public.padel_v17_player_score(text,text,integer,integer) to anon,authenticated;
commit;

-- Fase 8: naeste runde i isoleret test. Koer efter SQL 07.
-- Udskifter kun spillerens test-resultatfunktion og tilfoejer admin-runde-funktion.
begin;
create or replace function public.padel_admin_test_next_round()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; v_round jsonb; v_players jsonb; v_sorted jsonb; v_matches jsonb:='[]'::jsonb; v_used text[]:='{}'; v_arr jsonb; v_ids text[]; v_n integer; v_r integer; i integer; j integer; k integer; a text; b text; c text; d text; temp text; v_score integer; best_score integer; best_j integer; v_candidate text[]; v_key text;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 select data into v from public.padel_match_test where id='sandbox' for update;
 if v is null or jsonb_array_length(coalesce(v->'rounds','[]'::jsonb))=0 then raise exception 'Opret spilleaften foerst'; end if;
 v_r:=jsonb_array_length(v->'rounds');
 if v_r>=5 then raise exception 'Testen er begraenset til 5 runder'; end if;
 v_round:=v->'rounds'->(v_r-1);
 if exists(select 1 from jsonb_array_elements(v_round->'matches') m where coalesce((m->>'saved')::boolean,false)=false) then
  raise exception 'Alle resultater i den aktuelle runde skal gemmes foerst';
 end if;
 v_n:=jsonb_array_length(v->'tonightIds');
 if v_n not in (4,8) then raise exception 'Ugyldigt deltagerantal'; end if;
 -- Find tidligere makkerpar paa tvaers af alle runder.
 for v_round in select value from jsonb_array_elements(v->'rounds') loop
  for v_arr in select value from jsonb_array_elements(v_round->'matches') loop
   for j in 0..1 loop
    if j=0 then a:=v_arr->'teamA'->>0;b:=v_arr->'teamA'->>1;
    else a:=v_arr->'teamB'->>0;b:=v_arr->'teamB'->>1;end if;
    v_used:=array_append(v_used,least(a,b)||'|'||greatest(a,b));
   end loop;
  end loop;
 end loop;
 -- Sortering efter rating, dernaest stabilt efter spiller-id.
 select jsonb_agg(p order by (p->>'ratingPoints')::integer desc,p->>'id') into v_sorted
 from jsonb_array_elements(v->'squad') p where p->>'id' in (select jsonb_array_elements_text(v->'tonightIds'));
 if jsonb_array_length(v_sorted)<>v_n then raise exception 'En eller flere deltagere mangler'; end if;
 v_ids:=array(select p->>'id' from jsonb_array_elements(v_sorted) p);
 -- Kun byt spillere med PRAECIS samme rating; find forbedringer som undgaar gentagne makkere.
 for i in 1..v_n loop
  for j in i+1..v_n loop
   if (v_sorted->(i-1)->>'ratingPoints')::integer=(v_sorted->(j-1)->>'ratingPoints')::integer then
    -- Rating-sorteringen er grundlaget; bytter inden for ligestillede grupper.
    v_candidate:=v_ids;temp:=v_candidate[i];v_candidate[i]:=v_candidate[j];v_candidate[j]:=temp;
    v_score:=0;best_score:=0;
    for k in 0..(v_n/4)-1 loop
     a:=v_ids[k*4+1];b:=v_ids[k*4+3];c:=v_ids[k*4+2];d:=v_ids[k*4+4];
     if least(a,b)||'|'||greatest(a,b)=any(v_used) then best_score:=best_score+1;end if;
     if least(c,d)||'|'||greatest(c,d)=any(v_used) then best_score:=best_score+1;end if;
     a:=v_candidate[k*4+1];b:=v_candidate[k*4+3];c:=v_candidate[k*4+2];d:=v_candidate[k*4+4];
     if least(a,b)||'|'||greatest(a,b)=any(v_used) then v_score:=v_score+1;end if;
     if least(c,d)||'|'||greatest(c,d)=any(v_used) then v_score:=v_score+1;end if;
    end loop;
    if v_score<best_score then v_ids:=v_candidate;end if;
   end if;
  end loop;
 end loop;
 for i in 0..(v_n/4)-1 loop
  v_matches:=v_matches||jsonb_build_array(jsonb_build_object(
   'id','test-r'||(v_r+1)||'-b1'||i,'court',i,'round',v_r+1,'tournamentId','test-isolated',
   'teamA',jsonb_build_array(v_ids[i*4+1],v_ids[i*4+3]),
   'teamB',jsonb_build_array(v_ids[i*4+2],v_ids[i*4+4]),
   'saved',false,'applied',false
  ));
 end loop;
 v:=jsonb_set(v,ARRAY['rounds']::text[],v->'rounds'||jsonb_build_array(jsonb_build_object('roundNumber',v_r+1,'matches',v_matches)));
 v:=jsonb_set(v,ARRAY['currentRound']::text[],to_jsonb(v_r+1));
 update public.padel_match_test set data=v,version=version+1,updated_at=now() where id='sandbox';
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
 if p_match_id is null or p_match_id !~ '^test-r[0-9]+-b1[01]
 select data into v from public.padel_match_test where id='sandbox' for update;
 if v is null then raise exception 'Testturnering mangler'; end if;
 players:=v->'squad';
 for i in 0..jsonb_array_length(v->'rounds'->(jsonb_array_length(v->'rounds')-1)->'matches')-1 loop
  m:=v->'rounds'->(jsonb_array_length(v->'rounds')-1)->'matches'->i;
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
   v:=jsonb_set(v,ARRAY['rounds',(jsonb_array_length(v->'rounds')-1)::text,'matches',i::text],updated_match);
   v:=jsonb_set(v,ARRAY['squad']::text[],players);
   update public.padel_match_test set data=v,version=version+1,updated_at=now() where id='sandbox';
   return v;
  end if;
 end loop;
 raise exception 'Ukendt testkamp';
end;
$$;
 and p_match_id not in ('test-b10','test-b11') then raise exception 'Ukendt testkamp'; end if;
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

revoke all on function public.padel_admin_test_next_round() from public;
grant execute on function public.padel_admin_test_next_round() to authenticated;
revoke all on function public.padel_player_test_score(text,text,integer,integer) from public;
grant execute on function public.padel_player_test_score(text,text,integer,integer) to anon,authenticated;
commit;

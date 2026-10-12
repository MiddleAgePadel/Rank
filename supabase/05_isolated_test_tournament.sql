-- Isoleret testmiljoe. Berorer IKKE public.padel_state.
begin;
create table if not exists public.padel_match_test (
 id text primary key,
 data jsonb not null,
 version bigint not null default 1,
 updated_at timestamptz not null default now()
);
alter table public.padel_match_test enable row level security;
revoke all on public.padel_match_test from anon,authenticated;
create or replace function public.padel_admin_test_reset()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_players jsonb; v_matches jsonb; v_state jsonb; i integer;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 v_players:='[]'::jsonb;
 for i in 1..8 loop
  v_players:=v_players||jsonb_build_array(jsonb_build_object('id','test-'||i,'name','Testspiller '||i,'ratingPoints',500,'games',0,'wins',0,'losses',0,'matchPointsFor',0,'matchPointsAgainst',0,'results','[]'::jsonb));
 end loop;
 v_matches:=jsonb_build_array(
  jsonb_build_object('id','test-b10','court',0,'round',1,'tournamentId','test-isolated','teamA',jsonb_build_array('test-1','test-2'),'teamB',jsonb_build_array('test-3','test-4'),'saved',false,'applied',false),
  jsonb_build_object('id','test-b11','court',1,'round',1,'tournamentId','test-isolated','teamA',jsonb_build_array('test-5','test-6'),'teamB',jsonb_build_array('test-7','test-8'),'saved',false,'applied',false)
 );
 v_state:=jsonb_build_object('squad',v_players,'rounds',jsonb_build_array(jsonb_build_object('roundNumber',1,'matches',v_matches)),'currentRound',1,'tournamentId','test-isolated');
 insert into public.padel_match_test(id,data,version) values('sandbox',v_state,1)
 on conflict(id) do update set data=excluded.data,version=public.padel_match_test.version+1,updated_at=now();
 return v_state;
end;
$$;
create or replace function public.padel_admin_test_get()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 select data into v from public.padel_match_test where id='sandbox';
 return v;
end;
$$;
create or replace function public.padel_admin_test_score(p_match_id text,p_score_a integer,p_score_b integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; m jsonb; players jsonb; p jsonb; i integer; j integer; k integer; pid text; delta integer; score_for integer; score_against integer; won boolean; updated_match jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 if p_score_a is null or p_score_b is null or p_score_a<0 or p_score_b<0 or p_score_a>99 or p_score_b>99 or p_score_a=p_score_b then
  raise exception 'Ugyldigt resultat';
 end if;
 select data into v from public.padel_match_test where id='sandbox' for update;
 if v is null then raise exception 'Opret testturnering foerst'; end if;
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
    for k in 0..jsonb_array_length(players)-1 loop
     if players->k->>'id'=pid then
      p:=players->k;
      p:=jsonb_set(p,'{ratingPoints}',to_jsonb((p->>'ratingPoints')::integer+delta));
      p:=jsonb_set(p,'{games}',to_jsonb((p->>'games')::integer+1));
      if won then
       p:=jsonb_set(p,ARRAY['wins']::text[],to_jsonb((p->>'wins')::integer+1));
      else
       p:=jsonb_set(p,ARRAY['losses']::text[],to_jsonb((p->>'losses')::integer+1));
      end if;
      p:=jsonb_set(p,'{matchPointsFor}',to_jsonb((p->>'matchPointsFor')::integer+score_for));
      p:=jsonb_set(p,'{matchPointsAgainst}',to_jsonb((p->>'matchPointsAgainst')::integer+score_against));
      p:=jsonb_set(p,'{results}',p->'results'||jsonb_build_array(jsonb_build_object('matchId',p_match_id,'ratingChange',delta,'scoreFor',score_for,'scoreAgainst',score_against)));
      players:=jsonb_set(players,array[k::text],p);
      exit;
     end if;
    end loop;
   end loop;
   updated_match:=m||jsonb_build_object('scoreA',p_score_a,'scoreB',p_score_b,'saved',true,'applied',true);
   v:=jsonb_set(v,array['rounds','0','matches',i::text],updated_match);
   v:=jsonb_set(v,'{squad}',players);
   update public.padel_match_test set data=v,version=version+1,updated_at=now() where id='sandbox';
   return v;
  end if;
 end loop;
 raise exception 'Ukendt testkamp';
end;
$$;
revoke all on function public.padel_admin_test_reset() from public;
revoke all on function public.padel_admin_test_get() from public;
revoke all on function public.padel_admin_test_score(text,integer,integer) from public;
grant execute on function public.padel_admin_test_reset() to authenticated;
grant execute on function public.padel_admin_test_get() to authenticated;
grant execute on function public.padel_admin_test_score(text,integer,integer) to authenticated;
commit;
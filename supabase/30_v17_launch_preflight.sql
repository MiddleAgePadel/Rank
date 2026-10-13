-- SQL 30: Read-only launch checklist for the new season.
-- Does not create rounds or change any ratings, fixtures, or archives.
begin;
create or replace function public.padel_v17_admin_preflight()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; n integer; bad_rating integer; duplicate_ids integer; old_rounds integer;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 select data into v from public.padel_v17_season where id='main';
 if v is null then raise exception 'Den nye saeson mangler'; end if;
 select count(*) into n from jsonb_array_elements(coalesce(v->'squad','[]'::jsonb));
 select count(*) into bad_rating from jsonb_array_elements(coalesce(v->'squad','[]'::jsonb)) p
 where coalesce((p->>'ratingPoints')::integer,-1)<>500;
 select count(*) into duplicate_ids from (select p->>'id' id from jsonb_array_elements(coalesce(v->'squad','[]'::jsonb)) p group by p->>'id' having count(*)>1) x;
 old_rounds:=jsonb_array_length(coalesce(v->'rounds','[]'::jsonb));
 return jsonb_build_object('ready',n>0 and bad_rating=0 and duplicate_ids=0 and old_rounds=0 and v->>'status' in ('ready','draft') and v->>'matchmaking'='v17',
 'players',n,'ratingsNot500',bad_rating,'duplicateIds',duplicate_ids,'roundsAlreadyCreated',old_rounds,
 'status',v->>'status','matchmaking',v->>'matchmaking','selectedPlayers',jsonb_array_length(coalesce(v->'tonightIds','[]'::jsonb)),
 'seasonStart',v->>'seasonStart');
end $$;
revoke all on function public.padel_v17_admin_preflight() from public,anon;
grant execute on function public.padel_v17_admin_preflight() to authenticated;
commit;

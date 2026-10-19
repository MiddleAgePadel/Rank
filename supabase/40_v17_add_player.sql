-- SQL 40: Add a new player to the v17 season roster without touching games or rankings.
begin;
create or replace function public.padel_v17_admin_add_player(p_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; n text; new_player jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 n:=btrim(coalesce(p_name,''));
 if length(n)<2 or length(n)>100 then
  raise exception 'Spillernavn skal vaere mellem 2 og 100 tegn';
 end if;
 select data into v from public.padel_v17_season where id='main' for update;
 if v is null then raise exception 'Saeson mangler'; end if;
 if exists(select 1 from jsonb_array_elements(coalesce(v->'squad','[]'::jsonb)) p
           where lower(btrim(p->>'name'))=lower(n)) then
  raise exception 'En spiller med dette navn findes allerede';
 end if;
 new_player:=jsonb_build_object(
  'id',pg_catalog.gen_random_uuid()::text,'name',n,
  'ratingPoints',500,'results','[]'::jsonb,
  'wins',0,'losses',0,'games',0
 );
 v:=jsonb_set(v,'{squad}',coalesce(v->'squad','[]'::jsonb)||jsonb_build_array(new_player),true);
 update public.padel_v17_season set data=v,version=version+1,updated_at=now() where id='main';
 return v;
end;
$$;
revoke all on function public.padel_v17_admin_add_player(text) from public,anon;
grant execute on function public.padel_v17_admin_add_player(text) to authenticated;
commit;

-- SQL 27: Admin-only fresh-season read and roster selection.
-- Isolated from old production and realistic test. Run after SQL 25 and 26.
begin;
create or replace function public.padel_v17_admin_get()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 select data into v from public.padel_v17_season where id='main';
 if v is null then raise exception 'Ny turnering ikke initialiseret. Koer SQL 26'; end if;
 return v;
end $$;
create or replace function public.padel_v17_admin_prepare(
 p_player_ids text[],p_reserve_ids text[],p_total_rounds integer default 5
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; v_roster_ids text[]; v_id text; v_active integer;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 if p_total_rounds<>5 then raise exception 'Der skal vaere 5 runder'; end if;
 v_active:=coalesce(cardinality(p_player_ids),0);
 if v_active not in (4,8) then raise exception 'Vaelg 4 eller 8 deltagere'; end if;
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
revoke all on function public.padel_v17_admin_get() from public,anon;
revoke all on function public.padel_v17_admin_prepare(text[],text[],integer) from public,anon;
grant execute on function public.padel_v17_admin_get() to authenticated;
grant execute on function public.padel_v17_admin_prepare(text[],text[],integer) to authenticated;
commit;

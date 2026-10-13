-- SQL 29: Start another evening after the previous one has been archived.
-- Preserve current ratings and player statistics, reset only evening fixtures.
-- No effect on old production or realistic test tables.
begin;
create or replace function public.padel_v17_admin_new_evening()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 select data into v from public.padel_v17_season where id='main' for update;
 if v is null then raise exception 'Ny saeson er ikke oprettet'; end if;
 if v->>'status'<>'finished' then
  raise exception 'Afslut og arkiver den aktuelle aften foerst';
 end if;
 v:=jsonb_set(v,'{status}',to_jsonb('ready'::text),true);
 v:=jsonb_set(v,'{rounds}','[]'::jsonb,true);
 v:=jsonb_set(v,'{tonightIds}','[]'::jsonb,true);
 v:=jsonb_set(v,'{reserveIds}','[]'::jsonb,true);
 v:=jsonb_set(v,'{currentRound}',to_jsonb(0),true);
 v:=v-'finishedAt'-'archiveId';
 update public.padel_v17_season set data=v,version=version+1,updated_at=now() where id='main';
 return v;
end $$;
revoke all on function public.padel_v17_admin_new_evening() from public,anon;
grant execute on function public.padel_v17_admin_new_evening() to authenticated;
commit;

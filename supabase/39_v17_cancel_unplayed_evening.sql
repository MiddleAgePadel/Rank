-- SQL 39: Cancel an unplayed v17 evening safely.
-- Preserves all players, ratings, results and archives.
begin;
create or replace function public.padel_v17_admin_cancel_unplayed()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; r jsonb; m jsonb; v_evening text;
begin
 if auth.uid() is null or not exists
  (select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 select data into v from public.padel_v17_season where id='main' for update;
 if v is null then raise exception 'Saeson mangler'; end if;
 if v->>'status' not in ('draft','generated') then
  raise exception 'Kun en planlagt eller startet spilleaften uden resultater kan aflyses';
 end if;
 for r in select value from jsonb_array_elements(coalesce(v->'rounds','[]'::jsonb)) loop
  for m in select value from jsonb_array_elements(coalesce(r->'matches','[]'::jsonb)) loop
   if coalesce((m->>'saved')::boolean,false) or coalesce((m->>'applied')::boolean,false)
     or m ? 'scoreA' or m ? 'scoreB' then
    raise exception 'Der findes allerede kampresultater. Aflysning er blokeret for at beskytte point og historik';
   end if;
  end loop;
 end loop;
 if jsonb_array_length(coalesce(v->'rounds','[]'::jsonb))>1 then
  raise exception 'Flere runder findes allerede. Aflysning er blokeret';
 end if;
 v:=jsonb_set(v,'{status}','"ready"'::jsonb,true);
 v:=jsonb_set(v,'{rounds}','[]'::jsonb,true);
 v:=jsonb_set(v,'{tonightIds}','[]'::jsonb,true);
 v:=jsonb_set(v,'{reserveIds}','[]'::jsonb,true);
 v:=jsonb_set(v,'{currentRound}','0'::jsonb,true);
 v:=v-'finishedAt'-'archiveId';
 v:=jsonb_set(v,'{eveningId}',to_jsonb(pg_catalog.gen_random_uuid()::text),true);
 update public.padel_v17_season set data=v,version=version+1,updated_at=now() where id='main';
 return v;
end;
$$;
revoke all on function public.padel_v17_admin_cancel_unplayed() from public,anon;
grant execute on function public.padel_v17_admin_cancel_unplayed() to authenticated;
commit;

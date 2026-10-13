-- SQL 36: Restore the verified clean v17 launch snapshot after the test.
-- ONLY public.padel_v17_season and the v17 test archive are affected.
-- The legacy padel_state and realistic sandbox are never touched.
begin;
do $$
declare v_backup jsonb; v_current jsonb; v_count integer;
begin
 select data into v_backup from public.padel_v17_pretest_backup
 where backup_id='launch-2026-10-19';
 if v_backup is null then raise exception 'Verified launch backup missing; no changes made'; end if;
 if v_backup->>'status'<>'ready'
   or jsonb_array_length(coalesce(v_backup->'squad','[]'::jsonb))<>43
   or (v_backup->>'totalRounds')::integer<>4
   or jsonb_array_length(coalesce(v_backup->'rounds','[]'::jsonb))<>0
   or jsonb_array_length(coalesce(v_backup->'tonightIds','[]'::jsonb))<>0
   or exists(select 1 from jsonb_array_elements(v_backup->'squad') p
      where coalesce((p->>'ratingPoints')::integer,-1)<>500
         or jsonb_array_length(coalesce(p->'results','[]'::jsonb))<>0)
 then raise exception 'Backup is not the expected clean launch state; no changes made'; end if;
 select data into v_current from public.padel_v17_season where id='main' for update;
 if v_current is null or v_current->>'status'<>'finished'
   or jsonb_array_length(coalesce(v_current->'rounds','[]'::jsonb))<>4
 then raise exception 'Expected finished four-round test not found; no changes made'; end if;
 select count(*) into v_count from public.padel_v17_archive;
 if v_count<>1 then raise exception 'Expected exactly one test archive, found %; no changes made',v_count; end if;
 if not exists (select 1 from public.padel_v17_archive a
    where a.archive_id=(v_current->>'archiveId')::bigint)
 then raise exception 'Current finished test does not match archived record; no changes made'; end if;
 update public.padel_v17_season
 set data=v_backup,version=version+1,updated_at=now() where id='main';
 delete from public.padel_v17_archive
 where archive_id=(v_current->>'archiveId')::bigint;
end $$;
commit;
select jsonb_array_length(data->'squad') as players,
 (select count(*) from jsonb_array_elements(data->'squad') p
   where (p->>'ratingPoints')::integer=500) as players_at_500,
 data->>'status' as status,
 (data->>'totalRounds')::integer as rounds,
 jsonb_array_length(data->'rounds') as created_rounds,
 (select count(*) from public.padel_v17_archive) as archived_evenings
from public.padel_v17_season where id='main';

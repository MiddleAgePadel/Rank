-- SQL 17: Arkivering af realistisk testspilleaften.
-- Laeser og opdaterer KUN padel_realistic_test og padel_realistic_archive.
begin;
create table if not exists public.padel_realistic_archive(
 archive_id bigint generated always as identity primary key,
 archived_at timestamptz not null default now(),
 data jsonb not null
);
alter table public.padel_realistic_archive enable row level security;
revoke all on table public.padel_realistic_archive from public,anon,authenticated;
revoke all on sequence public.padel_realistic_archive_archive_id_seq from public,anon,authenticated;

create or replace function public.padel_admin_realistic_finish()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb; v_round jsonb; v_matches integer:=0; v_expected integer;
 v_archive_id bigint; v_final jsonb;
begin
 if auth.uid() is null or not exists(
  select 1 from public.padel_admins where user_id=auth.uid()
 ) then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 select t.data into v from public.padel_realistic_test t
 where t.id='sandbox' for update;
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
 insert into public.padel_realistic_archive(data) values(v_final)
 returning archive_id into v_archive_id;
 v_final:=jsonb_set(v_final,array['archiveId']::text[],to_jsonb(v_archive_id));
 update public.padel_realistic_archive a set data=v_final where a.archive_id=v_archive_id;
 update public.padel_realistic_test t set data=v_final,
  version=t.version+1,updated_at=now() where t.id='sandbox';
 return jsonb_build_object('archiveId',v_archive_id,'status','finished',
  'rounds',jsonb_array_length(v->'rounds'),'matches',v_matches,
  'finishedAt',v_final->'finishedAt');
end;
$$;

create or replace function public.padel_admin_realistic_archives()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(
  select 1 from public.padel_admins where user_id=auth.uid()
 ) then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
  'archiveId',a.archive_id,'archivedAt',a.archived_at,
  'data',a.data) order by a.archive_id desc)
 from public.padel_realistic_archive a),'[]'::jsonb);
end;
$$;
revoke all on function public.padel_admin_realistic_finish() from public;
revoke all on function public.padel_admin_realistic_archives() from public;
grant execute on function public.padel_admin_realistic_finish() to authenticated;
grant execute on function public.padel_admin_realistic_archives() to authenticated;
commit;

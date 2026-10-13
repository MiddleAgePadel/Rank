-- SQL 19: Bevar hver spillers seneste arkiverede rating, ogsaa efter fravaer.
-- Laeser arkivhistorik og rigtig spillerliste. Skriver kun nyt isoleret udkast.
-- Aendrer hverken eksisterende arkiver eller public.padel_state.
begin;

create or replace function public.padel_admin_realistic_players()
returns jsonb language plpgsql security definer set search_path='' as $$
declare s jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid())
 then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 select t.data into s from public.padel_state t where t.id='main';
 if s is null then raise exception 'Ingen spillerliste i Supabase'; end if;
 return coalesce((
  select jsonb_agg(jsonb_build_object(
   'id',base.item->>'id',
   'name',base.item->>'name',
   'ratingPoints',coalesce(arch.item->'ratingPoints',base.item->'ratingPoints',to_jsonb(500))
  ) order by lower(base.item->>'name'))
  from jsonb_array_elements(s->'squad') as base(item)
  left join lateral (
   select p.item
   from public.padel_realistic_archive a
   cross join lateral jsonb_array_elements(coalesce(a.data->'squad','[]'::jsonb)) as p(item)
   where p.item->>'id'=base.item->>'id'
     and exists (
      select 1 from jsonb_array_elements_text(coalesce(a.data->'tonightIds','[]'::jsonb)) as t(id)
      where t.id=base.item->>'id'
     )
   order by a.archive_id desc
   limit 1
  ) arch on true
 ),'[]'::jsonb);
end;
$$;

create or replace function public.padel_admin_realistic_create(
 p_player_ids text[],p_reserve_ids text[],p_total_rounds integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare s jsonb; current_data jsonb; latest_archive_id bigint;
 v_player jsonb; v_arch_player jsonb; selected jsonb:='[]'::jsonb;
 ids text[]; n integer; i integer; v_draft jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid())
 then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 n:=coalesce(array_length(p_player_ids,1),0);
 if n<4 or n>40 or n%4<>0 then
  raise exception 'Antal deltagere skal vaere deleligt med 4 (4-40)';
 end if;
 if p_total_rounds is null or p_total_rounds<1 or p_total_rounds>5 then
  raise exception 'Testen understotter 1-5 runder';
 end if;
 ids:=coalesce(p_player_ids,array[]::text[])||coalesce(p_reserve_ids,array[]::text[]);
 if exists(select 1 from unnest(ids) as x(id) group by x.id having count(*)>1)
 then raise exception 'Samme spiller er valgt flere gange'; end if;
 select t.data into current_data from public.padel_realistic_test t
 where t.id='sandbox' for update;
 if current_data is not null and current_data->>'status' not in ('finished','draft')
 then raise exception 'Afslut og arkiver den igangvaerende test foer du opretter en ny'; end if;
 if current_data is not null and current_data->>'status'='draft'
 and jsonb_array_length(coalesce(current_data->'rounds','[]'::jsonb))>0
 then raise exception 'Et udkast med kampe maa ikke overskrives'; end if;
 select ps.data into s from public.padel_state ps where ps.id='main';
 if s is null then raise exception 'Ingen rigtige spillere fundet'; end if;
 if exists(select 1 from unnest(ids) as x(id) where not exists (
  select 1 from jsonb_array_elements(s->'squad') as base(item)
  where base.item->>'id'=x.id
 )) then raise exception 'Ukendt spiller i valget'; end if;
 select max(a.archive_id) into latest_archive_id from public.padel_realistic_archive a;
 for i in 1..n loop
  select base.item into v_player
  from jsonb_array_elements(s->'squad') as base(item)
  where base.item->>'id'=p_player_ids[i];
  v_arch_player:=null;
  select p.item into v_arch_player
  from public.padel_realistic_archive a
  cross join lateral jsonb_array_elements(coalesce(a.data->'squad','[]'::jsonb)) as p(item)
  where p.item->>'id'=p_player_ids[i]
    and exists (
     select 1 from jsonb_array_elements_text(coalesce(a.data->'tonightIds','[]'::jsonb)) as t(id)
     where t.id=p_player_ids[i]
    )
  order by a.archive_id desc limit 1;
  if v_arch_player is not null then
   -- Bevar hele den seneste statistik; opdater kun navnet fra spillerlisten.
   v_player:=jsonb_set(v_arch_player,array['name']::text[],to_jsonb(v_player->>'name'));
  end if;
  selected:=selected||jsonb_build_array(v_player);
 end loop;
 v_draft:=jsonb_build_object('status','draft','squad',selected,
  'tonightIds',to_jsonb(p_player_ids),
  'reserveIds',to_jsonb(coalesce(p_reserve_ids,array[]::text[])),
  'totalRounds',p_total_rounds,'rounds','[]'::jsonb,
  'createdAt',now(),'source','real-player-names-isolated',
  'previousArchiveId',latest_archive_id);
 insert into public.padel_realistic_test(id,data,version,updated_at)
 values('sandbox',v_draft,1,now())
 on conflict(id) do update set data=excluded.data,
 version=public.padel_realistic_test.version+1,updated_at=now();
 return jsonb_build_object('status','draft','players',n,
  'reserves',coalesce(array_length(p_reserve_ids,1),0),
  'rounds',p_total_rounds,'previousArchiveId',latest_archive_id);
end;
$$;

revoke all on function public.padel_admin_realistic_players() from public;
revoke all on function public.padel_admin_realistic_create(text[],text[],integer) from public;
grant execute on function public.padel_admin_realistic_players() to authenticated;
grant execute on function public.padel_admin_realistic_create(text[],text[],integer) to authenticated;
commit;

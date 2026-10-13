-- SQL 12: Retter "column reference data is ambiguous" i administratorens isolerede testudkast.
-- Aendrer KUN funktionen. Ingen turneringer eller spillerdata nulstilles.
begin;
create or replace function public.padel_admin_realistic_create(
 p_player_ids text[],p_reserve_ids text[],p_total_rounds integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare s jsonb; p jsonb; selected jsonb:='[]'::jsonb; ids text[];
 n integer; i integer; v_draft jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 n:=coalesce(array_length(p_player_ids,1),0);
 if n<4 or n>40 or n%4<>0 then raise exception 'Antal deltagere skal vaere deleligt med 4 (4-40)'; end if;
 if p_total_rounds is null or p_total_rounds<1 or p_total_rounds>12 then
  raise exception 'Vaelg mellem 1 og 12 runder';
 end if;
 ids:=coalesce(p_player_ids,array[]::text[])||coalesce(p_reserve_ids,array[]::text[]);
 if exists(select 1 from unnest(ids) x group by x having count(*)>1) then
  raise exception 'Samme spiller er valgt flere gange';
 end if;
 select ps.data into s from public.padel_state as ps where ps.id='main';
 if s is null then raise exception 'Ingen rigtige spillere fundet'; end if;
 if exists(select 1 from unnest(ids) x where not exists (
  select 1 from jsonb_array_elements(s->'squad') p where p->>'id'=x
 )) then raise exception 'Ukendt spiller i valget'; end if;
 for i in 1..n loop
  select value into p from jsonb_array_elements(s->'squad') where value->>'id'=p_player_ids[i];
  selected:=selected||jsonb_build_array(p);
 end loop;
 -- Kun et isoleret planlaegningsudkast; ingen kampe genereres endnu.
 v_draft:=jsonb_build_object('status','draft','squad',selected,
   'tonightIds',to_jsonb(p_player_ids),'reserveIds',to_jsonb(coalesce(p_reserve_ids,array[]::text[])),
   'totalRounds',p_total_rounds,'rounds','[]'::jsonb,
   'createdAt',now(),'source','real-player-names-isolated');
 insert into public.padel_realistic_test(id,data,version,updated_at)
 values('sandbox',v_draft,1,now())
 on conflict(id) do update set data=excluded.data,
 version=public.padel_realistic_test.version+1,updated_at=now();
 return jsonb_build_object('status','draft','players',n,
   'reserves',coalesce(array_length(p_reserve_ids,1),0),'rounds',p_total_rounds);
end;
$$;

commit;

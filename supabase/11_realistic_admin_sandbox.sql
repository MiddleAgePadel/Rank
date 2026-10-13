-- SQL 11: Isoleret kopi af rigtige spillere til administrationstest.
-- Laeser kun fra padel_state. Skriver udelukkende til padel_realistic_test.
begin;
create table if not exists public.padel_realistic_test (
 id text primary key check(id='sandbox'),
 data jsonb not null,
 version bigint not null default 1,
 updated_at timestamptz not null default now()
);
alter table public.padel_realistic_test enable row level security;
revoke all on table public.padel_realistic_test from public,anon,authenticated;

create or replace function public.padel_admin_realistic_players()
returns jsonb language plpgsql security definer set search_path='' as $$
declare s jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 select data into s from public.padel_state where id='main';
 if s is null then raise exception 'Ingen spillerliste i Supabase'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',p->>'id','name',p->>'name','ratingPoints',p->'ratingPoints') order by lower(p->>'name'))
 from jsonb_array_elements(s->'squad') p),'[]'::jsonb);
end;
$$;

create or replace function public.padel_admin_realistic_create(
 p_player_ids text[],p_reserve_ids text[],p_total_rounds integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare s jsonb; p jsonb; selected jsonb:='[]'::jsonb; ids text[];
 n integer; i integer; data jsonb; old_version bigint;
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
 select data into s from public.padel_state where id='main';
 if s is null then raise exception 'Ingen rigtige spillere fundet'; end if;
 if exists(select 1 from unnest(ids) x where not exists (
  select 1 from jsonb_array_elements(s->'squad') p where p->>'id'=x
 )) then raise exception 'Ukendt spiller i valget'; end if;
 for i in 1..n loop
  select value into p from jsonb_array_elements(s->'squad') where value->>'id'=p_player_ids[i];
  selected:=selected||jsonb_build_array(p);
 end loop;
 -- Kun et isoleret planlaegningsudkast; ingen kampe genereres endnu.
 data:=jsonb_build_object('status','draft','squad',selected,
   'tonightIds',to_jsonb(p_player_ids),'reserveIds',to_jsonb(coalesce(p_reserve_ids,array[]::text[])),
   'totalRounds',p_total_rounds,'rounds','[]'::jsonb,
   'createdAt',now(),'source','real-player-names-isolated');
 insert into public.padel_realistic_test(id,data,version,updated_at)
 values('sandbox',data,1,now())
 on conflict(id) do update set data=excluded.data,
 version=public.padel_realistic_test.version+1,updated_at=now();
 return jsonb_build_object('status','draft','players',n,
   'reserves',coalesce(array_length(p_reserve_ids,1),0),'rounds',p_total_rounds);
end;
$$;

create or replace function public.padel_admin_realistic_get()
returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid()) then
  raise exception 'Administratoradgang kraeves' using errcode='42501';
 end if;
 select data into d from public.padel_realistic_test where id='sandbox';
 return d;
end;
$$;
revoke all on function public.padel_admin_realistic_players() from public;
revoke all on function public.padel_admin_realistic_create(text[],text[],integer) from public;
revoke all on function public.padel_admin_realistic_get() from public;
grant execute on function public.padel_admin_realistic_players() to authenticated;
grant execute on function public.padel_admin_realistic_create(text[],text[],integer) to authenticated;
grant execute on function public.padel_admin_realistic_get() to authenticated;
commit;

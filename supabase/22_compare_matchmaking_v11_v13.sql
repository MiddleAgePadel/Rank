-- SQL 22: Isoleret sammenligning af v11 og v13; kun laesning af kampdata.
begin;
create or replace function public.padel_test_v13_cost(p_ids text[],p_ratings jsonb,p_previous text[],p_earlier text[],p_opponents text[])
returns bigint language plpgsql immutable set search_path='' as $
declare i integer; n integer; a text; b text; key_pair text; gap integer; max_gap integer:=0; sum_gap integer:=0; repeats integer:=0; opp_repeats integer:=0;
begin
 n:=coalesce(array_length(p_ids,1),0);
 if n not in (4,8) then raise exception 'V13 kraever 4 eller 8 spillere'; end if;
 for i in 0..n/4-1 loop
  a:=p_ids[4*i+1];b:=p_ids[4*i+3];key_pair:=least(a,b)||'|'||greatest(a,b);
  if key_pair=any(p_previous) or key_pair=any(p_earlier) then repeats:=repeats+1;end if;
  a:=p_ids[4*i+2];b:=p_ids[4*i+4];key_pair:=least(a,b)||'|'||greatest(a,b);
  if key_pair=any(p_previous) or key_pair=any(p_earlier) then repeats:=repeats+1;end if;
  gap:=abs(coalesce((p_ratings->>p_ids[4*i+1])::integer,500)+coalesce((p_ratings->>p_ids[4*i+3])::integer,500)-
       coalesce((p_ratings->>p_ids[4*i+2])::integer,500)-coalesce((p_ratings->>p_ids[4*i+4])::integer,500));
  max_gap:=greatest(max_gap,gap);sum_gap:=sum_gap+gap;
  foreach key_pair in array array[
   least(p_ids[4*i+1],p_ids[4*i+2])||'|'||greatest(p_ids[4*i+1],p_ids[4*i+2]),
   least(p_ids[4*i+1],p_ids[4*i+4])||'|'||greatest(p_ids[4*i+1],p_ids[4*i+4]),
   least(p_ids[4*i+3],p_ids[4*i+2])||'|'||greatest(p_ids[4*i+3],p_ids[4*i+2]),
   least(p_ids[4*i+3],p_ids[4*i+4])||'|'||greatest(p_ids[4*i+3],p_ids[4*i+4])
  ] loop
   if key_pair=any(p_opponents) then opp_repeats:=opp_repeats+1;end if;
  end loop;
 end loop;
 -- Leksikografisk prioritet: nul gentagne makkere, lavest stoerste ubalance,
 -- derefter samlet ubalance, og til sidst modstandervariation.
 return repeats::bigint*1000000000+max_gap::bigint*1000000+sum_gap::bigint*1000+opp_repeats;
end;
$;
create or replace function public.padel_admin_compare_v11_v13()
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v jsonb; r jsonb; m jsonb; p jsonb; q jsonb;
 ids text[]:=array[]::text[]; original_ids text[]; trial text[];
 last_pairs text[]:=array[]::text[]; older_pairs text[]:=array[]::text[];
 opponents text[]:=array[]::text[]; ratings jsonb:='{}'::jsonb; names jsonb:='{}'::jsonb;
 v11_ids text[]:=array[]::text[]; best_ids text[]; candidate text[];
 best_cost bigint; cost bigint; step_cost bigint;
 n integer; round_count integer; i integer; j integer; k integer; seed integer; pass integer;
 swap text; pair_key text; a text; b text; result11 jsonb:='[]'::jsonb;
 result13 jsonb:='[]'::jsonb; arrangement text[];
 team_a integer; team_b integer; repeat_count integer; repeat11 integer:=0; repeat13 integer:=0;
 gap11 integer:=0; gap13 integer:=0; details jsonb; version_number integer;
begin
 if auth.uid() is null or not exists(select 1 from public.padel_admins where user_id=auth.uid())
 then raise exception 'Administratoradgang kraeves' using errcode='42501'; end if;
 select t.data into v from public.padel_realistic_test t where t.id='sandbox';
 if v is null then raise exception 'Ingen realistisk test fundet'; end if;
 round_count:=jsonb_array_length(coalesce(v->'rounds','[]'::jsonb));
 if round_count<2 then raise exception 'Generer mindst to runder for at sammenligne'; end if;
 n:=jsonb_array_length(coalesce(v->'tonightIds','[]'::jsonb));
 if n not in (4,8) then raise exception 'Sammenligning kraever 4 eller 8 deltagere'; end if;
 -- Brug den seneste rundes START-rating: slutrating minus +/- 50 fra denne rundes resultater.
 for p in select value from jsonb_array_elements(v->'squad') loop
  a:=p->>'id';
  team_a:=coalesce((p->>'ratingPoints')::integer,500);
  r:=v->'rounds'->(round_count-1);
  for m in select value from jsonb_array_elements(r->'matches') loop
   if coalesce((m->>'saved')::boolean,false) then
    if m->'teamA' ? a then
     team_a:=team_a-case when (m->>'scoreA')::integer>(m->>'scoreB')::integer then 50 else -50 end;
    elsif m->'teamB' ? a then
     team_a:=team_a-case when (m->>'scoreB')::integer>(m->>'scoreA')::integer then 50 else -50 end;
    end if;
   end if;
  end loop;
  ratings:=ratings||jsonb_build_object(a,team_a);
  names:=names||jsonb_build_object(a,p->>'name');
 end loop;
 -- Den faktiske v11-fordeling i seneste runde.
 r:=v->'rounds'->(round_count-1);
 for m in select value from jsonb_array_elements(r->'matches') loop
  v11_ids:=array_append(v11_ids,m->'teamA'->>0);
  v11_ids:=array_append(v11_ids,m->'teamB'->>0);
  v11_ids:=array_append(v11_ids,m->'teamA'->>1);
  v11_ids:=array_append(v11_ids,m->'teamB'->>1);
 end loop;
 if array_length(v11_ids,1)<>n then raise exception 'Ufuldstaendige kampe i sidste runde'; end if;
 -- Historik fra alle runder FOER seneste (samme tidspunkt som v11-genereringen).
 for i in 0..round_count-2 loop
  r:=v->'rounds'->i;
  for m in select value from jsonb_array_elements(r->'matches') loop
   a:=m->'teamA'->>0;b:=m->'teamA'->>1;
   pair_key:=least(a,b)||'|'||greatest(a,b);
   if i=round_count-2 then last_pairs:=array_append(last_pairs,pair_key);
   else older_pairs:=array_append(older_pairs,pair_key);end if;
   a:=m->'teamB'->>0;b:=m->'teamB'->>1;
   pair_key:=least(a,b)||'|'||greatest(a,b);
   if i=round_count-2 then last_pairs:=array_append(last_pairs,pair_key);
   else older_pairs:=array_append(older_pairs,pair_key);end if;
   for p in select value from jsonb_array_elements(m->'teamA') loop
    for q in select value from jsonb_array_elements(m->'teamB') loop
     a:=p#>>'{}';b:=q#>>'{}';
     opponents:=array_append(opponents,least(a,b)||'|'||greatest(a,b));
    end loop;
   end loop;
  end loop;
 end loop;
 -- Ens reference for begge: sorteret efter rating ved starten af runden.
 original_ids:=array(select x from unnest(v11_ids) as x order by (ratings->>x)::integer desc,x);
 -- Udtoemmende gennemsoegning af 4/8 spillere med symmetribegraensning.
 -- Ingen eksisterende kampe eller tabeller opdateres.
 select perm.arr into best_ids
 from (
  with recursive arrangements(arr,remaining) as (
   select array[]::text[],v11_ids
   union all
   select a.arr||a.remaining[pos.n],
          array_remove(a.remaining,a.remaining[pos.n])
   from arrangements a
   cross join lateral generate_subscripts(a.remaining,1) as pos(n)
   where cardinality(a.arr)<n
  )
  select arr from arrangements
  where cardinality(arr)=n
   and arr[1]<arr[3] and arr[2]<arr[4]
   and (n=4 or (arr[5]<arr[7] and arr[6]<arr[8] and arr[1]<arr[5]))
 ) perm
 order by public.padel_test_v13_cost(perm.arr,ratings,last_pairs,older_pairs,opponents),perm.arr::text
 limit 1;
 if best_ids is null then raise exception 'Ingen V13-fordeling fundet';end if;
 for version_number in 11..13 loop
  if version_number=12 then continue;end if;
  if version_number=11 then arrangement:=v11_ids;else arrangement:=best_ids;end if;
  details:='[]'::jsonb;
  repeat_count:=0;
  for k in 0..(n/4)-1 loop
   i:=k*4+1;
   team_a:=coalesce((ratings->>arrangement[i])::integer,500)+coalesce((ratings->>arrangement[i+2])::integer,500);
   team_b:=coalesce((ratings->>arrangement[i+1])::integer,500)+coalesce((ratings->>arrangement[i+3])::integer,500);
   a:=least(arrangement[i],arrangement[i+2])||'|'||greatest(arrangement[i],arrangement[i+2]);
   b:=least(arrangement[i+1],arrangement[i+3])||'|'||greatest(arrangement[i+1],arrangement[i+3]);
   if a=any(last_pairs) or a=any(older_pairs) then repeat_count:=repeat_count+1;end if;
   if b=any(last_pairs) or b=any(older_pairs) then repeat_count:=repeat_count+1;end if;
   details:=details||jsonb_build_array(jsonb_build_object(
    'court','B'||(10+k),
    'teamA',jsonb_build_array(names->>arrangement[i],names->>arrangement[i+2]),
    'teamB',jsonb_build_array(names->>arrangement[i+1],names->>arrangement[i+3]),
    'ratingA',team_a,'ratingB',team_b,'ratingGap',abs(team_a-team_b),
    'repeatedPartners',(case when a=any(last_pairs) or a=any(older_pairs) then 1 else 0 end)+
                       (case when b=any(last_pairs) or b=any(older_pairs) then 1 else 0 end)));
   if version_number=11 then gap11:=gap11+abs(team_a-team_b);
   else gap13:=gap13+abs(team_a-team_b);end if;
  end loop;
  if version_number=11 then result11:=details;repeat11:=repeat_count;
  else result13:=details;repeat13:=repeat_count;end if;
 end loop;
 return jsonb_build_object('round',round_count,'participants',n,
  'v11',jsonb_build_object('courts',result11,'totalRatingGap',gap11,'repeatedPartners',repeat11),
  'v12',jsonb_build_object('courts',result13,'totalRatingGap',gap13,'repeatedPartners',repeat13),
  'note','Sammenligning af senest genererede v11-runde mod v13-alternativ; ingen data aendret');
end;
$$;
revoke all on function public.padel_test_v13_cost(text[],jsonb,text[],text[],text[]) from public;
revoke all on function public.padel_admin_compare_v11_v13() from public;
grant execute on function public.padel_admin_compare_v11_v13() to authenticated;
commit;

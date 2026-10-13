-- SQL 21: Sammenlign den senest genererede v11-runde med v12.
-- KUN LAESNING: ingen update/insert/delete. Kræver SQL 20.
begin;
create or replace function public.padel_admin_compare_v11_v12()
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
 result12 jsonb:='[]'::jsonb; arrangement text[];
 team_a integer; team_b integer; repeat_count integer; repeat11 integer:=0; repeat12 integer:=0;
 gap11 integer:=0; gap12 integer:=0; details jsonb; version_number integer;
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
 -- Multistart-optimering, deterministisk, uden at aendre eksisterende v11-runde.
 best_ids:=v11_ids;
 best_cost:=public.padel_test_v12_cost(best_ids,original_ids,ratings,last_pairs,older_pairs,opponents);
 for seed in 0..n loop
  if seed=0 then trial:=v11_ids;
  else
   trial:=array(select original_ids[((gs.position+seed-2)%n)+1] from generate_series(1,n) as gs(position));
  end if;
  for pass in 1..100 loop
   step_cost:=public.padel_test_v12_cost(trial,original_ids,ratings,last_pairs,older_pairs,opponents);
   candidate:=trial;
   for i in 1..n-1 loop
    for j in i+1..n loop
     ids:=trial;swap:=ids[i];ids[i]:=ids[j];ids[j]:=swap;
     cost:=public.padel_test_v12_cost(ids,original_ids,ratings,last_pairs,older_pairs,opponents);
     if cost<step_cost then step_cost:=cost;candidate:=ids;end if;
    end loop;
   end loop;
   exit when candidate=trial;
   trial:=candidate;
  end loop;
  cost:=public.padel_test_v12_cost(trial,original_ids,ratings,last_pairs,older_pairs,opponents);
  if cost<best_cost then best_cost:=cost;best_ids:=trial;end if;
 end loop;
 for version_number in 11..12 loop
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
   else gap12:=gap12+abs(team_a-team_b);end if;
  end loop;
  if version_number=11 then result11:=details;repeat11:=repeat_count;
  else result12:=details;repeat12:=repeat_count;end if;
 end loop;
 return jsonb_build_object('round',round_count,'participants',n,
  'v11',jsonb_build_object('courts',result11,'totalRatingGap',gap11,'repeatedPartners',repeat11),
  'v12',jsonb_build_object('courts',result12,'totalRatingGap',gap12,'repeatedPartners',repeat12),
  'note','Sammenligning af senest genererede v11-runde mod v12-alternativ; ingen data aendret');
end;
$$;
revoke all on function public.padel_admin_compare_v11_v12() from public;
grant execute on function public.padel_admin_compare_v11_v12() to authenticated;
commit;

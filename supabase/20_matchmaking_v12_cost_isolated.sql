-- SQL 20: Matchmaking v12, ISOLERET omkostningsfunktion.
-- Installerer kun en ny funktion; aktiverer IKKE v12 i den igangvaerende turnering.
-- Skriver ikke til nogen tabeller.
begin;
create or replace function public.padel_test_v12_cost(
 p_ids text[],p_original text[],p_ratings jsonb,
 p_previous text[],p_earlier text[],p_opponents text[]
) returns bigint language plpgsql immutable set search_path='' as $$
declare n integer; i integer; j integer; a text; b text;
 ra integer; rb integer; rc integer; rd integer;
 gap integer; total bigint:=0; pair_key text; opponents text[];
begin
 n:=coalesce(array_length(p_ids,1),0);
 if n not in (4,8) then raise exception 'V12 understotter 4 eller 8 deltagere'; end if;
 if coalesce(array_length(p_original,1),0)<>n
 then raise exception 'Deltagerlisten er ufuldstaendig'; end if;
 if (select count(distinct x) from unnest(p_ids) x)<>n
 then raise exception 'Deltagerlisten indeholder dubletter'; end if;
 for i in 0..(n/4)-1 loop
  a:=p_ids[4*i+1];b:=p_ids[4*i+3];
  pair_key:=least(a,b)||'|'||greatest(a,b);
  if pair_key=any(p_previous) then total:=total+100000;
  elsif pair_key=any(p_earlier) then total:=total+40000; end if;
  a:=p_ids[4*i+2];b:=p_ids[4*i+4];
  pair_key:=least(a,b)||'|'||greatest(a,b);
  if pair_key=any(p_previous) then total:=total+100000;
  elsif pair_key=any(p_earlier) then total:=total+40000; end if;
  ra:=coalesce((p_ratings->>p_ids[4*i+1])::integer,500);
  rb:=coalesce((p_ratings->>p_ids[4*i+2])::integer,500);
  rc:=coalesce((p_ratings->>p_ids[4*i+3])::integer,500);
  rd:=coalesce((p_ratings->>p_ids[4*i+4])::integer,500);
  gap:=abs((ra+rc)-(rb+rd));
  -- Markant stoerre prioritet til jaevnbyrdige hold end v11.
  total:=total+20*gap+gap*gap/10;
  -- Undgaa meget ujaevne spillergrupper paa den enkelte bane.
  total:=total+(greatest(ra,rb,rc,rd)-least(ra,rb,rc,rd));
  -- Et modstanderpar kan moedes flere gange, men helst ikke unødigt.
  opponents:=array[
   least(p_ids[4*i+1],p_ids[4*i+2])||'|'||greatest(p_ids[4*i+1],p_ids[4*i+2]),
   least(p_ids[4*i+1],p_ids[4*i+4])||'|'||greatest(p_ids[4*i+1],p_ids[4*i+4]),
   least(p_ids[4*i+3],p_ids[4*i+2])||'|'||greatest(p_ids[4*i+3],p_ids[4*i+2]),
   least(p_ids[4*i+3],p_ids[4*i+4])||'|'||greatest(p_ids[4*i+3],p_ids[4*i+4])
  ];
  foreach pair_key in array opponents loop
   if pair_key=any(p_opponents) then total:=total+250; end if;
  end loop;
 end loop;
 -- Svag stabilitet i raekkefolgen, ikke et krav om at bevare den.
 for i in 1..n loop
  for j in 1..n loop
   if p_ids[i]=p_original[j] then
    total:=total+2*abs(i-j);
    exit;
   end if;
  end loop;
 end loop;
 return total;
end;
$$;
revoke all on function public.padel_test_v12_cost(text[],text[],jsonb,text[],text[],text[]) from public;
-- Funktionen bruges foreloebigt kun i SQL Editor, ikke via spilleradgangen.
commit;

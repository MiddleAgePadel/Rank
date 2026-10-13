# Matchmaking v14 – isoleret hel-aften-simulering

Status: Design og testkriterier. **Ikke aktiveret.**

## Dokumenteret udgangspunkt (spilleaften 3, v11)
| Runde | Samlet ratingforskel | Største baneforskel | Gentagne makkere | Gentagne modstandermøder |
|---|---:|---:|---:|---:|
| 1 | 300 | 250 | 0 | 0 |
| 2 | 100 | 100 | 0 | 2 |
| 3 | 200 | 200 | 0 | 3 |
| 4 | 500 | 400 | 0 | 5 |
| 5 | 700 | 700 | 0 | 6 |
| I alt | 1800 | 700 (maksimum) | 0 | 16 |

## Vigtigt om fair simulering
Et resultat fra en historisk kamp kan ikke uden videre overføres til en ny holdopstilling.
Derfor skal v14 beregne en **kontrafaktisk plan**, ikke påstå at kende
vinderne eller ratings efter endnu ikke spillede kampe.

To spor:
1. **Fast rating-scenarie**: brug rating ved aftenens start gennem alle fem runder.
   Sammenlign makkerrotation, modstandervariation og ratingbalance på et ensartet grundlag.
2. **Historisk rating-scenarie**: brug observeret rating ved starten af hver historisk runde,
   men mærk tydeligt at disse ratingforløb stammer fra de faktisk spillede v11-kampe.
   Dette er en følsomhedsanalyse, ikke en forudsigelse.

## Målfunktion (leksikografisk)
1. Minimér gentagne makkerpar over hele aftenen (helst nul).
2. Minimér den **største ratingforskel på en enkelt bane** på tværs af aftenen.
3. Minimér summen af absolutte ratingforskelle på alle baner.
4. Minimér gentagne modstandermøder.
5. Brug stabil deterministisk tie-breaker.

## Sikkerhed
- Læs kun fra `padel_realistic_test` og eksisterende isolerede arkiver.
- Ingen INSERT/UPDATE/DELETE i `padel_state`, `padel_realistic_test` eller arkiver.
- Kun administrator kan starte beregning.
- V11 er fortsat den aktive algoritme.
- Afbryd lange beregninger; for otte deltagere kan fuld udtømmende søgning over
  fem runder ikke gennemføres som en simpel 40.320^5-iteration.
- Anvend beam search med et begrænset antal bedste delplaner, diversificering
  og fast tidsbudget. Sammenlign også mod en simpel greedy-baseline.
- Kontrollér altid, at hver spiller optræder præcis én gang pr. runde.

## Acceptkriterier
- Kan reproducere v11-baselinen: 1.800 samlet ratingforskel, maksimum 700,
  nul gentagne makkerpar og 16 gentagne modstandermøder.
- Rapporterer v14-resultat og alle ti kampe i et separat, læsbart forslag.
- Skelner mellem faktisk og simuleret rating, især ved runde 2–5.
- Ingen eksisterende turneringsdata ændres.
- Først efter dokumenteret forbedring kan v14 overvejes til aktiv brug.

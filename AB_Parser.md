# Amtliches-Bulletin (pre-1999) Roll-Call Parser

Goal: recovering **per-fraction / per-bloc** final-vote tallies for the 1994–1999
bills (leg 44/45) from Amtliches-Bulletin "Schlussabstimmungen" pages, and merge
them into the existing pipeline (`source = "ab"`). Per-member PDFs do NOT exist
for leg 45 (verified 404), so the AB name-lists are the only source.

## Inputs
`cache/neue pdfs/kompliziert/<bizid>-<anr[,anr]>.pdf` — already collected for
anr 457,458,459,461,462,463,464,465,466,467,469,470 (user keeps adding more).
Each PDF is a session-day AB page with **several bills**; only the named anr(s)
are relevant. The matching `gesch_nr`, `titel_kurz_d` and **`dat-parl`** (exact
vote date) are in `Fraktion_Scraping.csv`.

## Page structure (verified)
Two-column layout. Per bill:
```
<German title>  /  <French title>
Schlussabstimmung – Vote final
Namentliche Abstimmung   (Ref.: NNNN)
Für Annahme des Entwurfes stimmen – Acceptent le projet:   <names…> (N_ja)
Dagegen stimmen – Rejettent le projet:                     <names…> (N_nein)
Der Stimme enthalten sich – S'abstiennent:                 <names…> (N_enth)
Entschuldigt/abwesend sind – Sont excusés/absents:         <names…> (N_abw)
<President>, e.g. "Heberlein (1)"   ← president, exclude from buckets
```
Map anr→Ref by title: 463→Ref 3250, 469→Ref 2683, 470→Ref 2684 (examples).
Names wrap with hyphens across line breaks: `Pi-\ndoux`→`Pidoux`,
`Witten-\nwiler`→`Wittenwiler`, `Müller-\nHemmi`→`Müller-Hemmi`.

## VERIFIED building block 1 — column-aware extraction
```python
def col_lines(page):
    w = page.width; cols = {0: [], 1: []}
    for wd in page.extract_words(use_text_flow=False):
        cols[0 if (wd['x0']+wd['x1'])/2 < w/2 else 1].append(wd)
    out = []
    for c in (0, 1):
        ws = sorted(cols[c], key=lambda x: (round(x['top']/3), x['x0']))
        line, lt, lines = [], None, []
        for x in ws:
            if lt is None or abs(x['top']-lt) < 3: line.append(x['text'])
            else: lines.append(" ".join(line)); line = [x['text']]
            lt = x['top']
        if line: lines.append(" ".join(line))
        out += lines
    return out   # col0 lines then col1 lines
```
NOTE: col0/col1 separation means names and their title/Ref can land in different
halves — associate a group of names with the *nearest* "(Ref.: N)" by walking the
ordered lines; don't assume title precedes names.

## VERIFIED building block 2 — date-accurate roster (OData)
```python
flt = ("Language eq 'DE' and DateJoining le datetime'1999-06-18T00:00:00' and "
       "(DateLeaving ge datetime'1999-06-18T00:00:00' or DateLeaving eq null)")
# GET ws.parlament.ch/odata.svc/MemberParlGroupHistory?$filter=<flt>
#     &$select=LastName,FirstName,ParlGroupAbbreviation&$top=300&$format=json
```
Returns ~246 NR+SR members with ParlGroupAbbreviation in MODERN coding
(RL, M-E, S, V, G, GL, L, F, U, FRAKTIONSLOS). Bloc map:
`RL,L→RL ; M-E→ME ; S→S ; V→V ; G→G ; GL→GL ; F,U,FRAKTIONSLOS→other`.
(Restrict to NR if needed via MemberCouncilHistory, but NR/SR surname clashes are
rare.) Use **`dat-parl`** as the date.

## Steps
1. For each anr: reading its bill block (match title → Ref), extracting the 4 name lists.
2. De-hyphenation, splitting names on commas; stripping the trailing `(N)`.
3. Looking up each name in the roster for that `dat-parl` → bloc.
4. Aggregating, **VALIDATING: bloc tallies must sum to the printed (N) per group.**
   If a block doesn't reconcile, flag it (don't silently emit).
5. Emiting rows in the SAME schema as `output/fraktionen_long.csv`
   (source `"ab"`), then re-run `blocs.py` / `summary.py` / `export_xlsx.py`.

## Reuse / context
- `parl_lib.py` (PoliteSession, normalize_title, gesch_display), bloc map +
  orientation in `blocs.py`, output schema in `scrape_fraktionen.py`.
- Read the memory file + `methodology.md` first.
- Gotchas: name disambiguation (two same surnames), the President line,
  multi-bill association, occasional French-only blocks.
- After the 11 provided pages work, the rest of the 50 leg-44/45 bills need their
  AB pages sourced (Amtliches Bulletin archive on parlament.ch, by `dat-parl`).
```
```

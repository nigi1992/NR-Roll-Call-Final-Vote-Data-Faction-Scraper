# Nationalrat Schlussabstimmung — Fraktionen Scraper

For every bill in `Fraktion_Scraping.csv`, this tool finds the **National
Council (Nationalrat) final vote (Schlussabstimmung)** and extracts **how each
parliamentary group (Fraktion) voted** — the data in the bottom
"Fraktion / Groupe / Gruppo" table of the roll-call PDFs.

## TL;DR — how to run

```bash
pip install pdfplumber requests          # one-time
python3 build_index.py                    # one-time: scans the 1999–2003 roll-call PDFs (~20–30 min, cached/resumable)
python3 scrape_fraktionen.py              # builds the output CSVs (re-runnable; OData calls are cached)
```

Outputs land in `output/`. Re-running `scrape_fraktionen.py` is cheap once the
caches exist.

## What you get (`output/`, each also as `.xlsx` with text-typed IDs)

| file | one row per | use |
|---|---|---|
| `fraktionen_long.csv`    | bill × fraction | tidy/long — easy to pivot or join back to your CSV |
| `fraktionen_wide.csv`    | bill | one row per final vote, a column block per fraction (`<CODE>_yes/_no/_abstain/_absent`) |
| `fraktionen_members.csv` | MP × bill | every individual vote (name, fraction, canton, decision) |
| `fraktionen_report.csv`  | bill | status of each bill: `api`/`pdf`/`pdf_manual`/`ab`/`unavailable`, the vote ref(s), PDF URL(s), match note |
| `fraktionen_blocs_{long,wide}.csv` | bill (× bloc) | 7 stable blocs + **orientation** (support/oppose) + predictors `support_coalition`, `elite_cue_lr` — see `methodology.md` |
| `fraktionen_summary.csv` | fraction | per-fraction yes-rate across all matched votes |

`bill_is_initiative` / `roll_call_inverted` flag the votes where a parliamentary
Ja means "recommend rejection" (so the roll call is inverted vs. support for the
proposal). The bloc files give substance-oriented `*_support`/`*_oppose`.

Vote buckets: **yes** (Ja), **no** (Nein), **abstain** (Enthaltung),
**absent** (entschuldigt / abwesend / nicht teilgenommen). The council
president (who does not vote) is excluded from the four buckets. Every row
carries a `vote_url` pointing at the actual PDF on parlament.ch.

## How it works — three sources, chosen automatically per bill

A bill is matched to its Nationalrat final vote by **business number**
(`gesch_nr`, e.g. `99.022`), not by the referendum date in the CSV (that date
is the *popular vote*, which happens months *after* the parliamentary final
vote).

1. **OData API** (`ws.parlament.ch`) — for final votes from the **47th
   legislature onward (Winter session 2003 → today)**. The API returns every
   member's vote together with their parliamentary group, which get aggregated.
   This is the same data the PDF's bottom table shows, but exact and machine
   readable. (Cross-checked: the API aggregation reproduces the PDF's
   bottom-table numbers.)

2. **Roll-call PDFs** (`build_index.py` → `cache/pdf_index.json`) — for the
   **46th legislature (Dec 1999 → Oct 2003)**, which the API does not cover.
   Downloading every `vote_<leg>_<ref>.pdf`, parse the member list, and
   aggregate by fraction. The parser was validated to reproduce the official
   "Gesamt" totals exactly on 120+ PDFs (200/200 members each).

   The 1999–2002 PDFs hide the business number in a broken embedded font, so
   each PDF is matched to a bill by **(a)** its Nationalrat final-vote *date*
   (from the OData `Resolution` chronology) and **(b)** token overlap between
   the PDF's formal bill title and the OData business `Title + Description`.

3. **Amtliches-Bulletin name-list pages** (`ab_parse.py`) — for **legislatures
   44–45 (1994–1999)**, which have no per-member roll-call PDFs online (they 404).
   The digitised AB "Schlussabstimmungen" pages list the members by name in each
   direction; the parser resolves those names to fractions via a date-accurate
   OData roster and aggregates. Marked `source = "ab"`. See `methodology.md` §5
   for the parser, the re-vote handling, and the validation gate. Drop more AB
   pages into `cache/neue pdfs/kompliziert/` (`<archive-id>-<anr[,anr]>.pdf`) and
   they are picked up automatically.

## Coverage — December 1999 forward is complete; 1994–1999 via the Amtliches Bulletin

The roll-call PDFs are only published online back to the **46th legislature
(Winter session 1999)**; legislatures 44–45 (1991–1999) return 404 at
`parlament.ch/poly/Abstimmung/<leg>/...`. Everything from **Dec 1999 onward** is
covered by the API/PDF sources. For **1994–1999** the per-fraction tallies are
recovered from the Amtliches-Bulletin name-list pages (source `ab`, see above),
page by page as they are collected. Bills whose **final vote predates roll-call
voting (before 1994)** are genuinely unrecoverable and stay `unavailable` (the
report still shows the NR final-vote date from OData when known).

On the supplied CSV (486 referendum subjects, 1970–2026) the current result is
**175 via API, 37 via PDF, 8 via manual PDF, 50 via Amtliches Bulletin, 216
unavailable** (mostly pre-1994 — roll-call voting didn't exist yet, which is as
far back as the data goes; the rest are 1994–1999 bills whose AB page isn't
collected yet or is too OCR-corrupted to parse cleanly, plus the 4 referendum
*Stichfragen*, which are ballot tie-breaks with no parliamentary vote). The AB
parser reads both the 1999+ and the 1994–98 page layouts and tolerates the OCR
errors in the older scans.

Each draft of a multi-draft business is matched to its **own** roll-call PDF (an
initiative and its counter-proposal never share a vote), and a provided AB page
that doesn't contain the target bill's own Schlussabstimmung is flagged
(`AB unresolved: …`) rather than mapped to a wrong vote — better no entry than a
wrong one.

Note: the final-vote `Subject` in OData is stored in whatever language the vote
was held in (`Schlussabstimmung`/`Vote final`/`Votazione finale`) and is
sometimes empty, so the API path matches all three languages and falls back to
the Nationalrat final-vote *date* (from `Resolution`) when the subject is blank.

A `summary.py` script writes `output/fraktionen_summary.csv` — per-fraction
Yes/No/Abstain/Absent totals and yes-rate across all matched final votes.

## Fraction codes

The PDFs use short codes that change over the decades. 1999–2003: `C` (CVP),
`S` (SP), `V` (SVP), `R` (FDP/Radikale), `L` (Liberale), `G` (Grüne),
`E` (EVP/EDU), `U` (LdU/Unabhängige), `-` (fraktionslos). Modern API data uses
e.g. `GL` (Grünliberale), `RL` (FDP-Liberale), `M-E` (Die Mitte). The API rows
carry the official group name; PDF rows use the lookup in `parl_lib.py`.

## Files

| file | purpose |
|---|---|
| `parl_lib.py`          | shared library: polite throttled HTTP, the validated PDF parser, code/decision lookups |
| `build_index.py`       | downloads & indexes the 1999–2003 roll-call PDFs (resumable; `--reparse` rebuilds from cache without re-downloading) |
| `scrape_fraktionen.py` | the main pipeline: routes each bill API↔PDF↔AB and writes the output CSVs |
| `ab_parse.py`          | Amtliches-Bulletin (leg 44/45) name-list parser → per-fraction tallies via a date-accurate OData roster (`run it standalone for a validation report`) |
| `summary.py`           | per-fraction yes-rate summary → `output/fraktionen_summary.csv` |
| `blocs.py`             | 7 stable blocs + orientation + predictors → `output/fraktionen_blocs_{long,wide}.csv` (see `methodology.md`) |
| `export_xlsx.py`       | `.xlsx` copies of every output with `gesch_nr`/IDs as text |
| `methodology.md`       | bloc grouping, the cohesion evidence, the orientation/inversion handling |
| `cache/neue pdfs/`     | hand-collected per-member roll-call PDFs (auto-loaded as `pdf_manual`); the `kompliziert/` subfolder holds Amtliches-Bulletin name-list pages (source `ab`) |
| `cache/`               | downloaded PDFs, the PDF index, and the OData response cache |
| `output/`              | the result CSV + xlsx files |

The pipeline uses the CSV's **`dat-parl`** (final-vote date) as the primary key
for matching PDFs, and auto-loads any PDFs you drop into `cache/neue pdfs/`.

## `gesch_nr` format

`gesch_nr` is written as a zero-padded **`YY.NNN`** string (e.g. `01.074`,
`00.034`, `92.070`) — `gesch_display()` in `parl_lib.py` reverses the
leading/trailing zeros that spreadsheets strip. **When reading the CSVs back,
import `gesch_nr` as text** (R: `col_types = cols(gesch_nr = "c")`; pandas:
`dtype={'gesch_nr': str}`) or tool will re-strip the zeros on open.

## Notes & limitations

* **Politeness** parlament.ch rate-limits bursts (HTTP 403). `build_index.py`
  throttles itself and backs off, not cranking `--workers` / lower
  `--min-interval` aggressively.
* **Multi-bill businesses.** A business with several drafts (Entwürfe) has one
  final vote per draft. The API splits these by bill number, for PDF-era
  multi-bill businesses the draft↔PDF mapping is best-effort (matched by date +
  title) — check `bill_title` / `vote_url` in the output to confirm.
* **Verification uncertain matches** via the `note` (match method + score) and
  `vote_url` columns in `fraktionen_report.csv`.

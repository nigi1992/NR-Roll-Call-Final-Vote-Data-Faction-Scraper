# Fraktion Scraping — R port

R port of the Python pipeline that extracts, for each bill in
`Fraktion_Scraping.csv` (486 Swiss federal popular-vote subjects, 1970–2026),
how each **parliamentary group (Fraktion)** voted in the **Nationalrat final
vote (Schlussabstimmung)** — the roll-call behind every referendum bill.

The scripts were ported 1:1 from the Python originals and **verified against
their outputs** (see *Verification* below). The Python scripts remain the
reference implementation; this port exists so the data can be (re)built and
extended directly from RStudio.

## Folder layout (inside the R project)

```
Swiss Popular Votes ML Forecasting Application/
├── Input Data/Fraktion Scraping/
│   ├── Fraktion_Scraping.csv        the 486 referendum subjects (source list)
│   ├── neue pdfs/                   hand-collected PDFs
│   │   ├── einfach/                 per-member roll-call protocols -> pdf_manual
│   │   └── kompliziert/             Amtliches-Bulletin pages       -> ab
│   └── cache/                       data caches (JSON; see below)
│       ├── pdf_index.json           parsed leg-46 roll-call PDFs (1233 votes)
│       ├── odata_cache.json         cached OData API responses
│       └── ab_roster_cache.json     date-accurate NR rosters
├── Output/Fraktion Scraping/        all CSVs + XLSX the scripts write
└── Scripts/Fraktion Scraping/       the .R scripts + this README
```

## Requirements

```r
install.packages(c("pdftools", "jsonlite", "httr2", "writexl"))
```

Base R does the rest (no tidyverse dependency). Tested on R 4.6 / pdftools 3.9.

## Running

Open the project in RStudio (so the working directory is inside the project —
the scripts find the project root themselves) and either

```r
source("Scripts/Fraktion Scraping/run_all.R")     # full chain
```

or run the steps individually, in this order:

| script | what it does | output |
|---|---|---|
| `scrape_fraktionen.R` | main pipeline: routes every bill to OData API / PDF index / manual PDFs / Amtliches Bulletin | `fraktionen_{long,wide,members,report}.csv` |
| `blocs.R`   | rolls fraction codes into 7 stable blocs + substance-oriented predictors | `fraktionen_blocs_{long,wide}.csv` |
| `summary.R` | per-fraction totals and yes-rates across all matched votes | `fraktionen_summary.csv` |
| `export_xlsx.R` | `.xlsx` copies with ID columns text-typed (keeps `03.026` intact in Excel) | one `.xlsx` per CSV |

Support files (not part of the chain):

| script | purpose |
|---|---|
| `parl_lib.R` | shared library: polite throttled HTTP, roll-call PDF parser, lookup tables (`source()`d by the others) |
| `ab_parse.R` | Amtliches-Bulletin name-list parser; **run standalone for a validation report** of every collected AB page |
| `build_index.R` | one-off scanner for the leg-46 roll-call PDFs; `--reparse` rebuilds the index from cached PDFs. Not needed in normal use — the shipped `pdf_index.json` is complete |

With the shipped caches the whole chain runs **offline** in a few minutes. New
bills (or a deleted cache) trigger polite live fetches — parlament.ch answers
request bursts with HTTP 403, so the built-in throttle must stay in place.

## About caches (the `__pycache__` / `cache` question)

R has no equivalent of Python's `__pycache__` (compiled bytecode) — nothing to
carry over, nothing was. The Python project's `cache/` folder however holds
**data**, not bytecode: cached OData responses, the parsed PDF index, and the
member rosters, all plain JSON. Those are kept, unchanged in format, under
`Input Data/Fraktion Scraping/cache/` — the R scripts read **and write** the
same files, using the same cache keys as the Python pipeline, so the two
implementations can even share them. Storing them in the RStudio environment
(.RData) instead would make runs non-reproducible and the files un-shareable;
files are the right tool here.

`cache/pdfs/` (the ~1200 raw leg-46 PDFs, 37 MB) is *not* shipped — the parsed
`pdf_index.json` is authoritative. If you ever need the raw PDFs (e.g. to
`--reparse` after changing the parser), `build_index.R` re-downloads them, or
copy the folder from the Python project.

## Verification against the Python pipeline

Every script was run on this machine against the Python outputs:

* `blocs.R`, `summary.R` — **cell-identical** output CSVs.
* `parl_lib.R` `parse_pdf()` — 150 randomly sampled roll-call PDFs re-parsed:
  **150/150 identical** (counts, ref, date, final-flag, member count).
* `build_index.R --reparse` — sampled PDFs produce index records identical to
  the Python index.
* `ab_parse.R` — same OK/FAIL verdict and identical tallies for 51 of 54
  collected AB pages; the same two OCR-corrupted pages (anr 428, 429) and the
  wrong-page 460 fail in both.
* `scrape_fraktionen.R` — same source routing and identical vote counts for
  every bill. Final tally: api 175 / pdf 37 / pdf_manual 8 / **ab 51** /
  unavailable 215.

**Known differences (all benign):**

1. **anr 444 (10. AHV-Revision initiative) resolves in R but not in Python.**
   The R PDF library (poppler) separates that page's side-by-side two-bill
   layout cleanly where the Python one garbles it. The R result passes the full
   validation gate (every printed bucket total reconciled, 200/200 members
   assigned) — it is a *bonus recovery*, so the R dataset has **one bill more**.
2. `bill_title` (descriptive text only) can differ in whitespace — the two PDF
   libraries join words/columns slightly differently. All counts, codes, dates
   and IDs are identical.
3. In `fraktionen_report.csv`, an AB vote without a printed `(Ref.: N)` shows
   `vote_refs = NA` (R convention) where Python printed `None`.

## Extending the dataset

More 1994–1999 bills only need their Amtliches-Bulletin page dropped into
`Input Data/Fraktion Scraping/neue pdfs/kompliziert/` as
`<archive-id>-<anr[,anr]>.pdf` (e.g. `20045649-467.pdf`); re-run the chain.
Run `ab_parse.R` standalone first to check the page validates. Pages that do
not reconcile with the printed totals are **skipped and reported**, never
force-emitted — better no entry than a wrong one.

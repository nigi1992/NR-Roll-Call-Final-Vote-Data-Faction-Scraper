# Building predictors from the fraction votes (blocs, orientation, missingness)

Turning the parliamentary final-vote fraction split
into predictors of the national Yes-share. See `blocs.py`.

## 1. Stable blocs (the missingness problem)

Raw fraction codes change over 1999–2026 (only V, S, G keep a stable
composition). Used as separate columns they create structural NAs. Rolling the
codes into **7 blocs** (codes per `Faktenblatt Fraktionen-d.pdf`):

```
S    Sozialdemokratische Fraktion
G    Grüne Fraktion
GL   Grünliberale Fraktion (glp)
ME   "Mitte": C, CE, CEg, BD, M-E, M-CEB   +  E (EVP/EDU)
RL   FDP-Liberale: R, L, RL
V    SVP
other  fraktionslos: -, U, W
```

**EVP and EDU.** The historical `E` fraction is literally "EVP/EDU", so EVP and
EDU cannot be separated in the roll call. Since for the last five legislatures
the EVP has caucused with the CVP/Mitte, `E` is folded into **ME**. The (1–2)
EDU members inside a historical `E` fraction therefore also land in ME; modern
EDU members who sit in the SVP fraction are already counted in **V**. This is
the one unavoidable imperfection of the scheme.

After grouping, **S, G, ME, RL, V have 0% structural absence** (present in every
vote); `GL` is absent for ~43% (it had no own fraction before 2011 — a *real*
absence, code as `NA`, not 0).

### Empirical justification (cohesion)
Merges were checked against how often the constituent fractions vote the same
way: R~L 97%, CVP~BDP 100%, CVP~M-E 91% (safe to merge); CVP~EVP only 66% (the
one weak join — EVP/EDU diverges on value issues, but is folded in for caucus
continuity as requested). glp is distinct (≤73% with any neighbour) → its own
bloc.

## 2. Orientation — making "support" mean support of the proposal

**121 of the final votes are a "Bundesbeschluss über eine Volksinitiative",
where a parliamentary Ja means "recommend rejection".** The roll call is then
inverted relative to support for the proposal's substance (the thing the people
vote on). `blocs.py` therefore adds **oriented** counts:

```
support = Nein if inverted else Ja
oppose  = Ja   if inverted else Nein
```

so that `support` always means "for the proposal". `inverted` is taken as
`bill_is_initiative` (true for the ~95% of initiatives parliament recommends
*rejecting*).

> **Answering the question directly:** a flag alone is *not* enough — orient the
> data. Providing oriented `*_support` / `*_oppose` per bloc plus
> `support_coalition` and `elite_cue_lr` computed on the oriented votes, so the
> predictor is directly usable for the Yes-share. The raw `*_ja`/`*_nein` are
> kept alongside for transparency.
>
> *Validation:* for `25.026` (Nachhaltigkeitsinitiative) the oriented
> `support_coalition` is **V** — matching your observation that the SVP was the
> only faction in favour, even though in the protocol they alone voted Nein.

**Refining the exceptions with your `nr-pos`.** The `bill_is_initiative`
heuristic is wrong only for the handful of initiatives parliament recommends
*accepting* (and some counter-proposal constructions). Recompute orientation
exactly with the Swissvotes recommendation:

```
inverted = bill_is_initiative AND nr-pos == 2 (Ablehnend)
```

(For an ordinary enacted law nr-pos is 1 and there is no inversion.)

## 3. Predictors in `fraktionen_blocs_wide.csv`

- `<bloc>_ja/_nein/_enth/_abw` — raw roll-call counts per bloc.
- `<bloc>_support/_oppose` — oriented to the proposal's substance.
- `support_coalition` — blocs whose majority *supported* the proposal
  (e.g. `S+G+GL` = left-green carries it; `ME+RL+V` = bourgeois).
- `elite_cue_lr` — left–right centre of gravity of the *support*: negative = the
  left supports it, positive = the right supports it. The bloc left–right
  values (`LR` in `blocs.py`) are indicative — replace with a cited scale.
- `bill_is_initiative`, `roll_call_inverted` — the orientation flags.

## 4. Data provenance / availability (`source` column)

- `api` (175) — OData per-member votes, leg 47+ (Dec 2003→).
- `pdf` (37) — leg-46 roll-call PDFs (Dec 1999–Oct 2003).
- `pdf_manual` (8) — hand-collected PDFs in `cache/neue pdfs/` (fills OData gaps).
- `ab` (50) — **Amtliches-Bulletin name-list pages** (leg 44/45, back to the
  spring 1994 session when roll-call recording began), parsed by `ab_parse.py`
  and resolved to per-fraction tallies via a date-accurate OData roster (see §5).
  Grows as more AB pages are added under `cache/neue pdfs/kompliziert/`.
- `unavailable` (216) — by `dat-parl`: pre-1994 (roll-call voting didn't exist
  yet), 1994–1999 bills whose AB page isn't sourced or is too OCR-corrupted to
  parse cleanly (4 collected pages are flagged `AB unresolved`), and the **4
  Stichfragen** (referendum tie-break ballots — never a parliamentary final vote,
  excluded by `rechtsform == 5`).

### Multi-draft businesses (one PDF per draft)
A business often has several drafts voted the same day (a popular initiative + a
counter-proposal, two initiatives, two amendments of one law). Each draft has its
**own** Schlussabstimmung, so the pipeline assigns the business's drafts to
*distinct* roll-call PDFs as a bijection (`PdfIndex.match_business`): pairs are
scored by how many of the draft's *content* title words the PDF carries
(function and structural words like *Änderung/Gesetz* are dropped so they can't
create a spurious hit), then assigned greedily, with the draft (entwurf) order
breaking ties between PDFs whose titles are identical (e.g. the two *Militärgesetz*
amendments — distinguished only by their vote sequence). A draft with no
confident PDF is left `unavailable` rather than sharing another draft's vote.
There is no date-less "title-only" fallback (it produced false positives for
pre-1999 bills whose votes simply aren't online).

## 5. Pre-1999 (Amtliches Bulletin) — implemented (`ab_parse.py`)

The 1994–1999 final votes are not online as per-member PDFs (leg 44/45 return
404). They survive only as Amtliches-Bulletin "Schlussabstimmungen" pages that
list member **names** by direction (no fraction labels). `ab_parse.py` recovers
per-fraction tallies from them:

1. **Two-column, multi-bill parser.** Each page is read column-aware (a bill's
   name lists routinely span the column break). Vote blocks are anchored on
   `Namentliche Abstimmung` / `(Ref.: N)`; each bucket is closed by its printed
   `(N)`. Wrapped names are de-hyphenated (`Witten-/wiler`→`Wittenwiler`,
   `Müller-/Hemmi`→`Müller-Hemmi`).
2. **Re-vote handling.** Blocks are grouped into *drafts*; a corrected re-vote
   flagged "Ich wiederhole die Abstimmung" supersedes the previous one (highest
   `Ref` wins). This is why anr 462 resolves to Ref 2688, not the botched 2687.
3. **Date-accurate roster.** Names are resolved against the Nationalrat roster on
   the exact `dat-parl` date — `MemberParlGroupHistory` (authoritative fraction)
   ∩ `MemberCouncilHistory` (NR membership, canton, `OfficialName`). The fraction
   code emitted is the OData `ParlGroupAbbreviation` (S, RL, M-E, V, G, F, L, U,
   …), the same modern coding `blocs.py` already rolls up.
4. **Name matching** is tiered: full surname / `OfficialName` (catches the
   hometown-disambiguated `Fischer-Hägglingen`/`Fischer-Seengen`), then
   surname+first-name (the AB prints a first name only to disambiguate, e.g.
   `Meyer Theo`/`Meyer Thérèse`), then the first component of a multi-part
   surname (`Roth`←`Roth-Bernasconi`, `Aeppli`←`Aeppli Wartmann`).
5. **Validation gate.** The yes/no/abstain buckets are a hard gate — the parsed
   count must equal the printed `(N)` and every name must resolve to exactly one
   roster member, else the page is reported and **skipped** (no silent emit).
   `absent` is reconstructed as `roster − (yes∪no∪abstain∪president)`, so a page
   truncated after the abstain list (e.g. 99.028 Bilaterale) is still usable.

**Two AB layouts.** The parser anchors each vote block on the universal
"Für Annahme des Entwurfes" heading, so it handles both the 1999+ layout (with a
`(Ref.: N)` line and "Entschuldigt/abwesend") and the **1994–98 layout**
("Namentliche Schlussabstimmung", no Ref, "Abwesend sind", "Präsident stimmt
nicht", plus a "Stimmen nicht / Ne votent pas" present-but-abstaining-from-the-
record category folded into reconstructed absent).

**OCR tolerance.** The early scans corrupt characters; matching therefore falls
back, after the exact tiered keys, to (a) a surname-only key when the first name
differs (`Eberhard Anton` = roster `Eberhard Toni`), and (b) a bounded
Levenshtein fuzzy match (`von Feiten`→Felten, `Verterli`→Vetterli, `Surgi`→Bürgi),
always requiring a unique roster member. Running headers spliced inside a line
(`Fischer-Hägg668 N 18 mars 1994 lingen`), `#…#` markers, and names glued with a
`.` (`Zisyadis.Zölch`) are repaired. The roster query allows a 10-day grace on the
leaving date so a within-session voter dated to the session's last day still
resolves.

A page named for a sub-numbered referendum (`20046702-465.pdf` → CSV rows
465.1/465.2/465.3) is expanded and each sub-row matched *strictly* — only the one
actually voted on the page resolves (465.1 = Solar-Initiative → block B). All
recovered pages pass the yes/no/abstain reconciliation gate, and the
coalitions reconcile with history (Kriegsmaterial-Verbot and the AHV/traffic
initiatives carried by S+G; "Jugend ohne Drogen" by the SVP alone; FinöV broad
except SVP; Bilaterale I near-unanimous). A handful of collected pages are too
OCR/layout-corrupted to parse safely (two side-by-side two-bill pages, one with
the column header spliced into the list) or are the wrong page for the bill
(anr 460's page is an April-1999 detail vote, not the Schlussabstimmung) — those
are reported as `AB unresolved` and skipped, never force-emitted. More leg-44/45
bills just need their pages dropped into `cache/neue pdfs/kompliziert/`
(`<archive-id>-<anr[,anr]>.pdf`), the parser picks them up automatically.

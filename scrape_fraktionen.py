#!/usr/bin/env python3
"""
scrape_fraktionen.py — For every bill in Fraktion_Scraping.csv, matching the
National Council (Nationalrat) FINAL vote (Schlussabstimmung) and extracting how
each parliamentary group (Fraktion) voted.

Two sources, chosen automatically per bill (keyed on the business number):

  * OData web service (ws.parlament.ch)  -> 47th legislature onward
    (Winter session 2003 -> today). Gives the individual member votes incl.
    their group, which get aggregated. This is the same data the bottom
    "Fraktion / Groupe / Gruppo" table of the PDF shows, but exact and machine
    readable.

  * roll-call PDFs (built into cache/pdf_index.json by build_index.py)
    -> 46th legislature (Dec 1999 - Oct 2003), which OData does not cover.
    Older PDFs hide the business number in a broken font, so they are matched
    to a bill by the (readable) full official title obtained from OData.

Outputs (in ./output):
  * fraktionen_long.csv     one row per bill x fraction (tidy)
  * fraktionen_wide.csv     one row per bill, a column block per fraction
  * fraktionen_members.csv  one row per MP per bill (individual votes)
  * fraktionen_report.csv   per-bill status: matched via api/pdf/unavailable
"""

import os
import re
import csv
import json
import argparse
from collections import defaultdict

import parl_lib as L
import ab_parse

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "cache")
OUT = os.path.join(HERE, "output")
INDEX_PATH = os.path.join(CACHE, "pdf_index.json")
ODATA_CACHE = os.path.join(CACHE, "odata_cache.json")
CSV_PATH = os.path.join(HERE, "Fraktion_Scraping.csv")
MANUAL_DIR = os.path.join(CACHE, "neue pdfs")   # hand-collected roll-call PDFs

ODATA = "https://ws.parlament.ch/odata.svc"


def norm_anr(a):
    """'479.0' -> '479', '682.3' -> '682.3'."""
    a = (a or "").strip()
    try:
        f = float(a)
        return str(int(f)) if f == int(f) else a
    except ValueError:
        return a


def datparl_to_pdf(d):
    """CSV dat-parl 'DD/MM/YYYY' -> PDF date 'DD.MM.YYYY'."""
    d = (d or "").strip()
    m = re.match(r"(\d{2})/(\d{2})/(\d{4})", d)
    return f"{m.group(1)}.{m.group(2)}.{m.group(3)}" if m else None


def _vote_url(v):
    """Online roll-call PDF URL, or the source's own (e.g. AB pages have none —
    the per-member leg-44/45 PDFs return 404, so never building that URL)."""
    if "vote_url" in v:                 # source supplied it explicitly (AB: "")
        return v["vote_url"]
    if v.get("leg") and v.get("vote_ref"):
        return L.pdf_url(v["leg"], v["vote_ref"])
    return ""


def load_manual_pdfs():
    """Parsing hand-collected PDFs under cache/neue pdfs/ -> {anr: [vote dict, ...]}.
    Filename convention: '<ident>-<anr[,anr...]>.pdf' (ident is 'vote_<leg>_<ref>'
    or a business number). PDFs the per-member parser can't read (Amtliches-
    Bulletin summary pages) are skipped here and handled separately."""
    import glob
    out = defaultdict(list)
    for f in glob.glob(os.path.join(MANUAL_DIR, "**", "*.pdf"), recursive=True):
        base = os.path.basename(f)
        m = re.match(r"(.+)-([\d,]+)\.pdf$", base)
        if not m:
            continue
        ident, anrs = m.group(1), m.group(2).split(",")
        try:
            rec = L.parse_pdf(open(f, "rb").read())
        except Exception:
            rec = None
        if not rec or rec.get("n_members", 0) == 0:
            continue
        mm = re.match(r"vote_(\d+)_", ident)
        leg = int(mm.group(1)) if mm else rec.get("leg")
        vote = {
            "vote_ref": rec.get("ref"), "leg": leg, "vote_date": rec.get("date"),
            "bill_number": None, "bill_title": rec.get("title"),
            "counts": rec.get("counts", {}),
            "group_names": {c: L.fraction_name(c) for c in rec.get("counts", {})},
            "members": rec.get("members", []), "n_members": rec.get("n_members"),
            "is_final": rec.get("is_final"), "subject": rec.get("subject"),
            "source_file": base,
        }
        for a in anrs:
            out[norm_anr(a)].append(vote)
    return out


# --------------------------------------------------------------------------
# OData access (cached to disk)
# --------------------------------------------------------------------------
class ODataClient:
    def __init__(self, session):
        self.s = session
        self.cache = {}
        if os.path.exists(ODATA_CACHE):
            try:
                self.cache = json.load(open(ODATA_CACHE))
            except Exception:
                self.cache = {}

    def save(self):
        json.dump(self.cache, open(ODATA_CACHE, "w"), ensure_ascii=False)

    def _get(self, path):
        if path in self.cache:
            return self.cache[path]
        url = ODATA + path
        r = self.s.get(url, accept="application/json", timeout=40)
        rows = []
        if r is not None and r.status_code == 200:
            raw = r.json().get("d", [])
            rows = raw["results"] if isinstance(raw, dict) else raw
        self.cache[path] = rows
        return rows

    def votes_for_business(self, business_number):
        return self._get(
            f"/Vote?$filter=BusinessNumber%20eq%20{business_number}"
            f"%20and%20Language%20eq%20'DE'&$format=json")

    def votings_for_vote(self, vote_id):
        return self._get(
            f"/Voting?$filter=IdVote%20eq%20{vote_id}"
            f"%20and%20Language%20eq%20'DE'&$format=json")

    def business_blob(self, business_number):
        """Title + Description — used to match the PDF's *formal* bill title.
        (For initiatives OData stores the popular nickname in Title but the
        official wording in Description, which is what the PDF prints.)"""
        rows = self._get(
            f"/Business?$filter=ID%20eq%20{business_number}"
            f"%20and%20Language%20eq%20'DE'&$select=Title,Description&$format=json")
        if not rows:
            return ""
        return (rows[0].get("Title") or "") + " " + (rows[0].get("Description") or "")

    def bills(self, business_number):
        return self._get(
            f"/Bill?$filter=BusinessNumber%20eq%20{business_number}"
            f"%20and%20Language%20eq%20'DE'&$select=ID,BillNumber&$format=json")

    def nr_schlussabstimmung_dates(self, business_number):
        """Return [(date 'dd.mm.yyyy', bill_number)] for every Nationalrat
        final-vote resolution of the business (across its bills)."""
        out = []
        for b in self.bills(business_number):
            bid = b["ID"]
            res = self._get(
                f"/Resolution?$filter=IdBill%20eq%20guid'{bid}'"
                f"%20and%20Language%20eq%20'DE'&$format=json")
            for r in res:
                if (r.get("CouncilName") == "Nationalrat"
                        and "chlussab" in (r.get("ResolutionText") or "")):
                    out.append((_odate(r.get("ResolutionDate")), b.get("BillNumber")))
        return out


# --------------------------------------------------------------------------
# Aggregation helpers
# --------------------------------------------------------------------------
def aggregate_api_votings(votings):
    """votings -> {parlgroup_code: {bucket: n}}, plus group display names + members."""
    counts = defaultdict(lambda: defaultdict(int))
    names = {}
    members = []
    for v in votings:
        code = v.get("ParlGroupCode") or "-"
        if code.upper() == "FRAKTIONSLOS":   # unify with the PDF-era '-' code
            code = "-"
        bucket = L.DECISION_BUCKET.get(v.get("Decision"))
        if bucket is None:
            continue
        counts[code][bucket] += 1
        names[code] = (v.get("ParlGroupName") or L.fraction_name(code))
        members.append({
            "name": f"{v.get('LastName','')} {v.get('FirstName','')}".strip(),
            "fraction": code, "canton": v.get("Canton"), "bucket": bucket,
            "decision_text": v.get("DecisionText"),
        })
    return counts, names, members


def api_schlussabstimmungen(odata, business_number):
    """Return NR final votes for a business: list of dicts with vote meta +
    aggregated counts + members. Filters to Nationalrat by member count."""
    votes = odata.votes_for_business(business_number)

    # primary: the final-vote subject, recordeding in the language it was held in
    # ('Schlussabstimmung' DE / 'Vote final' FR / 'Votazione finale' IT)
    sa = [v for v in votes
          if re.search(r"schlussab|vote final|votazione finale",
                       v.get("Subject") or "", re.I)]
    # fallback: some final votes have an empty Subject -> identifing them by the
    # Nationalrat Schlussabstimmung date from the OData chronology (Resolution)
    if not sa:
        nr_dates = {d for d, _ in odata.nr_schlussabstimmung_dates(business_number)}
        if nr_dates:
            sa = [v for v in votes if _odate(v.get("VoteEnd")) in nr_dates]

    # a bill is voted on once in the final vote; if OData lists several
    # 'Vote final' entries for the same bill (re-vote / correction artifacts),
    # keeping only the definitive one = highest RegistrationNumber.
    by_bill = {}
    for v in sa:
        key = v.get("BillNumber")
        if key not in by_bill or (v.get("RegistrationNumber") or 0) > (by_bill[key].get("RegistrationNumber") or 0):
            by_bill[key] = v
    sa = list(by_bill.values())

    out = []
    for v in sa:
        votings = odata.votings_for_vote(v["ID"])
        if len(votings) <= 100:           # Ständerat (~46) -> skiping, keeping Nationalrat (~200)
            continue
        counts, names, members = aggregate_api_votings(votings)
        out.append({
            "vote_ref": v.get("RegistrationNumber"),
            "leg": v.get("IdLegislativePeriod"),
            "vote_date": _odate(v.get("VoteEnd")),
            "bill_number": v.get("BillNumber"),
            "bill_title": v.get("BillTitle"),
            "counts": {k: dict(c) for k, c in counts.items()},
            "group_names": names,
            "members": members,
            "n_members": len(members),
        })
    return out


def _odate(s):
    if not s:
        return None
    import re
    m = re.search(r"(\d+)", s)
    if not m:
        return None
    import datetime
    return datetime.datetime.fromtimestamp(
        int(m.group(1)) / 1000, datetime.timezone.utc).strftime("%d.%m.%Y")


# --------------------------------------------------------------------------
# PDF-era matching (leg 46)
# --------------------------------------------------------------------------
def _tokens(s):
    s = (s or "").lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        s = s.replace(a, b)
    return set(w for w in re.split(r"[^a-z0-9]+", s) if len(w) > 3)


# function words + non-discriminating structural words (they appear in nearly
# every bill title, so letting them count as a content hit causes false matches,
# e.g. 'Änderung des Mietrechts' grabbing a 'Raumplanungsgesetz. Änderung' PDF).
_STOP = {"fuer", "ein", "eine", "einen", "einem", "einer", "und", "oder", "der",
         "die", "das", "den", "dem", "des", "von", "vom", "zur", "zum", "ueber",
         "aus", "auf", "mit", "bei", "gegen", "ohne", "pour", "dans", "sur",
         "les", "des", "une", "aux",
         "aenderung", "aenderungen", "revision", "teilrevision", "gesetz",
         "bundesgesetz", "bundesbeschluss", "verordnung", "beschluss", "loi"}


def _dtok(s):
    """Tokens of a draft's (CSV) title — like _tokens but with function words
    dropped, so two drafts of the same business are told apart by their *content*
    words (e.g. 'Strom ohne Atom' vs 'MoratoriumPlus')."""
    return {w for w in _tokens(s) if w not in _STOP}


class PdfIndex:
    def __init__(self, path):
        self.recs = []
        idx = json.load(open(path)) if os.path.exists(path) else {}
        for rec in idx.values():
            if rec.get("is_final"):
                rec["_tok"] = _tokens(rec.get("title"))
                self.recs.append(rec)
        self.by_short = defaultdict(list)
        self.by_date = defaultdict(list)
        for r in self.recs:
            if r.get("business_short"):
                self.by_short[r["business_short"]].append(r)
            if r.get("date"):
                self.by_date[r["date"]].append(r)

    @staticmethod
    def _score(rec, blob_tokens):
        pt = rec.get("_tok") or set()
        if not pt:
            return 0.0
        return len(pt & blob_tokens) / len(pt)

    def match_business(self, draft_rows, sa_dates, blob, business_short):
        """Assigning every draft (CSV row) of a business to a *distinct* roll-call
        PDF — so a multi-draft business (initiative + counter-proposal, two
        initiatives, two amendments of one law) doesn't put the same vote on
        several drafts.

        Candidates are the PDFs carrying the business number (good-font era) or,
        failing that, the PDFs on the business's final-vote date(s). Each
        (draft, PDF) pair is scored by how many of the draft's *content* title
        words the PDF title carries (primary) and by the business-title token
        precision (secondary); pairs are then assigned greedily as a bijection,
        with the draft (entwurf) order breaking ties between PDFs whose titles are
        identical (e.g. the two 'Militärgesetz' amendments). A draft with no
        confident PDF is left unmatched (better no entry than a wrong one).

        There is deliberately **no** date-less title-only fallback: it produced
        false positives for pre-1999 bills (whose votes simply aren't online).

        Returns {anr: (rec_or_None, how, score)}.
        """
        blob_tokens = _tokens(blob)
        # candidate PDFs
        how = "date+title"
        if business_short and business_short in self.by_short:
            cands = list(self.by_short[business_short])
            how = "short"
        else:
            dates = set()
            for r in draft_rows:
                pd = datparl_to_pdf(r.get("dat-parl"))
                if pd:
                    dates.add(pd)
            dates |= {d for d, _ in sa_dates if d}
            seen, cands = set(), []
            for d in dates:
                for r in self.by_date.get(d, []):
                    if r.get("is_final") and r["ref"] not in seen:
                        seen.add(r["ref"])
                        cands.append(r)
        anrs = [norm_anr(r["anr"]) for r in draft_rows]
        if not cands:
            return {a: (None, None, 0.0) for a in anrs}

        # entwurf order, as a dense rank over the drafts
        def _ek(r):
            e = (r.get("entwurf_nr") or "").strip()
            return int(e) if e.isdigit() else 99
        erank = {norm_anr(r["anr"]): i
                 for i, r in enumerate(sorted(draft_rows, key=_ek))}

        raw = []
        for r in draft_rows:
            a = norm_anr(r["anr"])
            dt = _dtok(r.get("titel_kurz_d"))
            for c in cands:
                pt = c.get("_tok") or set()
                prim = len(pt & dt)
                sec = (len(pt & blob_tokens) / len(pt)) if pt else 0.0
                raw.append([prim, round(sec, 4), a, c])
        # dense rank of only the *title-relevant* PDFs (those a draft's content
        # words actually hit) — so two identical-title PDFs (the two Militärgesetz
        # amendments) pairing with the drafts in entwurf order, vote-sequence aligned.
        relevant = sorted({c["ref"] for prim, _s, _a, c in raw if prim >= 1})
        crank = {ref: i for i, ref in enumerate(relevant)}
        pairs = [(prim, sec, -abs(erank[a] - crank.get(c["ref"], 99)), a, c)
                 for prim, sec, a, c in raw]
        pairs.sort(key=lambda x: (x[0], x[1], x[2]), reverse=True)

        out, used = {}, set()
        for prim, sec, _order, a, c in pairs:
            if a in out or c["ref"] in used:
                continue
            if prim >= 1 or sec >= 0.40:
                out[a] = (c, how if how == "short" else ("parl-date+title"
                          if prim else "date+title"), max(sec, prim / 4.0))
                used.add(c["ref"])
        for a in anrs:
            out.setdefault(a, (None, None, 0.0))
        return out


# --------------------------------------------------------------------------
# Pipeline
# --------------------------------------------------------------------------
def load_csv():
    with open(CSV_PATH, encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def counts_to_buckets(counts_for_fraction):
    return {b: counts_for_fraction.get(b, 0) for b in ("yes", "no", "abstain", "absent")}


def run(limit=None):
    os.makedirs(OUT, exist_ok=True)
    session = L.PoliteSession(min_interval=0.12)
    odata = ODataClient(session)
    pdfindex = PdfIndex(INDEX_PATH)

    all_rows = load_csv()
    rows = all_rows[:limit] if limit else all_rows
    # group a business's drafts together so the PDF regime can hand each draft a
    # distinct roll-call PDF; Stichfragen (rechtsform 5) are referendum
    # tie-breaks, never a parliamentary final vote, so they are excluded here.
    rows_by_short = defaultdict(list)
    for r in all_rows:
        if (r.get("rechtsform") or "").strip() != "5":
            rows_by_short[L.business_short_norm(r["gesch_nr"])].append(r)
    pdf_group_cache = {}
    manual = load_manual_pdfs()
    # Amtliches-Bulletin name-list pages (leg 44/45, pre-Dec-1999), resolved to
    # per-fraction tallies via a date-accurate OData roster (source "ab").
    ab_votes, ab_reports = ab_parse.load_ab_votes(session)
    # A provided AB page that did not resolve (validation failure, or the page
    # holds other drafts than the target anr) is worth flagging — it needs a
    # better page, not a silent 'unavailable'.
    _ab_unresolved = [r for r in ab_reports
                      if (("ok" in r and not r["ok"])
                          or ("skip" in r and "not in CSV" not in r["skip"]
                              and not r.get("expected")))]
    for r in _ab_unresolved:
        why = "; ".join(r["flags"]) if r.get("flags") else r.get("skip", "")
        print(f"  AB unresolved: anr {r.get('anr')} ({r.get('file')}) — {why}")

    long_rows, wide_rows, member_rows, report_rows = [], [], [], []
    all_fraction_codes = set()

    for i, row in enumerate(rows):
        anr = row["anr"]
        gesch = row["gesch_nr"]
        entwurf = (row.get("entwurf_nr") or "").strip()
        bn = L.gesch_to_business_number(gesch)
        short = L.business_short_norm(gesch)
        parl_date = datparl_to_pdf(row.get("dat-parl"))
        base = {
            "anr": anr, "gesch_nr": L.gesch_display(gesch), "entwurf_nr": entwurf,
            "referendum_date": row["datum"], "parl_date": row.get("dat-parl", ""),
            "title_short": row["titel_kurz_d"],
        }

        votes = []            # list of (meta, counts, group_names, members)
        source = "unavailable"
        note = ""

        if (row.get("rechtsform") or "").strip() == "5":
            # Stichfrage: the referendum tie-break question, decided at the ballot
            # box — there is no parliamentary Schlussabstimmung for it.
            report_rows.append({**base, "source": "unavailable", "n_votes": 0,
                                "vote_refs": "",
                                "note": "Stichfrage (referendum tie-break; no "
                                "parliamentary final vote)"})
            continue

        if norm_anr(anr) in manual:
            # hand-collected PDF takes precedence (fills OData/PDF-index gaps)
            source = "pdf_manual"
            for v in manual[norm_anr(anr)]:
                votes.append(v)
            note = "from provided PDF: " + ";".join(
                sorted({v["source_file"] for v in votes})) + \
                ("" if all(v.get("is_final") for v in votes)
                 else " (proxy: not labelled Schlussabstimmung)")
        elif norm_anr(anr) in ab_votes:
            # Amtliches-Bulletin name-list page resolved to per-fraction tallies
            source = "ab"
            v = ab_votes[norm_anr(anr)]
            votes.append(v)
            note = (f"Amtliches Bulletin {v['source_file']} (Ref {v['vote_ref']}); "
                    f"names resolved to {v['ab_report']['roster_n']}-member "
                    f"date-accurate NR roster")
            if v["ab_report"].get("warnings"):
                note += " | " + "; ".join(v["ab_report"]["warnings"])
        elif bn is not None:
            sa = api_schlussabstimmungen(odata, bn)
            if sa:
                source = "api"
                sa = _select_bills(sa, entwurf)
                for v in sa:
                    votes.append(v)
            else:
                # PDF regime (leg 46, Dec 1999 - Oct 2003). Assign the whole
                # business at once so each draft gets its own distinct PDF.
                if short not in pdf_group_cache:
                    blob = odata.business_blob(bn)
                    sa_dates = odata.nr_schlussabstimmung_dates(bn)
                    pdf_group_cache[short] = pdfindex.match_business(
                        rows_by_short.get(short, [row]), sa_dates, blob, short)
                rec, how, score = pdf_group_cache[short].get(
                    norm_anr(anr), (None, None, 0.0))
                if rec:
                    source = "pdf"
                    note = f"match={how} score={score:.2f}"
                    votes.append({
                        "vote_ref": rec.get("ref"), "leg": rec.get("leg"),
                        "vote_date": rec.get("date"),
                        "bill_number": None, "bill_title": rec.get("title"),
                        "counts": rec.get("counts", {}),
                        "group_names": {c: L.fraction_name(c) for c in rec.get("counts", {})},
                        "members": rec.get("members", []),
                        "n_members": rec.get("n_members"),
                    })
                else:
                    sa_dates = odata.nr_schlussabstimmung_dates(bn)   # disk-cached
                    if not sa_dates and not parl_date:
                        note = ("Schlussabstimmung predates online PDFs (before "
                                "Dec 1999) or no NR final vote")
                    else:
                        dd = parl_date or sorted({d for d, _ in sa_dates})
                        note = f"NR final vote on {dd} but no matching PDF"

        # emit
        if not votes:
            report_rows.append({**base, "source": source, "n_votes": 0,
                                "vote_refs": "", "note": note})
            continue

        report_rows.append({
            **base, "source": source, "n_votes": len(votes),
            "vote_refs": ";".join(str(v["vote_ref"]) for v in votes),
            "vote_urls": ";".join(u for v in votes if (u := _vote_url(v))),
            "note": note,
        })

        for v in votes:
            # On a 'Bundesbeschluss über die Volksinitiative ...' a roll-call Ja
            # is (almost always) a vote to RECOMMEND REJECTION, so it is inverted
            # relative to "support for the proposal's substance". The AB source
            # already carries an explicit flag (from the CSV legal form)
            # for other sources it is detected from the bill title
            is_init = v.get("bill_is_initiative")
            if is_init is None:
                is_init = 1 if "olksinitiative" in (v.get("bill_title") or "") else 0
            # --- verified per-anr overrides (review 2026-07; ground truth:
            # Swissvotes Position des Parlaments + OData MeaningYes) ---------
            # NOT inverted: direct counter-proposals whose BB title mentions the
            # Volksinitiative (title heuristic false positives), the UNO
            # initiative (parliament recommended ACCEPTANCE), and 544 (title
            # contains 'Volksinitiative' but is an ordinary Bundesbeschluss).
            # Inverted: initiative BBs the title heuristic missed.
            _INV_OVERRIDE = {
                "485": 0, "504": 0, "541": 0, "544": 0, "552.2": 0, "558": 0,
                "563": 0, "578": 0, "581": 0, "613": 0, "620": 0, "682.2": 0,
                "556": 1, "593": 1, "658": 1,
            }
            inv = _INV_OVERRIDE.get(str(anr), is_init)
            vinfo = {
                "vote_ref": v["vote_ref"], "leg": v["leg"], "vote_date": v["vote_date"],
                "bill_number": v.get("bill_number"), "bill_title": v.get("bill_title"),
                "bill_is_initiative": is_init, "roll_call_inverted": inv,
                "vote_url": _vote_url(v),
            }
            # long + wide
            wide = {**base, "source": source, **vinfo}
            for code, c in sorted(v["counts"].items()):
                b = counts_to_buckets(c)
                all_fraction_codes.add(code)
                total = b["yes"] + b["no"] + b["abstain"] + b["absent"]
                long_rows.append({
                    **base, "source": source, **vinfo,
                    "fraction_code": code,
                    "fraction_name": v["group_names"].get(code, L.fraction_name(code)),
                    "yes": b["yes"], "no": b["no"], "abstain": b["abstain"],
                    "absent": b["absent"], "total": total,
                })
                wide[f"{code}_yes"] = b["yes"]
                wide[f"{code}_no"] = b["no"]
                wide[f"{code}_abstain"] = b["abstain"]
                wide[f"{code}_absent"] = b["absent"]
            wide_rows.append(wide)
            # members
            for m in v.get("members", []):
                member_rows.append({
                    **base, "source": source, "vote_ref": v["vote_ref"],
                    "mp_name": m.get("name"), "fraction_code": m.get("fraction"),
                    "fraction_name": v["group_names"].get(m.get("fraction"),
                                                          L.fraction_name(m.get("fraction"))),
                    "canton": m.get("canton"), "decision": m.get("bucket"),
                })

        if (i + 1) % 25 == 0:
            odata.save()
            print(f"  processed {i+1}/{len(rows)} bills...", flush=True)

    odata.save()
    _write_outputs(long_rows, wide_rows, member_rows, report_rows, sorted(all_fraction_codes))
    _print_summary(report_rows)


def _select_bills(sa_list, entwurf):
    """API: pick the Schlussabstimmung(en) matching the CSV draft number."""
    if entwurf and entwurf.isdigit():
        m = [v for v in sa_list if str(v.get("bill_number")) == entwurf]
        if m:
            return m
    return sa_list


def _write_outputs(long_rows, wide_rows, member_rows, report_rows, codes):
    # long
    long_cols = ["anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
                 "title_short", "source", "vote_ref", "leg", "vote_date",
                 "bill_number", "bill_title", "bill_is_initiative", "roll_call_inverted",
                 "vote_url", "fraction_code", "fraction_name",
                 "yes", "no", "abstain", "absent", "total"]
    _csv(os.path.join(OUT, "fraktionen_long.csv"), long_cols, long_rows)

    # wide
    base_cols = ["anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
                 "title_short", "source", "vote_ref", "leg", "vote_date",
                 "bill_number", "bill_title", "bill_is_initiative", "roll_call_inverted",
                 "vote_url"]
    frac_cols = []
    for c in codes:
        frac_cols += [f"{c}_yes", f"{c}_no", f"{c}_abstain", f"{c}_absent"]
    _csv(os.path.join(OUT, "fraktionen_wide.csv"), base_cols + frac_cols, wide_rows)

    # members
    mem_cols = ["anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
                "title_short", "source", "vote_ref", "mp_name", "fraction_code",
                "fraction_name", "canton", "decision"]
    _csv(os.path.join(OUT, "fraktionen_members.csv"), mem_cols, member_rows)

    # report
    rep_cols = ["anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
                "title_short", "source", "n_votes", "vote_refs", "vote_urls", "note"]
    _csv(os.path.join(OUT, "fraktionen_report.csv"), rep_cols, report_rows)


def _csv(path, cols, rows):
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"  wrote {path}  ({len(rows)} rows)")


def _print_summary(report_rows):
    from collections import Counter
    c = Counter(r["source"] for r in report_rows)
    print("\n=== SUMMARY ===")
    print(f"bills total:           {len(report_rows)}")
    print(f"  via OData (api):     {c.get('api', 0)}")
    print(f"  via PDF (pdf):       {c.get('pdf', 0)}")
    print(f"  via PDF (manual):    {c.get('pdf_manual', 0)}")
    print(f"  via Amtl.Bull. (ab): {c.get('ab', 0)}")
    print(f"  unavailable:         {c.get('unavailable', 0)}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=None, help="process only first N bills (testing)")
    args = ap.parse_args()
    run(limit=args.limit)

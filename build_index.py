#!/usr/bin/env python3
"""
build_index.py — Enumerate the Nationalrat roll-call PDFs for the legislatures
that the OData API does NOT cover (44, 45, 46 -> roughly 1995-2003) and build a
local index keyed by business number.

The OData service only goes back to the 47th legislature (Winter session 2003).
For older final votes the only source is the PDFs at

    https://www.parlament.ch/poly/Abstimmung/<leg>/out/vote_<leg>_<ref>.pdf

Within a legislature only the *recorded* (namentlich) votes have a PDF, and the
ref numbers are scattered across the legislature's full vote count, so having
to probe each ref. The scan is:
  * polite     — global rate cap (PoliteSession), backoff on 403,
  * resumable  — every checked ref is remembered in cache/scan_state.json,
  * cached     — every found PDF is parsed once and stored in cache/pdf_index.json
                 (raw bytes kept under cache/pdfs/ for provenance).

Run it as a one-off (it can be re-run safely; it resumes):

    python3 build_index.py --legs 46 45 44 --max-ref 5200

Progress lines go to stdout so it can be watched while running in the background.
"""

import os
import sys
import json
import time
import argparse
import concurrent.futures as cf

import parl_lib as L

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "cache")
PDF_DIR = os.path.join(CACHE, "pdfs")
INDEX_PATH = os.path.join(CACHE, "pdf_index.json")
STATE_PATH = os.path.join(CACHE, "scan_state.json")


def load_json(path, default):
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return default


def save_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def reparse():
    """Rebuild pdf_index.json from the cached PDF files, no network.
    Use after changing the parser in parl_lib.py."""
    import glob, re
    index = {}
    files = sorted(glob.glob(os.path.join(PDF_DIR, "vote_*.pdf")))
    print(f"re-parsing {len(files)} cached PDFs ...", flush=True)
    for n, f in enumerate(files):
        m = re.search(r"vote_(\d+)_(\d+)\.pdf$", f)
        if not m:
            continue
        leg, ref = int(m.group(1)), int(m.group(2))
        try:
            rec = L.parse_pdf(open(f, "rb").read())
        except Exception as e:
            rec = {"parse_error": str(e)}
        if rec:
            rec["leg"], rec["ref"], rec["url"] = leg, ref, L.pdf_url(leg, ref)
            index[f"{leg}:{ref}"] = rec
        if (n + 1) % 200 == 0:
            print(f"  {n+1}/{len(files)}", flush=True)
    save_json(INDEX_PATH, index)
    finals = sum(1 for v in index.values() if v.get("is_final"))
    print(f"re-parsed {len(index)} PDFs, {finals} final votes -> {INDEX_PATH}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    # Only the 46th legislature (Dec 1999 - Oct 2003) has roll-call PDFs online
    # at this path. Legs 44/45 (1991-1999) were verified to return 404s.
    ap.add_argument("--legs", nargs="+", type=int, default=[46])
    ap.add_argument("--max-ref", type=int, default=5200)
    ap.add_argument("--min-ref", type=int, default=1)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--min-interval", type=float, default=0.13,
                    help="min seconds between requests (global rate cap)")
    ap.add_argument("--reparse", action="store_true",
                    help="rebuild index from cached PDFs (no network) and exit")
    args = ap.parse_args()

    if args.reparse:
        reparse()
        return

    os.makedirs(PDF_DIR, exist_ok=True)
    session = L.PoliteSession(min_interval=args.min_interval)

    index = load_json(INDEX_PATH, {})       # "leg:ref" -> parsed record (hits only)
    state = load_json(STATE_PATH, {})       # "leg" -> {"checked": [ref,...]} compacted to max contiguous + set
    # state stores, per leg, the sorted list of refs already checked (as a compact set via "done" list)
    done = {int(k): set(v.get("done", [])) for k, v in state.items()}

    def save_state():
        save_json(STATE_PATH, {str(leg): {"done": sorted(s)} for leg, s in done.items()})

    def check(leg, ref):
        url = L.pdf_url(leg, ref)
        r = session.get(url, timeout=30)
        if r is None:
            return (leg, ref, "retry", None)        # network error -> retry next run
        if r.status_code == 200 and r.content[:4] == b"%PDF":
            try:
                rec = L.parse_pdf(r.content)
            except Exception as e:
                rec = {"parse_error": str(e)}
            if rec is not None:
                # keep raw pdf for provenance / re-parsing without re-download
                with open(os.path.join(PDF_DIR, f"vote_{leg}_{ref}.pdf"), "wb") as fh:
                    fh.write(r.content)
                rec["leg"] = leg
                rec["ref"] = ref
                rec["url"] = url
                return (leg, ref, "hit", rec)
            return (leg, ref, "miss", None)
        if r.status_code == 404:
            return (leg, ref, "miss", None)          # definitively absent
        # 403 (throttle) / 5xx -> do NOT record as done; retry on a later run
        return (leg, ref, "retry", None)

    total_hits = sum(1 for k in index)
    for leg in args.legs:
        d = done.setdefault(leg, set())
        todo = [ref for ref in range(args.min_ref, args.max_ref + 1) if ref not in d]
        print(f"[leg {leg}] {len(todo)} refs to check "
              f"({len(d)} already done, {sum(1 for k in index if k.startswith(f'{leg}:'))} hits cached)",
              flush=True)
        n_done = 0
        last_save = time.time()
        n_retry = 0
        with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
            futs = {ex.submit(check, leg, ref): ref for ref in todo}
            for fut in cf.as_completed(futs):
                leg_, ref, status, rec = fut.result()
                if status != "retry":
                    d.add(ref)               # only 200/404 are definitive
                else:
                    n_retry += 1
                n_done += 1
                if status == "hit":
                    index[f"{leg_}:{ref}"] = rec
                    total_hits += 1
                    biz = rec.get("business_short")
                    fin = "FINAL" if rec.get("is_final") else "     "
                    print(f"  HIT  leg {leg_} ref {ref:>5}  {fin}  biz={biz}  "
                          f"date={rec.get('date')}  n={rec.get('n_members')}  "
                          f"subj={(rec.get('subject') or '')[:45]!r}", flush=True)
                # periodic checkpoint
                if time.time() - last_save > 20 or n_done % 500 == 0:
                    save_json(INDEX_PATH, index)
                    save_state()
                    last_save = time.time()
                    print(f"  .. leg {leg} progress {n_done}/{len(todo)}  total_hits={total_hits}", flush=True)
        save_json(INDEX_PATH, index)
        save_state()
        leg_hits = sum(1 for k in index if k.startswith(f"{leg}:"))
        leg_final = sum(1 for k, v in index.items()
                        if k.startswith(f"{leg}:") and v.get("is_final"))
        print(f"[leg {leg}] DONE — {leg_hits} PDFs found, {leg_final} final votes"
              f"{f', {n_retry} throttled (re-run to retry)' if n_retry else ''}",
              flush=True)

    save_json(INDEX_PATH, index)
    save_state()
    print(f"ALL DONE — {total_hits} PDFs in index -> {INDEX_PATH}", flush=True)


if __name__ == "__main__":
    main()

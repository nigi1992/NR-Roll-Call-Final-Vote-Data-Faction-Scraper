#!/usr/bin/env python3
"""Quick summary view over output/fraktionen_long.csv:
per-fraction Yes/No/Abstain/Absent totals and yes-rate across all matched
final votes. Writes output/fraktionen_summary.csv and prints a table.

Because fraction codes change over the decades, also rolling codes up
into stable party families for a coherent cross-time view.
"""
import csv
import os
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
LONG = os.path.join(HERE, "output", "csv", "fraktionen_long.csv")
OUT = os.path.join(HERE, "output", "csv", "fraktionen_summary.csv")

# raw PDF/API codes -> stable party family
FAMILY = {
    "S": "SP", "V": "SVP", "R": "FDP", "RL": "FDP",
    "C": "CVP/Mitte", "CE": "CVP/Mitte", "CEg": "CVP/Mitte",
    "M-E": "CVP/Mitte", "M-CEB": "CVP/Mitte",
    "G": "Grüne", "GL": "glp", "L": "Liberale (LPS)",
    "E": "EVP/EDU", "BD": "BDP", "U": "LdU", "-": "Fraktionslos",
}


def summarize(key_fn, rows):
    agg = defaultdict(lambda: {"yes": 0, "no": 0, "abstain": 0, "absent": 0,
                               "bills": set(), "opposed": 0})
    # per (key, bill) to count "opposed" bills (fraction majority voted no)
    perbill = defaultdict(lambda: defaultdict(lambda: [0, 0]))  # key -> billid -> [yes,no]
    for r in rows:
        k = key_fn(r["fraction_code"])
        billid = (r["anr"], r["vote_ref"])
        a = agg[k]
        y, n = int(r["yes"]), int(r["no"])
        a["yes"] += y
        a["no"] += n
        a["abstain"] += int(r["abstain"])
        a["absent"] += int(r["absent"])
        a["bills"].add(billid)
        pb = perbill[k][billid]
        pb[0] += y
        pb[1] += n
    for k, bills in perbill.items():
        agg[k]["opposed"] = sum(1 for b in bills.values() if b[1] > b[0])
    out = []
    for k, a in agg.items():
        cast = a["yes"] + a["no"]
        yes_rate = a["yes"] / cast if cast else None
        out.append({
            "fraction": k,
            "n_final_votes": len(a["bills"]),
            "yes": a["yes"], "no": a["no"],
            "abstain": a["abstain"], "absent": a["absent"],
            "yes_rate_of_cast": round(yes_rate, 3) if yes_rate is not None else "",
            "bills_opposed_majority": a["opposed"],
        })
    out.sort(key=lambda d: -(d["yes"] + d["no"]))
    return out


def main():
    rows = list(csv.DictReader(open(LONG, encoding="utf-8-sig")))
    by_family = summarize(lambda c: FAMILY.get(c, c), rows)
    by_code = summarize(lambda c: c, rows)

    with open(OUT, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(by_family[0].keys()))
        w.writeheader()
        w.writerows(by_family)
    print(f"wrote {OUT}\n")

    n_votes = len({(r['anr'], r['vote_ref']) for r in rows})
    print(f"Per-fraction summary across {n_votes} matched Nationalrat final votes "
          f"(1999–2026):\n")
    hdr = f"{'fraction':<16}{'votes':>6}{'yes':>8}{'no':>7}{'abst':>6}{'absent':>8}{'yes-rate':>10}{'opposed':>9}"
    print(hdr)
    print("-" * len(hdr))
    for d in by_family:
        yr = f"{d['yes_rate_of_cast']:.0%}" if d["yes_rate_of_cast"] != "" else "—"
        print(f"{d['fraction']:<16}{d['n_final_votes']:>6}{d['yes']:>8}{d['no']:>7}"
              f"{d['abstain']:>6}{d['absent']:>8}{yr:>10}{d['bills_opposed_majority']:>9}")
    print("\nyes-rate = share of *cast* (yes+no) votes that were Yes;  "
          "opposed = # final votes where the fraction's majority voted No.")


if __name__ == "__main__":
    main()

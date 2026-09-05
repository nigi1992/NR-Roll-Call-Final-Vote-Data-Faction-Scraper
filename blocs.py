#!/usr/bin/env python3
"""
blocs.py — Roll the changing fraction codes into 7 stable blocs and produce
substance-oriented predictors for modelling the national Yes-share.

Blocs (per the user's scheme; codes per 'Faktenblatt Fraktionen-d.pdf'):
    S    Sozialdemokratische Fraktion
    G    Grüne Fraktion
    GL   Grünliberale Fraktion (glp)
    ME   Mitte: C, CE, CEg, BD, M-E, M-CEB  +  E (EVP/EDU)   *see EDU note
    RL   FDP-Liberale: R, L, RL
    V    SVP-Fraktion
    other  fraktionslos: -, U, W

EDU note: the historical 'E' fraction is "EVP/EDU", so the (1-2) EDU members
can't be separated from EVP and go to ME with EVP. Modern EDU members who sit
in the SVP fraction are already counted in V.

ORIENTATION (for predicting the Yes-share):
On a 'Bundesbeschluss über die Volksinitiative' a parliamentary Ja means
"recommend rejection", so the roll call is inverted relative to support for the
proposal's substance. Therefore adding *oriented* counts where
    support = (Nein if inverted else Ja)   oppose = (Ja if inverted else Nein)
so that 'support' always means "for the thing the people vote on".
`inverted` is taken as `bill_is_initiative` (true for ~95% of initiatives —
those parliament recommends rejecting). Refine the rare exceptions
(initiative + recommend-acceptance, or counter-proposals) with the Swissvotes
`nr-pos` variable: inverted = is_initiative AND nr-pos == 2 (Ablehnend).

Outputs:
    output/fraktionen_blocs_long.csv   one row per vote x bloc (raw + oriented)
    output/fraktionen_blocs_wide.csv   one row per vote: bloc columns + predictors
"""
import os
import csv
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
LONG = os.path.join(HERE, "output", "csv", "fraktionen_long.csv")

BLOC = {
    "S": "S", "G": "G", "V": "V", "GL": "GL",
    "C": "ME", "CE": "ME", "CEg": "ME", "BD": "ME", "M-E": "ME", "M-CEB": "ME",
    "E": "ME",
    "R": "RL", "L": "RL", "RL": "RL",
    "-": "other", "U": "other", "W": "other", "FRAKTIONSLOS": "other",
}
BLOCS = ["S", "G", "GL", "ME", "RL", "V"]            # left -> right (excl. other)
LR = {"G": -8.0, "S": -6.5, "GL": -1.5, "ME": 1.5, "RL": 5.5, "V": 8.5}
# ^ indicative left-right placements, can be replaced with a researched scale

# Interpretation caveats attached to the outputs (review 2026-07):
NOTES = {
    "556": "Keine Empfehlung der Bundesversammlung (Einigungskonferenz gescheitert); Roll call = EK-Abstimmung 28.09.2011; Ja = Antrag EK-Mehrheit (= Ablehnung empfehlen)",
    "560": "Keine Empfehlung der Bundesversammlung (Einigungskonferenz gescheitert); Roll call = EK-Abstimmung 28.09.2011; Ja = Antrag EK-Mehrheit (= Annahme empfehlen)",
    "568": "Keine Empfehlung der Bundesversammlung: BB in der Schlussabstimmung 15.06.2012 abgelehnt (87:104); support-Seite = Nein-Stimmen, Vorsicht (taktisches Nein von links UND rechts)",
    "582": "Keine Empfehlung der Bundesversammlung (SR dagegen); NR-Position laut Swissvotes: Befuerwortend 97:91, konsistent mit support-Orientierung hier",
    "552.1": "Gruene stimmten Nein zum BB aus Ablehnung des Gegenentwurfs, nicht aus Unterstuetzung der Initiative",
    "465.1": "BB kombinierte Ablehnungs-Empfehlung mit Unterbreitung des Gegenentwurfs; Nein-Stimmen (RL/V) galten dem Gegenentwurf - nicht als Unterstuetzung der Solar-Initiative lesen (Swissvotes NR-Position: Ablehnend 63:125)",
    "485": "Parlament empfahl ANNAHME der UNO-Initiative (NR 147:39) - Roll call nicht invertiert",
    "620": "Vote = direkter Gegenentwurf 'Velowege' (Entwurf 2, reg 16712) = Abstimmungsvorlage",
}


def run():
    rows = list(csv.DictReader(open(LONG, encoding="utf-8-sig")))
    votes = defaultdict(lambda: {"meta": None,
                                 "blocs": defaultdict(lambda: [0, 0, 0, 0])})
    for r in rows:
        key = (r["anr"], r["vote_ref"])
        bloc = BLOC.get(r["fraction_code"], "other")
        v = votes[key]
        v["meta"] = r
        b = v["blocs"][bloc]
        b[0] += int(r["yes"]); b[1] += int(r["no"])
        b[2] += int(r["abstain"]); b[3] += int(r["absent"])

    long_out, wide_out = [], []
    for (anr, ref), v in votes.items():
        m = v["meta"]
        inverted = (m.get("roll_call_inverted") or m.get("bill_is_initiative") or "0") == "1"
        base = {k: m.get(k, "") for k in (
            "anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
            "title_short", "source", "vote_ref", "leg", "vote_date", "vote_url",
            "bill_title", "bill_is_initiative")}
        base["roll_call_inverted"] = 1 if inverted else 0
        base["note"] = NOTES.get(anr, "")
        wide = dict(base)
        majority_support = []
        cue_num = cue_den = 0.0
        for bloc in BLOCS + ["other"]:
            ja, nein, enth, abw = v["blocs"].get(bloc, [0, 0, 0, 0])
            if bloc == "GL" and not any((ja, nein, enth, abw)):
                # structural NA: the glp fraction did not exist for this vote
                long_out.append({**base, "bloc": bloc, "ja": "", "nein": "",
                                 "enthaltung": "", "abwesend": "",
                                 "support": "", "oppose": "", "support_share": ""})
                for suf in ("ja", "nein", "enth", "abw", "support", "oppose"):
                    wide[f"GL_{suf}"] = ""
                continue
            support = nein if inverted else ja        # for the proposal substance
            oppose = ja if inverted else nein
            cast = support + oppose
            long_out.append({**base, "bloc": bloc,
                             "ja": ja, "nein": nein, "enthaltung": enth, "abwesend": abw,
                             "support": support, "oppose": oppose,
                             "support_share": round(support / cast, 3) if cast else ""})
            wide[f"{bloc}_ja"] = ja
            wide[f"{bloc}_nein"] = nein
            wide[f"{bloc}_enth"] = enth
            wide[f"{bloc}_abw"] = abw
            if bloc in BLOCS:
                wide[f"{bloc}_support"] = support
                wide[f"{bloc}_oppose"] = oppose
                if cast:
                    if support > oppose:
                        majority_support.append(bloc)
                    cue_num += LR[bloc] * support
                    cue_den += support
        wide["support_coalition"] = "+".join(majority_support) if majority_support else "none"
        wide["elite_cue_lr"] = round(cue_num / cue_den, 2) if cue_den else ""
        wide_out.append(wide)

    long_cols = ["anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
                 "title_short", "source", "vote_ref", "leg", "vote_date", "vote_url",
                 "bill_title", "bill_is_initiative", "roll_call_inverted",
                 "bloc", "ja", "nein", "enthaltung", "abwesend",
                 "support", "oppose", "support_share", "note"]
    _csv(os.path.join(HERE, "output", "csv", "fraktionen_blocs_long.csv"), long_cols, long_out)

    bloc_cols = []
    for b in BLOCS:
        bloc_cols += [f"{b}_ja", f"{b}_nein", f"{b}_enth", f"{b}_abw",
                      f"{b}_support", f"{b}_oppose"]
    bloc_cols += ["other_ja", "other_nein", "other_enth", "other_abw"]
    wide_cols = (["anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
                  "title_short", "source", "vote_ref", "leg", "vote_date", "vote_url",
                  "bill_title", "bill_is_initiative", "roll_call_inverted"]
                 + bloc_cols + ["support_coalition", "elite_cue_lr", "note"])
    _csv(os.path.join(HERE, "output", "csv", "fraktionen_blocs_wide.csv"), wide_cols, wide_out)


def _csv(path, cols, rows):
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader(); w.writerows(rows)
    print(f"wrote {path}  ({len(rows)} rows)")


if __name__ == "__main__":
    run()

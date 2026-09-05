#!/usr/bin/env python3
"""
ab_parse.py — Recover per-fraction Nationalrat final-vote (Schlussabstimmung)
tallies for the 1994-1999 bills (legislatures 44/45) from the digitised
*Amtliches Bulletin* "Schlussabstimmungen" pages.

For these bills the per-member roll-call PDFs do not exist online (leg 45 returns
404), so the AB name-lists are the only source. Each collected page (under
``cache/neue pdfs/kompliziert/<bizid>-<anr[,anr]>.pdf``) is a session-day AB page
holding several bills, only the named ``anr``(s) are relevant.

How it works
------------
1. Read every content page with a **column-aware** extractor (the AB is printed
   in two columns, a bill's name lists routinely span the column break).
2. Split the ordered lines into *vote blocks* — each anchored by
   ``Namentliche Abstimmung`` / ``(Ref.: N)`` followed by the buckets
   ``Für Annahme`` (yes) / ``Dagegen`` (no) / ``enthalten`` (abstain) /
   ``Entschuldigt/abwesend`` (absent) / ``Präsidium`` (president).
3. Group the blocks into *drafts*: a draft's title comes from its first block,
   a block flagged "Ich wiederhole die Abstimmung" (a corrected re-vote)
   supersedes the previous one of the same draft (keep the highest ``Ref``).
4. For a target ``anr`` (with its ``gesch_nr`` / ``dat-parl`` from
   ``Fraktion_Scraping.csv``) pick the matching draft by business number +
   title overlap, then resolve every name against a **date-accurate** roster
   built from OData (``MemberParlGroupHistory`` ∩ ``MemberCouncilHistory`` for
   the Nationalrat on ``dat-parl``).
5. **Validate**: the parsed yes/no/abstain counts must equal the printed ``(N)``
   per bucket and every name must resolve to exactly one roster member, the
   ``absent`` bucket is reconstructed as ``roster − (yes∪no∪abstain∪president)``
   so a page truncated after the abstain list (e.g. 99.028) is still usable.

The fraction code emitted is the OData ``ParlGroupAbbreviation`` (S, RL, M-E, V,
G, F, L, U, …), i.e. the same modern coding ``blocs.py`` already rolls up.
"""

import os
import re
import csv
import json
import glob
import urllib.parse
from collections import defaultdict, Counter

import pdfplumber

import parl_lib as L

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "cache")
KOMPLIZIERT = os.path.join(CACHE, "neue pdfs", "kompliziert")
ROSTER_CACHE = os.path.join(CACHE, "ab_roster_cache.json")
CSV_PATH = os.path.join(HERE, "Fraktion_Scraping.csv")
ODATA = "https://ws.parlament.ch/odata.svc"

# --------------------------------------------------------------------------
# Text normalisation + roster
# --------------------------------------------------------------------------
_TRANSLIT = (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss"), ("é", "e"),
             ("è", "e"), ("ê", "e"), ("ë", "e"), ("à", "a"), ("â", "a"),
             ("ç", "c"), ("ô", "o"), ("î", "i"), ("ï", "i"), ("û", "u"))


def _translit(x):
    x = (x or "").lower()
    for a, b in _TRANSLIT:
        x = x.replace(a, b)
    return x


def _norm(x):
    """Normalised match key: transliterate umlauts, drop everything non-alnum."""
    return re.sub(r"[^a-z0-9]+", "", _translit(x))


# function words that show up in many titles (both German + French halves are
# captured) and would otherwise create spurious overlaps.
_STOP = {"fuer", "ein", "eine", "einen", "einem", "einer", "und", "oder", "der",
         "die", "das", "den", "dem", "des", "von", "vom", "zur", "zum", "ueber",
         "aus", "auf", "mit", "bei", "pour", "dans", "sur", "les", "des", "une",
         "aux", "par", "avec", "entre", "contre", "sont", "dont"}


def _tok(x):
    """Token set for title overlap (words > 3 chars, function words dropped).
    German initiative names are often one compound ('Solarinitiative') in the CSV
    but spaced ('Solar-Initiative') in the AB, so a '…initiative' compound also
    yields its stem ('solar') and 'initiative'."""
    out = set()
    for w in re.split(r"[^a-z0-9]+", _translit(x)):
        if len(w) > 3 and w not in _STOP:
            out.add(w)
            if w.endswith("initiative") and len(w) > len("initiative") + 3:
                out.add(w[:-len("initiative")])
                out.add("initiative")
    return out


class Roster:
    """Date-accurate Nationalrat roster + a tiered name index, OData-backed."""

    def __init__(self, session):
        self.s = session
        self.bydate = {}
        self._disk = {}
        if os.path.exists(ROSTER_CACHE):
            try:
                self._disk = json.load(open(ROSTER_CACHE, encoding="utf-8"))
            except Exception:
                self._disk = {}

    def save(self):
        json.dump(self._disk, open(ROSTER_CACHE, "w", encoding="utf-8"),
                  ensure_ascii=False)

    def _get(self, path):
        r = self.s.get(ODATA + path, accept="application/json", timeout=60)
        if r is None or r.status_code != 200:
            return []
        d = r.json().get("d", [])
        return d["results"] if isinstance(d, dict) else d

    def for_date(self, date_iso):
        """date_iso = 'YYYY-MM-DD' -> list of member dicts (cached on disk)."""
        if date_iso in self.bydate:
            return self.bydate[date_iso]
        if date_iso in self._disk:
            roster = self._disk[date_iso]
            self.bydate[date_iso] = roster
            return roster
        # The CSV dat-parl can be the session's final-votes day while a given
        # bill was actually voted a few days earlier, a member who left
        # mid-session would then be missing on the exact date. Allow a small
        # 10-day grace on the DateLeaving bound so such within-session voters are
        # still in the roster (extra members only land in reconstructed 'absent').
        # Kept tight so it doesn't straddle a December legislature turnover.
        import datetime
        lo = (datetime.date.fromisoformat(date_iso)
              - datetime.timedelta(days=10)).isoformat()
        flt = (f"Language eq 'DE' and DateJoining le datetime'{date_iso}T00:00:00' "
               f"and (DateLeaving ge datetime'{lo}T00:00:00' or DateLeaving eq null)")
        q = urllib.parse.quote(flt)
        pg = self._get(f"/MemberParlGroupHistory?$filter={q}"
                       f"&$select=PersonNumber,LastName,FirstName,ParlGroupAbbreviation,"
                       f"ParlGroupName&$top=400&$format=json")
        qc = urllib.parse.quote(flt + " and Council eq 1")
        ch = self._get(f"/MemberCouncilHistory?$filter={qc}"
                       f"&$select=PersonNumber,OfficialName,CantonAbbreviation,"
                       f"ParlGroupAbbreviation&$top=400&$format=json")
        chby = {r["PersonNumber"]: r for r in ch}
        roster = []
        for r in pg:
            pn = r["PersonNumber"]
            if pn not in chby:          # Ständerat -> skiping, keeping Nationalrat
                continue
            c = chby[pn]
            roster.append({"pn": pn, "last": r["LastName"], "first": r["FirstName"],
                           "abbr": r["ParlGroupAbbreviation"],
                           "name": r["ParlGroupName"],
                           "official": c.get("OfficialName") or "",
                           "canton": c.get("CantonAbbreviation")})
        self._disk[date_iso] = roster
        self.bydate[date_iso] = roster
        return roster

    @staticmethod
    def index(roster):
        """Tiered match index: A=identity (last / official name),
        B=last+first, C=first-word-of-multiword-last."""
        A, B, C = defaultdict(list), defaultdict(list), defaultdict(list)
        for m in roster:
            last, first, off = m["last"], m["first"], m["official"]
            A[_norm(last)].append(m)
            if off:
                A[_norm(off)].append(m)
            ft = first.replace(".", " ").split()
            B[_norm(last + first)].append(m)
            for t in ({ft[0], ft[-1]} if ft else set()):
                B[_norm(last + t)].append(m)
            # first component of a multi-part surname — the AB often prints only
            # that (Roth-Bernasconi -> "Roth", Aeppli Wartmann -> "Aeppli"),
            # whether the parts are space- or hyphen-joined.
            lw = re.split(r"[ \-]", last)
            if len(lw) > 1 and lw[0]:
                C[_norm(lw[0])].append(m)
                if ft:
                    C[_norm(lw[0] + ft[0])].append(m)
        return A, B, C


# bloc map (only used here to allow same-bloc ambiguity to resolve quietly,
# the real roll-up lives in blocs.py, which understands these same codes).
_BLOC = {"S": "S", "G": "G", "V": "V", "GL": "GL", "M-E": "ME", "RL": "RL",
         "L": "RL", "F": "other", "U": "other", "FRAKTIONSLOS": "other"}


def _lev(a, b, maxd):
    """Bounded Levenshtein distance, returns >maxd if it exceeds the cap."""
    la, lb = len(a), len(b)
    if abs(la - lb) > maxd:
        return maxd + 1
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        cur = [i] + [0] * lb
        row_best = cur[0]
        ca = a[i - 1]
        for j in range(1, lb + 1):
            cost = 0 if ca == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            row_best = min(row_best, cur[j])
        if row_best > maxd:
            return maxd + 1
        prev = cur
    return prev[lb]


def _resolve(members):
    """A list of candidate roster members -> (member, reason) or (None, reason)."""
    uniq = list({m["pn"]: m for m in members}.values())
    if len(uniq) == 1:
        return uniq[0], None
    if len({_BLOC.get(m["abbr"], "other") for m in uniq}) == 1:
        return uniq[0], "ambiguous-same-bloc"
    return None, "ambiguous:" + ",".join(sorted(f"{m['last']}/{m['abbr']}" for m in uniq))


def match_name(ab, idx):
    """Resolve an AB name string to one roster member. Returns (member, reason),
    member None on failure. Tries, in order: exact tiered keys, a last-name prefix
    (dropping a differing first name, e.g. AB 'Eberhard Anton' vs roster
    'Eberhard Toni' — unique surname), then an OCR-tolerant fuzzy match (the
    1994–95 scans corrupt letters, e.g. 'von Feiten'->Felten, 'Verterli'->Vetterli)."""
    A, B, C = idx
    n = _norm(ab)
    for tier in idx:
        if n in tier:
            return _resolve(tier[n])
    # last-name prefix: drop trailing (first-name) tokens, keep a unique surname
    toks = ab.split()
    for k in range(len(toks) - 1, 0, -1):
        pn = _norm(" ".join(toks[:k]))
        if pn in A:
            uniq = list({m["pn"]: m for m in A[pn]}.values())
            if len(uniq) == 1:
                return uniq[0], "surname-only"
    # fuzzy (OCR): nearest key in the identity / last+first tiers
    if len(n) >= 4:
        maxd = 1 if len(n) < 5 else 2     # OCR tolerance
        best_d, hits = maxd + 1, []
        for tier in (A, B):
            for key, members in tier.items():
                d = _lev(n, key, maxd)
                if d > maxd:           # over the cap -> not a candidate
                    continue
                if d < best_d:
                    best_d, hits = d, list(members)
                elif d == best_d:
                    hits += members
        if hits:
            m, why = _resolve(hits)
            if m:
                return m, f"fuzzy~{best_d}"
            return None, why
    return None, "no-match"


# --------------------------------------------------------------------------
# AB page parsing
# --------------------------------------------------------------------------
_MONTHS = (r"Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|"
           r"November|Dezember|janvier|février|mars|avril|mai|juin|juillet|août|"
           r"septembre|octobre|novembre|décembre")
_NOISE = re.compile(
    r"^(Amtliches Bulletin|Bulletin officiel|Bollettino|Votations? finales?|"
    r"\d+\s+Schlussabstimmungen|\d+\s+Votations|Schlussabstimmungen|"
    # running page header: a bare date with a month name, in any of the odd
    # OCR spacings seen ('N9 octobre 199 8', '18. Juni 1999N', '1405 N',
    # '18. März 1994 N 667'), optional leading/trailing 'N' and page number.
    r"N?\s*\d{0,2}\.?\s*(" + _MONTHS + r")[\dN .]*$|"
    r"\d{1,4}\s*N$|N\s*\d{1,4}$|#\w{0,3}#|"
    r"Communications? (de|du)|Mitteilungen des|Kommuniké|"
    r".*Bundesversammlung$|.*Assemblée fédérale$|f[üu]r das Amtliche|"
    r"Schweizerisches Bundesarchiv|Archives fédérales|Archivio federale)", re.I)
_HEAD = {
    "yes": re.compile(r"F[üu]r (den |die )?Annahme des Entwurfes|Acceptent le projet", re.I),
    "no": re.compile(r"Dagegen stimmen|Rejettent le projet|Gegen den Entwurf|"
                     r"Ablehnung des Entwurfes", re.I),
    "abstain": re.compile(r"Der Stimme enthalten|abstiennent", re.I),
    "absent": re.compile(r"Entschuldigt|abwesend sind|Abwesend sind|"
                         r"Sont excus|Sont absents", re.I),
    "president": re.compile(r"Pr[äae]sid(ium|ent|entin).*stimmt nicht|"
                            r"[Pp]r[ée]siden.*ne vote|sidence.*ne vote", re.I),
    # 'present but did not vote' — recognised only to terminate the previous
    # bucket, these members are folded into the reconstructed 'absent'.
    "novote": re.compile(r"Stimmen nicht|Ne votent pas", re.I),
}
_REF = re.compile(r"\(Ref\.?:?\s*0*(\d+)\)")
_BIZ = re.compile(r"^(\d{2}\.\d{3})\s*$")
_NAMENTLICH = re.compile(r"Namentliche\s+(Schluss)?[Aa]bstimmung|Vote nominatif|"
                         r"appel nominal", re.I)
_COUNT_END = re.compile(r"\(\s*(\d+)\s*\)\s*$")
_REPEAT = re.compile(r"wiederhol|Wiederholung der Abstimmung|r[ée]it[ée]r|r[ée]p[èé]t", re.I)
_LETTER = re.compile(r"^([A-C])\.\s+\S")
_TITLEY = re.compile(r"Bundesgesetz|Bundesbeschluss|Arr[êe]t[ée] f[ée]d|Loi f[ée]d|"
                     r"Volksinitiative|initiative populaire|Code|Schweizerisches", re.I)
_SEP = re.compile(r"^_{5,}$|Schlussabstimmung\s*[–-]\s*Vote final|^Siehe Seite|"
                  r"^Voir page|^Beschluss des|^D[ée]cision du|\(.*Beifall\)|"
                  r"\(.*Unruhe\)|\(Applaud|\(Teilweis|brouhaha|^Pr[äa]sident", re.I)
_SPEAKER = re.compile(r"^[A-ZÄÖÜ][\wäöü\-]+.*\([A-Z][^)]*,\s*[A-Z]{2}\)\s*:")


def _col_lines(page):
    """Two-column-aware line reconstruction: col0 (left) lines then col1."""
    w = page.width
    cols = {0: [], 1: []}
    for wd in page.extract_words(use_text_flow=False):
        cols[0 if (wd["x0"] + wd["x1"]) / 2 < w / 2 else 1].append(wd)
    out = []
    for c in (0, 1):
        ws = sorted(cols[c], key=lambda x: (round(x["top"] / 3), x["x0"]))
        line, lt = [], None
        for x in ws:
            if lt is None or abs(x["top"] - lt) < 3:
                line.append(x["text"])
            else:
                out.append(" ".join(line))
                line = [x["text"]]
            lt = x["top"]
        if line:
            out.append(" ".join(line))
    return out


# a running header spliced *inside* a line by the OCR, e.g.
# 'Fischer-Hägg668 N 18 mars 1994 lingen' or '1968 N 7 octobre 1994 Schweingruber'
_INLINE_HDR = re.compile(r"\s*\d{0,4}\s*N\s*\d{1,2}\.?\s*(" + _MONTHS + r")\s*\d{2,4}\s*",
                         re.I)


def _all_lines(pdfpath):
    out = []
    with pdfplumber.open(pdfpath) as pdf:
        for page in pdf.pages:
            for ln in _col_lines(page):
                t = _INLINE_HDR.sub(" ", ln)
                t = re.sub(r"#\w{0,4}#", " ", t).strip()   # stray OCR markers
                if t and not _NOISE.match(t):
                    out.append(t)
    return out


def _join_names(lines):
    """Concatenate wrapped name-list lines. A trailing '-' is a line-break wrap:
    keep it only if the continuation is a real compound (next part capitalised,
    e.g. Müller-/Hemmi -> Müller-Hemmi), otherwise it is a syllable split
    (Witten-/wiler -> Wittenwiler, Pi-/doux -> Pidoux)."""
    out = ""
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        if not out:
            out = ln
        elif out.endswith("-"):
            core = out[:-1]
            out = core + "-" + ln if ln[:1].isupper() else core + ln
        else:
            out = out + " " + ln
    return out


def _split_names(text):
    m = _COUNT_END.search(text)
    printed = int(m.group(1)) if m else None
    if m:
        text = text[:m.start()]
    # the old scans sometimes glue two names with a '.' instead of ', '
    # ('Zisyadis.Zölch', 'Steiger Hans.Zwygart') — split on a lower.Upper period.
    text = re.sub(r"(?<=[a-zäöü])\.(?=[A-ZÄÖÜ])", ",", text)
    names = [p.strip(" .") for p in text.split(",")]
    return [p for p in names if p], printed


def parse_blocks(lines):
    """Ordered list of vote blocks: {ref, pos, biz, title, letter, repeat, buckets}.
    Anchored on the universal 'Für Annahme des Entwurfes' heading so it handles
    both the 1999+ layout (with a '(Ref.: N)' line) and the 1994–98 layout
    ('Namentliche Schlussabstimmung', no Ref). buckets[bucket]=(names, printed_n)."""
    yesidx = [i for i, ln in enumerate(lines) if _HEAD["yes"].search(ln)]
    blocks = []
    for k, yi in enumerate(yesidx):
        prev = yesidx[k - 1] if k > 0 else -1
        end = yesidx[k + 1] if k + 1 < len(yesidx) else len(lines)
        # the vote header sits just above the 'Für Annahme' line
        nidx = yi
        for j in range(yi - 1, prev, -1):
            if _NAMENTLICH.search(lines[j]):
                nidx = j
                break
        header = lines[prev + 1:yi]           # title / Ref / Namentliche / biz
        ref = next((int(_REF.search(g).group(1)) for g in header if _REF.search(g)), None)
        biz = next((_BIZ.match(lines[j]).group(1)
                    for j in range(yi - 1, -1, -1) if _BIZ.match(lines[j])), None)
        repeat = any(_REPEAT.search(g) for g in header)
        letter = next((_LETTER.match(g).group(1) for g in header if _LETTER.match(g)), None)
        title_lines = []
        for g in reversed(lines[prev + 1:nidx]):
            if _SEP.search(g) or _SPEAKER.search(g) or _BIZ.match(g):
                break
            title_lines.insert(0, g)
            if len(title_lines) >= 6:
                break
        title = " ".join(title_lines)
        # buckets from the 'Für Annahme' heading on, each closed by its printed (N)
        buckets = {}
        cur, acc = None, []

        def flush():
            if cur and acc:
                names, printed = _split_names(_join_names(acc))
                buckets[cur] = (names, printed)

        for ln in lines[yi:end]:
            h = next((b for b, rx in _HEAD.items() if rx.search(ln)), None)
            if h:
                flush()
                cur = h
                after = ln.split(":", 1)[1] if ":" in ln else ""
                acc = [after] if after.strip() else []
            elif cur:
                acc.append(ln)
                if _COUNT_END.search(ln):     # bucket closes at its printed (N)
                    flush()
                    cur, acc = None, []
        flush()
        blocks.append({"ref": ref, "pos": yi, "biz": biz, "title": title,
                       "letter": letter, "repeat": repeat, "buckets": buckets})
    return blocks


def group_drafts(blocks):
    """Collapse re-votes: within a business number, a 'wiederhole' block
    supersedes the previous draft (keep highest ref), distinct A./B./… or
    distinct un-lettered bills are separate drafts. Returns list of drafts
    {biz, title, ref, buckets} (title carried from the draft's first block)."""
    drafts = []
    last_for_biz = {}
    for b in blocks:
        biz = b["biz"]
        if b["repeat"] and biz in last_for_biz:
            d = last_for_biz[biz]            # corrected re-vote of the same draft
            d["ref"] = b["ref"]
            d["pos"] = b["pos"]
            d["buckets"] = b["buckets"]
            continue
        d = {"biz": biz, "title": b["title"], "ref": b["ref"], "pos": b["pos"],
             "buckets": b["buckets"], "letter": b["letter"]}
        drafts.append(d)
        last_for_biz[biz] = d
    return drafts


# --------------------------------------------------------------------------
# anr -> draft selection + name resolution
# --------------------------------------------------------------------------
def _norm_anr(a):
    a = (a or "").strip()
    try:
        f = float(a)
        return str(int(f)) if f == int(f) else a
    except ValueError:
        return a


def _dat_iso(d):
    m = re.match(r"(\d{2})/(\d{2})/(\d{4})", d or "")
    return f"{m.group(3)}-{m.group(2)}-{m.group(1)}" if m else None


def _leg_for(date_iso):
    y = int(date_iso[:4])
    m = int(date_iso[5:7])
    # legislatures start in the December after the October election
    if (y, m) >= (1995, 12) or (1996 <= y <= 1999):
        return 45 if (y, m) < (1999, 12) else 46
    if (y, m) >= (1991, 12) or (1992 <= y <= 1995):
        return 44
    return 44


def select_draft(drafts, gesch_short, titel, entwurf, strict=False):
    """Pick the draft for a target bill. A unique business-number match is
    trusted as-is. When a business has several drafts on the page (initiative +
    counter-proposal, two initiatives, …) disambiguate by title overlap, with the
    draft (entwurf) order as a tie-break. ``strict`` (used when a filename
    sub-anr like 465 is expanded to 465.1/465.2/…) requires a real title hit, so
    a sub-row that isn't actually on the page resolves to None instead of being
    forced onto a block."""
    cands = [d for d in drafts if d["biz"] == gesch_short] or drafts
    if not cands:
        return None
    if len(cands) == 1:
        return None if strict and not (_tok(titel) & _tok(cands[0]["title"])) else cands[0]
    want = _tok(titel)
    scored = sorted(cands, key=lambda d: len(_tok(d["title"]) & want), reverse=True)
    best = scored[0]
    best_score = len(_tok(best["title"]) & want)
    if best_score == 0:
        if strict:
            return None
        # no title signal at all -> fall back to draft (entwurf) order (1->A, …)
        try:
            return sorted(cands, key=lambda d: d["pos"])[int(entwurf) - 1]
        except (ValueError, TypeError, IndexError):
            return best
    # tie on title -> prefering the draft whose position matches the entwurf order
    tied = [d for d in scored if len(_tok(d["title"]) & want) == best_score]
    if len(tied) > 1:
        try:
            return sorted(tied, key=lambda d: d["pos"])[int(entwurf) - 1]
        except (ValueError, TypeError, IndexError):
            return best
    return best


def resolve_draft(draft, roster):
    """Resolve a draft's name lists against the roster. Returns
    (counts, members, report) where counts[abbr][bucket] = n and report
    carries the validation status."""
    idx = Roster.index(roster)
    by_pn = {m["pn"]: m for m in roster}
    counts = defaultdict(Counter)
    members = []
    assigned = {}                      # pn -> bucket (yes/no/abstain/president)
    flags = []                         # hard failures -> not ok
    warnings = []                      # soft notes (absent reconstruction delta)
    checks = {}
    for bucket in ("yes", "no", "abstain", "president"):
        if bucket not in draft["buckets"]:
            continue
        names, printed = draft["buckets"][bucket]
        matched = 0
        for nm in names:
            m, why = match_name(nm, idx)
            if not m:
                flags.append(f"{bucket}:{nm}({why})")
                continue
            if m["pn"] in assigned:
                flags.append(f"{bucket}:{nm}(dup of {assigned[m['pn']]})")
                continue
            assigned[m["pn"]] = bucket
            counts[m["abbr"]][bucket] += 1
            members.append({"name": f"{m['last']} {m['first']}".strip(),
                            "fraction": m["abbr"], "canton": m["canton"],
                            "bucket": bucket})
            matched += 1
        checks[bucket] = {"parsed": len(names), "printed": printed, "matched": matched}
        # hard gate on the substantive buckets
        if bucket in ("yes", "no", "abstain"):
            if printed is not None and printed != len(names):
                flags.append(f"{bucket}: parsed {len(names)} != printed {printed}")
            if matched != len(names):
                flags.append(f"{bucket}: matched {matched} != parsed {len(names)}")
    # reconstruct 'absent' as roster minus everyone who voted / chaired
    absent_pns = [pn for pn in by_pn if pn not in assigned]
    parsed_absent = draft["buckets"].get("absent", ([], None))
    for pn in absent_pns:
        m = by_pn[pn]
        counts[m["abbr"]]["absent"] += 1
        members.append({"name": f"{m['last']} {m['first']}".strip(),
                        "fraction": m["abbr"], "canton": m["canton"],
                        "bucket": "absent"})
    checks["absent"] = {"parsed": len(parsed_absent[0]),
                        "printed": parsed_absent[1],
                        "reconstructed": len(absent_pns)}
    # The yes/no/abstain buckets are the hard gate (they carry the substantive
    # vote and feed the predictor). 'absent' is reconstructed from the roster,
    # so a small delta vs the printed list only signals a roster/source vacancy
    # mismatch (the few missing members were absent anyway) -> soft warning.
    if parsed_absent[1] is not None and parsed_absent[1] != len(absent_pns):
        warnings.append(f"absent: printed {parsed_absent[1]} != reconstructed "
                        f"{len(absent_pns)} (roster {len(roster)}; non-voters only)")
    report = {"ref": draft["ref"], "biz": draft["biz"], "title": draft["title"],
              "roster_n": len(roster), "assigned": len(assigned),
              "checks": checks, "flags": flags, "warnings": warnings,
              "ok": not flags}
    return {k: dict(v) for k, v in counts.items()}, members, report


# --------------------------------------------------------------------------
# Public entry point
# --------------------------------------------------------------------------
def _load_csv():
    with open(CSV_PATH, encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def load_ab_votes(session, verbose=False):
    """Parse every kompliziert AB page and resolve its target anr(s).

    Returns {anr: vote_dict} for blocks that pass validation. The vote_dict
    mirrors the shape scrape_fraktionen.py already consumes (counts,
    group_names, members, …) plus an ``ab_report`` with the validation detail.
    Bills that fail validation are reported (and skipped) so they can be fixed
    or re-sourced rather than silently emitting wrong tallies.
    """
    roster = Roster(session)
    bycsv = {_norm_anr(r["anr"]): r for r in _load_csv()}
    out = {}
    reports = []
    for f in sorted(glob.glob(os.path.join(KOMPLIZIERT, "*.pdf"))):
        base = os.path.basename(f)
        m = re.match(r"(.+)-([\d,]+)\.pdf$", base)
        if not m:
            continue
        anrs = [_norm_anr(a) for a in m.group(2).split(",")]
        # expand a filename anr that is sub-numbered in the CSV (e.g. a page
        # named '465' whose CSV rows are 465.1/465.2/465.3). Each sub-row is
        # matched strictly: only the one(s) actually voted on this page resolve.
        targets = []
        for a in anrs:
            if a in bycsv:
                targets.append((a, False))
            else:
                subs = sorted(k for k in bycsv if re.match(rf"{re.escape(a)}\.\d+$", k))
                if subs:
                    targets.extend((s, True) for s in subs)
                else:
                    reports.append({"file": base, "anr": a, "skip": "anr not in CSV"})
        try:
            drafts = group_drafts(parse_blocks(_all_lines(f)))
        except Exception as e:               # noqa: BLE001 — report, don't crash
            reports.append({"file": base, "error": repr(e)})
            continue
        for anr, strict in targets:
            row = bycsv[anr]
            rechtsform = (row.get("rechtsform") or "").strip()
            if rechtsform == "5":     # Stichfrage: a referendum tie-break ballot,
                continue              # never a parliamentary Schlussabstimmung
            gesch_short = L.business_short_norm(row["gesch_nr"])
            date_iso = _dat_iso(row.get("dat-parl"))
            if not date_iso:
                reports.append({"file": base, "anr": anr, "skip": "no dat-parl"})
                continue
            is_init = 1 if rechtsform == "3" else 0
            draft = select_draft(drafts, gesch_short, row["titel_kurz_d"],
                                 row.get("entwurf_nr"), strict=strict)
            if not draft:
                reports.append({"file": base, "anr": anr, "expected": strict,
                                "skip": "no matching Schlussabstimmung block on "
                                "this page"})
                continue
            counts, members, rep = resolve_draft(draft, roster.for_date(date_iso))
            rep.update({"file": base, "anr": anr, "gesch": L.gesch_display(row["gesch_nr"]),
                        "date": date_iso})
            reports.append(rep)
            if not rep["ok"]:
                continue
            group_names = {abbr: next((mm["name"] for mm in roster.for_date(date_iso)
                                       if mm["abbr"] == abbr), L.fraction_name(abbr))
                           for abbr in counts}
            out[anr] = {
                "vote_ref": draft["ref"], "leg": _leg_for(date_iso),
                "vote_date": date_iso[8:10] + "." + date_iso[5:7] + "." + date_iso[:4],
                "bill_number": row.get("entwurf_nr"),
                "bill_title": draft["title"][:300] or row["titel_kurz_d"],
                "bill_is_initiative": is_init,
                "counts": counts, "group_names": group_names,
                "members": members, "n_members": len(members),
                "is_final": True, "subject": "Schlussabstimmung",
                "source_file": base, "vote_url": "",
                "ab_report": rep,
            }
    roster.save()
    return out, reports


# --------------------------------------------------------------------------
# Standalone validation report
# --------------------------------------------------------------------------
def _print_report(reports):
    ok = [r for r in reports if r.get("ok")]
    bad = [r for r in reports if "ok" in r and not r["ok"]]
    skip = [r for r in reports if "skip" in r or "error" in r]
    print("=" * 72)
    print("Amtliches-Bulletin parser — validation report")
    print("=" * 72)
    for r in sorted([r for r in reports if "checks" in r],
                    key=lambda r: (r.get("anr") or "")):
        c = r["checks"]
        sizes = " ".join(f"{b}={c[b].get('matched', c[b].get('reconstructed'))}"
                         f"/{c[b].get('printed')}" for b in
                         ("yes", "no", "abstain", "absent", "president") if b in c)
        status = "OK " if r["ok"] else "FAIL"
        print(f"[{status}] anr {r['anr']:>4} gesch {r.get('gesch'):>7} ref {r['ref']}"
              f"  roster={r['roster_n']} assigned={r['assigned']}")
        print(f"        {sizes}   title='{r['title'][:48]}'")
        for fl in r["flags"]:
            print(f"        FLAG: {fl}")
        for wn in r.get("warnings", []):
            print(f"        note: {wn}")
    for r in skip:
        print(f"[SKIP] {r}")
    print("-" * 72)
    print(f"OK: {len(ok)}   FAIL: {len(bad)}   SKIP: {len(skip)}")


if __name__ == "__main__":
    sess = L.PoliteSession(min_interval=0.12)
    votes, reps = load_ab_votes(sess, verbose=True)
    _print_report(reps)
    print(f"\nresolved {len(votes)} anr(s): {sorted(votes)}")

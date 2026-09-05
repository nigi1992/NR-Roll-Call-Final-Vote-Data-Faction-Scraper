"""
parl_lib.py — Shared helpers for scraping Swiss National Council (Nationalrat)
final-vote (Schlussabstimmung) fraction tallies.

Two data sources are used by the pipeline:
  * The official OData web service (ws.parlament.ch) for votes from the
    47th legislature onward (Winter session 2003 -> today). It exposes the
    individual member votes incl. their parliamentary group (fraction).
  * The roll-call PDFs (www.parlament.ch/poly/Abstimmung/<leg>/out/vote_<leg>_<ref>.pdf)
    for the 1995-2003 era, which the OData service does not cover.

This module holds the bits both sources share: a polite throttled HTTP
session, the PDF parser, and the code/decision lookup tables.
"""

import io
import re
import time
import random
import threading

import requests

# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

USER_AGENT = (
    "fraktionen-scraper/1.0 (research, respects rate limits, "
    "contact: nicolas.waser@icloud.com)"
)


class PoliteSession:
    """A requests.Session wrapper that:
      * keeps a minimum delay between requests (avoids the parliament site's
        rate limiter, which returns HTTP 403 after bursts),
      * retries on 403/429/5xx with exponential backoff plus a long cooldown
        specifically for 403 (the site's throttle signal).
    """

    def __init__(self, min_interval=0.15, max_retries=5):
        self.s = requests.Session()
        self.s.headers.update({"User-Agent": USER_AGENT})
        self.min_interval = min_interval
        self.max_retries = max_retries
        self._lock = threading.Lock()
        self._next_allowed = 0.0

    def _throttle(self):
        with self._lock:
            now = time.monotonic()
            wait = self._next_allowed - now
            if wait > 0:
                time.sleep(wait)
            # jitter so concurrent workers don't sync up
            self._next_allowed = time.monotonic() + self.min_interval + random.uniform(0, 0.05)

    def get(self, url, accept=None, timeout=30, stream=False):
        headers = {"Accept": accept} if accept else None
        backoff = 1.0
        for attempt in range(self.max_retries):
            self._throttle()
            try:
                r = self.s.get(url, headers=headers, timeout=timeout, stream=stream)
            except requests.RequestException as e:
                if attempt == self.max_retries - 1:
                    raise
                time.sleep(backoff)
                backoff = min(backoff * 2, 30)
                continue
            if r.status_code in (403, 429):
                # rate limited -> long cooldown
                cool = 20 * (attempt + 1)
                time.sleep(cool)
                continue
            if 500 <= r.status_code < 600:
                time.sleep(backoff)
                backoff = min(backoff * 2, 30)
                continue
            return r
        return r  # last response (likely an error) for caller to inspect


# --------------------------------------------------------------------------
# Vote decision / symbol -> bucket
# --------------------------------------------------------------------------
# Output buckets mirror the four rows of the PDF "Ergebnisse / Resultats"
# fraction table, plus a separate 'president' (counted out of the four).
#   yes      = Ja / oui
#   no       = Nein / non
#   abstain  = Enthaltung / abstention
#   absent   = entschuldigt / abwesend / hat nicht teilgenommen
#   president = Der Praesident stimmt nicht  (always 0 or 1)
BUCKETS = ["yes", "no", "abstain", "absent", "president"]

# OData "Voting.Decision" integer code -> bucket
DECISION_BUCKET = {
    1: "yes",        # Ja
    2: "no",         # Nein
    3: "abstain",    # Enthaltung
    5: "absent",     # Hat nicht teilgenommen
    6: "absent",     # Entschuldigt gemaess Art. 57 Abs. 4
    7: "president",  # Die Praesidentin / der Praesident stimmt nicht
}

# PDF symbol -> bucket
SYMBOL_BUCKET = {
    "+": "yes",       # ja / oui / si
    "=": "no",        # nein / non / no
    "o": "abstain",   # enth. / abst. / ast.
    "*": "absent",    # entschuldigt / excuse, abwesend / absent
    "%": "absent",    # entschuldigt gemaess Art. 57 Abs. 4 (leg 47+ protocols)
    "#": "president", # Der Praesident stimmt nicht
}

CANTONS = {
    "ZH", "BE", "LU", "UR", "SZ", "OW", "NW", "GL", "ZG", "FR", "SO", "BS",
    "BL", "SH", "AR", "AI", "SG", "GR", "AG", "TG", "TI", "VD", "VS", "NE",
    "GE", "JU",
}

# --------------------------------------------------------------------------
# Fraction code -> human-readable name (for PDF-era single/short codes).
# For the OData era the API's ParlGroupName gets used directly, this table is a
# best-effort label for the historical PDF codes (1995-2003 and a few later).
# --------------------------------------------------------------------------
FRACTION_NAMES = {
    "S": "Sozialdemokratische Fraktion (SP)",
    "V": "Fraktion der Schweizerischen Volkspartei (SVP)",
    "R": "Freisinnig-demokratische / FDP-Fraktion",
    "RL": "FDP-Liberale Fraktion",
    "C": "Christlichdemokratische Fraktion (CVP)",
    "CE": "Fraktion CVP/EVP/glp",
    "L": "Liberale Fraktion (LPS)",
    "G": "Grüne Fraktion (GPS)",
    "GL": "Grünliberale Fraktion (glp)",
    "BD": "BDP-Fraktion",
    "E": "Fraktion EVP/EDU/(LdU)",
    "M-E": "Fraktion Die Mitte / EVP",
    "M-CEB": "Fraktion Die Mitte",
    "U": "Fraktion des Landesrings (LdU/EVP)",
    "W": "Fraktion (W)",
    "-": "Fraktionslos / ohne Fraktion",
}


def fraction_name(code):
    return FRACTION_NAMES.get(code, code)


# --------------------------------------------------------------------------
# Business number helpers
# --------------------------------------------------------------------------

def gesch_to_business_number(gesch_nr):
    """'92.012' -> 19920012 ; '24.063' -> 20240063 ; '1.025' -> 20010025.

    Returns int or None if it can't be parsed. Sub-rows like '682.3' in the
    *anr* column are NOT business numbers; only the gesch_nr column is valid.
    """
    if gesch_nr is None:
        return None
    m = re.match(r"^\s*(\d{1,2})\.(\d{3})\s*$", str(gesch_nr))
    if not m:
        return None
    yy, num = int(m.group(1)), m.group(2)
    # pivot: 00..30 -> 2000s, 31..99 -> 1900s  (data spans 1970-2026)
    year = 2000 + yy if yy <= 30 else 1900 + yy
    return year * 10000 + int(num)


def business_short_norm(s):
    """Normalize a business short number for matching: '01.074' / '1.074' -> '1.074'."""
    if s is None:
        return None
    m = re.match(r"^\s*(\d{1,2})\.(\d{3})", str(s))
    if not m:
        return None
    return f"{int(m.group(1))}.{m.group(2)}"


def gesch_display(s):
    """Canonical zero-padded business number for OUTPUT, e.g. '03.026'.

    Spreadsheets read 'gesch_nr' as a number and drop leading zeros from the
    year ('03.026' -> '3.026', '00.034' -> '0.034') and trailing zeros from the
    running number ('92.070' -> '92.07'). This reverses both: year padded to 2
    digits, running number padded to 3. Pre-1976 numbers (no dot) are kept as is.
    """
    if s is None:
        return ""
    s = str(s).strip()
    m = re.match(r"^(\d{1,2})\.(\d{1,4})$", s)
    if not m:
        return s                       # pre-1976 5-digit code or other format
    yy, num = m.group(1).zfill(2), m.group(2)
    if len(num) < 3:                   # reverse spreadsheet trailing-zero loss
        num = num.ljust(3, "0")
    return f"{yy}.{num}"


# --------------------------------------------------------------------------
# PDF parsing
# --------------------------------------------------------------------------
# The 2003+ roll-call PDFs embed a normal font (all text readable). The
# 1995-2002 PDFs render the *labels* and the *business number* in a subset
# font with no Unicode map, so they come out as "(cid:N)" tokens. The field
# *values* (title, date, "Schlussabstimmung", member rows, result totals) are
# in a readable font. Therefore: (a) reconstructing readable text by dropping
# cid glyphs, and (b) matching those older votes to a business via the readable
# full title (the business number is unrecoverable from the cid glyphs).

_BIZ_RE = re.compile(r"\b(\d{2}\.\d{3})\b")
_REF_RE = re.compile(r"Ref\.?\s*0*(\d+)", re.I)
_DATE_RE = re.compile(r"\b(\d{2}\.\d{2}\.\d{4})\b")
_CANTON_ALT = "|".join(sorted(CANTONS))
_MEMBER_LINE_RE = re.compile(r"[+=o*#]\s*[A-Za-zÄÖÜäöü\-]\s*(?:" + _CANTON_ALT + r")\b")

# In the 1995-2002 PDFs an embedded font drops the first letter of some canton
# codes (JU -> "IU", NW/OW -> "W"). Adding those quirks to the canton set so
# every member is still captured, the false 1-letter "cantons" (a following name's
# initial) are excluded because they are not in this set.
_QUIRK_CANTONS = {"IU", "W"}
_CANTON_FIX = {"IU": "JU"}  # "W" is left as-is (ambiguous NW/OW)
_CANTON_ALT2 = "|".join(sorted(CANTONS | _QUIRK_CANTONS, key=len, reverse=True))
# member entry: <symbol><fraction><canton> — glued or space-separated.
# Fraction is 1 char in the 1999-2003 PDFs but 2-3 (GL, RL, M-E) in modern ones,
# the lazy {1,5} plus the canton anchor handles both without over-matching.
_MEMBER_RE = re.compile(
    r"([+=o*#])\s*([A-Za-zÄÖÜäöü\-]{1,5}?)\s*(" + _CANTON_ALT2 + r")(?![a-zäöü])")
# where the member list ends and the legend / results block begins
_LEGEND_RE = re.compile(r"\+\s*ja\s*/\s*oui|ja\s*/\s*oui\s*/\s*s|Ergebnisse|R[ée]sultats")
_TOTAL_PATS = {
    "yes":     r"ja\s*/\s*oui[^\d\n]*?(\d+)",
    "no":      r"nein\s*/\s*non[^\d\n]*?(\d+)",
    "abstain": r"enth\.[^\d\n]*?(\d+)",
    "absent":  r"entschuldigt[^\d\n]*?(\d+)",
}

# Object values that are NOT the business title (so skiping them when guessing
# the title line).
_OBJECT_VALUES = re.compile(
    r"^(schlussabstimmung|vote final|gesamtabstimmung|vote sur l['’]ensemble|"
    r"art\.|ziff\.|titre|titel|eintreten|gegenentwurf|ordnungsantrag|"
    r"r[uü]ckweisung|dringlichkeit)",
    re.I,
)
_LABELS = re.compile(
    r"(abstimmungsprotokoll|namentliche abstimmung|vote nominatif|"
    r"proc[eè]s-verbal|gesch[aä]ft\s*/\s*objet|gegenstand\s*/\s*objet|"
    r"objet du vote|abstimmung vom|vote du:|^ref\.|"
    r"^nationalrat|^conseil national)",
    re.I,
)


def normalize_title(s):
    """Lowercase, transliterate umlauts (OData stores 'Aenderung', PDFs 'Änderung'),
    drop non-alphanumerics -> for robust title matching across the two sources."""
    if not s:
        return ""
    s = s.lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"),
                 ("ß", "ss"), ("é", "e"), ("è", "e"),
                 ("ê", "e"), ("à", "a"), ("ç", "c")):
        s = s.replace(a, b)
    return re.sub(r"[^a-z0-9]+", "", s)


def parse_pdf(pdf_bytes):
    """Parse a Nationalrat roll-call PDF (bytes) -> dict or None.

    Returns a dict with: business_short (or None for cid-era PDFs), ref,
    subject (object voted on), title (readable German business title),
    title_norm, header_text, date, is_final, n_members, counts, members.
    """
    import pdfplumber
    from collections import defaultdict

    with pdfplumber.open(io.BytesIO(pdf_bytes)) as pdf:
        if not pdf.pages:
            return None
        page = pdf.pages[0]
        chars = page.chars
        full_text = page.extract_text() or ""

    # readable lines: drop cid glyphs, group chars by line (rounded top)
    rlines = defaultdict(list)
    for c in chars:
        if c["text"].startswith("(cid:"):
            continue
        rlines[round(c["top"])].append(c)
    lines = []
    for top in sorted(rlines):
        row = sorted(rlines[top], key=lambda c: c["x0"])
        s = "".join(c["text"] for c in row).strip()
        if s:
            lines.append(s)

    full_readable = "\n".join(lines)
    if "Abstimmung" not in full_readable and "vote" not in full_readable.lower():
        return None

    # split header (before member rows) from the rest
    header_lines = []
    for ln in lines:
        if _MEMBER_LINE_RE.search(ln):
            break
        header_lines.append(ln)
    header_text = " ".join(header_lines)

    low = header_text.lower()
    is_final = ("vote final" in low) or ("schlussabstimmung" in low)

    ref = None
    m = _REF_RE.search(full_readable)
    if m:
        ref = int(m.group(1))

    biz = None
    m = _BIZ_RE.search(full_readable)
    if m:
        biz = business_short_norm(m.group(1))

    date = None
    m = _DATE_RE.search(full_readable)
    if m:
        date = m.group(1)

    # title: first header line that is a real title (not a label / object / date / cid noise)
    title = None
    subject = None
    for ln in header_lines:
        s = ln.strip()
        if _OBJECT_VALUES.match(s) and subject is None:
            subject = s[:120]
        if title is not None:
            continue
        if (len(s) < 6 or _LABELS.search(s) or _OBJECT_VALUES.match(s)
                or _DATE_RE.search(s) or re.fullmatch(r"[\W\d_]+", s)):
            continue
        title = s[:300]

    # member votes: parse the member region (between header and the legend).
    # The pdfminer text extraction glues "<symbol><fraction><canton>" together,
    # so scanning with a regex anchored on the symbol and the 2-letter canton.
    mleg = _LEGEND_RE.search(full_text)
    region = full_text[:mleg.start()] if mleg else full_text

    counts = defaultdict(lambda: defaultdict(int))
    members = []
    prev_end = 0
    for m in _MEMBER_RE.finditer(region):
        sym, frac, canton = m.groups()
        bucket = SYMBOL_BUCKET[sym]
        canton = _CANTON_FIX.get(canton, canton)
        # best-effort member name = text in this column before the symbol
        gap = region[prev_end:m.start()]
        name = re.split(r"\s{2,}|\n", gap)[-1].strip(" .-")
        prev_end = m.end()
        counts[frac][bucket] += 1
        members.append({"name": name[:60], "fraction": frac,
                        "canton": canton, "bucket": bucket})

    # official "Gesamt" totals (for validation)
    official = {}
    for k, pat in _TOTAL_PATS.items():
        mm = re.search(pat, full_text)
        official[k] = int(mm.group(1)) if mm else None

    return {
        "business_short": biz,
        "ref": ref,
        "subject": subject,
        "title": title,
        "title_norm": normalize_title(title),
        "header_text": header_text[:400],
        "date": date,
        "is_final": is_final,
        "n_members": len(members),
        "counts": {k: dict(v) for k, v in counts.items()},
        "official_totals": official,
        "members": members,
    }


def pdf_url(leg, ref):
    return f"https://www.parlament.ch/poly/Abstimmung/{leg}/out/vote_{leg}_{ref}.pdf"


def empty_counts():
    return {b: 0 for b in BUCKETS}

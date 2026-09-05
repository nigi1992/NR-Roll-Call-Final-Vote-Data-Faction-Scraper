# ============================================================================
# parl_lib.R — Shared helpers for scraping Swiss National Council (Nationalrat)
# final-vote (Schlussabstimmung) fraction tallies. R port of parl_lib.py.
#
# Holds: a polite throttled HTTP getter (rate-limit aware; parlament.ch answers
# bursts with HTTP 403), the roll-call PDF parser (pdftools), and the
# code/decision lookup tables. source() this file from the other scripts.
#
# Packages: httr2, pdftools, jsonlite
# ============================================================================

# one-time setup on a new machine:
#   install.packages(c("httr2", "pdftools", "jsonlite", "writexl"))
for (.p in c("httr2", "pdftools", "jsonlite")) {
  if (!requireNamespace(.p, quietly = TRUE))
    stop("Package '", .p, "' is not installed. Run:\n  ",
         'install.packages(c("httr2", "pdftools", "jsonlite", "writexl"))',
         call. = FALSE)
}
library(httr2)
library(pdftools)

USER_AGENT <- paste0("fraktionen-scraper-R/1.0 (research; respects rate limits; ",
                     "contact: nicolas.waser@icloud.com)")

# --------------------------------------------------------------------------
# Polite HTTP: minimum delay between requests + backoff on 403/429/5xx
# --------------------------------------------------------------------------
.polite <- new.env()
.polite$next_allowed <- 0
.polite$min_interval <- 0.15

polite_get <- function(url, accept = NULL, timeout = 40, max_retries = 5) {
  backoff <- 1
  for (attempt in seq_len(max_retries)) {
    wait <- .polite$next_allowed - as.numeric(Sys.time())
    if (wait > 0) Sys.sleep(wait)
    .polite$next_allowed <- as.numeric(Sys.time()) + .polite$min_interval +
      runif(1, 0, 0.05)
    req <- request(url) |>
      req_user_agent(USER_AGENT) |>
      req_timeout(timeout) |>
      req_error(is_error = function(resp) FALSE)   # handle status ourselves
    if (!is.null(accept)) req <- req |> req_headers(Accept = accept)
    resp <- tryCatch(req_perform(req), error = function(e) NULL)
    if (is.null(resp)) {                    # network error -> retry
      Sys.sleep(backoff); backoff <- min(backoff * 2, 30); next
    }
    st <- resp_status(resp)
    if (st %in% c(403L, 429L)) {            # rate limited -> long cooldown
      Sys.sleep(20 * attempt); next
    }
    if (st >= 500L) {
      Sys.sleep(backoff); backoff <- min(backoff * 2, 30); next
    }
    return(resp)
  }
  resp                                       # last response for caller to inspect
}

# --------------------------------------------------------------------------
# Vote decision / symbol -> bucket
# --------------------------------------------------------------------------
BUCKETS <- c("yes", "no", "abstain", "absent", "president")

# OData Voting.Decision integer code -> bucket
DECISION_BUCKET <- c(`1` = "yes", `2` = "no", `3` = "abstain",
                     `5` = "absent", `6` = "absent", `7` = "president")

# PDF symbol -> bucket
SYMBOL_BUCKET <- c(`+` = "yes", `=` = "no", `o` = "abstain",
                   `*` = "absent", `#` = "president")

CANTONS <- c("ZH","BE","LU","UR","SZ","OW","NW","GL","ZG","FR","SO","BS","BL",
             "SH","AR","AI","SG","GR","AG","TG","TI","VD","VS","NE","GE","JU")

# Fraction code -> human-readable name (historical PDF-era codes)
FRACTION_NAMES <- c(
  "S"     = "Sozialdemokratische Fraktion (SP)",
  "V"     = "Fraktion der Schweizerischen Volkspartei (SVP)",
  "R"     = "Freisinnig-demokratische / FDP-Fraktion",
  "RL"    = "FDP-Liberale Fraktion",
  "C"     = "Christlichdemokratische Fraktion (CVP)",
  "CE"    = "Fraktion CVP/EVP/glp",
  "L"     = "Liberale Fraktion (LPS)",
  "G"     = "Grüne Fraktion (GPS)",
  "GL"    = "Grünliberale Fraktion (glp)",
  "BD"    = "BDP-Fraktion",
  "E"     = "Fraktion EVP/EDU/(LdU)",
  "M-E"   = "Fraktion Die Mitte / EVP",
  "M-CEB" = "Fraktion Die Mitte",
  "U"     = "Fraktion des Landesrings (LdU/EVP)",
  "W"     = "Fraktion (W)",
  "-"     = "Fraktionslos / ohne Fraktion")

fraction_name <- function(code) {
  if (!is.null(code) && code %in% names(FRACTION_NAMES)) FRACTION_NAMES[[code]]
  else code
}

# --------------------------------------------------------------------------
# Business number helpers
# --------------------------------------------------------------------------

# '92.012' -> 19920012 ; '24.063' -> 20240063. NA if unparseable.
gesch_to_business_number <- function(gesch_nr) {
  if (is.null(gesch_nr) || is.na(gesch_nr)) return(NA_real_)
  m <- regmatches(gesch_nr, regexec("^\\s*(\\d{1,2})\\.(\\d{3})\\s*$", gesch_nr))[[1]]
  if (length(m) == 0) return(NA_real_)
  yy <- as.integer(m[2]); num <- as.integer(m[3])
  year <- if (yy <= 30) 2000 + yy else 1900 + yy   # data spans 1970-2026
  year * 10000 + num
}

# '01.074' / '1.074' -> '1.074' (normalized short form for matching)
business_short_norm <- function(s) {
  if (is.null(s) || is.na(s)) return(NA_character_)
  m <- regmatches(s, regexec("^\\s*(\\d{1,2})\\.(\\d{3})", s))[[1]]
  if (length(m) == 0) return(NA_character_)
  paste0(as.integer(m[2]), ".", m[3])
}

# Canonical zero-padded business number for OUTPUT, e.g. '03.026'.
# Spreadsheets strip leading year zeros and trailing running-number zeros;
# this reverses both. Pre-1976 codes without a dot are kept as-is.
gesch_display <- function(s) {
  if (is.null(s) || is.na(s)) return("")
  s <- trimws(as.character(s))
  m <- regmatches(s, regexec("^(\\d{1,2})\\.(\\d{1,4})$", s))[[1]]
  if (length(m) == 0) return(s)
  yy <- formatC(m[2], width = 2, flag = "0")
  num <- m[3]
  if (nchar(num) < 3) num <- paste0(num, strrep("0", 3 - nchar(num)))
  paste0(yy, ".", num)
}

# Lowercase, transliterate umlauts, drop non-alphanumerics -> robust matching
normalize_title <- function(s) {
  if (is.null(s) || is.na(s) || !nzchar(s)) return("")
  s <- tolower(s)
  from <- c("ä","ö","ü","ß","é","è","ê",
            "à","ç")
  to   <- c("ae","oe","ue","ss","e","e","e","a","c")
  for (i in seq_along(from)) s <- gsub(from[i], to[i], s, fixed = TRUE)
  gsub("[^a-z0-9]+", "", s)
}

# --------------------------------------------------------------------------
# PDF parsing (roll-call protocol PDFs, leg 46+)
# --------------------------------------------------------------------------
# The 2003+ PDFs embed a normal font. The 1999-2002 PDFs render the *labels*
# and the business number in a subset font with no Unicode map: pdfplumber
# showed those as '(cid:N)' tokens; poppler/pdftools emits shifted garbage
# glyphs instead. Either way the fix is the same - drop every word set in the
# embedded subset font (name like 'JPEHOF+Arial...') and work with the
# readable remainder. Verified to reproduce the Python parser's counts.

.CANTON_QUIRKS <- c("IU", "W")                   # broken font drops a letter
.CANTON_FIX <- c(IU = "JU")                      # 'W' left as-is (NW/OW ambiguous)
.ALL_CANTONS <- c(CANTONS, .CANTON_QUIRKS)
.CANTON_ALT2 <- paste(.ALL_CANTONS[order(nchar(.ALL_CANTONS), decreasing = TRUE)],
                      collapse = "|")
.MEMBER_RX <- paste0("([+=o*#])\\s*([A-Za-zÄÖÜäöü-]",
                     "{1,5}?)\\s*(", .CANTON_ALT2, ")(?![a-zäöü])")
.LEGEND_RX <- paste0("\\+\\s*ja\\s*/\\s*oui|ja\\s*/\\s*oui\\s*/\\s*s|",
                     "Ergebnisse|R[ée]sultats")
.TOTAL_PATS <- c(
  yes     = "ja\\s*/\\s*oui[^0-9\n]*?([0-9]+)",
  no      = "nein\\s*/\\s*non[^0-9\n]*?([0-9]+)",
  abstain = "enth\\.[^0-9\n]*?([0-9]+)",
  absent  = "entschuldigt[^0-9\n]*?([0-9]+)")
.OBJECT_RX <- paste0("^(schlussabstimmung|vote final|gesamtabstimmung|",
                     "vote sur l['’]ensemble|art\\.|ziff\\.|titre|titel|",
                     "eintreten|gegenentwurf|ordnungsantrag|",
                     "r[uü]ckweisung|dringlichkeit)")
.LABELS_RX <- paste0("(abstimmungsprotokoll|namentliche abstimmung|",
                     "vote nominatif|proc[eè]s-verbal|",
                     "gesch[aä]ft\\s*/\\s*objet|gegenstand\\s*/\\s*objet|",
                     "objet du vote|abstimmung vom|vote du:|^ref\\.|",
                     "^nationalrat|^conseil national)")

# Parse a Nationalrat roll-call PDF -> list or NULL (mirrors Python parse_pdf).
# Uses the layout-preserving pdf_text (like pdfplumber's extract_text), after
# deleting the garbage words that poppler emits for the broken subset font
# (identified via pdf_data(font_info=TRUE)).
parse_pdf <- function(pdf_path) {
  full <- tryCatch(pdf_text(pdf_path)[1], error = function(e) NULL)
  if (is.null(full) || !nzchar(full)) return(NULL)
  # The broken 1999-2002 label font has no Unicode map; poppler emits shifted
  # gibberish for it ('1$7,21$/5$7' = NATIONALRAT). A font-NAME test is not
  # enough (modern PDFs subset all fonts), so detect the garbage font by its
  # decoded text: real German/French has ~40% vowels among letters, the
  # shifted glyphs almost none. Words of such fonts are deleted before parsing
  # (the Python/pdfplumber equivalent dropped '(cid:N)' glyphs).
  junk <- tryCatch({
    d <- pdf_data(pdf_path, font_info = TRUE)[[1]]
    bad <- character(0)
    for (fn in unique(d$font_name)) {
      txt <- paste(d$text[d$font_name == fn], collapse = "")
      letters_only <- gsub("[^A-Za-zÄÖÜäöü]", "", txt)
      if (nchar(letters_only) < 20) next
      vshare <- nchar(gsub("[^AEIOUYaeiouyÄÖÜäöü]", "", letters_only)) /
        nchar(letters_only)
      if (vshare < 0.2) bad <- c(bad, fn)
    }
    unique(d$text[d$font_name %in% bad])
  }, error = function(e) character(0))
  for (w in junk[nchar(junk) >= 2])
    full <- gsub(w, " ", full, fixed = TRUE)
  lines <- strsplit(full, "\n", fixed = TRUE)[[1]]
  lines <- trimws(lines)
  if (!grepl("Abstimmung", full) && !grepl("vote", tolower(full))) return(NULL)

  # header = lines before the first member row
  member_line <- grepl(paste0("[+=o*#]\\s*[A-Za-zÄÖÜäöü-]\\s*(",
                              paste(CANTONS, collapse = "|"), ")\\b"), lines, perl = TRUE)
  first_member <- if (any(member_line)) which(member_line)[1] else length(lines) + 1
  header_lines <- if (first_member > 1) lines[1:(first_member - 1)] else character(0)
  header_text <- paste(header_lines, collapse = " ")
  low <- tolower(header_text)
  is_final <- grepl("vote final", low) || grepl("schlussabstimmung", low)

  ref <- NA_integer_
  m <- regmatches(full, regexec("Ref\\.?\\s*0*([0-9]+)", full, ignore.case = TRUE))[[1]]
  if (length(m)) ref <- as.integer(m[2])
  biz <- NA_character_
  m <- regmatches(full, regexec("\\b([0-9]{2}\\.[0-9]{3})\\b", full))[[1]]
  if (length(m)) biz <- business_short_norm(m[2])
  date <- NA_character_
  m <- regmatches(full, regexec("\\b([0-9]{2}\\.[0-9]{2}\\.[0-9]{4})\\b", full))[[1]]
  if (length(m)) date <- m[2]

  # title: first header line that is a real title (not label/object/date noise)
  title <- NA_character_; subject <- NA_character_
  for (ln in header_lines) {
    s <- trimws(ln)
    if (is.na(subject) && grepl(.OBJECT_RX, tolower(s), perl = TRUE))
      subject <- substr(s, 1, 120)
    if (!is.na(title)) next
    if (nchar(s) < 6 || grepl(.LABELS_RX, tolower(s), perl = TRUE) ||
        grepl(.OBJECT_RX, tolower(s), perl = TRUE) ||
        grepl("\\b[0-9]{2}\\.[0-9]{2}\\.[0-9]{4}\\b", s) ||
        grepl("^[^A-Za-z]*$", s)) next
    title <- substr(s, 1, 300)
  }

  # member votes: scan the region before the legend/results block
  mleg <- regexpr(.LEGEND_RX, full, perl = TRUE)
  region <- if (mleg > 0) substr(full, 1, mleg - 1) else full
  g <- gregexpr(.MEMBER_RX, region, perl = TRUE)[[1]]
  counts <- list(); members <- list()
  if (g[1] > 0) {
    hits  <- regmatches(region, list(g))[[1]]
    sym   <- sub(.MEMBER_RX, "\\1", hits, perl = TRUE)
    frac  <- sub(.MEMBER_RX, "\\2", hits, perl = TRUE)
    cant  <- sub(.MEMBER_RX, "\\3", hits, perl = TRUE)
    starts <- as.integer(g)
    ends   <- starts + attr(g, "match.length") - 1L
    prev_end <- 0L
    for (i in seq_along(hits)) {
      bucket <- SYMBOL_BUCKET[[sym[i]]]
      canton <- if (cant[i] %in% names(.CANTON_FIX)) .CANTON_FIX[[cant[i]]] else cant[i]
      f <- frac[i]
      # best-effort member name = text in this column before the symbol
      gap <- substr(region, prev_end + 1L, starts[i] - 1L)
      pieces <- strsplit(gap, "\\s{2,}|\n", perl = TRUE)[[1]]
      nm <- if (length(pieces)) trimws(pieces[length(pieces)]) else ""
      nm <- substr(gsub("^[ .-]+|[ .-]+$", "", nm), 1, 60)
      prev_end <- ends[i]
      if (is.null(counts[[f]])) counts[[f]] <- integer(0)
      counts[[f]][bucket] <- (if (bucket %in% names(counts[[f]]))
        counts[[f]][[bucket]] else 0L) + 1L
      members[[length(members) + 1]] <- list(name = nm, fraction = f,
                                             canton = canton, bucket = bucket)
    }
  }

  official <- list()
  for (k in names(.TOTAL_PATS)) {
    mm <- regmatches(full, regexec(.TOTAL_PATS[[k]], full, perl = TRUE))[[1]]
    official[[k]] <- if (length(mm)) as.integer(mm[2]) else NA_integer_
  }

  list(business_short = biz, ref = ref, subject = subject, title = title,
       title_norm = normalize_title(title),
       header_text = substr(header_text, 1, 400), date = date,
       is_final = is_final, n_members = length(members),
       counts = lapply(counts, as.list), official_totals = official,
       members = members)
}

pdf_url <- function(leg, ref)
  sprintf("https://www.parlament.ch/poly/Abstimmung/%s/out/vote_%s_%s.pdf",
          leg, leg, ref)

# --------------------------------------------------------------------------
# CSV output helper (UTF-8 with BOM, Excel-friendly - same as the Python CSVs)
# --------------------------------------------------------------------------
write_csv_bom <- function(df, path) {
  con <- file(path, open = "wb")
  writeBin(as.raw(c(0xEF, 0xBB, 0xBF)), con)
  close(con)
  con <- file(path, open = "a", encoding = "UTF-8")
  write.csv(df, con, row.names = FALSE, na = "")
  close(con)
  cat(sprintf("  wrote %s  (%d rows)\n", path, nrow(df)))
}

# --------------------------------------------------------------------------
# Project-root resolution (shared by all scripts)
# --------------------------------------------------------------------------
find_root <- function() {
  d <- normalizePath(getwd())
  for (i in 1:6) {
    if (dir.exists(file.path(d, "Input Data")) && dir.exists(file.path(d, "Scripts")))
      return(d)
    p <- dirname(d)
    if (p == d) break
    d <- p
  }
  stop("Project root not found - set the working directory to the project root")
}

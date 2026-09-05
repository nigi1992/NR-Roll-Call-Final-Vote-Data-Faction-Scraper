# ============================================================================
# scrape_fraktionen.R — For every bill in Fraktion_Scraping.csv, find the
# National Council (Nationalrat) FINAL vote (Schlussabstimmung) and extract how
# each parliamentary group (Fraktion) voted. R port of scrape_fraktionen.py.
#
# Sources, chosen automatically per bill:
#   * OData API (ws.parlament.ch)      -> leg 47+ (Dec 2003 -> today)
#   * roll-call PDF index (pdf_index.json, built by build_index)  -> leg 46
#   * hand-collected per-member PDFs ('neue pdfs/')               -> pdf_manual
#   * Amtliches-Bulletin name-list pages (ab_parse.R)             -> ab,
#     legs 44/45 back to the spring 1994 session
#   * Stichfragen (rechtsform 5) are referendum tie-breaks -> no parliamentary
#     vote, excluded.
#
# Multi-draft businesses are assigned to *distinct* roll-call PDFs (an
# initiative and its counter-proposal never share a vote).
#
# Input : Input Data/Fraktion Scraping/Fraktion_Scraping.csv
#         Input Data/Fraktion Scraping/cache/{pdf_index,odata_cache}.json
#         Input Data/Fraktion Scraping/neue pdfs/...
# Output: Output/Fraktion Scraping/fraktionen_{long,wide,members,report}.csv
#
# With the shipped caches this runs fully offline; new bills trigger polite
# OData fetches (throttled; parlament.ch 403s on bursts).
# ============================================================================

.find_root0 <- function() {
  d <- normalizePath(getwd())
  for (i in 1:6) {
    if (dir.exists(file.path(d, "Input Data")) && dir.exists(file.path(d, "Scripts")))
      return(d)
    p <- dirname(d); if (p == d) break; d <- p
  }
  stop("Project root not found")
}
source(file.path(.find_root0(), "Scripts", "Fraktion Scraping", "parl_lib.R"))
source(file.path(.find_root0(), "Scripts", "Fraktion Scraping", "ab_parse.R"))
suppressMessages(library(jsonlite))

ROOT   <- find_root()
IN     <- file.path(ROOT, "Input Data", "Fraktion Scraping")
OUT    <- file.path(ROOT, "Output", "Fraktion Scraping")
CACHE  <- file.path(IN, "cache")
INDEX_PATH  <- file.path(CACHE, "pdf_index.json")
ODATA_CACHE <- file.path(CACHE, "odata_cache.json")
CSV_PATH    <- file.path(IN, "Fraktion_Scraping.csv")
MANUAL_DIR  <- file.path(IN, "neue pdfs")
ODATA_URL   <- "https://ws.parlament.ch/odata.svc"
LIMIT <- NULL          # set to an integer to process only the first N bills

datparl_to_pdf <- function(d) {
  m <- regexec("(\\d{2})/(\\d{2})/(\\d{4})", trimws(ifelse(is.na(d), "", d)))[[1]]
  if (m[1] < 1) return(NA_character_)
  p <- regmatches(d, list(m))[[1]]
  paste0(p[2], ".", p[3], ".", p[4])
}

vote_url_of <- function(v) {
  if (!is.null(v$vote_url)) return(v$vote_url)   # source supplied it (AB: "")
  if (!is.null(v$leg) && !is.na(v$leg) && !is.null(v$vote_ref) && !is.na(v$vote_ref))
    return(pdf_url(v$leg, v$vote_ref))
  ""
}

odate <- function(s) {
  if (is.null(s) || is.na(s) || !nzchar(s)) return(NA_character_)
  m <- regmatches(s, regexec("(\\d+)", s))[[1]]
  if (length(m) < 2) return(NA_character_)
  format(as.POSIXct(as.numeric(m[2]) / 1000, origin = "1970-01-01", tz = "UTC"),
         "%d.%m.%Y")
}

# --------------------------------------------------------------------------
# Hand-collected per-member PDFs -> {anr: [vote, ...]}
# --------------------------------------------------------------------------
load_manual_pdfs <- function() {
  out <- list()
  files <- list.files(MANUAL_DIR, pattern = "\\.pdf$", recursive = TRUE,
                      full.names = TRUE)
  for (f in files) {
    base <- basename(f)
    mm <- regexec("(.+)-([0-9,]+)\\.pdf$", base)[[1]]
    if (mm[1] < 1) next
    parts <- regmatches(base, list(mm))[[1]]
    ident <- parts[2]
    anrs <- strsplit(parts[3], ",", fixed = TRUE)[[1]]
    rec <- tryCatch(parse_pdf(f), error = function(e) NULL)
    # keep only real per-member protocols (~200 member symbols); AB name-list
    # pages yield none/few and are handled by ab_parse.R instead
    if (is.null(rec) || rec$n_members < 20) next
    lm <- regexec("vote_(\\d+)_", ident)[[1]]
    leg <- if (lm[1] > 0) as.integer(regmatches(ident, list(lm))[[1]][2]) else NA_integer_
    gn <- list()
    for (cc in names(rec$counts)) gn[[cc]] <- fraction_name(cc)
    vote <- list(vote_ref = rec$ref, leg = leg, vote_date = rec$date,
                 bill_number = NULL, bill_title = rec$title,
                 counts = rec$counts, group_names = gn,
                 members = rec$members, n_members = rec$n_members,
                 is_final = rec$is_final, subject = rec$subject,
                 source_file = base)
    for (a in anrs) {
      k <- norm_anr(a)
      out[[k]] <- c(if (!is.null(out[[k]])) out[[k]] else list(), list(vote))
    }
  }
  out
}

# --------------------------------------------------------------------------
# OData access (disk-cached; cache keys identical to the Python pipeline's, so
# the shipped odata_cache.json is hit as-is and no network is needed)
# --------------------------------------------------------------------------
.odc <- new.env()
.odc$cache <- NULL
.odc$dirty <- FALSE

odc_load <- function() {
  if (is.null(.odc$cache)) {
    if (file.exists(ODATA_CACHE)) {
      cat("  loading OData cache (large file, one-time)...\n")
      .odc$cache <- list2env(fromJSON(ODATA_CACHE, simplifyVector = FALSE),
                             hash = TRUE)
    } else .odc$cache <- new.env(hash = TRUE)
  }
  invisible(NULL)
}

odc_save <- function() {
  if (isTRUE(.odc$dirty)) {
    cat("  saving OData cache...\n")
    write_json(as.list(.odc$cache), ODATA_CACHE, auto_unbox = TRUE, null = "null")
    .odc$dirty <- FALSE
  }
  invisible(NULL)
}

odc_get <- function(path) {
  odc_load()
  hit <- .odc$cache[[path]]
  if (!is.null(hit)) return(hit)
  r <- polite_get(paste0(ODATA_URL, path), accept = "application/json", timeout = 40)
  rows <- list()
  if (!is.null(r) && resp_status(r) == 200) {
    d <- resp_body_json(r)$d
    rows <- if (!is.null(d$results)) d$results else d
  }
  .odc$cache[[path]] <- rows
  .odc$dirty <- TRUE
  rows
}

.num <- function(x) format(x, scientific = FALSE, trim = TRUE)

votes_for_business <- function(bn)
  odc_get(sprintf("/Vote?$filter=BusinessNumber%%20eq%%20%s%%20and%%20Language%%20eq%%20'DE'&$format=json",
                  .num(bn)))
votings_for_vote <- function(vote_id)
  odc_get(sprintf("/Voting?$filter=IdVote%%20eq%%20%s%%20and%%20Language%%20eq%%20'DE'&$format=json",
                  .num(vote_id)))
business_blob <- function(bn) {
  rows <- odc_get(sprintf("/Business?$filter=ID%%20eq%%20%s%%20and%%20Language%%20eq%%20'DE'&$select=Title,Description&$format=json",
                          .num(bn)))
  if (!length(rows)) return("")
  t <- rows[[1]]$Title; d <- rows[[1]]$Description
  paste(if (is.null(t)) "" else t, if (is.null(d)) "" else d)
}
bills_of <- function(bn)
  odc_get(sprintf("/Bill?$filter=BusinessNumber%%20eq%%20%s%%20and%%20Language%%20eq%%20'DE'&$select=ID,BillNumber&$format=json",
                  .num(bn)))
nr_schlussabstimmung_dates <- function(bn) {
  out <- list()
  for (b in bills_of(bn)) {
    res <- odc_get(sprintf("/Resolution?$filter=IdBill%%20eq%%20guid'%s'%%20and%%20Language%%20eq%%20'DE'&$format=json",
                           b$ID))
    for (r in res) {
      rt <- if (is.null(r$ResolutionText)) "" else r$ResolutionText
      cn <- if (is.null(r$CouncilName)) "" else r$CouncilName
      if (cn == "Nationalrat" && grepl("chlussab", rt, fixed = TRUE))
        out[[length(out) + 1]] <- list(date = odate(r$ResolutionDate),
                                       bill = b$BillNumber)
    }
  }
  out
}

# --------------------------------------------------------------------------
# API aggregation
# --------------------------------------------------------------------------
aggregate_api_votings <- function(votings) {
  counts <- list(); gnames <- list(); members <- list()
  for (v in votings) {
    code <- if (is.null(v$ParlGroupCode) || !nzchar(v$ParlGroupCode)) "-" else v$ParlGroupCode
    if (toupper(code) == "FRAKTIONSLOS") code <- "-"
    dec <- as.character(v$Decision)
    if (!(dec %in% names(DECISION_BUCKET))) next
    bucket <- DECISION_BUCKET[[dec]]
    if (is.null(counts[[code]])) counts[[code]] <- list()
    old <- counts[[code]][[bucket]]
    counts[[code]][[bucket]] <- (if (is.null(old)) 0L else old) + 1L
    gnames[[code]] <- if (!is.null(v$ParlGroupName)) v$ParlGroupName else fraction_name(code)
    members[[length(members) + 1]] <- list(
      name = trimws(paste(if (is.null(v$LastName)) "" else v$LastName,
                          if (is.null(v$FirstName)) "" else v$FirstName)),
      fraction = code, canton = v$Canton, bucket = bucket)
  }
  list(counts = counts, names = gnames, members = members)
}

api_schlussabstimmungen <- function(bn) {
  votes <- votes_for_business(bn)
  subj <- vapply(votes, function(v) if (is.null(v$Subject)) "" else v$Subject, "")
  sa <- votes[grepl("schlussab|vote final|votazione finale", subj, ignore.case = TRUE)]
  if (!length(sa)) {   # fallback: match by the NR final-vote date (Resolution)
    nrd <- unique(vapply(nr_schlussabstimmung_dates(bn),
                         function(x) ifelse(is.na(x$date), "", x$date), ""))
    nrd <- nrd[nzchar(nrd)]
    if (length(nrd))
      sa <- votes[vapply(votes, function(v) {
        d <- odate(v$VoteEnd); !is.na(d) && d %in% nrd }, TRUE)]
  }
  # dedup: one definitive final vote per bill = highest RegistrationNumber
  by_bill <- list()
  for (v in sa) {
    key <- as.character(if (is.null(v$BillNumber)) "NA" else v$BillNumber)
    rn <- if (is.null(v$RegistrationNumber)) 0 else v$RegistrationNumber
    old <- by_bill[[key]]
    orn <- if (is.null(old) || is.null(old$RegistrationNumber)) 0 else old$RegistrationNumber
    if (is.null(old) || rn > orn) by_bill[[key]] <- v
  }
  out <- list()
  for (v in by_bill) {
    votings <- votings_for_vote(v$ID)
    if (length(votings) <= 100) next        # Staenderat (~46) -> skip; NR ~200
    agg <- aggregate_api_votings(votings)
    out[[length(out) + 1]] <- list(
      vote_ref = v$RegistrationNumber, leg = v$IdLegislativePeriod,
      vote_date = odate(v$VoteEnd), bill_number = v$BillNumber,
      bill_title = v$BillTitle, counts = agg$counts, group_names = agg$names,
      members = agg$members, n_members = length(agg$members))
  }
  out
}

select_bills <- function(sa_list, entwurf) {
  if (nzchar(entwurf) && grepl("^\\d+$", entwurf)) {
    m <- Filter(function(v) identical(as.character(v$bill_number), entwurf), sa_list)
    if (length(m)) return(m)
  }
  sa_list
}

# --------------------------------------------------------------------------
# PDF-era matching (leg 46) — one distinct PDF per draft of a business
# --------------------------------------------------------------------------
sc_tokens <- function(s) {
  if (is.null(s) || length(s) == 0 || is.na(s)) s <- ""
  s <- tolower(s)
  from <- c("ä","ö","ü","ß"); to <- c("ae","oe","ue","ss")
  for (i in seq_along(from)) s <- gsub(from[i], to[i], s, fixed = TRUE)
  ws <- strsplit(s, "[^a-z0-9]+")[[1]]
  unique(ws[nchar(ws) > 3])
}

# function + structural words (in nearly every title) -> never a content hit
.SC_STOP <- c("fuer","ein","eine","einen","einem","einer","und","oder","der",
              "die","das","den","dem","des","von","vom","zur","zum","ueber",
              "aus","auf","mit","bei","gegen","ohne","pour","dans","sur",
              "les","des","une","aux",
              "aenderung","aenderungen","revision","teilrevision","gesetz",
              "bundesgesetz","bundesbeschluss","verordnung","beschluss","loi")

sc_dtok <- function(s) setdiff(sc_tokens(s), .SC_STOP)

pdfindex_load <- function() {
  idx <- fromJSON(INDEX_PATH, simplifyVector = FALSE)
  recs <- list()
  for (rec in idx) {
    if (isTRUE(rec$is_final)) {
      rec$tok <- sc_tokens(if (is.null(rec$title)) "" else rec$title)
      recs[[length(recs) + 1]] <- rec
    }
  }
  by_short <- list(); by_date <- list()
  for (i in seq_along(recs)) {
    r <- recs[[i]]
    if (!is.null(r$business_short))
      by_short[[r$business_short]] <- c(by_short[[r$business_short]], i)
    if (!is.null(r$date))
      by_date[[r$date]] <- c(by_date[[r$date]], i)
  }
  list(recs = recs, by_short = by_short, by_date = by_date)
}

# Assign every draft (CSV row) of a business to a DISTINCT roll-call PDF.
# Greedy bijection: primary score = draft content-title words hit; secondary =
# business-blob token precision; entwurf order breaks ties between PDFs with
# identical titles. No date-less title-only fallback (it false-matched
# pre-1999 bills). Returns list anr -> list(rec, how, score) (rec NULL if none).
match_business <- function(pidx, draft_rows, sa_dates, blob, business_short) {
  blob_tokens <- sc_tokens(blob)
  how <- "date+title"
  if (!is.na(business_short) && !is.null(pidx$by_short[[business_short]])) {
    cand_i <- pidx$by_short[[business_short]]
    how <- "short"
  } else {
    dates <- character(0)
    for (j in seq_len(nrow(draft_rows))) {
      pd <- datparl_to_pdf(draft_rows[["dat-parl"]][j])
      if (!is.na(pd)) dates <- c(dates, pd)
    }
    for (x in sa_dates) if (!is.na(x$date)) dates <- c(dates, x$date)
    cand_i <- integer(0)
    for (d in unique(dates)) cand_i <- c(cand_i, pidx$by_date[[d]])
    cand_i <- unique(cand_i)
  }
  anrs <- vapply(draft_rows$anr, norm_anr, "")
  out <- setNames(vector("list", length(anrs)), anrs)
  if (!length(cand_i)) return(out)

  ek <- vapply(seq_len(nrow(draft_rows)), function(j) {
    e <- trimws(draft_rows$entwurf_nr[j])
    if (grepl("^\\d+$", e)) as.integer(e) else 99L
  }, 0L)
  erank <- setNames(rank(ek, ties.method = "first") - 1L, anrs)

  raw <- list()
  for (j in seq_len(nrow(draft_rows))) {
    a <- anrs[j]
    dt <- sc_dtok(draft_rows$titel_kurz_d[j])
    for (ci in cand_i) {
      pt <- pidx$recs[[ci]]$tok
      prim <- length(intersect(pt, dt))
      sec <- if (length(pt)) round(length(intersect(pt, blob_tokens)) / length(pt), 4) else 0
      raw[[length(raw) + 1]] <- list(prim = prim, sec = sec, a = a, ci = ci)
    }
  }
  relevant <- sort(unique(vapply(Filter(function(x) x$prim >= 1, raw),
                                 function(x) pidx$recs[[x$ci]]$ref, 0)))
  crank <- setNames(seq_along(relevant) - 1L, as.character(relevant))
  ord_key <- vapply(raw, function(x) {
    key <- as.character(pidx$recs[[x$ci]]$ref)
    cr <- if (key %in% names(crank)) crank[[key]] else 99L
    -abs(erank[[x$a]] - cr)
  }, 0)
  o <- order(vapply(raw, function(x) x$prim, 0),
             vapply(raw, function(x) x$sec, 0),
             ord_key, decreasing = TRUE)
  used <- character(0)
  for (k in o) {
    x <- raw[[k]]
    refc <- as.character(pidx$recs[[x$ci]]$ref)
    if (!is.null(out[[x$a]]) || refc %in% used) next
    if (x$prim >= 1 || x$sec >= 0.40) {
      out[[x$a]] <- list(rec = pidx$recs[[x$ci]],
                         how = if (how == "short") "short"
                               else if (x$prim >= 1) "parl-date+title" else "date+title",
                         score = max(x$sec, x$prim / 4.0))
      used <- c(used, refc)
    }
  }
  out
}

# --------------------------------------------------------------------------
# Pipeline
# --------------------------------------------------------------------------
counts_to_buckets <- function(cf) {
  vapply(c("yes", "no", "abstain", "absent"), function(b) {
    v <- cf[[b]]; if (is.null(v)) 0L else as.integer(v)
  }, 0L)
}

.mk_df <- function(rows, cols) {
  m <- do.call(rbind, lapply(rows, function(r) {
    vapply(cols, function(cn) {
      x <- r[[cn]]
      if (is.null(x) || (length(x) == 1 && is.na(x))) NA_character_
      else as.character(x)
    }, "")
  }))
  df <- as.data.frame(m, stringsAsFactors = FALSE, check.names = FALSE)
  names(df) <- cols
  df
}

run <- function(limit = LIMIT) {
  dir.create(OUT, showWarnings = FALSE, recursive = TRUE)
  pidx <- pdfindex_load()
  all_rows <- read.csv(CSV_PATH, colClasses = "character",
                       fileEncoding = "UTF-8-BOM", check.names = FALSE)
  rows <- if (!is.null(limit)) all_rows[seq_len(limit), ] else all_rows
  # group a business's drafts (excl. Stichfragen) for the per-business matcher
  rf <- trimws(ifelse(is.na(all_rows$rechtsform), "", all_rows$rechtsform))
  grp <- all_rows[rf != "5", , drop = FALSE]
  grp$short <- vapply(grp$gesch_nr, business_short_norm, "")
  pdf_group_cache <- list()

  manual <- load_manual_pdfs()
  abres <- load_ab_votes()
  ab_votes <- abres$votes
  for (r in abres$reports) {   # flag AB pages that need re-sourcing
    unresolved <- (!is.null(r$ok) && !isTRUE(r$ok)) ||
      (!is.null(r$skip) && !grepl("not in CSV", r$skip) && !isTRUE(r$expected))
    if (unresolved) {
      why <- if (length(r$flags)) paste(r$flags, collapse = "; ") else r$skip
      cat(sprintf("  AB unresolved: anr %s (%s) - %s\n", r$anr, r$file, why))
    }
  }

  long_rows <- list(); wide_rows <- list(); member_rows <- list(); report_rows <- list()
  all_codes <- character(0)

  for (i in seq_len(nrow(rows))) {
    row <- rows[i, ]
    anr <- row$anr
    gesch <- row$gesch_nr
    entwurf <- trimws(ifelse(is.na(row$entwurf_nr), "", row$entwurf_nr))
    bn <- gesch_to_business_number(gesch)
    short <- business_short_norm(gesch)
    parl_date <- datparl_to_pdf(row[["dat-parl"]])
    base <- list(anr = anr, gesch_nr = gesch_display(gesch), entwurf_nr = entwurf,
                 referendum_date = row$datum, parl_date = row[["dat-parl"]],
                 title_short = row$titel_kurz_d)

    votes <- list(); source <- "unavailable"; note <- ""

    if (trimws(ifelse(is.na(row$rechtsform), "", row$rechtsform)) == "5") {
      # Stichfrage: decided at the ballot box; no parliamentary final vote
      report_rows[[length(report_rows) + 1]] <- c(base, list(
        source = "unavailable", n_votes = 0, vote_refs = "",
        note = "Stichfrage (referendum tie-break; no parliamentary final vote)"))
      next
    }

    na <- norm_anr(anr)
    if (!is.null(manual[[na]])) {
      source <- "pdf_manual"
      votes <- manual[[na]]
      fls <- sort(unique(vapply(votes, function(v) v$source_file, "")))
      allfin <- all(vapply(votes, function(v) isTRUE(v$is_final), TRUE))
      note <- paste0("from provided PDF: ", paste(fls, collapse = ";"),
                     if (allfin) "" else " (proxy: not labelled Schlussabstimmung)")
    } else if (!is.null(ab_votes[[na]])) {
      source <- "ab"
      v <- ab_votes[[na]]
      votes <- list(v)
      note <- sprintf(paste0("Amtliches Bulletin %s (Ref %s); names resolved to ",
                             "%d-member date-accurate NR roster"),
                      v$source_file, v$vote_ref, v$ab_report$roster_n)
      if (length(v$ab_report$warnings))
        note <- paste0(note, " | ", paste(v$ab_report$warnings, collapse = "; "))
    } else if (!is.na(bn)) {
      sa <- api_schlussabstimmungen(bn)
      if (length(sa)) {
        source <- "api"
        votes <- select_bills(sa, entwurf)
      } else {
        if (is.null(pdf_group_cache[[short]])) {
          blob <- business_blob(bn)
          sa_dates <- nr_schlussabstimmung_dates(bn)
          drows <- grp[!is.na(grp$short) & grp$short == short, , drop = FALSE]
          if (!nrow(drows)) drows <- row
          pdf_group_cache[[short]] <- match_business(pidx, drows, sa_dates,
                                                     blob, short)
        }
        hit <- pdf_group_cache[[short]][[na]]
        if (!is.null(hit) && !is.null(hit$rec)) {
          rec <- hit$rec
          source <- "pdf"
          note <- sprintf("match=%s score=%.2f", hit$how, hit$score)
          gn <- list()
          for (cc in names(rec$counts)) gn[[cc]] <- fraction_name(cc)
          votes <- list(list(vote_ref = rec$ref, leg = rec$leg,
                             vote_date = rec$date, bill_number = NULL,
                             bill_title = rec$title, counts = rec$counts,
                             group_names = gn, members = rec$members,
                             n_members = rec$n_members))
        } else {
          sa_dates <- nr_schlussabstimmung_dates(bn)
          if (!length(sa_dates) && is.na(parl_date)) {
            note <- paste0("Schlussabstimmung predates online PDFs (before ",
                           "Dec 1999) or no NR final vote")
          } else {
            dd <- if (!is.na(parl_date)) parl_date else {
              ds <- sort(unique(vapply(sa_dates,
                                       function(x) ifelse(is.na(x$date), "", x$date), "")))
              paste0("['", paste(ds[nzchar(ds)], collapse = "', '"), "']")
            }
            note <- sprintf("NR final vote on %s but no matching PDF", dd)
          }
        }
      }
    }

    if (!length(votes)) {
      report_rows[[length(report_rows) + 1]] <- c(base, list(
        source = source, n_votes = 0, vote_refs = "", note = note))
      next
    }

    urls <- vapply(votes, vote_url_of, "")
    report_rows[[length(report_rows) + 1]] <- c(base, list(
      source = source, n_votes = length(votes),
      vote_refs = paste(vapply(votes, function(v) as.character(v$vote_ref), ""),
                        collapse = ";"),
      vote_urls = paste(urls[nzchar(urls)], collapse = ";"),
      note = note))

    for (v in votes) {
      # AB carries an explicit initiative flag (from the CSV legal form); other
      # sources detect the 'Bundesbeschluss ueber die Volksinitiative' inversion
      # from the bill title.
      is_init <- v$bill_is_initiative
      if (is.null(is_init))
        is_init <- if (grepl("olksinitiative",
                             ifelse(is.null(v$bill_title) || is.na(v$bill_title),
                                    "", v$bill_title), fixed = TRUE)) 1L else 0L
      vinfo <- list(vote_ref = v$vote_ref, leg = v$leg, vote_date = v$vote_date,
                    bill_number = if (is.null(v$bill_number)) NA else v$bill_number,
                    bill_title = v$bill_title,
                    bill_is_initiative = is_init, roll_call_inverted = is_init,
                    vote_url = vote_url_of(v))
      wide <- c(base, list(source = source), vinfo)
      for (code in sort(names(v$counts), method = "radix")) {
        b <- counts_to_buckets(v$counts[[code]])
        all_codes <- unique(c(all_codes, code))
        gname <- v$group_names[[code]]
        long_rows[[length(long_rows) + 1]] <- c(base, list(source = source), vinfo,
          list(fraction_code = code,
               fraction_name = if (is.null(gname)) fraction_name(code) else gname,
               yes = b[["yes"]], no = b[["no"]], abstain = b[["abstain"]],
               absent = b[["absent"]], total = sum(b)))
        wide[[paste0(code, "_yes")]]     <- b[["yes"]]
        wide[[paste0(code, "_no")]]      <- b[["no"]]
        wide[[paste0(code, "_abstain")]] <- b[["abstain"]]
        wide[[paste0(code, "_absent")]]  <- b[["absent"]]
      }
      wide_rows[[length(wide_rows) + 1]] <- wide
      for (m in v$members) {
        gname <- v$group_names[[m$fraction]]
        member_rows[[length(member_rows) + 1]] <- c(base, list(
          source = source, vote_ref = v$vote_ref, mp_name = m$name,
          fraction_code = m$fraction,
          fraction_name = if (is.null(gname)) fraction_name(m$fraction) else gname,
          canton = m$canton, decision = m$bucket))
      }
    }

    if (i %% 25 == 0) cat(sprintf("  processed %d/%d bills...\n", i, nrow(rows)))
  }

  odc_save()

  long_cols <- c("anr","gesch_nr","entwurf_nr","referendum_date","parl_date",
                 "title_short","source","vote_ref","leg","vote_date",
                 "bill_number","bill_title","bill_is_initiative","roll_call_inverted",
                 "vote_url","fraction_code","fraction_name",
                 "yes","no","abstain","absent","total")
  write_csv_bom(.mk_df(long_rows, long_cols), file.path(OUT, "fraktionen_long.csv"))

  base_cols <- c("anr","gesch_nr","entwurf_nr","referendum_date","parl_date",
                 "title_short","source","vote_ref","leg","vote_date",
                 "bill_number","bill_title","bill_is_initiative","roll_call_inverted",
                 "vote_url")
  frac_cols <- unlist(lapply(sort(all_codes, method = "radix"), function(cc)
    paste0(cc, c("_yes","_no","_abstain","_absent"))))
  write_csv_bom(.mk_df(wide_rows, c(base_cols, frac_cols)),
                file.path(OUT, "fraktionen_wide.csv"))

  mem_cols <- c("anr","gesch_nr","entwurf_nr","referendum_date","parl_date",
                "title_short","source","vote_ref","mp_name","fraction_code",
                "fraction_name","canton","decision")
  write_csv_bom(.mk_df(member_rows, mem_cols),
                file.path(OUT, "fraktionen_members.csv"))

  rep_cols <- c("anr","gesch_nr","entwurf_nr","referendum_date","parl_date",
                "title_short","source","n_votes","vote_refs","vote_urls","note")
  write_csv_bom(.mk_df(report_rows, rep_cols),
                file.path(OUT, "fraktionen_report.csv"))

  src <- vapply(report_rows, function(r) r$source, "")
  cat("\n=== SUMMARY ===\n")
  cat(sprintf("bills total:           %d\n", length(report_rows)))
  cat(sprintf("  via OData (api):     %d\n", sum(src == "api")))
  cat(sprintf("  via PDF (pdf):       %d\n", sum(src == "pdf")))
  cat(sprintf("  via PDF (manual):    %d\n", sum(src == "pdf_manual")))
  cat(sprintf("  via Amtl.Bull. (ab): %d\n", sum(src == "ab")))
  cat(sprintf("  unavailable:         %d\n", sum(src == "unavailable")))
}

if (sys.nframe() == 0L) run()

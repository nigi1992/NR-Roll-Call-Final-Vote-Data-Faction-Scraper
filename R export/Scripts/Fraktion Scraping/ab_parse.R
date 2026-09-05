# ============================================================================
# ab_parse.R — Recover per-fraction Nationalrat final-vote (Schlussabstimmung)
# tallies for the 1994-1999 bills (legislatures 44/45) from the digitised
# *Amtliches Bulletin* "Schlussabstimmungen" pages. R port of ab_parse.py.
#
# For these bills the per-member roll-call PDFs do not exist online, so the AB
# name-lists are the only source. Each collected page (under
# 'Input Data/Fraktion Scraping/neue pdfs/kompliziert/<bizid>-<anr[,anr]>.pdf')
# is a session-day AB page holding several bills.
#
# How it works (same as the Python version):
#  1. column-aware page extraction (two-column layout; name lists span the break)
#  2. vote blocks anchored on the universal 'Fuer Annahme des Entwurfes' heading
#     (handles both the 1999+ layout with '(Ref.: N)' and the 1994-98 layout)
#  3. re-vote blocks ("Ich wiederhole die Abstimmung") supersede their draft
#  4. names resolved against a date-accurate OData roster
#     (MemberParlGroupHistory  intersect  MemberCouncilHistory, NR only), with
#     OCR-tolerant matching: exact tiers, surname-only, bounded Levenshtein
#  5. VALIDATION: yes/no/abstain must equal the printed (N) and fully resolve,
#     else the page is reported and skipped; 'absent' is reconstructed as
#     roster minus voters.
#
# Run standalone for a validation report; scrape_fraktionen.R source()s this
# file and calls load_ab_votes().
# ============================================================================

if (!exists("polite_get")) {
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
}
suppressMessages(library(jsonlite))

AB_ROOT   <- find_root()
AB_IN     <- file.path(AB_ROOT, "Input Data", "Fraktion Scraping")
AB_KOMPL  <- file.path(AB_IN, "neue pdfs", "kompliziert")
AB_ROSTER_CACHE <- file.path(AB_IN, "cache", "ab_roster_cache.json")
AB_CSV    <- file.path(AB_IN, "Fraktion_Scraping.csv")
ODATA     <- "https://ws.parlament.ch/odata.svc"

# --------------------------------------------------------------------------
# Text normalisation
# --------------------------------------------------------------------------
.AB_TR_FROM <- c("ä","ö","ü","ß","é","è","ê",
                 "ë","à","â","ç","ô","î","ï","û")
.AB_TR_TO   <- c("ae","oe","ue","ss","e","e","e","e","a","a","c","o","i","i","u")

ab_translit <- function(x) {
  x <- tolower(ifelse(is.na(x), "", x))
  for (i in seq_along(.AB_TR_FROM))
    x <- gsub(.AB_TR_FROM[i], .AB_TR_TO[i], x, fixed = TRUE)
  x
}

ab_norm <- function(x) gsub("[^a-z0-9]+", "", ab_translit(x))

# function words that show up in many titles -> spurious overlaps
.AB_STOP <- c("fuer","ein","eine","einen","einem","einer","und","oder","der",
              "die","das","den","dem","des","von","vom","zur","zum","ueber",
              "aus","auf","mit","bei","pour","dans","sur","les","des","une",
              "aux","par","avec","entre","contre","sont","dont")

# token set for title overlap; a '...initiative' compound also yields its stem
ab_tok <- function(x) {
  ws <- strsplit(ab_translit(x), "[^a-z0-9]+")[[1]]
  out <- character(0)
  for (w in ws) {
    if (nchar(w) > 3 && !(w %in% .AB_STOP)) {
      out <- c(out, w)
      if (endsWith(w, "initiative") && nchar(w) > nchar("initiative") + 3)
        out <- c(out, substr(w, 1, nchar(w) - nchar("initiative")), "initiative")
    }
  }
  unique(out)
}

# --------------------------------------------------------------------------
# Date-accurate Nationalrat roster (OData, disk-cached)
# --------------------------------------------------------------------------
.roster <- new.env()
.roster$disk <- NULL
.roster$dirty <- FALSE

.roster_load <- function() {
  if (is.null(.roster$disk)) {
    .roster$disk <- if (file.exists(AB_ROSTER_CACHE))
      tryCatch(fromJSON(AB_ROSTER_CACHE, simplifyVector = FALSE),
               error = function(e) list())
    else list()
  }
  invisible(NULL)
}

roster_save <- function() {
  if (isTRUE(.roster$dirty)) {
    dir.create(dirname(AB_ROSTER_CACHE), showWarnings = FALSE, recursive = TRUE)
    write_json(.roster$disk, AB_ROSTER_CACHE, auto_unbox = TRUE)
    .roster$dirty <- FALSE
  }
  invisible(NULL)
}

.odata_rows <- function(path) {
  r <- polite_get(paste0(ODATA, path), accept = "application/json", timeout = 60)
  if (is.null(r) || resp_status(r) != 200) return(list())
  d <- resp_body_json(r)$d
  if (!is.null(d$results)) d$results else d
}

roster_for_date <- function(date_iso) {
  .roster_load()
  if (!is.null(.roster$disk[[date_iso]])) return(.roster$disk[[date_iso]])
  # 10-day grace on DateLeaving: a member who left mid-session still resolves
  # when the CSV dat-parl is the session's last day (kept tight so it does not
  # straddle a December legislature turnover).
  lo <- format(as.Date(date_iso) - 10, "%Y-%m-%d")
  flt <- paste0("Language eq 'DE' and DateJoining le datetime'", date_iso,
                "T00:00:00' and (DateLeaving ge datetime'", lo,
                "T00:00:00' or DateLeaving eq null)")
  q <- utils::URLencode(flt, reserved = TRUE)
  pg <- .odata_rows(paste0("/MemberParlGroupHistory?$filter=", q,
                           "&$select=PersonNumber,LastName,FirstName,",
                           "ParlGroupAbbreviation,ParlGroupName&$top=400&$format=json"))
  qc <- utils::URLencode(paste0(flt, " and Council eq 1"), reserved = TRUE)
  ch <- .odata_rows(paste0("/MemberCouncilHistory?$filter=", qc,
                           "&$select=PersonNumber,OfficialName,CantonAbbreviation,",
                           "ParlGroupAbbreviation&$top=400&$format=json"))
  chby <- list()
  for (r in ch) chby[[as.character(r$PersonNumber)]] <- r
  roster <- list()
  for (r in pg) {
    pn <- as.character(r$PersonNumber)
    if (is.null(chby[[pn]])) next               # Staenderat -> skip
    c0 <- chby[[pn]]
    roster[[length(roster) + 1]] <- list(
      pn = r$PersonNumber, last = r$LastName, first = r$FirstName,
      abbr = r$ParlGroupAbbreviation, name = r$ParlGroupName,
      official = if (is.null(c0$OfficialName)) "" else c0$OfficialName,
      canton = c0$CantonAbbreviation)
  }
  .roster$disk[[date_iso]] <- roster
  .roster$dirty <- TRUE
  roster
}

# --------------------------------------------------------------------------
# Tiered name index + OCR-tolerant matching
# --------------------------------------------------------------------------
.env_add <- function(e, key, val) {
  if (!nzchar(key)) return(invisible(NULL))
  e[[key]] <- c(if (!is.null(e[[key]])) e[[key]] else list(), list(val))
  invisible(NULL)
}

roster_index <- function(roster) {
  A <- new.env(hash = TRUE); B <- new.env(hash = TRUE); C <- new.env(hash = TRUE)
  for (m in roster) {
    last <- m$last; first <- m$first; off <- m$official
    .env_add(A, ab_norm(last), m)
    if (nzchar(off)) .env_add(A, ab_norm(off), m)
    ft <- strsplit(gsub(".", " ", first, fixed = TRUE), "\\s+")[[1]]
    ft <- ft[nzchar(ft)]
    .env_add(B, ab_norm(paste0(last, first)), m)
    for (t in unique(c(ft[1], ft[length(ft)])))
      if (length(ft)) .env_add(B, ab_norm(paste0(last, t)), m)
    # first component of a multi-part surname (space- or hyphen-joined):
    # Roth-Bernasconi -> 'Roth', Aeppli Wartmann -> 'Aeppli'
    lw <- strsplit(last, "[ -]")[[1]]
    if (length(lw) > 1 && nzchar(lw[1])) {
      .env_add(C, ab_norm(lw[1]), m)
      if (length(ft)) .env_add(C, ab_norm(paste0(lw[1], ft[1])), m)
    }
  }
  list(A = A, B = B, C = C)
}

# bloc map (only to let same-bloc ambiguity resolve quietly; the real roll-up
# lives in blocs.R, which understands these same codes)
.AB_BLOC <- c(S = "S", G = "G", V = "V", GL = "GL", `M-E` = "ME", RL = "RL",
              L = "RL", F = "other", U = "other", FRAKTIONSLOS = "other")

.bloc_of <- function(abbr) if (abbr %in% names(.AB_BLOC)) .AB_BLOC[[abbr]] else "other"

.resolve_members <- function(members) {
  pns <- vapply(members, function(m) as.character(m$pn), "")
  uniq <- members[!duplicated(pns)]
  if (length(uniq) == 1) return(list(member = uniq[[1]], reason = NULL))
  blocs <- unique(vapply(uniq, function(m) .bloc_of(m$abbr), ""))
  if (length(blocs) == 1) return(list(member = uniq[[1]], reason = "ambiguous-same-bloc"))
  who <- sort(vapply(uniq, function(m) paste0(m$last, "/", m$abbr), ""))
  list(member = NULL, reason = paste0("ambiguous:", paste(who, collapse = ",")))
}

match_name <- function(ab, idx) {
  n <- ab_norm(ab)
  for (tier in list(idx$A, idx$B, idx$C)) {
    hit <- tier[[n]]
    if (!is.null(hit)) return(.resolve_members(hit))
  }
  # surname-only: drop trailing (first-name) tokens, keep a unique surname
  toks <- strsplit(ab, "\\s+")[[1]]
  if (length(toks) > 1) for (k in (length(toks) - 1):1) {
    pn <- ab_norm(paste(toks[1:k], collapse = " "))
    hit <- idx$A[[pn]]
    if (!is.null(hit)) {
      pns <- vapply(hit, function(m) as.character(m$pn), "")
      uniq <- hit[!duplicated(pns)]
      if (length(uniq) == 1)
        return(list(member = uniq[[1]], reason = "surname-only"))
    }
  }
  # fuzzy (OCR): nearest key in the identity / last+first tiers (Levenshtein)
  if (nchar(n) >= 4) {
    maxd <- if (nchar(n) < 5) 1L else 2L
    best_d <- maxd + 1L; hits <- list()
    for (tier in list(idx$A, idx$B)) {
      keys <- ls(tier)
      if (!length(keys)) next
      d <- as.integer(utils::adist(n, keys))
      cand <- which(d <= maxd)
      for (ci in cand) {
        if (d[ci] < best_d) { best_d <- d[ci]; hits <- tier[[keys[ci]]] }
        else if (d[ci] == best_d) hits <- c(hits, tier[[keys[ci]]])
      }
    }
    if (length(hits)) {
      r <- .resolve_members(hits)
      if (!is.null(r$member))
        return(list(member = r$member, reason = paste0("fuzzy~", best_d)))
      return(r)
    }
  }
  list(member = NULL, reason = "no-match")
}

# --------------------------------------------------------------------------
# AB page parsing
# --------------------------------------------------------------------------
.MONTHS <- paste0("Januar|Februar|März|April|Mai|Juni|Juli|August|September|",
                  "Oktober|November|Dezember|janvier|février|mars|avril|mai|",
                  "juin|juillet|août|septembre|octobre|novembre|décembre")
.NOISE_RX <- paste0(
  "^(Amtliches Bulletin|Bulletin officiel|Bollettino|Votations? finales?|",
  "\\d+\\s+Schlussabstimmungen|\\d+\\s+Votations|Schlussabstimmungen|",
  "N?\\s*\\d{0,2}\\.?\\s*(", .MONTHS, ")[\\dN .]*$|",
  "\\d{1,4}\\s*N$|N\\s*\\d{1,4}$|#\\w{0,3}#|",
  "Communications? (de|du)|Mitteilungen des|Kommuniqué|",
  ".*Bundesversammlung$|.*Assemblée fédérale$|f[üu]r das Amtliche|",
  "Schweizerisches Bundesarchiv|Archives fédérales|Archivio federale)")
.HEAD_RX <- c(   # order matters: first match wins
  yes = "F[üu]r (den |die )?Annahme des Entwurfes|Acceptent le projet",
  no  = paste0("Dagegen stimmen|Rejettent le projet|Gegen den Entwurf|",
               "Ablehnung des Entwurfes"),
  abstain = "Der Stimme enthalten|abstiennent",
  absent  = "Entschuldigt|abwesend sind|Abwesend sind|Sont excus|Sont absents",
  president = paste0("Pr[äae]sid(ium|ent|entin).*stimmt nicht|",
                     "[Pp]r[ée]siden.*ne vote|sidence.*ne vote"),
  # 'present but did not vote' - recognised only to terminate the previous
  # bucket; these members are folded into the reconstructed 'absent'.
  novote = "Stimmen nicht|Ne votent pas")
.REF_RX  <- "\\(Ref\\.?:?\\s*0*(\\d+)\\)"
.BIZ_RX  <- "^(\\d{2}\\.\\d{3})\\s*$"
.NAMENTL_RX <- "Namentliche\\s+(Schluss)?[Aa]bstimmung|Vote nominatif|appel nominal"
.COUNT_END_RX <- "\\(\\s*(\\d+)\\s*\\)\\s*$"
.REPEAT_RX <- "wiederhol|Wiederholung der Abstimmung|r[ée]it[ée]r|r[ée]p[èé]t"
.LETTER_RX <- "^([A-C])\\.\\s+\\S"
.SEP_RX <- paste0("^_{5,}$|Schlussabstimmung\\s*[–-]\\s*Vote final|^Siehe Seite|",
                  "^Voir page|^Beschluss des|^D[ée]cision du|\\(.*Beifall\\)|",
                  "\\(.*Unruhe\\)|\\(Applaud|\\(Teilweis|brouhaha|^Pr[äa]sident")
.SPEAKER_RX <- paste0("^[A-ZÄÖÜ][\\wäöü-]+.*",
                      "\\([A-Z][^)]*,\\s*[A-Z]{2}\\)\\s*:")
.INLINE_HDR_RX <- paste0("\\s*\\d{0,4}\\s*N\\s*\\d{1,2}\\.?\\s*(", .MONTHS,
                         ")\\s*\\d{2,4}\\s*")

.grepl1 <- function(rx, x) grepl(rx, x, perl = TRUE, ignore.case = TRUE)

# two-column-aware line reconstruction: col0 (left) lines then col1
ab_col_lines <- function(words, page_width) {
  if (nrow(words) == 0) return(character(0))
  mid <- (words$x + words$x + words$width) / 2
  out <- character(0)
  for (side in 0:1) {
    w <- words[if (side == 0) mid < page_width / 2 else mid >= page_width / 2, ,
               drop = FALSE]
    if (nrow(w) == 0) next
    w <- w[order(round(w$y / 3), w$x), , drop = FALSE]
    cur <- character(0); lt <- NA_real_
    for (i in seq_len(nrow(w))) {
      if (!is.na(lt) && abs(w$y[i] - lt) >= 3) {
        out <- c(out, paste(cur, collapse = " ")); cur <- character(0)
      }
      cur <- c(cur, w$text[i]); lt <- w$y[i]
    }
    if (length(cur)) out <- c(out, paste(cur, collapse = " "))
  }
  out
}

ab_all_lines <- function(pdfpath) {
  pages <- pdf_data(pdfpath)
  sizes <- pdf_pagesize(pdfpath)
  out <- character(0)
  for (p in seq_along(pages)) {
    for (ln in ab_col_lines(pages[[p]], sizes$width[p])) {
      t <- gsub(.INLINE_HDR_RX, " ", ln, perl = TRUE, ignore.case = TRUE)
      t <- trimws(gsub("#\\w{0,4}#", " ", t, perl = TRUE))
      if (nzchar(t) && !.grepl1(.NOISE_RX, t)) out <- c(out, t)
    }
  }
  out
}

# concatenate wrapped name-list lines; a trailing '-' is a line-break wrap
ab_join_names <- function(lines) {
  out <- ""
  for (ln in lines) {
    ln <- trimws(ln)
    if (!nzchar(ln)) next
    if (!nzchar(out)) out <- ln
    else if (endsWith(out, "-")) {
      core <- substr(out, 1, nchar(out) - 1)
      first <- substr(ln, 1, 1)
      out <- if (first %in% c(LETTERS, "Ä", "Ö", "Ü"))
        paste0(core, "-", ln) else paste0(core, ln)   # compound vs syllable wrap
    } else out <- paste(out, ln)
  }
  out
}

ab_split_names <- function(text) {
  m <- regexec(.COUNT_END_RX, text, perl = TRUE)[[1]]
  printed <- NA_integer_
  if (m[1] > 0) {
    printed <- as.integer(regmatches(text, list(m))[[1]][2])
    text <- substr(text, 1, m[1] - 1)
  }
  # old scans sometimes glue two names with '.' instead of ', '
  text <- gsub("(?<=[a-zäöü])\\.(?=[A-ZÄÖÜ])", ",",
               text, perl = TRUE)
  parts <- trimws(gsub("^[ .]+|[ .]+$", "", strsplit(text, ",", fixed = TRUE)[[1]]))
  list(names = parts[nzchar(parts)], printed = printed)
}

# ordered vote blocks; anchored on the universal 'Fuer Annahme' heading
ab_parse_blocks <- function(lines) {
  n <- length(lines)
  yesidx <- which(.grepl1(.HEAD_RX[["yes"]], lines))
  blocks <- list()
  for (k in seq_along(yesidx)) {
    yi <- yesidx[k]
    prev <- if (k > 1) yesidx[k - 1] else 0L
    end <- if (k < length(yesidx)) yesidx[k + 1] else n + 1L
    nidx <- yi
    if (yi - 1 >= prev + 1) for (j in (yi - 1):(prev + 1)) {
      if (.grepl1(.NAMENTL_RX, lines[j])) { nidx <- j; break }
    }
    header <- if (yi - 1 >= prev + 1) lines[(prev + 1):(yi - 1)] else character(0)
    ref <- NA_integer_
    for (g in header) {
      mm <- regexec(.REF_RX, g, perl = TRUE)[[1]]
      if (mm[1] > 0) { ref <- as.integer(regmatches(g, list(mm))[[1]][2]); break }
    }
    biz <- NA_character_
    if (yi > 1) for (j in (yi - 1):1) {
      mm <- regexec(.BIZ_RX, lines[j], perl = TRUE)[[1]]
      if (mm[1] > 0) { biz <- regmatches(lines[j], list(mm))[[1]][2]; break }
    }
    repeat_ <- any(.grepl1(.REPEAT_RX, header))
    letter <- NA_character_
    for (g in header) {
      mm <- regexec(.LETTER_RX, g, perl = TRUE)[[1]]
      if (mm[1] > 0) { letter <- regmatches(g, list(mm))[[1]][2]; break }
    }
    title_lines <- character(0)
    if (nidx - 1 >= prev + 1) for (j in (nidx - 1):(prev + 1)) {
      g <- lines[j]
      if (.grepl1(.SEP_RX, g) || grepl(.SPEAKER_RX, g, perl = TRUE) ||
          grepl(.BIZ_RX, g, perl = TRUE)) break
      title_lines <- c(g, title_lines)
      if (length(title_lines) >= 6) break
    }
    title <- paste(title_lines, collapse = " ")

    buckets <- list()
    cur <- NULL; acc <- character(0)
    flush <- function() {
      if (!is.null(cur) && length(acc)) {
        sp <- ab_split_names(ab_join_names(acc))
        buckets[[cur]] <<- sp
      }
    }
    for (ln in lines[yi:min(end - 1, n)]) {
      h <- NULL
      for (b in names(.HEAD_RX)) if (.grepl1(.HEAD_RX[[b]], ln)) { h <- b; break }
      if (!is.null(h)) {
        flush()
        cur <- h
        after <- if (grepl(":", ln, fixed = TRUE)) sub("^[^:]*:", "", ln) else ""
        acc <- if (nzchar(trimws(after))) after else character(0)
      } else if (!is.null(cur)) {
        acc <- c(acc, ln)
        if (grepl(.COUNT_END_RX, ln, perl = TRUE)) {   # bucket closes at its (N)
          flush(); cur <- NULL; acc <- character(0)
        }
      }
    }
    flush()
    blocks[[length(blocks) + 1]] <- list(ref = ref, pos = yi, biz = biz,
                                         title = title, letter = letter,
                                         repeat_ = repeat_, buckets = buckets)
  }
  blocks
}

# collapse re-votes: a 'wiederhole' block supersedes the previous draft
ab_group_drafts <- function(blocks) {
  drafts <- list()
  last_for_biz <- list()
  for (b in blocks) {
    bizk <- if (is.na(b$biz)) "\r_nobiz" else b$biz
    if (isTRUE(b$repeat_) && !is.null(last_for_biz[[bizk]])) {
      i <- last_for_biz[[bizk]]
      drafts[[i]]$ref <- b$ref
      drafts[[i]]$pos <- b$pos
      drafts[[i]]$buckets <- b$buckets
      next
    }
    drafts[[length(drafts) + 1]] <- list(biz = b$biz, title = b$title,
                                         ref = b$ref, pos = b$pos,
                                         buckets = b$buckets, letter = b$letter)
    last_for_biz[[bizk]] <- length(drafts)
  }
  drafts
}

# --------------------------------------------------------------------------
# anr -> draft selection + name resolution
# --------------------------------------------------------------------------
norm_anr <- function(a) {
  a <- trimws(ifelse(is.na(a), "", a))
  f <- suppressWarnings(as.numeric(a))
  if (!is.na(f) && f == as.integer(f)) as.character(as.integer(f)) else a
}

ab_dat_iso <- function(d) {
  m <- regexec("(\\d{2})/(\\d{2})/(\\d{4})", ifelse(is.na(d), "", d))[[1]]
  if (m[1] < 1) return(NA_character_)
  p <- regmatches(d, list(m))[[1]]
  paste0(p[4], "-", p[3], "-", p[2])
}

ab_leg_for <- function(date_iso) {
  y <- as.integer(substr(date_iso, 1, 4)); m <- as.integer(substr(date_iso, 6, 7))
  if ((y > 1995 || (y == 1995 && m >= 12)) && (y < 1999 || (y == 1999 && m < 12)))
    return(45L)
  if (y >= 1999 && !(y == 1999 && m < 12)) return(46L)
  44L
}

ab_select_draft <- function(drafts, gesch_short, titel, entwurf, strict = FALSE) {
  cands <- Filter(function(d) !is.na(d$biz) && identical(d$biz, gesch_short), drafts)
  if (!length(cands)) cands <- drafts
  if (!length(cands)) return(NULL)
  want <- ab_tok(titel)
  score <- vapply(cands, function(d) length(intersect(ab_tok(d$title), want)), 0L)
  if (length(cands) == 1) {
    if (strict && score[1] == 0) return(NULL)
    return(cands[[1]])
  }
  best_score <- max(score)
  if (best_score == 0) {
    if (strict) return(NULL)
    # no title signal -> fall back to draft (entwurf) order (1 -> A, ...)
    e <- suppressWarnings(as.integer(entwurf))
    ord <- order(vapply(cands, function(d) d$pos, 0L))
    if (!is.na(e) && e >= 1 && e <= length(cands)) return(cands[[ord[e]]])
    return(cands[[which.max(score)]])
  }
  tied <- which(score == best_score)
  if (length(tied) > 1) {
    e <- suppressWarnings(as.integer(entwurf))
    ord <- tied[order(vapply(cands[tied], function(d) d$pos, 0L))]
    if (!is.na(e) && e >= 1 && e <= length(ord)) return(cands[[ord[e]]])
  }
  cands[[which.max(score)]]
}

ab_resolve_draft <- function(draft, roster) {
  idx <- roster_index(roster)
  by_pn <- list()
  for (m in roster) by_pn[[as.character(m$pn)]] <- m
  counts <- list(); members <- list()
  assigned <- list()                   # pn -> bucket
  flags <- character(0); warnings <- character(0); checks <- list()
  add_count <- function(abbr, bucket) {
    if (is.null(counts[[abbr]])) counts[[abbr]] <<- list()
    v <- counts[[abbr]][[bucket]]
    counts[[abbr]][[bucket]] <<- (if (is.null(v)) 0L else v) + 1L
  }
  for (bucket in c("yes", "no", "abstain", "president")) {
    bl <- draft$buckets[[bucket]]
    if (is.null(bl)) next
    nms <- bl$names; printed <- bl$printed
    matched <- 0L
    for (nm in nms) {
      r <- match_name(nm, idx)
      m <- r$member
      if (is.null(m)) {
        flags <- c(flags, sprintf("%s:%s(%s)", bucket, nm, r$reason)); next
      }
      pn <- as.character(m$pn)
      if (!is.null(assigned[[pn]])) {
        flags <- c(flags, sprintf("%s:%s(dup of %s)", bucket, nm, assigned[[pn]]))
        next
      }
      assigned[[pn]] <- bucket
      add_count(m$abbr, bucket)
      members[[length(members) + 1]] <- list(
        name = trimws(paste(m$last, m$first)), fraction = m$abbr,
        canton = m$canton, bucket = bucket)
      matched <- matched + 1L
    }
    checks[[bucket]] <- list(parsed = length(nms), printed = printed,
                             matched = matched)
    if (bucket %in% c("yes", "no", "abstain")) {     # hard gate
      if (!is.na(printed) && printed != length(nms))
        flags <- c(flags, sprintf("%s: parsed %d != printed %d",
                                  bucket, length(nms), printed))
      if (matched != length(nms))
        flags <- c(flags, sprintf("%s: matched %d != parsed %d",
                                  bucket, matched, length(nms)))
    }
  }
  # reconstruct 'absent' = roster minus everyone who voted / chaired
  absent_pns <- setdiff(names(by_pn), names(assigned))
  pa <- draft$buckets[["absent"]]
  if (is.null(pa)) pa <- list(names = character(0), printed = NA_integer_)
  for (pn in absent_pns) {
    m <- by_pn[[pn]]
    add_count(m$abbr, "absent")
    members[[length(members) + 1]] <- list(
      name = trimws(paste(m$last, m$first)), fraction = m$abbr,
      canton = m$canton, bucket = "absent")
  }
  checks[["absent"]] <- list(parsed = length(pa$names), printed = pa$printed,
                             reconstructed = length(absent_pns))
  if (!is.na(pa$printed) && pa$printed != length(absent_pns))
    warnings <- c(warnings, sprintf(
      "absent: printed %d != reconstructed %d (roster %d; non-voters only)",
      pa$printed, length(absent_pns), length(roster)))
  report <- list(ref = draft$ref, biz = draft$biz, title = draft$title,
                 roster_n = length(roster), assigned = length(assigned),
                 checks = checks, flags = flags, warnings = warnings,
                 ok = length(flags) == 0)
  list(counts = counts, members = members, report = report)
}

# --------------------------------------------------------------------------
# Public entry point
# --------------------------------------------------------------------------
load_ab_votes <- function() {
  rows <- read.csv(AB_CSV, colClasses = "character",
                   fileEncoding = "UTF-8-BOM", check.names = FALSE)
  bycsv <- split(rows, vapply(rows$anr, norm_anr, ""))
  out <- list(); reports <- list()
  for (f in sort(list.files(AB_KOMPL, pattern = "\\.pdf$", full.names = TRUE))) {
    base <- basename(f)
    mm <- regexec("(.+)-([0-9,]+)\\.pdf$", base)[[1]]
    if (mm[1] < 1) next
    anrs <- strsplit(regmatches(base, list(mm))[[1]][3], ",", fixed = TRUE)[[1]]
    anrs <- vapply(anrs, norm_anr, "")
    # expand a filename anr that is sub-numbered in the CSV (465 -> 465.1/.2/.3);
    # each sub-row is matched strictly (only those actually on the page resolve)
    targets <- list()
    for (a in anrs) {
      if (!is.null(bycsv[[a]])) {
        targets[[length(targets) + 1]] <- list(anr = a, strict = FALSE)
      } else {
        subs <- sort(grep(paste0("^", gsub("\\.", "\\\\.", a), "\\.\\d+$"),
                          names(bycsv), value = TRUE, perl = TRUE))
        if (length(subs)) {
          for (s in subs)
            targets[[length(targets) + 1]] <- list(anr = s, strict = TRUE)
        } else {
          reports[[length(reports) + 1]] <-
            list(file = base, anr = a, skip = "anr not in CSV")
        }
      }
    }
    drafts <- tryCatch(ab_group_drafts(ab_parse_blocks(ab_all_lines(f))),
                       error = function(e) e)
    if (inherits(drafts, "error")) {
      reports[[length(reports) + 1]] <- list(file = base,
                                             error = conditionMessage(drafts))
      next
    }
    for (tg in targets) {
      anr <- tg$anr
      row <- bycsv[[anr]][1, ]
      rechtsform <- trimws(ifelse(is.na(row$rechtsform), "", row$rechtsform))
      if (rechtsform == "5") next     # Stichfrage: referendum tie-break ballot,
                                      # never a parliamentary Schlussabstimmung
      gesch_short <- business_short_norm(row$gesch_nr)
      date_iso <- ab_dat_iso(row[["dat-parl"]])
      if (is.na(date_iso)) {
        reports[[length(reports) + 1]] <- list(file = base, anr = anr,
                                               skip = "no dat-parl")
        next
      }
      is_init <- if (rechtsform == "3") 1L else 0L
      draft <- ab_select_draft(drafts, gesch_short, row$titel_kurz_d,
                               row$entwurf_nr, strict = tg$strict)
      if (is.null(draft)) {
        reports[[length(reports) + 1]] <- list(
          file = base, anr = anr, expected = tg$strict,
          skip = "no matching Schlussabstimmung block on this page")
        next
      }
      roster <- roster_for_date(date_iso)
      res <- ab_resolve_draft(draft, roster)
      rep <- res$report
      rep$file <- base; rep$anr <- anr
      rep$gesch <- gesch_display(row$gesch_nr); rep$date <- date_iso
      reports[[length(reports) + 1]] <- rep
      if (!isTRUE(rep$ok)) next
      group_names <- list()
      for (abbr in names(res$counts)) {
        gn <- NULL
        for (m in roster) if (identical(m$abbr, abbr)) { gn <- m$name; break }
        group_names[[abbr]] <- if (is.null(gn)) fraction_name(abbr) else gn
      }
      out[[anr]] <- list(
        vote_ref = draft$ref, leg = ab_leg_for(date_iso),
        vote_date = paste0(substr(date_iso, 9, 10), ".",
                           substr(date_iso, 6, 7), ".", substr(date_iso, 1, 4)),
        bill_number = row$entwurf_nr,
        bill_title = if (nzchar(draft$title)) substr(draft$title, 1, 300)
                     else row$titel_kurz_d,
        bill_is_initiative = is_init,
        counts = res$counts, group_names = group_names,
        members = res$members, n_members = length(res$members),
        is_final = TRUE, subject = "Schlussabstimmung",
        source_file = base, vote_url = "",
        ab_report = rep)
    }
  }
  roster_save()
  list(votes = out, reports = reports)
}

# --------------------------------------------------------------------------
# Standalone validation report
# --------------------------------------------------------------------------
ab_print_report <- function(reports) {
  has_checks <- Filter(function(r) !is.null(r$checks), reports)
  has_checks <- has_checks[order(vapply(has_checks, function(r)
    if (is.null(r$anr)) "" else r$anr, ""))]
  cat(strrep("=", 72), "\n")
  cat("Amtliches-Bulletin parser - validation report (R)\n")
  cat(strrep("=", 72), "\n")
  n_ok <- 0; n_bad <- 0
  for (r in has_checks) {
    if (isTRUE(r$ok)) n_ok <- n_ok + 1 else n_bad <- n_bad + 1
    sizes <- character(0)
    for (b in c("yes", "no", "abstain", "absent", "president")) {
      cc <- r$checks[[b]]
      if (is.null(cc)) next
      got <- if (!is.null(cc$matched)) cc$matched else cc$reconstructed
      sizes <- c(sizes, sprintf("%s=%s/%s", b, got,
                                ifelse(is.na(cc$printed), "NA", cc$printed)))
    }
    cat(sprintf("[%s] anr %4s gesch %7s ref %s  roster=%d assigned=%d\n",
                ifelse(isTRUE(r$ok), "OK ", "FAIL"), r$anr, r$gesch,
                ifelse(is.na(r$ref), "None", r$ref), r$roster_n, r$assigned))
    cat("        ", paste(sizes, collapse = " "),
        sprintf("  title='%s'\n", substr(r$title, 1, 48)))
    for (fl in r$flags) cat("        FLAG:", fl, "\n")
    for (wn in r$warnings) cat("        note:", wn, "\n")
  }
  skips <- Filter(function(r) !is.null(r$skip) || !is.null(r$error), reports)
  for (r in skips)
    cat("[SKIP]", r$file, "anr", ifelse(is.null(r$anr), "?", r$anr), "-",
        ifelse(is.null(r$skip), r$error, r$skip), "\n")
  cat(strrep("-", 72), "\n")
  cat(sprintf("OK: %d   FAIL: %d   SKIP: %d\n", n_ok, n_bad, length(skips)))
}

if (sys.nframe() == 0L) {
  res <- load_ab_votes()
  ab_print_report(res$reports)
  cat(sprintf("\nresolved %d anr(s): %s\n", length(res$votes),
              paste(sort(names(res$votes)), collapse = ", ")))
}

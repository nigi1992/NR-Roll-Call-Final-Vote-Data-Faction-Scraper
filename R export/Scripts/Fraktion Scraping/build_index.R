# ============================================================================
# build_index.R — Enumerate the Nationalrat roll-call PDFs for the legislatures
# the OData API does not cover (leg 46 -> Dec 1999 - Oct 2003) and build the
# local index keyed 'leg:ref'. R port of build_index.py.
#
# Only *recorded* (namentlich) votes have a PDF and the ref numbers are
# scattered, so every ref is probed:
#   * polite    - global rate cap + backoff on 403 (parlament.ch throttling)
#   * resumable - checked refs remembered in cache/scan_state.json
#   * cached    - found PDFs parsed once into cache/pdf_index.json
#                 (raw bytes kept under cache/pdfs/ for provenance)
#
# NOTE: the shipped Input Data already contains the finished pdf_index.json
# (1233 PDFs, built by the Python pipeline and byte-verified against this
# parser). You only need this script to re-scan (new refs) or --reparse after
# changing parse_pdf(). Legs 44/45 return 404 (they only exist as Amtliches-
# Bulletin pages -> ab_parse.R).
#
# Usage (from RStudio, working dir anywhere in the project):
#   source("Scripts/Fraktion Scraping/build_index.R")      # scan leg 46
# or from a terminal:
#   Rscript "Scripts/Fraktion Scraping/build_index.R" [--reparse]
#           [--legs 46] [--min-ref 1] [--max-ref 5200]
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
suppressMessages(library(jsonlite))

ROOT   <- find_root()
CACHE  <- file.path(ROOT, "Input Data", "Fraktion Scraping", "cache")
PDF_DIR    <- file.path(CACHE, "pdfs")
INDEX_PATH <- file.path(CACHE, "pdf_index.json")
STATE_PATH <- file.path(CACHE, "scan_state.json")

# defaults (override via command line)
OPT <- list(legs = 46L, min_ref = 1L, max_ref = 5200L, reparse = FALSE)
args <- commandArgs(trailingOnly = TRUE)
i <- 1
while (i <= length(args)) {
  a <- args[i]
  if (a == "--reparse") { OPT$reparse <- TRUE; i <- i + 1 }
  else if (a == "--legs")    { OPT$legs    <- as.integer(args[i + 1]); i <- i + 2 }
  else if (a == "--min-ref") { OPT$min_ref <- as.integer(args[i + 1]); i <- i + 2 }
  else if (a == "--max-ref") { OPT$max_ref <- as.integer(args[i + 1]); i <- i + 2 }
  else i <- i + 1
}

load_json <- function(path, default) {
  if (file.exists(path)) fromJSON(path, simplifyVector = FALSE) else default
}
save_json_atomic <- function(path, obj) {
  tmp <- paste0(path, ".tmp")
  write_json(obj, tmp, auto_unbox = TRUE, na = "null", null = "null")
  file.rename(tmp, path)
}

.finish_rec <- function(rec, leg, ref) {
  rec$leg <- leg; rec$ref <- ref; rec$url <- pdf_url(leg, ref)
  rec
}

reparse <- function() {
  files <- sort(list.files(PDF_DIR, pattern = "^vote_\\d+_\\d+\\.pdf$",
                           full.names = TRUE))
  cat(sprintf("re-parsing %d cached PDFs ...\n", length(files)))
  index <- list()
  for (n in seq_along(files)) {
    f <- files[n]
    m <- regmatches(f, regexec("vote_(\\d+)_(\\d+)\\.pdf$", f))[[1]]
    leg <- as.integer(m[2]); ref <- as.integer(m[3])
    rec <- tryCatch(parse_pdf(f),
                    error = function(e) list(parse_error = conditionMessage(e)))
    if (!is.null(rec))
      index[[sprintf("%d:%d", leg, ref)]] <- .finish_rec(rec, leg, ref)
    if (n %% 200 == 0) cat(sprintf("  %d/%d\n", n, length(files)))
  }
  save_json_atomic(INDEX_PATH, index)
  finals <- sum(vapply(index, function(v) isTRUE(v$is_final), TRUE))
  cat(sprintf("re-parsed %d PDFs, %d final votes -> %s\n",
              length(index), finals, INDEX_PATH))
}

scan <- function() {
  dir.create(PDF_DIR, showWarnings = FALSE, recursive = TRUE)
  index <- load_json(INDEX_PATH, list())
  state <- load_json(STATE_PATH, list())

  for (leg in OPT$legs) {
    legk <- as.character(leg)
    done <- as.integer(unlist(state[[legk]]$done))
    todo <- setdiff(seq(OPT$min_ref, OPT$max_ref), done)
    cat(sprintf("[leg %d] %d refs to check (%d already done)\n",
                leg, length(todo), length(done)))
    n_retry <- 0; last_save <- Sys.time()
    for (n in seq_along(todo)) {
      ref <- todo[n]
      url <- pdf_url(leg, ref)
      r <- polite_get(url, timeout = 30)
      status <- "retry"
      if (!is.null(r)) {
        st <- resp_status(r)
        if (st == 200) {
          body <- resp_body_raw(r)
          if (length(body) > 4 && rawToChar(body[1:4]) == "%PDF") {
            fp <- file.path(PDF_DIR, sprintf("vote_%d_%d.pdf", leg, ref))
            writeBin(body, fp)      # keep raw pdf for provenance / re-parsing
            rec <- tryCatch(parse_pdf(fp),
                            error = function(e) list(parse_error = conditionMessage(e)))
            if (!is.null(rec)) {
              index[[sprintf("%d:%d", leg, ref)]] <- .finish_rec(rec, leg, ref)
              status <- "hit"
              cat(sprintf("  HIT  leg %d ref %5d  %s  biz=%s date=%s n=%s\n",
                          leg, ref, ifelse(isTRUE(rec$is_final), "FINAL", "     "),
                          ifelse(is.na(rec$business_short), "-", rec$business_short),
                          ifelse(is.na(rec$date), "-", rec$date), rec$n_members))
            } else status <- "miss"
          } else status <- "miss"
        } else if (st == 404) status <- "miss"    # definitively absent
        # 403/5xx stay "retry": not recorded as done, re-probed on a later run
      }
      if (status != "retry") done <- c(done, ref) else n_retry <- n_retry + 1
      if (difftime(Sys.time(), last_save, units = "secs") > 20 || n %% 500 == 0) {
        state[[legk]] <- list(done = sort(done))
        save_json_atomic(INDEX_PATH, index)
        save_json_atomic(STATE_PATH, state)
        last_save <- Sys.time()
        cat(sprintf("  .. leg %d progress %d/%d\n", leg, n, length(todo)))
      }
    }
    state[[legk]] <- list(done = sort(done))
    save_json_atomic(INDEX_PATH, index)
    save_json_atomic(STATE_PATH, state)
    keys <- names(index)
    leg_hits <- sum(startsWith(keys, paste0(leg, ":")))
    cat(sprintf("[leg %d] DONE - %d PDFs in index%s\n", leg, leg_hits,
                if (n_retry) sprintf(", %d throttled (re-run to retry)", n_retry)
                else ""))
  }
}

if (OPT$reparse) reparse() else scan()

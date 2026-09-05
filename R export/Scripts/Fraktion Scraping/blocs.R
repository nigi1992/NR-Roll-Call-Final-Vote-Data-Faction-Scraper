# ============================================================================
# blocs.R — Roll the changing fraction codes into 7 stable blocs and produce
# substance-oriented predictors for modelling the national Yes-share.
# R port of blocs.py (same logic, same outputs).
#
# Blocs (codes per 'Faktenblatt Fraktionen-d.pdf'):
#   S     Sozialdemokratische Fraktion
#   G     Gruene Fraktion
#   GL    Gruenliberale Fraktion (glp)
#   ME    Mitte: C, CE, CEg, BD, M-E, M-CEB  +  E (EVP/EDU)   *see EDU note
#   RL    FDP-Liberale: R, L, RL
#   V     SVP-Fraktion
#   other fraktionslos & right-fringe: -, U, W, F, D-1, D-2, FRAKTIONSLOS
#
# ORIENTATION: on a 'Bundesbeschluss ueber die Volksinitiative' a parliamentary
# Ja means "recommend rejection", so the roll call is inverted relative to
# support for the proposal's substance:
#   support = Nein if inverted else Ja ;  oppose = Ja if inverted else Nein
#
# Input : Output/Fraktion Scraping/fraktionen_long.csv
# Output: Output/Fraktion Scraping/fraktionen_blocs_long.csv
#         Output/Fraktion Scraping/fraktionen_blocs_wide.csv
# ============================================================================

# --- locate the project root (works from any working directory inside it) ---
find_root <- function() {
  d <- normalizePath(getwd())
  for (i in 1:6) {
    if (dir.exists(file.path(d, "Input Data")) && dir.exists(file.path(d, "Scripts")))
      return(d)
    p <- dirname(d)
    if (p == d) break
    d <- p
  }
  stop("Project root not found - open the .Rproj / set the working directory ",
       "to 'Swiss Popular Votes ML Forecasting Application'")
}
ROOT <- find_root()
OUT  <- file.path(ROOT, "Output", "Fraktion Scraping")
LONG <- file.path(OUT, "fraktionen_long.csv")
if (!file.exists(LONG))   # fall back to Input Data if the pipeline hasn't run here
  LONG <- file.path(ROOT, "Input Data", "Fraktion Scraping", "fraktionen_long.csv")

# raw fraction code -> bloc
BLOC <- c(S = "S", G = "G", V = "V", GL = "GL",
          C = "ME", CE = "ME", CEg = "ME", BD = "ME", `M-E` = "ME", `M-CEB` = "ME",
          E = "ME",
          R = "RL", L = "RL", RL = "RL",
          `-` = "other", U = "other", W = "other", FRAKTIONSLOS = "other")
BLOCS <- c("S", "G", "GL", "ME", "RL", "V")   # left -> right (excl. other)
LR <- c(G = -8.0, S = -6.5, GL = -1.5, ME = 1.5, RL = 5.5, V = 8.5)
# ^ indicative left-right placements; replace with a cited scale for the thesis.

write_csv_bom <- function(df, path) {
  con <- file(path, open = "wb")
  writeBin(as.raw(c(0xEF, 0xBB, 0xBF)), con)   # UTF-8 BOM (Excel-friendly)
  close(con)
  con <- file(path, open = "a", encoding = "UTF-8")
  write.csv(df, con, row.names = FALSE, na = "")
  close(con)
  cat(sprintf("wrote %s  (%d rows)\n", path, nrow(df)))
}

run <- function() {
  rows <- read.csv(LONG, colClasses = "character",
                   fileEncoding = "UTF-8-BOM", check.names = FALSE)
  rows$bloc <- ifelse(rows$fraction_code %in% names(BLOC),
                      BLOC[rows$fraction_code], "other")
  key <- paste(rows$anr, rows$vote_ref, sep = "\r")
  vote_keys <- unique(key)                     # keep file (first-appearance) order

  meta_cols <- c("anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
                 "title_short", "source", "vote_ref", "leg", "vote_date",
                 "vote_url", "bill_title", "bill_is_initiative")

  long_out <- list(); wide_out <- list()
  for (k in vote_keys) {
    g <- rows[key == k, , drop = FALSE]
    m <- g[1, ]                                # meta identical within a vote
    inverted <- (nzchar(m$roll_call_inverted) && m$roll_call_inverted == "1") ||
                (!nzchar(m$roll_call_inverted) &&
                 nzchar(m$bill_is_initiative) && m$bill_is_initiative == "1")
    base <- as.list(m[meta_cols])
    base$roll_call_inverted <- if (inverted) 1L else 0L

    wide <- base
    majority_support <- character(0)
    cue_num <- 0; cue_den <- 0
    for (bloc in c(BLOCS, "other")) {
      sub <- g[g$bloc == bloc, , drop = FALSE]
      ja   <- sum(as.integer(sub$yes));      nein <- sum(as.integer(sub$no))
      enth <- sum(as.integer(sub$abstain));  abw  <- sum(as.integer(sub$absent))
      support <- if (inverted) nein else ja  # for the proposal substance
      oppose  <- if (inverted) ja  else nein
      cast <- support + oppose
      long_out[[length(long_out) + 1]] <- c(base, list(
        bloc = bloc, ja = ja, nein = nein, enthaltung = enth, abwesend = abw,
        support = support, oppose = oppose,
        support_share = if (cast > 0) round(support / cast, 3) else NA))
      wide[[paste0(bloc, "_ja")]]   <- ja
      wide[[paste0(bloc, "_nein")]] <- nein
      wide[[paste0(bloc, "_enth")]] <- enth
      wide[[paste0(bloc, "_abw")]]  <- abw
      if (bloc %in% BLOCS) {
        wide[[paste0(bloc, "_support")]] <- support
        wide[[paste0(bloc, "_oppose")]]  <- oppose
        if (cast > 0) {
          if (support > oppose) majority_support <- c(majority_support, bloc)
          cue_num <- cue_num + LR[[bloc]] * support
          cue_den <- cue_den + support
        }
      }
    }
    wide$support_coalition <- if (length(majority_support))
      paste(majority_support, collapse = "+") else "none"
    wide$elite_cue_lr <- if (cue_den > 0) round(cue_num / cue_den, 2) else NA
    wide_out[[length(wide_out) + 1]] <- wide
  }

  long_cols <- c("anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
                 "title_short", "source", "vote_ref", "leg", "vote_date", "vote_url",
                 "bill_title", "bill_is_initiative", "roll_call_inverted",
                 "bloc", "ja", "nein", "enthaltung", "abwesend",
                 "support", "oppose", "support_share")
  long_df <- do.call(rbind, lapply(long_out, function(r)
    as.data.frame(r[long_cols], check.names = FALSE, stringsAsFactors = FALSE)))
  write_csv_bom(long_df, file.path(OUT, "fraktionen_blocs_long.csv"))

  bloc_cols <- unlist(lapply(BLOCS, function(b)
    paste0(b, c("_ja", "_nein", "_enth", "_abw", "_support", "_oppose"))))
  bloc_cols <- c(bloc_cols, paste0("other", c("_ja", "_nein", "_enth", "_abw")))
  wide_cols <- c("anr", "gesch_nr", "entwurf_nr", "referendum_date", "parl_date",
                 "title_short", "source", "vote_ref", "leg", "vote_date", "vote_url",
                 "bill_title", "bill_is_initiative", "roll_call_inverted",
                 bloc_cols, "support_coalition", "elite_cue_lr")
  wide_df <- do.call(rbind, lapply(wide_out, function(r)
    as.data.frame(r[wide_cols], check.names = FALSE, stringsAsFactors = FALSE)))
  write_csv_bom(wide_df, file.path(OUT, "fraktionen_blocs_wide.csv"))
}

run()

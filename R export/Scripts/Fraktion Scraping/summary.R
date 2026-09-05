# ============================================================================
# summary.R — Quick summary over fraktionen_long.csv: per-fraction
# Yes/No/Abstain/Absent totals and yes-rate across all matched final votes.
# R port of summary.py (same logic, same output).
#
# Because fraction codes change over the decades, the codes are also rolled
# up into stable party families for a coherent cross-time view.
#
# Input : Output/Fraktion Scraping/fraktionen_long.csv
# Output: Output/Fraktion Scraping/fraktionen_summary.csv  (+ printed table)
# ============================================================================

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
ROOT <- find_root()
OUT  <- file.path(ROOT, "Output", "Fraktion Scraping")
LONG <- file.path(OUT, "fraktionen_long.csv")
if (!file.exists(LONG))
  LONG <- file.path(ROOT, "Input Data", "Fraktion Scraping", "fraktionen_long.csv")

# raw PDF/API/AB codes -> stable party family
FAMILY <- c(S = "SP", V = "SVP", R = "FDP", RL = "FDP",
            C = "CVP/Mitte", CE = "CVP/Mitte", CEg = "CVP/Mitte",
            `M-E` = "CVP/Mitte", `M-CEB` = "CVP/Mitte",
            G = "Grüne", GL = "glp", L = "Liberale (LPS)",
            E = "EVP/EDU", BD = "BDP", U = "LdU", `-` = "Fraktionslos")

write_csv_bom <- function(df, path) {
  con <- file(path, open = "wb")
  writeBin(as.raw(c(0xEF, 0xBB, 0xBF)), con)
  close(con)
  con <- file(path, open = "a", encoding = "UTF-8")
  write.csv(df, con, row.names = FALSE, na = "")
  close(con)
}

summarize <- function(keys, rows) {
  billid <- paste(rows$anr, rows$vote_ref, sep = "\r")
  out <- lapply(unique(keys), function(k) {
    g <- rows[keys == k, , drop = FALSE]
    gb <- billid[keys == k]
    yes <- as.integer(g$yes); no <- as.integer(g$no)
    # bills where this fraction's majority voted No
    per_y <- tapply(yes, gb, sum); per_n <- tapply(no, gb, sum)
    opposed <- sum(per_n > per_y)
    cast <- sum(yes) + sum(no)
    data.frame(
      fraction = k,
      n_final_votes = length(unique(gb)),
      yes = sum(yes), no = sum(no),
      abstain = sum(as.integer(g$abstain)),
      absent  = sum(as.integer(g$absent)),
      yes_rate_of_cast = if (cast > 0) round(sum(yes) / cast, 3) else NA,
      bills_opposed_majority = opposed,
      stringsAsFactors = FALSE, check.names = FALSE)
  })
  df <- do.call(rbind, out)
  df[order(-(df$yes + df$no)), , drop = FALSE]
}

main <- function() {
  rows <- read.csv(LONG, colClasses = "character",
                   fileEncoding = "UTF-8-BOM", check.names = FALSE)
  fam <- ifelse(rows$fraction_code %in% names(FAMILY),
                FAMILY[rows$fraction_code], rows$fraction_code)
  by_family <- summarize(fam, rows)
  write_csv_bom(by_family, file.path(OUT, "fraktionen_summary.csv"))
  cat(sprintf("wrote %s\n\n", file.path(OUT, "fraktionen_summary.csv")))

  n_votes <- length(unique(paste(rows$anr, rows$vote_ref)))
  cat(sprintf("Per-fraction summary across %d matched Nationalrat final votes (1994-2026):\n\n",
              n_votes))
  cat(sprintf("%-16s%6s%8s%7s%6s%8s%10s%9s\n", "fraction", "votes", "yes", "no",
              "abst", "absent", "yes-rate", "opposed"))
  cat(strrep("-", 70), "\n")
  for (i in seq_len(nrow(by_family))) {
    d <- by_family[i, ]
    yr <- if (!is.na(d$yes_rate_of_cast))
      sprintf("%.0f%%", 100 * d$yes_rate_of_cast) else "-"
    cat(sprintf("%-16s%6d%8d%7d%6d%8d%10s%9d\n", d$fraction, d$n_final_votes,
                d$yes, d$no, d$abstain, d$absent, yr, d$bills_opposed_majority))
  }
  cat("\nyes-rate = share of *cast* (yes+no) votes that were Yes;",
      " opposed = # final votes where the fraction's majority voted No.\n")
}

main()

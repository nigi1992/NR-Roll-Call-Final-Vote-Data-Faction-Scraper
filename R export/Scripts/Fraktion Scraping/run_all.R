# ============================================================================
# run_all.R — Run the whole Fraktion-Scraping chain in order:
#   scrape_fraktionen.R  ->  blocs.R  ->  summary.R  ->  export_xlsx.R
# (build_index.R is a one-off maintenance script and not part of the chain;
#  the shipped pdf_index.json already covers legislature 46.)
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
SCR <- file.path(.find_root0(), "Scripts", "Fraktion Scraping")

source(file.path(SCR, "scrape_fraktionen.R")); run()
source(file.path(SCR, "blocs.R"))
source(file.path(SCR, "summary.R"))
source(file.path(SCR, "export_xlsx.R"))
cat("\nAll Fraktion-Scraping outputs regenerated in Output/Fraktion Scraping/.\n")

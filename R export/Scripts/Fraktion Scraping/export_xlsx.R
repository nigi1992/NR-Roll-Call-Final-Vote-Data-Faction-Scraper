# ============================================================================
# export_xlsx.R — Write .xlsx copies of the output CSVs with every column kept
# as TEXT, so Excel/Numbers don't strip the leading/trailing zeros of gesch_nr
# ('03.026' -> '3.026') on open. R port of export_xlsx.py.
#
# (The CSVs are already correct; this is purely so spreadsheet apps display
# the ID columns faithfully. writexl writes character columns as text cells,
# which is exactly what the Python/openpyxl version produced.)
#
# Input : Output/Fraktion Scraping/*.csv
# Output: Output/Fraktion Scraping/*.xlsx  (one per CSV)
# ============================================================================

if (!requireNamespace("writexl", quietly = TRUE))
  stop('Package "writexl" is not installed. Run: install.packages("writexl")',
       call. = FALSE)
library(writexl)

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
OUT <- file.path(find_root(), "Output", "Fraktion Scraping")

for (f in sort(list.files(OUT, pattern = "\\.csv$", full.names = TRUE))) {
  df <- read.csv(f, colClasses = "character",
                 fileEncoding = "UTF-8-BOM", check.names = FALSE)
  xlsx <- sub("\\.csv$", ".xlsx", f)
  write_xlsx(df, xlsx)
  cat(sprintf("wrote %s  (%d rows)\n", basename(xlsx), nrow(df)))
}

# tests/validate.R
#
# Independent validation of output/marks_imputed.csv against data/marks.csv.
# Does NOT assume anything about how the imputation was produced - it only
# checks the hard requirements. Fails loudly (stop()) on any violation.
#
# Run from task2-mark-imputation/:  Rscript tests/validate.R

library(data.table)

raw <- fread("data/marks.csv", colClasses = "character", na.strings = NULL)
imp <- fread("output/marks_imputed.csv", colClasses = "character", na.strings = NULL)

if (nrow(raw) != nrow(imp)) {
  stop(sprintf("Row count changed: raw has %d rows, imputed has %d", nrow(raw), nrow(imp)))
}
if (!identical(names(raw), names(imp))) {
  stop("Header / column order changed between raw and imputed files")
}
if (!identical(raw$student_id, imp$student_id)) {
  stop("Row order (student_id sequence) changed between raw and imputed files")
}

paper_cols <- setdiff(names(raw), "student_id")
weight <- as.integer(sub("^.*-([0-9]+)$", "\\1", paper_cols))

n_blank_checked <- 0L
n_numeric_checked <- 0L
n_imputed_checked <- 0L

for (k in seq_along(paper_cols)) {
  col <- paper_cols[k]
  w <- weight[k]
  r <- raw[[col]]
  m <- imp[[col]]

  was_blank <- r == ""
  was_M <- r == "M"
  was_numeric <- !was_blank & !was_M

  if (!all(m[was_blank] == "")) {
    stop(sprintf("Column %s: a blank ('not registered') cell was changed", col))
  }
  if (!all(m[was_numeric] == r[was_numeric])) {
    stop(sprintf("Column %s: a non-M numeric cell was changed", col))
  }
  if (any(m[was_M] == "M")) {
    stop(sprintf("Column %s: an 'M' value was not imputed", col))
  }

  imputed_vals <- suppressWarnings(as.numeric(m[was_M]))
  if (any(is.na(imputed_vals))) {
    stop(sprintf("Column %s: imputed value is not numeric", col))
  }
  if (any(imputed_vals != round(imputed_vals))) {
    stop(sprintf("Column %s: imputed value is not an integer", col))
  }
  if (any(imputed_vals < 0 | imputed_vals > w)) {
    stop(sprintf("Column %s: imputed value outside [0, %d]", col, w))
  }

  n_blank_checked <- n_blank_checked + sum(was_blank)
  n_numeric_checked <- n_numeric_checked + sum(was_numeric)
  n_imputed_checked <- n_imputed_checked + sum(was_M)
}

cat("All validation checks passed.\n")
cat(sprintf("  Blank cells preserved:      %d\n", n_blank_checked))
cat(sprintf("  Numeric cells unchanged:    %d\n", n_numeric_checked))
cat(sprintf("  M cells imputed (int, in-range): %d\n", n_imputed_checked))

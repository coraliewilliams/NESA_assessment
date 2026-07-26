# code/run_imputation.R
#
# Entry point: evaluates candidate imputation methods on data/marks.csv,
# selects the best-performing one, and writes output/marks_imputed.csv.
# data/marks.csv is read-only; only output/ is written to.
#
# Run from task2-mark-imputation/:  Rscript code/run_imputation.R

library(data.table)
source("code/impute.R")

SEED <- 20260726  # fixed for full reproducibility; also seeds the masking used in evaluation

raw <- fread("data/marks.csv", colClasses = "character", na.strings = NULL)
col_info <- parse_paper_cols(setdiff(names(raw), "student_id"))
long <- melt_marks(raw, col_info)

cat("== Evaluating candidate methods (30 repeats, seed =", SEED, ") ==\n")
eval_result <- evaluate_methods(long, n_repeats = 30, seed = SEED,
                                 lambda_grid = c(1, 3, 5, 10, 20))
print(eval_result$summary)

fwrite(eval_result$summary, "output/evaluation_results.csv")
fwrite(eval_result$per_repeat, "output/evaluation_results_per_repeat.csv")

best_row <- eval_result$summary[1]
best_method_raw <- best_row$method
cat("\nBest method by mean RMSE (proportion scale):", best_method_raw, "\n")

if (startsWith(best_method_raw, "als_bias_lambda")) {
  best_lambda <- as.numeric(sub("als_bias_lambda", "", best_method_raw))
  final_method <- "als_bias"
} else {
  best_lambda <- NULL
  final_method <- best_method_raw
}

cat("Fitting final model (method =", final_method,
    if (!is.null(best_lambda)) paste0(", lambda = ", best_lambda) else "", ") on full data\n")

imputed <- impute_missing(long, method = final_method, lambda = best_lambda)
cat("Imputed", nrow(imputed), "M cells.\n")

# ---- write output: copy the raw table and overwrite only the M cells ----
out <- copy(raw)
row_idx <- match(imputed$student_id, out$student_id)
for (k in seq_len(nrow(imputed))) {
  set(out, i = row_idx[k], j = imputed$col[k], value = as.character(imputed$mark_hat[k]))
}

fwrite(out, "output/marks_imputed.csv", quote = FALSE)
cat("Wrote output/marks_imputed.csv\n")

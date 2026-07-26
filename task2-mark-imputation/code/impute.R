# code/impute.R
#
# Functions for imputing missing ("M") exam marks in marks.csv.
# This file only defines functions - sourcing it has no side effects
# (no file I/O, no plotting, no random draws at source time).
#
# Conventions:
#  - "long" tables have one row per (student_id, col) cell with columns:
#      student_id, col, subject, weight, val (raw string), status
#      ("Not registered" / "Observed" / "Missing (M)"), mark (numeric or NA).
#  - All predict_*() functions take a `target` data.table with a `row_id`
#    column (1..n, matching the row order the caller wants results in) plus
#    student_id, col, subject, weight, and return a numeric vector of
#    predicted PROPORTIONS (mark / weight), aligned to increasing row_id.
#    This keeps every method's output on a common scale so the final
#    mark_hat <- round_clamp(p_hat * weight, weight) step is identical for all.

library(data.table)

# ---- header parsing -----------------------------------------------------

#' Parse "<SUBJECT>-<WEIGHT>" paper column names.
parse_paper_cols <- function(cols) {
  data.table(
    col     = cols,
    subject = sub("-([0-9]+)$", "", cols),
    weight  = as.integer(sub("^.*-([0-9]+)$", "\\1", cols))
  )
}

#' Reshape the wide marks table into long format with status/weight/subject.
melt_marks <- function(dt_wide, col_info) {
  paper_cols <- col_info$col
  long <- melt(dt_wide, id.vars = "student_id", variable.name = "col",
               value.name = "val", variable.factor = FALSE)
  long[col_info, subject := i.subject, on = "col"]
  long[col_info, weight  := i.weight,  on = "col"]
  long[, status := fifelse(val == "", "Not registered",
                     fifelse(val == "M", "Missing (M)", "Observed"))]
  long[, mark := suppressWarnings(as.numeric(val))]
  long[]
}

# ---- shared utilities ----------------------------------------------------

#' Round to the nearest integer and clamp to [0, weight]. This is the single
#' rounding/clamping rule used for every method, applied only at the final
#' step so intermediate model fitting stays on a continuous scale.
round_clamp <- function(x, weight) {
  pmin(pmax(round(x), 0), weight)
}

# ---- baseline 1: paper mean / median --------------------------------------

#' Per-paper mean and median mark, expressed as a proportion of that paper's
#' weight, computed from Observed cells only.
fit_paper_stats <- function(train_long) {
  train_long[status == "Observed",
             .(paper_mean_prop = mean(mark / weight),
               paper_median_prop = median(mark / weight)),
             by = col]
}

predict_paper_baseline <- function(target, paper_stats, use_median = FALSE) {
  stat_col <- if (use_median) "paper_median_prop" else "paper_mean_prop"
  out <- merge(target[, .(row_id, col)], paper_stats, by = "col", all.x = TRUE)
  setorder(out, row_id)
  out[[stat_col]]
}

# ---- baseline 2: student's own same-subject performance -------------------

#' For each target cell, predict using the student's mean proportion across
#' their OTHER observed papers in the same subject. Falls back to the paper
#' mean (from fit_paper_stats) when the student has no other observed paper
#' in that subject (e.g. single-paper subjects, or all sibling papers are
#' also missing/unregistered).
predict_same_subject <- function(target, train_long, paper_stats) {
  obs <- train_long[status == "Observed", .(student_id, subject, prop = mark / weight)]
  agg <- obs[, .(mean_prop = mean(prop), n = .N), by = .(student_id, subject)]

  out <- merge(target[, .(row_id, student_id, col, subject, weight)], agg,
               by = c("student_id", "subject"), all.x = TRUE)
  out <- merge(out, paper_stats[, .(col, paper_mean_prop)], by = "col", all.x = TRUE)
  out[, p_hat := fifelse(!is.na(mean_prop), mean_prop, paper_mean_prop)]
  setorder(out, row_id)
  out$p_hat
}

# ---- principled model: additive student + paper effects on logit scale ---
#
# Model:  logit(p*_ij) = mu + a_i + b_j + e_ij
#   p*_ij is the continuity-corrected proportion (mark+0.5)/(weight+1), which
#   avoids -Inf/Inf at the boundary and stabilises the mean-variance
#   relationship of a bounded proportion (McCullagh & Nelder, 1989).
#   a_i (student effect) and b_j (paper effect) are fit by ridge-regularised
#   alternating least squares (coordinate descent) over OBSERVED cells only -
#   equivalent to the "bias-only" matrix-factorisation baseline of Koren,
#   Bell & Volinsky (2009), with lambda_student/lambda_paper controlling how
#   strongly each effect is shrunk toward 0 (important for students/papers
#   with few observations).

fit_als_bias <- function(train_long, lambda_student = 5, lambda_paper = 5,
                          max_iter = 200, tol = 1e-8) {
  d <- train_long[status == "Observed", .(student_id, col, weight, mark)]
  p_star <- (d$mark + 0.5) / (d$weight + 1)
  y <- qlogis(p_star)

  students <- unique(d$student_id)
  papers   <- unique(d$col)
  sid <- match(d$student_id, students)
  pid <- match(d$col, papers)
  n_s <- length(students)
  n_p <- length(papers)

  sid_f <- factor(sid, levels = seq_len(n_s))
  pid_f <- factor(pid, levels = seq_len(n_p))
  n_i <- as.numeric(table(sid_f))
  n_j <- as.numeric(table(pid_f))

  mu <- mean(y)
  resid_base <- y - mu
  a <- numeric(n_s)
  b <- numeric(n_p)

  for (iter in seq_len(max_iter)) {
    r_b <- resid_base - a[sid]
    b_new <- as.numeric(tapply(r_b, pid_f, sum)) / (n_j + lambda_paper)

    r_a <- resid_base - b_new[pid]
    a_new <- as.numeric(tapply(r_a, sid_f, sum)) / (n_i + lambda_student)

    delta <- max(abs(b_new - b), abs(a_new - a))
    a <- a_new
    b <- b_new
    if (delta < tol) break
  }

  list(mu = mu, a = a, b = b, students = students, papers = papers,
       lambda_student = lambda_student, lambda_paper = lambda_paper,
       iterations = iter)
}

predict_als_bias <- function(target, model) {
  a <- model$a[match(target$student_id, model$students)]
  a[is.na(a)] <- 0  # unseen student: shrink fully to 0 (no student effect)
  b <- model$b[match(target$col, model$papers)]
  b[is.na(b)] <- 0  # unseen paper: shrink fully to 0 (no paper effect)

  y_hat <- model$mu + a + b
  p_star_hat <- plogis(y_hat)
  mark_hat_raw <- p_star_hat * (target$weight + 1) - 0.5
  mark_hat_raw / target$weight
}

# ---- masking for evaluation ------------------------------------------------

#' Mask a sample of currently-Observed cells that mimics the real missingness
#' pattern: for each paper column, mask exactly as many cells as that column
#' has real `M`s (n_M), drawn at random from that column's Observed cells.
#' This preserves the real per-column missingness RATE. It does not replicate
#' the real per-STUDENT clustering of M's (a handful of students account for
#' most M's) - a simplification noted in IMPUTATION.md.
mask_like_observed <- function(long, m_counts_by_col, seed) {
  set.seed(seed)
  obs <- long[status == "Observed"]
  obs[m_counts_by_col, n_mask := i.n_M, on = "col"]
  obs[is.na(n_mask), n_mask := 0]
  obs[, {
    n <- n_mask[1]
    if (n > 0 && n <= .N) .SD[sample(.N, n)] else .SD[0]
  }, by = col]
}

# ---- one evaluation repeat --------------------------------------------------

run_masked_repeat <- function(long, m_counts_by_col, seed, lambda_grid) {
  masked <- mask_like_observed(long, m_counts_by_col, seed)

  train_long <- copy(long)
  train_long[masked, status := "Masked", on = c("student_id", "col")]

  target <- masked[, .(row_id = .I, student_id, col, subject, weight, true_mark = mark)]
  paper_stats <- fit_paper_stats(train_long)

  preds <- list(
    paper_mean   = predict_paper_baseline(target, paper_stats, use_median = FALSE),
    paper_median = predict_paper_baseline(target, paper_stats, use_median = TRUE),
    same_subject = predict_same_subject(target, train_long, paper_stats)
  )
  for (lam in lambda_grid) {
    model <- fit_als_bias(train_long, lambda_student = lam, lambda_paper = lam)
    preds[[paste0("als_bias_lambda", lam)]] <- predict_als_bias(target, model)
  }

  rbindlist(lapply(names(preds), function(nm) {
    p_hat <- preds[[nm]]
    mark_hat <- round_clamp(p_hat * target$weight, target$weight)
    err_prop <- (mark_hat - target$true_mark) / target$weight
    err_raw  <- mark_hat - target$true_mark
    data.table(method = nm, seed = seed,
               mae_prop = mean(abs(err_prop)), rmse_prop = sqrt(mean(err_prop^2)),
               mae_raw = mean(abs(err_raw)),   rmse_raw = sqrt(mean(err_raw^2)))
  }))
}

# ---- full evaluation harness ------------------------------------------------

#' Evaluate all methods over `n_repeats` independent masks, returning both
#' the per-repeat results (to show variability) and a summary aggregated by
#' method (mean/sd of each metric across repeats).
evaluate_methods <- function(long, n_repeats = 30, seed = 1,
                              lambda_grid = c(1, 3, 5, 10, 20)) {
  m_counts_by_col <- long[status == "Missing (M)", .N, by = col]
  setnames(m_counts_by_col, "N", "n_M")

  seeds <- seed + seq_len(n_repeats)
  per_repeat <- rbindlist(lapply(seeds, function(s) {
    run_masked_repeat(long, m_counts_by_col, s, lambda_grid)
  }))

  summary <- per_repeat[, .(
    mean_mae_prop = mean(mae_prop), sd_mae_prop = sd(mae_prop),
    mean_rmse_prop = mean(rmse_prop), sd_rmse_prop = sd(rmse_prop),
    mean_mae_raw = mean(mae_raw), mean_rmse_raw = mean(rmse_raw)
  ), by = method][order(mean_rmse_prop)]

  list(per_repeat = per_repeat, summary = summary)
}

# ---- final imputation on the full dataset ----------------------------------

#' Fit `method` on ALL Observed cells and predict every `M` cell.
#' `method` is one of "paper_mean", "paper_median", "same_subject",
#' or "als_bias" (with `lambda` used for both student and paper shrinkage).
impute_missing <- function(long, method, lambda = NULL) {
  target <- long[status == "Missing (M)", .(row_id = .I, student_id, col, subject, weight, mark)]
  paper_stats <- fit_paper_stats(long)

  p_hat <- switch(method,
    paper_mean   = predict_paper_baseline(target, paper_stats, use_median = FALSE),
    paper_median = predict_paper_baseline(target, paper_stats, use_median = TRUE),
    same_subject = predict_same_subject(target, long, paper_stats),
    als_bias     = predict_als_bias(target, fit_als_bias(long, lambda, lambda)),
    stop("Unknown method: ", method)
  )
  target[, mark_hat := round_clamp(p_hat * weight, weight)]
  target[]
}

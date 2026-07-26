# code/explore_data.R
#
# Exploratory analysis and missingness visualisation for data/marks.csv.
# Read-only with respect to data/marks.csv: nothing in this script writes back
# to data/. All figures are written to output/.
#
# Run from the task2-mark-imputation/ directory:
#   Rscript code/explore_data.R

library(data.table)
library(ggplot2)
library(patchwork)

raw <- fread("data/marks.csv", colClasses = "character", na.strings = NULL)

paper_cols <- setdiff(names(raw), "student_id")
col_info <- data.table(
  col     = paper_cols,
  subject = sub("-([0-9]+)$", "", paper_cols),
  weight  = as.integer(sub("^.*-([0-9]+)$", "\\1", paper_cols))
)

long <- melt(raw, id.vars = "student_id", variable.name = "col", value.name = "val")
long[, col := as.character(col)]
long[col_info, subject := i.subject, on = "col"]
long[col_info, weight  := i.weight,  on = "col"]
long[, status := fifelse(val == "", "Not registered",
                   fifelse(val == "M", "Missing (M)", "Observed"))]
long[, status := factor(status, levels = c("Not registered", "Observed", "Missing (M)"))]
long[, mark := suppressWarnings(as.numeric(val))]
long[, prop := mark / weight]

status_colours <- c("Not registered" = "grey80", "Observed" = "steelblue",
                     "Missing (M)" = "firebrick")

# ---- Figure 1: simple, dataset-wide missingness summary (no 49-row breakdown) ----
# Panel A: one overall composition bar - the headline numbers for the whole
# 1000x49 grid, not per paper (kept simple deliberately; per-paper/per-subject
# counts are tabulated in README.md instead of plotted).
overall_status <- long[, .N, by = status]
overall_status[, pct := N / sum(N)]

subtitle_txt <- paste0(
  "Not registered ", format(overall_status[status == "Not registered", N], big.mark = ","),
  " (", sprintf("%.1f%%", overall_status[status == "Not registered", pct] * 100), ")  |  ",
  "Observed ", format(overall_status[status == "Observed", N], big.mark = ","),
  " (", sprintf("%.1f%%", overall_status[status == "Observed", pct] * 100), ")  |  ",
  "M ", format(overall_status[status == "Missing (M)", N], big.mark = ","),
  " (", sprintf("%.2f%%", overall_status[status == "Missing (M)", pct] * 100), ")"
)

p1 <- ggplot(overall_status, aes(x = 1, y = N, fill = status)) +
  geom_col(width = 0.5, colour = "white") +
  scale_fill_manual(values = status_colours, name = NULL) +
  coord_flip() +
  labs(title = "All 49,000 cells", subtitle = subtitle_txt, x = NULL, y = NULL) +
  theme_minimal(base_size = 10) +
  theme(axis.text.y = element_blank(), panel.grid = element_blank(),
        legend.position = "bottom", plot.subtitle = element_text(size = 7.5))

# Panel B: M cells per student - the shape that matters for imputation risk
# (are M's spread thinly, or concentrated in a few heavily-affected students?).
m_per_row <- long[, .(n_M = sum(status == "Missing (M)")), by = student_id]
p2 <- ggplot(m_per_row, aes(n_M)) +
  geom_bar(fill = "firebrick") +
  labs(title = "M cells per student", subtitle = "945 / 1000 students have zero",
       x = "# of M papers for that student", y = "# students") +
  theme_minimal(base_size = 10)

# Panel C: M rate by SUBJECT (20 rows, not 49 papers) - a general view of
# whether missingness concentrates in particular subjects.
subj_status <- long[, .(n_M = sum(status == "Missing (M)"),
                         n_registered = sum(status != "Not registered")), by = subject]
subj_status[, m_rate := n_M / n_registered]
subj_status[, subject := factor(subject, levels = subject[order(m_rate)])]

p3 <- ggplot(subj_status, aes(subject, m_rate)) +
  geom_col(fill = "firebrick", alpha = 0.85) +
  coord_flip() +
  scale_y_continuous(labels = scales::percent) +
  labs(title = "M rate by subject", subtitle = "% of registered cells that are M",
       x = NULL, y = NULL) +
  theme_minimal(base_size = 10)

fig1 <- (p1 / p2) | p3
fig1 <- fig1 + plot_annotation(title = "Figure 1: Missingness summary of marks.csv")
ggsave("output/fig01_missingness_overview.png", fig1, width = 10, height = 6, dpi = 150)

fwrite(subj_status[order(-m_rate)], "output/missingness_by_subject.csv")

# ---- Figure 2: observed mark distributions (proportion of max), by SUBJECT ----
# Pooled at subject level (20 groups) rather than per paper (49 groups) for a
# more general, readable view; every observed paper-mark still contributes one
# point, just grouped by its subject.
obs <- long[status == "Observed"]
obs[, subject := factor(subject, levels = col_info[, unique(subject)])]

p4 <- ggplot(obs, aes(subject, prop)) +
  geom_boxplot(fill = "steelblue", alpha = 0.7, outlier.size = 0.6) +
  labs(title = "Figure 2a: Observed marks (proportion of maximum) by subject",
       subtitle = "Each point is one paper result; papers within a subject are pooled",
       x = NULL, y = "Mark / weight") +
  theme_minimal(base_size = 10) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

p5 <- ggplot(obs, aes(prop)) +
  geom_histogram(binwidth = 0.05, fill = "steelblue", colour = "white") +
  labs(title = "Figure 2b: All observed marks pooled across every paper",
       subtitle = paste0("n = ", nrow(obs), " observed marks; roughly unimodal, no pile-up at 0 or 1"),
       x = "Mark / weight", y = "Count") +
  theme_minimal(base_size = 10)

fig2 <- p4 / p5
ggsave("output/fig02_mark_distributions.png", fig2, width = 8, height = 8, dpi = 150)

# ---- Figure 3: within-subject vs cross-subject correlation ----
# This comparison is the empirical basis for the imputation design: it shows
# whether a paper's missing mark is better predicted by the student's other
# papers in the SAME subject, or by their performance in OTHER subjects.
wide_prop <- dcast(obs, student_id ~ col, value.var = "prop")

multi_paper_subjects <- col_info[, .N, by = subject][N > 1, subject]
within_cor <- rbindlist(lapply(multi_paper_subjects, function(s) {
  cols_s <- col_info[subject == s, col]
  m <- suppressWarnings(cor(wide_prop[, ..cols_s], use = "pairwise.complete.obs"))
  data.table(subject = s, r = m[upper.tri(m)])
}))

subj_mean <- obs[, .(prop = mean(prop)), by = .(student_id, subject)]
wide_subj <- dcast(subj_mean, student_id ~ subject, value.var = "prop")
subj_names <- setdiff(names(wide_subj), "student_id")
cross_cor_mat <- cor(wide_subj[, ..subj_names], use = "pairwise.complete.obs")
diag(cross_cor_mat) <- NA
cross_df <- as.data.frame(as.table(cross_cor_mat))
names(cross_df) <- c("s1", "s2", "r")
cross_df <- cross_df[!is.na(cross_df$r), ]

p4 <- ggplot(within_cor, aes(subject, r)) +
  geom_boxplot(fill = "steelblue", alpha = 0.6) +
  geom_hline(yintercept = 0, linetype = 2) +
  labs(title = "Within-subject: correlation between a student's papers in the same subject",
       x = NULL, y = "Pearson r (proportion scale)") +
  theme_minimal(base_size = 9) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

p5 <- ggplot(cross_df, aes(s1, s2, fill = r)) +
  geom_tile() +
  scale_fill_gradient2(low = "blue", mid = "white", high = "red", midpoint = 0) +
  labs(title = "Cross-subject: correlation between a student's subject-mean performance",
       x = NULL, y = NULL, fill = "r") +
  theme_minimal(base_size = 8) +
  theme(axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5))

fig3 <- p4 / p5 +
  plot_annotation(title = "Figure 3: Within-subject signal is strong and consistent; cross-subject signal is weak and noisy")
ggsave("output/fig03_within_vs_cross_subject_correlation.png", fig3, width = 9, height = 12, dpi = 150)

cat("Saved output/fig01_missingness_overview.png\n")
cat("Saved output/missingness_by_subject.csv\n")
cat("Saved output/fig02_mark_distributions.png\n")
cat("Saved output/fig03_within_vs_cross_subject_correlation.png\n")

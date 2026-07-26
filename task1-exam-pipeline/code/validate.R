#' Validation checks for output/exams.jsonl and output/exams.parquet
#'
#' Each check is a standalone function that either returns invisibly or
#' aborts via cli::cli_abort with an informative message — never a warning.
#' All checks re-parse the source XML independently of the pipeline code in
#' R/, so a bug shared between the pipeline and the check can't hide a
#' failure. Run interactively or via:
#'   Rscript R/validate.R [--input PATH] [--jsonl PATH] [--parquet PATH]
suppressPackageStartupMessages({
  library(data.table)
})

#' Parse the full source XML into a flat exam-grain reference table.
#' Deliberately independent of R/xml_chunk_reader.R and R/parse_student.R:
#' loads the whole (small, test-scale) file via xml2 in one go, which is fine
#' for validation even though the pipeline itself must stream at scale.
reference_from_xml <- function(input) {
  doc <- xml2::read_xml(input)
  students <- xml2::xml_find_all(doc, "/students/student")

  rows <- vector("list", length(students))
  for (i in seq_along(students)) {
    s <- students[[i]]
    student_id <- xml2::xml_attr(s, "id")
    courses <- xml2::xml_find_all(s, "courses/course")
    course_rows <- vector("list", length(courses))
    for (j in seq_along(courses)) {
      co <- courses[[j]]
      marks <- as.integer(xml2::xml_text(xml2::xml_find_all(co, "exams/exam/mark")))
      course_rows[[j]] <- data.table(
        student_id = student_id,
        school = xml2::xml_attr(co, "school"),
        course_name = xml2::xml_attr(co, "name"),
        exam_seq = seq_along(marks),
        mark = marks
      )
    }
    rows[[i]] <- rbindlist(course_rows)
  }
  rbindlist(rows)
}

#' Check 1: entity counts in each output match the source XML.
check_entity_counts <- function(input, jsonl, parquet) {
  ref <- reference_from_xml(input)
  n_students_ref <- length(unique(ref$student_id))
  n_enrolments_ref <- nrow(unique(ref[, .(student_id, course_name, school)]))
  n_exams_ref <- nrow(ref)

  # jsonlite::stream_in() simplifies each student's `courses` array into a
  # data.frame, and each course's `exams` array into a nested data.frame
  # column - so counts come from nrow()/vapply(), not list indexing.
  jl <- jsonlite::stream_in(file(jsonl), verbose = FALSE)
  n_students_jsonl <- nrow(jl)
  n_enrolments_jsonl <- sum(vapply(jl$courses, nrow, integer(1)))
  n_exams_jsonl <- sum(vapply(jl$courses, function(cs) sum(vapply(cs$exams, nrow, integer(1))), integer(1)))

  pq <- arrow::read_parquet(parquet)
  n_students_pq <- length(unique(pq$student_id))
  n_enrolments_pq <- nrow(unique(pq[, c("student_id", "course_name", "school")]))
  n_exams_pq <- nrow(pq)

  stopifnot(
    "student count mismatch: XML vs JSONL" = n_students_ref == n_students_jsonl,
    "student count mismatch: XML vs Parquet" = n_students_ref == n_students_pq,
    "enrolment count mismatch: XML vs JSONL" = n_enrolments_ref == n_enrolments_jsonl,
    "enrolment count mismatch: XML vs Parquet" = n_enrolments_ref == n_enrolments_pq,
    "exam/mark count mismatch: XML vs JSONL" = n_exams_ref == n_exams_jsonl,
    "exam/mark count mismatch: XML vs Parquet" = n_exams_ref == n_exams_pq
  )
  cli::cli_inform("PASS check_entity_counts: {n_students_ref} students, {n_enrolments_ref} enrolments, {n_exams_ref} exams in all three sources")
}

#' Check 2: referential integrity, both directions, in the Parquet output.
#' (JSONL is nested so orphans are structurally impossible there.)
check_referential_integrity <- function(input, parquet) {
  ref <- reference_from_xml(input)
  pq <- as.data.table(arrow::read_parquet(parquet))

  orphan_rows <- pq[!student_id %in% unique(ref$student_id)]
  if (nrow(orphan_rows) > 0) {
    cli::cli_abort("{nrow(orphan_rows)} Parquet row(s) reference a student_id absent from the source XML.")
  }

  missing_rows <- fsetdiff(
    unique(ref[, .(student_id, course_name, school, exam_seq)]),
    unique(pq[, .(student_id, course_name, school, exam_seq)])
  )
  if (nrow(missing_rows) > 0) {
    cli::cli_abort("{nrow(missing_rows)} source exam(s) are missing from the Parquet output.")
  }
  cli::cli_inform("PASS check_referential_integrity: no orphan keys either direction")
}

#' Check 3: round-trip reconciliation of JSONL and Parquet against the
#' source, including at least one multi-school student and one multi-exam
#' course (the two documented nested/multi-value cases).
check_round_trip <- function(input, jsonl, parquet) {
  ref <- reference_from_xml(input)

  # multi-value case 1: a student enrolled at more than one school
  multi_school_id <- ref[, .(n = uniqueN(school)), by = student_id][n > 1][1, student_id]
  # multi-value case 2: a course with more than one exam
  multi_exam <- ref[, .N, by = .(student_id, course_name)][N > 1][1]

  jl <- jsonlite::stream_in(file(jsonl), verbose = FALSE)
  jl_flat <- rbindlist(lapply(seq_len(nrow(jl)), function(i) {
    sid <- jl$student_id[i]
    co_df <- jl$courses[[i]]
    rbindlist(lapply(seq_len(nrow(co_df)), function(j) {
      ex_df <- co_df$exams[[j]]
      data.table(
        student_id = sid, school = co_df$school[j], course_name = co_df$course_name[j],
        exam_seq = ex_df$exam_seq, mark = ex_df$mark
      )
    }))
  }))

  pq <- as.data.table(arrow::read_parquet(parquet))
  key_cols <- c("student_id", "school", "course_name", "exam_seq", "mark")
  setkeyv(ref, key_cols); setkeyv(jl_flat, key_cols); setkeyv(pq, key_cols)

  stopifnot(
    "JSONL does not exactly reconcile with source (as sets)" =
      nrow(fsetdiff(ref, jl_flat)) == 0 && nrow(fsetdiff(jl_flat, ref)) == 0,
    "Parquet does not exactly reconcile with source (as sets)" =
      nrow(fsetdiff(ref, pq[, ..key_cols])) == 0 && nrow(fsetdiff(pq[, ..key_cols], ref)) == 0
  )

  # explicitly re-check the two nested/multi-value cases survived in both outputs
  schools_jsonl <- unique(jl_flat[student_id == multi_school_id, school])
  schools_pq <- unique(pq[student_id == multi_school_id, school])
  schools_ref <- unique(ref[student_id == multi_school_id, school])
  stopifnot(
    "multi-school student lost a school in JSONL" = setequal(schools_jsonl, schools_ref),
    "multi-school student lost a school in Parquet" = setequal(schools_pq, schools_ref)
  )

  marks_jsonl <- jl_flat[student_id == multi_exam$student_id & course_name == multi_exam$course_name, mark]
  marks_pq <- pq[student_id == multi_exam$student_id & course_name == multi_exam$course_name, mark]
  marks_ref <- ref[student_id == multi_exam$student_id & course_name == multi_exam$course_name, mark]
  stopifnot(
    "multi-exam course lost a mark in JSONL" = setequal(marks_jsonl, marks_ref),
    "multi-exam course lost a mark in Parquet" = setequal(marks_pq, marks_ref)
  )

  cli::cli_inform("PASS check_round_trip: JSONL and Parquet reconcile exactly with source, including student {multi_school_id} ({length(schools_ref)} schools) and {multi_exam$student_id}/{multi_exam$course_name} ({multi_exam$N} exams)")
}

#' Check 4: no silent type coercion or introduced NAs.
check_types_and_no_na <- function(parquet) {
  pq <- arrow::read_parquet(parquet)
  expected_types <- c(
    student_id = "character", first_name = "character", last_name = "character",
    year_level = "integer", age = "integer", attendance_rate = "numeric",
    socioeconomic_band = "character", school = "character", course_name = "character",
    exam_seq = "integer", mark = "integer"
  )
  actual_types <- vapply(pq[names(expected_types)], function(x) class(x)[1], character(1))
  mismatched <- names(expected_types)[actual_types != expected_types]
  if (length(mismatched) > 0) {
    cli::cli_abort("Column type mismatch in Parquet: {paste(mismatched, collapse = ', ')}")
  }
  na_counts <- vapply(pq, function(x) sum(is.na(x)), integer(1))
  if (any(na_counts > 0)) {
    cli::cli_abort("Unexpected NA(s) introduced in Parquet column(s): {paste(names(na_counts)[na_counts > 0], collapse = ', ')}")
  }
  cli::cli_inform("PASS check_types_and_no_na: all column types explicit, zero NAs")
}

if (identical(environment(), globalenv()) && sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  get_arg <- function(flag, default) {
    idx <- which(args == flag)
    if (length(idx) == 0) default else args[idx + 1L]
  }
  proj_root <- normalizePath(file.path(dirname(normalizePath(sub("--file=", "", grep("--file=", commandArgs(trailingOnly = FALSE), value = TRUE)))), ".."))
  input <- get_arg("--input", file.path(proj_root, "data", "exams.xml"))
  jsonl <- get_arg("--jsonl", file.path(proj_root, "output", "exams.jsonl"))
  parquet <- get_arg("--parquet", file.path(proj_root, "output", "exams.parquet"))

  check_entity_counts(input, jsonl, parquet)
  check_referential_integrity(input, parquet)
  check_round_trip(input, jsonl, parquet)
  check_types_and_no_na(parquet)
  cli::cli_inform("All validation checks passed.")
}

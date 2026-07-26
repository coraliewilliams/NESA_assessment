#!/usr/bin/env Rscript
# Convert data/exams.xml into output/exams.jsonl and output/exams.parquet.
#
# Streams the source in fixed-size chunks of students end to end: memory use
# is bounded by chunk_size, not file size (see PIPELINE.md for the
# scalability argument and where this would need to change for true
# multi-GB/TB input).
#
# Usage:
#   Rscript scripts/run_pipeline.R [--input PATH] [--jsonl-out PATH] \
#     [--parquet-out PATH] [--chunk-size N]
suppressPackageStartupMessages({
  library(data.table)
})

suppressPackageStartupMessages({
  library(data.table)
})

# resolve paths relative to the task1-exam-pipeline/ directory regardless of
# the working directory the script is invoked from
proj_root <- normalizePath(file.path(dirname(normalizePath(sub("--file=", "", grep("--file=", commandArgs(trailingOnly = FALSE), value = TRUE)))), ".."))
source(file.path(proj_root, "R", "xml_chunk_reader.R"))
source(file.path(proj_root, "R", "parse_student.R"))
source(file.path(proj_root, "R", "write_jsonl.R"))
source(file.path(proj_root, "R", "write_parquet.R"))

parse_args <- function(args) {
  defaults <- list(
    input = file.path(proj_root, "data", "exams.xml"),
    `jsonl-out` = file.path(proj_root, "output", "exams.jsonl"),
    `parquet-out` = file.path(proj_root, "output", "exams.parquet"),
    `chunk-size` = 200L
  )
  i <- 1L
  while (i <= length(args)) {
    key <- sub("^--", "", args[i])
    if (!key %in% names(defaults)) cli::cli_abort("Unknown argument: {args[i]}")
    defaults[[key]] <- args[i + 1L]
    i <- i + 2L
  }
  defaults$`chunk-size` <- as.integer(defaults$`chunk-size`)
  defaults
}

run_pipeline <- function(input, jsonl_out, parquet_out, chunk_size) {
  cli::cli_inform("Reading {input} in chunks of {chunk_size} students")

  dir.create(dirname(jsonl_out), recursive = TRUE, showWarnings = FALSE)
  dir.create(dirname(parquet_out), recursive = TRUE, showWarnings = FALSE)

  reader <- new_xml_record_reader(input)
  parquet_writer <- new_parquet_writer(parquet_out)
  on.exit({
    reader$close()
    parquet_writer$close()
  })

  n_students <- 0L
  n_exam_rows <- 0L
  first_chunk <- TRUE

  repeat {
    fragments <- reader$next_batch(chunk_size)
    if (length(fragments) == 0L) break

    parsed <- lapply(fragments, parse_student_fragment)

    write_jsonl_chunk(
      lapply(parsed, `[[`, "jsonl_record"),
      jsonl_out,
      append = !first_chunk
    )

    exam_rows <- data.table::rbindlist(lapply(parsed, `[[`, "exam_rows"), use.names = TRUE)
    parquet_writer$write_chunk(exam_rows)

    n_students <- n_students + length(fragments)
    n_exam_rows <- n_exam_rows + nrow(exam_rows)
    first_chunk <- FALSE
    cli::cli_inform("  ...{n_students} students / {n_exam_rows} exam rows written")
  }

  cli::cli_inform("Done: {n_students} students, {n_exam_rows} exam rows.")
  invisible(list(n_students = n_students, n_exam_rows = n_exam_rows))
}

if (identical(environment(), globalenv()) && sys.nframe() == 0L) {
  args <- parse_args(commandArgs(trailingOnly = TRUE))
  run_pipeline(
    input = args$input,
    jsonl_out = args$`jsonl-out`,
    parquet_out = args$`parquet-out`,
    chunk_size = args$`chunk-size`
  )
}

#' Append a chunk of JSONL records to a file
#'
#' Writes one JSON object per line and flushes immediately, so the caller can
#' discard `records` afterwards — memory use stays bounded by chunk size, not
#' file size. `append` lets the pipeline open the file fresh on the first
#' chunk and append on subsequent ones without holding all chunks in memory.
#'
#' @param records List of nested student records (see `parse_student.R`).
#' @param path Output .jsonl path.
#' @param append If FALSE, truncates the file first (start of a new run).
write_jsonl_chunk <- function(records, path, append = TRUE) {
  lines <- vapply(
    records,
    function(r) jsonlite::toJSON(r, auto_unbox = TRUE, digits = NA),
    character(1)
  )
  con <- file(path, open = if (append) "ab" else "wb", encoding = "UTF-8")
  writeLines(lines, con, useBytes = TRUE)
  close(con)
}

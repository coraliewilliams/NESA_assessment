#' Exam-grain Arrow schema for the Parquet fact table
#'
#' Explicit types so every chunk is coerced identically and no column's type
#' is inferred (and potentially guessed differently) chunk-to-chunk.
exam_table_schema <- function() {
  arrow::schema(
    student_id = arrow::utf8(),
    first_name = arrow::utf8(),
    last_name = arrow::utf8(),
    year_level = arrow::int32(),
    age = arrow::int32(),
    attendance_rate = arrow::float64(),
    socioeconomic_band = arrow::utf8(),
    school = arrow::utf8(),
    course_name = arrow::utf8(),
    exam_seq = arrow::int32(),
    mark = arrow::int32()
  )
}

#' Open an incremental Parquet writer
#'
#' Wraps `arrow::ParquetFileWriter`, which writes one row group per
#' `WriteTable()` call. This lets the pipeline commit each chunk to disk as
#' it's produced instead of accumulating every row in memory and writing the
#' whole file at the end.
#'
#' @param path Output .parquet path.
#' @param schema An `arrow::schema()`, e.g. `exam_table_schema()`.
#' @return A list with `write_chunk(dt)` (writes `dt` as one row group) and
#'   `close()`.
new_parquet_writer <- function(path, schema = exam_table_schema()) {
  sink <- arrow::FileOutputStream$create(path)
  properties <- arrow::ParquetWriterProperties$create(column_names = names(schema))
  writer <- arrow::ParquetFileWriter$create(schema, sink, properties = properties)
  list(
    write_chunk = function(dt) {
      tbl <- arrow::as_arrow_table(dt, schema = schema)
      writer$WriteTable(tbl, chunk_size = nrow(dt))
    },
    close = function() {
      writer$Close()
      sink$close()
    }
  )
}

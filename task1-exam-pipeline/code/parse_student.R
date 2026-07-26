#' Parse one <student>...</student> XML fragment into both output shapes
#'
#' Each fragment is small (one student's subtree), so a full DOM parse here is
#' cheap and safe even though the source file as a whole is not held in
#' memory. Returns both representations up front so the pipeline only walks
#' the DOM once per student.
#'
#' @param fragment Raw XML text for a single <student> element.
#' @return A list with:
#'   `jsonl_record` — nested list (student -> courses[] -> exams[]), ready for
#'     `jsonlite::toJSON()`.
#'   `exam_rows` — data.table at exam grain (one row per exam/mark) with the
#'     student's fields repeated, ready to append to the Parquet fact table.
parse_student_fragment <- function(fragment) {
  node <- xml2::read_xml(fragment)

  student_id <- xml2::xml_attr(node, "id")
  first_name <- xml2::xml_text(xml2::xml_find_first(node, "first_name"))
  last_name <- xml2::xml_text(xml2::xml_find_first(node, "last_name"))
  year_level <- as.integer(xml2::xml_text(xml2::xml_find_first(node, "year_level")))
  age <- as.integer(xml2::xml_text(xml2::xml_find_first(node, "age")))
  attendance_rate <- as.double(xml2::xml_text(xml2::xml_find_first(node, "attendance_rate")))
  socioeconomic_band <- xml2::xml_text(xml2::xml_find_first(node, "socioeconomic_band"))

  if (anyNA(c(year_level, age, attendance_rate)) || anyNA(c(student_id, first_name, last_name, socioeconomic_band))) {
    cli::cli_abort("Student {student_id}: missing or non-numeric core field; refusing to silently coerce to NA.")
  }

  course_nodes <- xml2::xml_find_all(node, "courses/course")
  courses <- vector("list", length(course_nodes))
  exam_rows <- vector("list", length(course_nodes)) # one data.table per course, rbindlist'd below

  for (ci in seq_along(course_nodes)) {
    co <- course_nodes[[ci]]
    course_name <- xml2::xml_attr(co, "name")
    school <- xml2::xml_attr(co, "school")
    exam_nodes <- xml2::xml_find_all(co, "exams/exam")
    marks <- as.integer(xml2::xml_text(xml2::xml_find_all(exam_nodes, "mark")))

    if (length(marks) == 0L || anyNA(marks)) {
      cli::cli_abort("Student {student_id}, course '{course_name}': missing or non-integer mark.")
    }

    exam_seq <- seq_along(marks) # document order is the only order signal in the source
    courses[[ci]] <- list(
      course_name = course_name,
      school = school,
      exams = lapply(exam_seq, function(i) list(exam_seq = i, mark = marks[i]))
    )
    exam_rows[[ci]] <- data.table::data.table(
      student_id = student_id,
      first_name = first_name,
      last_name = last_name,
      year_level = year_level,
      age = age,
      attendance_rate = attendance_rate,
      socioeconomic_band = socioeconomic_band,
      school = school,
      course_name = course_name,
      exam_seq = exam_seq,
      mark = marks
    )
  }

  list(
    jsonl_record = list(
      student_id = student_id,
      first_name = first_name,
      last_name = last_name,
      year_level = year_level,
      age = age,
      attendance_rate = attendance_rate,
      socioeconomic_band = socioeconomic_band,
      courses = courses
    ),
    exam_rows = data.table::rbindlist(exam_rows, use.names = TRUE)
  )
}

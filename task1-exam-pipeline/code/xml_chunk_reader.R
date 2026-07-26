#' Streaming reader over a flat, repeating-record XML file
#'
#' xml2 (libxml2's tree API) has no SAX/pull parser exposed in R: `read_xml()`
#' always builds the full DOM. To keep memory bounded on multi-GB input we
#' instead read the file as text in fixed-size character blocks, and slice out
#' complete `<record_tag>...</record_tag>` fragments from a small rolling
#' buffer. Each fragment is small (one student's subtree) and is parsed
#' independently by the caller. At most one block plus one pending fragment is
#' held in memory at a time, regardless of file size.
#'
#' Assumption: `record_tag` elements do not nest and their text content never
#' contains the literal substrings "<record_tag " / "<record_tag>" /
#' "</record_tag>". True for this dataset (checked in README.md). This is
#' the documented limitation of the approach; a hostile/edge-case file (e.g.
#' free-text fields containing "</student>") would break it silently.
#'
#' @param path Path to the XML file.
#' @param record_tag Name of the repeating record element, e.g. "student".
#' @param block_chars Characters to read per underlying disk read.
#' @return A list with `next_batch(n)` (returns a character vector of up to
#'   `n` raw XML fragments, or `character(0)` at end of stream) and `close()`.
new_xml_record_reader <- function(path, record_tag = "student", block_chars = 1e6) {
  # readChar() is only multibyte-boundary-safe on a connection opened in
  # binary mode; a text-mode connection triggers an "incorrect results"
  # warning and applies platform line-ending translation we don't want here.
  con <- file(path, open = "rb", encoding = "UTF-8")
  buffer <- ""
  eof <- FALSE

  # tag-boundary regex so "<student" doesn't also match the root "<students"
  open_pat <- paste0("<", record_tag, "[\\s>]")
  close_tag <- paste0("</", record_tag, ">")

  refill <- function() {
    if (eof) return(invisible())
    chunk <- readChar(con, nchars = block_chars, useBytes = FALSE)
    if (length(chunk) == 0 || nchar(chunk) == 0) {
      eof <<- TRUE
    } else {
      buffer <<- paste0(buffer, chunk)
    }
  }

  # pull one complete fragment out of `buffer`, refilling from disk as needed;
  # returns NULL when no more complete records remain and the file is exhausted
  extract_one <- function() {
    repeat {
      start_match <- regexpr(open_pat, buffer, perl = TRUE)
      if (start_match == -1) {
        if (eof) return(NULL)
        refill()
        next
      }
      start_pos <- start_match[1]
      end_pos <- regexpr(close_tag, substring(buffer, start_pos), fixed = TRUE)
      if (end_pos == -1) {
        if (eof) cli::cli_abort("Unterminated <{record_tag}> element near end of file.")
        refill()
        next
      }
      end_pos <- start_pos + end_pos[1] + nchar(close_tag) - 2L
      fragment <- substring(buffer, start_pos, end_pos)
      buffer <<- substring(buffer, end_pos + 1L)
      return(fragment)
    }
  }

  list(
    next_batch = function(n) {
      out <- character(n)
      i <- 0L
      while (i < n) {
        frag <- extract_one()
        if (is.null(frag)) break
        i <- i + 1L
        out[i] <- frag
      }
      out[seq_len(i)]
    },
    close = function() close(con)
  )
}

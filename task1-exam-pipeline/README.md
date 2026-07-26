# Task 1 — Exam Data Pipeline

Converts `data/exams.xml` into `output/exams.jsonl` and `output/exams.parquet`, with no
loss of data and no change to the source file. `data/` holds the raw input only —
nothing in this pipeline writes to it; all generated files go to `output/`.

## Dependencies

R (tested on 4.6.1) with packages: `xml2`, `arrow`, `jsonlite`, `data.table`, `cli`.
Versions used during development (no `renv.lock` — a plain version pin is cheaper here
and every dependency is a widely-used CRAN package with a stable API):

| package | version |
|---|---|
| xml2 | 1.6.0 |
| arrow | 25.0.0 |
| jsonlite | 2.0.0 |
| data.table | 1.18.4 |
| cli | 3.6.6 |

```r
install.packages(c("xml2", "arrow", "jsonlite", "data.table", "cli"))
```

## Run

From this directory (`task1-exam-pipeline/`):

```sh
Rscript code/run_pipeline.R
```

Optional arguments (all default to the paths/value shown):

```sh
Rscript code/run_pipeline.R \
  --input data/exams.xml \
  --jsonl-out output/exams.jsonl \
  --parquet-out output/exams.parquet \
  --chunk-size 200
```

## Validate

```sh
Rscript code/validate.R
```

Runs independently of the pipeline code (re-parses the source XML itself) and checks:
entity counts, referential integrity, a JSONL/Parquet round-trip against the source
(including a multi-school student and a multi-exam course), and column types/NAs.

Actual output from the current `output/exams.jsonl` and `output/exams.parquet`:

```
PASS check_entity_counts: 1000 students, 4690 enrolments, 4898 exams in all three sources
PASS check_referential_integrity: no orphan keys either direction
PASS check_round_trip: JSONL and Parquet reconcile exactly with source, including student S0028 (3 schools) and S0003/Physics (2 exams)
PASS check_types_and_no_na: all column types explicit, zero NAs
All validation checks passed.
```

## Repo layout

```
code/                  small, single-purpose functions + entry point
  xml_chunk_reader.R   streaming reader: yields <student> fragments in bounded memory
  parse_student.R      one fragment -> nested JSON record + flat exam-grain rows
  write_jsonl.R        append a chunk of JSON records to output/exams.jsonl
  write_parquet.R      write a chunk as one Parquet row group
  run_pipeline.R       entry point: wires the above together end to end
  validate.R           standalone validation checks (see above)
data/exams.xml         source (read-only — never written to)
output/                exams.jsonl, exams.parquet (generated)
```

## Data model discovered in `data/exams.xml`

The source has a flat, uniform, five-level hierarchy — no variation in shape between
records (verified programmatically, see below):

```
<students dataset="...">                                     1 root, 1 attribute
  <student id="Sxxxx">                                        1,000 nodes, id = attribute
    <first_name>, <last_name>                                 text
    <year_level>, <age>                                       text, integer-valued
    <attendance_rate>                                         text, float 0–1
    <socioeconomic_band>                                       text, enum
    <courses>                                                 wrapper, no attributes
      <course name="..." school="...">                        2 attributes, no text
        <exams>                                                wrapper, no attributes
          <exam>                                               no attributes
            <mark>NN</mark>                                    text, integer
```

Counts, from a full parse: **1,000 students, 4,690 `<course>` (enrolment) nodes, 4,898
`<exam>` nodes, 4,898 `<mark>` values**. File is 1.06 MB, UTF‑8, ASCII content.

Cardinalities (measured, not assumed):

| relation | finding |
|---|---|
| courses per student | 1–7 (mean 4.69), drawn from 12 distinct course names |
| schools per student | 1–3 distinct schools; **98/1000 students span more than one school** — genuine student↔school many-to-many |
| exams per course-enrolment | 1 (4,482 cases) or 2 (208 cases) |
| repeated course per student | never — a student takes each course name at most once |
| marks per exam | always exactly 1, integer 38–100, never missing |

No missing/empty values were found in any field for this file. `first_name`,
`last_name`, `year_level`, `age`, `attendance_rate`, `socioeconomic_band` are present
on every one of the 1,000 students.

### Key modelling assumption

`school` and `course` are **not** first-class XML entities — they are bare attribute
strings on `<course>`, with no id, address, or catalogue metadata anywhere in the file.
The true grain of a `<course>` node is therefore a **student–course–school enrolment
fact**, not a row in a course catalogue. Both outputs treat "school" and "course" as
dimensions identified only by name, and synthesize keys positionally rather than
inventing surrogate ids:

- enrolment key = `(student_id, course_name, school)` — sufficient because a student
  never repeats a course name.
- exam key = `(student_id, course_name, school, exam_seq)`, where `exam_seq` is the
  1-based position of the `<exam>` within its `<course>`, in document order (the only
  ordering signal the source provides — there's no date/sitting-type field).
- mark is folded directly onto the exam row (1:1 in the data); if a future schema
  allowed multiple marks per exam (e.g. raw vs. moderated) this would need revisiting.

## Output layouts and justification

### `exams.jsonl` — one line per student, nested `courses[].exams[]`

Each line is a self-contained subtree, mirroring the XML 1:1:

```json
{"student_id":"S0001","first_name":"Isla", ..., "courses":[
  {"course_name":"Visual Arts","school":"Harbour College","exams":[{"exam_seq":1,"mark":43}]},
  ...
]}
```

**Why student-per-line, nested, rather than flattened per-mark:** the student is the
natural unit the source streams in (a whole `<student>` subtree is parsed then
discarded — see below), so nesting requires no extra bookkeeping to regroup rows. It
also avoids repeating six student-level fields across up to 14 lines per student in a
text format that gets no columnar compression — at multi-GB scale that repetition is
real disk and I/O cost, unlike in Parquet (see below). The trade-off: answering "all
marks for course X" from the JSONL requires scanning and flattening every line. That's
acceptable because JSONL here is the lossless exchange/archival format; Parquet is the
query layer.

### `exams.parquet` — single flat table, one row per exam/mark

Columns: `student_id, first_name, last_name, year_level, age, attendance_rate,
socioeconomic_band, school, course_name, exam_seq, mark`.

**Why one denormalised table instead of a normalised student/school/enrolment/exam
star schema:** the deliverable name is singular (`exams.parquet`), which rules out
shipping several separate table files. Given a single physical file, the choice is
between one flat table and one table with nested list/struct columns
(`courses: list<struct<...>>`, mirroring the JSONL). Flat wins for this use case:

- Parquet's per-column dictionary/RLE encoding makes repeating low-cardinality values
  (`school`, `course_name`, `socioeconomic_band`, and even repeated student demographic
  fields) essentially free to store — the "denormalise to avoid repetition" cost that
  matters in JSON text mostly disappears in columnar storage.
- A flat table supports the obvious downstream queries (`GROUP BY course_name,
  socioeconomic_band`, join marks to demographics) with no `UNNEST`/explode step in
  DuckDB, Spark, pandas, or Arrow itself. Nested struct columns would require that step
  in every consumer, for no compression benefit that flat columns don't already give.
- Row-group pruning and per-column statistics (min/max mark, etc.) work directly on a
  flat schema; nested columns complicate predicate pushdown in most engines.

### Many-to-many preservation

Student↔school is not modelled as a junction table — it doesn't need one, because
there's no school metadata beyond the name. A student with 3 schools simply produces
rows with 3 distinct `school` values under the same `student_id`; the relationship is
recovered with `SELECT DISTINCT student_id, school`. Because every key is derived
positionally from the parse itself (never looked up against a separate table), orphan
keys are structurally impossible in either output.

## Performance and scalability strategy

**Constraint:** `xml2` wraps libxml2's *tree* API only — `xml2::read_xml()` always
materialises the full DOM in memory. There is no SAX/pull-parser callback interface
exposed in R's `xml2` (this is the well-known gap behind the classic "how do I read a
20 GB XML file in R" problem: the common answers there fall back to either the older
`XML` package's `xmlEventParse()`/SAX handlers, or pre-splitting the file with an
external tool before touching R at all). Since the brief asks for `xml2` specifically
and R-only, we can't use either of those.

**What the pipeline does instead** (`code/xml_chunk_reader.R`): treat the file as text,
not XML, until the last moment.

1. Open the file as a connection and read fixed-size **character blocks**
   (`readChar()` on a binary-mode connection, so multibyte UTF‑8 characters are never
   split across a block boundary).
2. Maintain a small rolling text buffer. Repeatedly search it for a complete
   `<student ...>...</student>` fragment using tag-boundary-anchored string search
   (not a general regex over the whole file, and not the DOM parser).
3. As soon as a fragment is found, slice it out of the buffer and hand it to
   `xml2::read_xml()` — safe and cheap *because the fragment is one student's subtree*,
   not the whole document. The buffer only ever holds "leftover, not-yet-complete"
   text, bounded by roughly one record's size, not by file size.
4. Batch `chunk_size` fragments (a CLI parameter, default 200), parse each into a
   nested JSON record and a flat data.table of exam rows, then:
   - append the JSON lines to `exams.jsonl` and discard them, and
   - write the exam-grain rows as **one new Parquet row group** via
     `arrow::ParquetFileWriter$WriteTable()` and discard them.
5. Never call `rbind`/`c()` to grow a single object across the whole file — chunks are
   assembled with `data.table::rbindlist()` *within* a chunk only, then written and
   dropped.

**Memory profile:** roughly `O(block_chars + chunk_size × avg_student_subtree_size)`,
i.e. bounded and independent of total file size. Confirmed by re-running the reader
with an artificially tiny 5,000-character block against the real file: identical
counts, zero unparseable fragments.

**Documented limitation of the boundary-scan approach:** it assumes `<student>`
elements don't nest and that no text field ever contains the literal substrings
`<student ` / `<student>` / `</student>`. True for this dataset (checked). A hostile or
free-text-bearing file could break this silently — the first thing to change for a
harder production guarantee would be to replace the boundary scanner with a real
event-driven parser (e.g. shelling out to `xmllint --stream`, or a small compiled SAX
binding), while keeping the rest of the pipeline (chunk → parse → write) unchanged.

**Where this would bottleneck first at multi-GB scale, and what to change:**

| stage | bottleneck | fix |
|---|---|---|
| text buffer scan | `regexpr`/substring calls on a growing buffer if a record is unusually large or the block size is mis-tuned | increase `block_chars`; cap max fragment size and abort loudly rather than scanning unboundedly |
| per-fragment `xml2::read_xml()` | still O(1) per student, but creates/destroys many small libxml2 docs — GC pressure at very high chunk throughput | increase `chunk_size` to amortise R-level overhead per batch (fewer, larger `rbindlist`/write calls) without changing the memory bound materially |
| JSONL write | one `file()` open/close per chunk | keep the connection open across chunks instead of reopening (current code favours simplicity/testability of `write_jsonl_chunk()` in isolation; trivial to switch once profiled) |
| Parquet write | single-threaded row-group writes | increase `chunk_size` (fewer, larger row groups) and/or route through `arrow::write_dataset()` for partitioned, parallel writes if a single physical file is no longer a hard requirement |

Complexity is linear in input size for every stage (O(n) parse, O(n) write); no stage
holds more than O(chunk_size) records at once.

## Assumptions and known limitations

- School and course are name-only dimensions (no separate catalogue in the source);
  see above. If a real catalogue with ids/metadata existed, both outputs would need an
  additional lookup table/object.
- `exam_seq` is inferred from document order, since no date or sitting-type field
  exists to distinguish a resit from a first attempt.
- Mark is folded 1:1 onto its exam row rather than kept as a separate table — valid
  here because every exam has exactly one mark, always.
- The text-buffer XML boundary scanner assumes non-nesting, non-adversarial
  `<student>` records; see the documented limitation above for the production
  hardening path.
- This run processed the actual 1.06 MB / 1,000-student file (not multi-GB test data);
  the streaming design was validated for correctness under stress (5,000-char blocks,
  non-round batch sizes) rather than for absolute throughput at production scale.

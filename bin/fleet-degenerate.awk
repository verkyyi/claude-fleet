# fleet-degenerate.awk — is a pane's screen a DEGENERATE stream? (issue #1557)
#
# A worker whose model output collapses into one token repeated thousands of times
# (#1498 on 2026-10-04: `<br>` 16,822 times, 7 minutes, until a human pressed Esc)
# is healthy to every other watchdog: the Stop hook is not missing, the CPU is
# idle, the API is streaming. Only the SCREEN says so, and it says it plainly: row
# after row of the same short unit.
#
# INPUT: one or more captures (`tmux capture-pane -p`), each preceded by a header
#   @@fleet-degenerate@@ <key> [<pane>]
# OUTPUT: one line per capture that is degenerate:
#   HIT <key> <pane> <rows> <unit>
# Nothing for a clean screen. -v min=<rows> (default 12).
#
# THE RULE. Strip every blank from each row; a blank row is skipped (neither
# counted nor a break — markdown puts one between paragraphs). A RUN is consecutive
# non-blank rows whose concatenation is periodic with ONE short period p: p <= 8
# bytes, or p = the length of a single HTML-ish tag (`<section>`, `</div>`). That
# is "the same row repeated" (`<br>` on a row of its own) AND the soft-wrapped form
# (`<br><br>…<b` / `r><br>…` — a width that is not a multiple of the unit shifts
# its phase every row, so the rows themselves are NOT identical). A run of >= min
# rows whose unit carries a letter or digit is a hit.
#
# What it must NOT hit (the false-alarm side, which costs an interrupted turn):
#   · separators, box drawing, an ASCII table's empty rows, a progress bar — no
#     ASCII letter or digit in the unit (`─`, `│      │`, `.....`, `====`)
#   · an ASCII table's DATA rows — `│ ok │ ok │` repeated is `│ok│ok│` per row,
#     and the concatenation `…│││ok…` breaks the period at every row boundary
#   · a long repeated line (a log line, a code line) — its period is the whole
#     line, far past 8 bytes, and it is not a single tag
# The caller adds the rest: only a `working` window, two consecutive sweeps.
#
# Byte-oriented on purpose (run under LC_ALL=C): BSD awk and gawk agree on bytes,
# and a period in bytes is all the rule needs.

function period(s, maxp,    n, p, i, ok) {
  n = length(s)
  for (p = 1; p <= maxp && p <= n; p++) {
    ok = 1
    for (i = p + 1; i <= n; i++)
      if (substr(s, i, 1) != substr(s, i - p, 1)) { ok = 0; break }
    if (ok) return p
  }
  return 0
}
# is s periodic with exactly period p? (vacuously yes when it is no longer than p)
function periodic(s, p,    n, i) {
  n = length(s)
  for (i = p + 1; i <= n; i++)
    if (substr(s, i, 1) != substr(s, i - p, 1)) return 0
  return 1
}
# the period of a row, or 0 when it is not a short-unit repetition
function row_period(s,    p) {
  p = period(s, 8)
  if (p) return p
  # a single tag repeated: `<section><section>` — the unit is the first tag
  if (match(s, /^<\/?[A-Za-z][^<>]*>/) && RLENGTH <= 32) {
    if (periodic(s, RLENGTH)) return RLENGTH
  }
  return 0
}
function flush(    i, s, p, run, best, bunit, unit, prev) {
  if (key == "") return
  run = 0; p = 0; best = 0; bunit = ""; prev = ""
  for (i = 1; i <= nr; i++) {
    s = row[i]
    if (s == "") continue
    # extend the run: same period across the row boundary (the last p bytes of
    # the previous row + the first p of this one) and within this row
    if (run > 0 && periodic(s, p) && periodic(substr(prev, length(prev) - p + 1) substr(s, 1, p), p)) {
      run++
    } else {
      p = row_period(s); run = 0; unit = ""
      if (p && length(s) >= p) {
        unit = substr(s, 1, p)
        if (unit ~ /[A-Za-z0-9]/) run = 1
      }
    }
    prev = s
    if (run > best) { best = run; bunit = unit }
  }
  if (best >= min) print "HIT", key, pane, best, bunit
  key = ""; nr = 0
}
BEGIN { if (min == "" || min < 2) min = 12; key = ""; nr = 0 }
/^@@fleet-degenerate@@ / { flush(); key = $2; pane = ($3 == "" ? "-" : $3); next }
{ s = $0; gsub(/[ \t\r]+/, "", s); row[++nr] = s }
END { flush() }

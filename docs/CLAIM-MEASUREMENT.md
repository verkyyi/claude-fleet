# Claim and grounding measurements

`bin/fleet-claim-grounding-measure.sh` reads Claude Code JSONL transcripts locally.
It never executes transcript commands, contacts GitHub, or modifies sessions.
This implements the repeatable measurement requested in #461; it does not parse
Codex transcripts or claim to reproduce the earlier ad hoc baseline exactly.

```sh
# Latest 10 claim sessions in the default claude-fleet issue project directories
bin/fleet-claim-grounding-measure.sh

# Another repository, or an archived before/after cohort
bin/fleet-claim-grounding-measure.sh --project-glob '*my-repo-issue-*'
bin/fleet-claim-grounding-measure.sh /path/to/cohort --limit 0 --json

# Explicit files also work; repeated paths are deduplicated
bin/fleet-claim-grounding-measure.sh /path/to/session.jsonl --json
```

The default project root is `~/.claude/projects`; `--projects-dir` overrides it.
Directory arguments are searched recursively. The default discovery only reads
JSONL files directly inside matching project directories, excluding nested agent
transcripts. `--limit` selects by session start time, not last modification time.
Exit status is 0 when at least one claim session is found, 1 for an empty cohort,
and 2 for invalid arguments. JSON includes selection and malformed-line diagnostics.

## Method version 1

**Session selection.** The first main-thread user message must start with
`/fleet-claim`, `/fleet:fleet-claim`, or the corresponding `<command-name>` block
(optionally preceded by `<command-message>`). A dashboard classifier or summarizer
that merely quotes the command later in its prompt is excluded, regardless of file
size. Main-thread requests before that user message and `isSidechain` rows are
ignored. A malformed/torn JSONL line is skipped and counted. Other seed formats
are deliberately excluded and appear in JSON's `skipped` list.

**Turns and usage.** A turn means one unique assistant API request, not one JSONL
line, tool call, or human turn. Group by `requestId`, falling back to `message.id`.
These IDs are different in real transcripts; a message-ID alias joins split
content blocks even when one lacks `requestId`. If both IDs are absent, count the
row separately and report `rows_without_request_id`. For each grouped request,
take the maximum observed `output_tokens` and cached input sum, never add repeated
usage objects. Tool blocks are also deduplicated by their ID. Missing usage is
unknown, not zero. Context means `cache_read_input_tokens + cache_creation_input_tokens`,
matching the original proposal; it excludes uncached input and output tokens.

**Phases.** Preamble is the initial sequence of requests containing only fleet
setup/issue/charter reads and text-only responses. Recognized setup includes
`fleet-lib.sh`, `fleet-claim-brief.sh`, fleet session/config/seat/charter/directive
functions, `gh issue view/edit`, and reads naming charter, CLAUDE, AGENTS or
fleet configuration/claim files. Simple assignments, prints and shell guards are
treated as scaffolding. Bash is split at lines, semicolons and `&&`/`||`; each
piece must match scaffolding. This is a lexical heuristic, not a shell parser.
The first request containing another tool/command starts grounding; a later issue
read never moves the boundary back. Both phases stop **before** the first-write
request, which belongs to neither phase, even if it also contains reads.

**First write.** Detect a `Write`, `Edit`, `MultiEdit`, `NotebookEdit` or
`apply_patch` tool, or these Bash command shapes:

- `apply_patch`, `sed -i`/`--in-place`, `perl -pi` and related `-i` forms;
- output redirection (`>`, `>>`, `&>`, `&>>`) or `tee` to a non-`/dev/` target;
- Python commands whose source contains `.write_text(...)`, `.write_bytes(...)`,
  or `open(..., 'w'/'a'/'x'...)` (including `mode=`).

Quoted literal `>` and fd duplication (`2>&1`) do not count. A heredoc by itself,
read-only `python3 -`, `file-history-snapshot` events and metadata never count.
The output identifies the detection rule, not the command text. Elapsed seconds
run from the first user timestamp to the write tool block's timestamp. Missing
or backwards timestamps yield unknown elapsed time.

This detects an **attempt**, not a successful disk change. It does not reconstruct
cwd, resolve shell variables, or distinguish implementation writes from scratch
files/logs (including `/tmp`). It may miss indirect writes through scripts,
`cp`/`mv`, builds or unusual command wrappers; Python-source matching can also
match a quoted example. Inspect the source transcript when a result is surprising.
Use the same method version and comparable cohorts for before/after comparisons.

**Medians.** Only sessions with a detected first write contribute to the phase
and first-write medians; unfinished or undetected sessions remain visible in
`sessions` but are censored from the aggregates. Each metric reports its own
sample count and omits unknown values. No detected writes means unknown medians,
not zero. JSON also contains each selected transcript path, phase totals,
first-write request ID, and detection reason so a result is auditable without
printing private transcript text into reports.

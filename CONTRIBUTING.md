# Contributing to claude-fleet

## Shell script conventions

Every script in `bin/` and `extras/` is linted by `shellcheck` in CI
(`.github/workflows/shellcheck.yml`, over `bin hooks shell extras`). Keep the
tree clean — a warning fails the build. Baseline disables (the by-path
`source`s shellcheck can't resolve) live in `.shellcheckrc`.

### `set -u` + `pipefail` policy

Pick the header by the shebang:

| Shebang | Header line | Why |
|---|---|---|
| `#!/bin/bash` | `set -uo pipefail` | catch unset vars **and** mid-pipeline failures |
| `#!/bin/sh` | `set -u` | `pipefail` is **not** POSIX — dash (Debian/Ubuntu `/bin/sh`) has no `-o pipefail`, so it must stay bash-only. The repo ships Linux `systemd` units, so portability is real. |
| sourced library (`fleet-lib.sh`) | *neither* | a sourced file's `set` leaks into every caller's shell. Write it `set -u`-safe instead (default every optional expansion: `${VAR:-}`). |

Place the `set` line right after the header comment block, before the first
line of code. A `#!/bin/sh` script carries a one-line note so the omission of
`pipefail` reads as deliberate, not forgotten:

```sh
set -u  # POSIX sh: pipefail is bash-only (dash has none)
```

**We deliberately do NOT use `set -e`.** These scripts lean on commands that are
*expected* to fail (a missing cache file, `gh` unauthed, `tmux` not running) and
handle it inline with `|| true`, `|| continue`, guards, and captured exit
statuses. `set -e` would abort them halfway; `set -u` + `pipefail` give the
failure-surfacing we want without that hazard.

### Writing `set -u`-safe code

- Default every expansion that can be unset: positional args (`"${1:-}"`),
  env-provided config (`"${FLEET_SESSION:-}"`, `"${POPUP:-}"`), and `read`
  targets. `$*`/`$@` are safe with no args; bare `"$1"` is not.
- Empty bash arrays are fine (`"${arr[@]}"`, `${#arr[@]}`); only out-of-range
  *indexing* trips `-u`.

### Tolerant-by-design pipelines

With `pipefail` on, a pipeline reports the **rightmost non-zero** stage. Two
common patterns are tolerant on purpose and must stay that way:

- `… | grep -q …` / `… | grep -oE …` where **no match is normal** — `grep`
  exits 1 and that's expected.
- `… | head -n1` (or any early-closing consumer) — upstream stages get
  `SIGPIPE` (exit 141).

Both are safe **only when the pipeline's exit status is discarded** — i.e. the
output is captured into a variable (`x=$(a | b)`) and the *variable* is tested,
not the pipeline. They are **not** safe as the condition of an `if`/`while`, or
joined with `&&`/`||`, unless you genuinely want the whole pipeline to be
considered failed on a tolerated stage. When a discarded-status pipeline isn't
obviously intentional, add a one-line `# tolerant by design:` comment (see
`tmux-dash-collect.sh`, `tmux-summarize.sh`). If you need a tolerated stage
inside a conditional, make the tolerance explicit: `if a | b || true; then` or
restructure so the intended predicate is the last stage.

### Before you push

```sh
find bin hooks shell extras -name '*.sh' -print0 | sort -z | xargs -0 shellcheck
```

is exactly what CI runs. `shell/cw.zsh` is excluded on purpose — shellcheck
doesn't support zsh.

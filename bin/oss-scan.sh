#!/bin/bash
# oss-scan.sh — where this repo still says an internal name or address, and
# whether its history still holds anything secret-shaped nobody confirmed
# (issue #3571, EPIC #3569 C1).
#
#   oss-scan.sh [--summary|--files|--inventory|--all] [--root DIR] [-- <pathspec>…]
#       the current tree: `git grep -E` for every rule in conf/oss-scan.rules,
#       minus a match conf/oss-scan.rules keeps (#@keep) and a file:rule
#       conf/oss-scan.allow allows. One line per hit, `file:line:rule:class`.
#         --summary    the counts: files · hits · by directory · rule · class
#         --files      one line per file still holding a hit
#         --inventory  the per-file Markdown table docs/dev/OSS-INVENTORY.md carries
#         --all        allowed hits too (class `allow`)
#   oss-scan.sh --history [--summary] [--root DIR]
#       `gitleaks git --redact` over every commit with the repo's .gitleaks.toml:
#       one line per finding the allowlist has not confirmed (commit:path:line:rule).
#
#   --rules F / --allow F   another table (the selftest's seam)
#
# Exit: 0 nothing found · 1 something found · 2 usage / a tool missing.
#
# The class of a hit is what to DO with it (the inventory's three words):
#   allow        conf/oss-scan.allow names its file + rule, with the reason
#   placeholder  a test, a doc or a comment — swap in a placeholder word (C8)
#   config       anything else: code or deploy that runs with the value — make
#                it a setting, our own value outside the repo (C7)
# The rule table is the ONE copy (共同约定 1): the gate (C2), C7 / C8's acceptance
# and the plugin check (C16 / C17) run this script or read the same two files.
set -u

BIN=$(cd "$(dirname "$0")" && pwd)
ROOT=""
RULES=""
ALLOW=""
MODE=hits
HISTORY=0
SHOW_ALL=0

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --summary) MODE=summary ;;
        --files) MODE=files ;;
        --inventory) MODE=inventory ;;
        --all) SHOW_ALL=1 ;;
        --history) HISTORY=1 ;;
        --root) ROOT=${2:-}; shift ;;
        --rules) RULES=${2:-}; shift ;;
        --allow) ALLOW=${2:-}; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) echo "oss-scan: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "oss-scan: not in a git repo (--root DIR)" >&2; exit 2; }
[ -n "$RULES" ] || RULES="$BIN/../conf/oss-scan.rules"
[ -n "$ALLOW" ] || ALLOW="$BIN/../conf/oss-scan.allow"

# ---- history ----------------------------------------------------------------
if [ "$HISTORY" = 1 ]; then
    command -v gitleaks >/dev/null 2>&1 \
        || { echo "oss-scan: gitleaks not found (brew install gitleaks)" >&2; exit 2; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/oss-scan.XXXXXX") || exit 2
    cfg=()
    [ -f "$ROOT/.gitleaks.toml" ] && cfg=(--config "$ROOT/.gitleaks.toml")
    gitleaks git --redact --no-banner --log-level error \
        ${cfg[@]+"${cfg[@]}"} --report-format json --report-path "$tmp" \
        --exit-code 0 "$ROOT" >/dev/null 2>&1
    rc=$?
    if [ "$rc" != 0 ] || [ ! -s "$tmp" ]; then
        rm -f "$tmp"; echo "oss-scan: gitleaks failed (rc $rc)" >&2; exit 2
    fi
    python3 - "$tmp" "$MODE" <<'PY'
import collections, json, sys
rows = json.load(open(sys.argv[1]))
if sys.argv[2] == "summary":
    by = collections.Counter(r["RuleID"] for r in rows)
    commits = len({r["Commit"] for r in rows})
    print(f"history: {len(rows)} 处未确认 · {commits} 个提交")
    if by:
        print("  by rule: " + " · ".join(f"{k} {v}" for k, v in by.most_common()))
else:
    for r in rows:
        print(f'{r["Commit"][:8]}:{r["File"]}:{r["StartLine"]}:{r["RuleID"]}')
sys.exit(1 if rows else 0)
PY
    rc=$?
    rm -f "$tmp"
    exit "$rc"
fi

# ---- current tree -----------------------------------------------------------
[ -f "$RULES" ] || { echo "oss-scan: no rule table: $RULES" >&2; exit 2; }

# Every rule's matching lines, tagged `<rule>\t<path>:<line>:<text>`.
grep_all() {
    local id ere rest
    while IFS="$(printf '\t')" read -r id ere rest; do
        case "$id" in ''|'#'*) continue ;; esac
        [ -n "$ere" ] || continue
        git -C "$ROOT" grep -nIE --no-color -e "$ere" -- "$@" 2>/dev/null \
            | awk -v id="$id" '{ print id "\t" $0 }'
    done < "$RULES"
}

grep_all ${1+"$@"} | awk -v rules="$RULES" -v allow="$ALLOW" -v mode="$MODE" -v all="$SHOW_ALL" '
function glob2re(g,   r, i, c) {
    r = "^"
    for (i = 1; i <= length(g); i++) {
        c = substr(g, i, 1)
        if (c == "*") {
            if (substr(g, i + 1, 1) == "*") { r = r ".*"; i++ } else r = r "[^/]*"
        } else if (c == "?") r = r "[^/]"
        else if (index(".[]()+^$|{}\\", c)) r = r "\\" c
        else r = r c
    }
    return r "$"
}
function trim(s) { sub(/^[^A-Za-z0-9]+/, "", s); sub(/[^A-Za-z0-9]+$/, "", s); return s }
function testfile(p) {
    return p ~ /(^|\/)[^\/]*selftest[^\/]*$/ || p ~ /_test\.go$/ || p ~ /\.test\.[a-z]+$/ ||
           p ~ /(^|\/)(testdata|tests?|__tests__|fixtures)\// || p ~ /(^|\/)smoke\.py$/
}
function docfile(p) { return p ~ /\.(md|txt|html)$/ || p ~ /^docs\// }
function comment(t) { sub(/^[ \t]+/, "", t); return t ~ /^(#|\/\/|\*|\/\*|--|<!--|;)/ }
BEGIN {
    FS = "\t"
    while ((getline line < rules) > 0) {
        if (line ~ /^#@keep\t/) { split(line, f, "\t"); keep[f[2]] = 1; continue }
        if (line ~ /^#/ || line == "") continue
        split(line, f, "\t"); if (f[2] != "") ere[f[1]] = f[2]
    }
    na = 0
    while ((getline line < allow) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, f, "\t"); na++; agl[na] = glob2re(f[1]); arule[na] = f[2]
    }
}
{
    id = $1; rest = substr($0, length(id) + 2)
    # <path>:<line>:<text> — a path in this repo carries no colon
    p = index(rest, ":"); path = substr(rest, 1, p - 1); rest = substr(rest, p + 1)
    p = index(rest, ":"); ln = substr(rest, 1, p - 1); text = substr(rest, p + 1)
    # a line counts for a rule only when some match on it is not a kept word
    t = text; real = 0
    while (match(t, ere[id])) {
        m = substr(t, RSTART, RLENGTH)
        if (!(trim(m) in keep)) { real = 1; break }
        t = substr(t, RSTART + (RLENGTH > 0 ? RLENGTH : 1))
    }
    if (!real) next
    key = path SUBSEP ln SUBSEP id
    if (key in seen) next
    seen[key] = 1
    cls = ""
    for (i = 1; i <= na; i++)
        if ((arule[i] == "*" || arule[i] == id) && path ~ agl[i]) { cls = "allow"; break }
    if (cls == "") cls = (testfile(path) || docfile(path) || comment(text)) ? "placeholder" : "config"
    if (cls == "allow" && !all && mode == "hits") next
    if (cls == "allow" && !all && mode == "files") next
    print path ":" ln ":" id ":" cls
}
' | {
    # The hit list is the source of every other view.
    hits=$(cat)
    case "$MODE" in
        hits) [ -n "$hits" ] && printf '%s\n' "$hits" ;;
        files) [ -n "$hits" ] && printf '%s\n' "$hits" | awk -F: '!s[$1]++ { print $1 }' ;;
        summary|inventory)
            printf '%s\n' "$hits" | awk -F: -v mode="$MODE" '
            NF < 4 { next }
            {
                f = $1; r = $3; c = $4
                if (c == "allow") { af[f] = 1; next }
                h++; files[f] = 1; fr[f, r]++; fc[f, c] = 1; nf[f]++
                rh[r]++; if (!((f, r) in rf)) { rf[f, r] = 1; rn[r]++ }
                d = f; sub(/\/.*/, "", d); if (d == f) d = "(根)"
                if (!(f in fd)) { fd[f] = d; dn[d]++ }
            }
            END {
                for (f in files) n++
                for (f in af) if (!(f in files)) na++
                if (mode == "summary") {
                    printf "tree: %d 个文件 · %d 处（允许清单另放过 %d 个文件）\n", n, h, na
                    out = ""; for (d in dn) out = out sprintf("%d\t%s %d\n", dn[d], d, dn[d])
                    printf "  by dir:   %s\n", join(out)
                    out = ""; for (r in rn) out = out sprintf("%d\t%s %d 个文件/%d 处\n", rn[r], r, rn[r], rh[r])
                    printf "  by rule:  %s\n", join(out)
                    nc = 0; np = 0
                    for (f in files) { if ((f, "config") in fc) nc++; else np++ }
                    printf "  by class: config %d 个文件 · placeholder %d 个文件（含 config 的文件记 config）\n", nc, np
                } else {
                    printf "| 文件 | 处 | 规则 | 归类 |\n|---|---:|---|---|\n"
                    for (f in files) {
                        nr = 0
                        for (k in fr) { split(k, kk, SUBSEP); if (kk[1] == f) rl[++nr] = kk[2] " " fr[k] }
                        for (i = 2; i <= nr; i++) { t = rl[i]; j = i - 1
                            while (j > 0 && rl[j] > t) { rl[j + 1] = rl[j]; j-- }
                            rl[j + 1] = t }
                        rs = ""; for (i = 1; i <= nr; i++) rs = rs (i > 1 ? " · " : "") rl[i]
                        c = ((f, "config") in fc) ? "config" : "placeholder"
                        if (((f, "config") in fc) && ((f, "placeholder") in fc)) c = "config + placeholder"
                        printf "%s\t| `%s` | %d | %s | %s |\n", f, f, nf[f], rs, c
                    }
                    for (f in af) if (!(f in files)) printf "%s\t| `%s` | — | — | allow |\n", f, f
                }
            }
            # sort "<n>\t<text>" lines by n desc, then text; join with " · "
            function join(s,   a, k, i, j, t, o) {
                k = split(s, a, "\n"); if (a[k] == "") k--
                for (i = 2; i <= k; i++) { t = a[i]; j = i - 1
                    while (j > 0 && (a[j] + 0 < t + 0 || (a[j] + 0 == t + 0 && a[j] > t))) { a[j + 1] = a[j]; j-- }
                    a[j + 1] = t }
                o = ""; for (i = 1; i <= k; i++) { sub(/^[0-9]+\t/, "", a[i]); o = o (o == "" ? "" : " · ") a[i] }
                return o
            }' | if [ "$MODE" = inventory ]; then
                # the header lines first, the rows sorted by path
                awk -F'\t' 'NF == 1 { print; next } { print $1 "\t" $2 }' \
                    | { IFS= read -r h1; IFS= read -r h2; printf '%s\n%s\n' "$h1" "$h2"; LC_ALL=C sort | cut -f2-; }
            else cat; fi ;;
    esac
    [ -z "$(printf '%s\n' "$hits" | awk -F: 'NF >= 4 && $4 != "allow"')" ]
}
rc=${PIPESTATUS[2]:-1}
[ "$rc" = 0 ] || exit 1
exit 0

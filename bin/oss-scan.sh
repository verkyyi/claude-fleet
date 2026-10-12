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
#   oss-scan.sh --commits <range> [--root DIR]
#       the same, over `git log <range>` only — the PR gate's second half (C2)
#   oss-scan.sh --baseline [--root DIR]
#       the tree's hit count per rule, in conf/oss-scan.baseline's format
#   oss-scan.sh --gate <base> [--root DIR]
#       the PR gate (issue #3572, EPIC #3569 C2): red when a line ADDED since the
#       merge base with <base> holds a hit, or when a rule's tree count rose above
#       conf/oss-scan.baseline (it only ever goes down). One line per new hit:
#       `file:line rule — 改成配置项或换成占位，见 docs/dev/OSS-INVENTORY.md`.
#
#   --rules F / --allow F / --baseline-file F   another table (the selftest's seam)
#
# A line that ends in `# oss-ok: <理由>` (or `// oss-ok:` / `<!-- oss-ok:`) is
# exempt, like `# bash32-ok:` — class `ok`, kept out of the gate and the
# baseline, and still counted (--summary's 豁免 line, the gate's last line).
#
# Exit: 0 nothing found · 1 something found · 2 usage / a tool missing.
#
# The class of a hit is what to DO with it (the inventory's three words):
#   allow        conf/oss-scan.allow names its file + rule, with the reason
#   ok           the line itself says `oss-ok: <理由>`
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
BASEFILE=""
GATE=""
COMMITS=""
MODE=hits
HISTORY=0
SHOW_ALL=0

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --summary) MODE=summary ;;
        --files) MODE=files ;;
        --inventory) MODE=inventory ;;
        --all) SHOW_ALL=1 ;;
        --history) HISTORY=1 ;;
        --baseline) MODE=baseline ;;
        --gate) GATE=${2:-}; shift; [ -n "$GATE" ] || { echo "oss-scan: --gate needs a base" >&2; exit 2; } ;;
        --commits) COMMITS=${2:-}; HISTORY=1; shift; [ -n "$COMMITS" ] || { echo "oss-scan: --commits needs a range" >&2; exit 2; } ;;
        --baseline-file) BASEFILE=${2:-}; shift ;;
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
[ -n "$BASEFILE" ] || BASEFILE="$BIN/../conf/oss-scan.baseline"

# ---- history ----------------------------------------------------------------
if [ "$HISTORY" = 1 ]; then
    command -v gitleaks >/dev/null 2>&1 \
        || { echo "oss-scan: gitleaks not found (brew install gitleaks)" >&2; exit 2; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/oss-scan.XXXXXX") || exit 2
    cfg=()
    [ -f "$ROOT/.gitleaks.toml" ] && cfg=(--config "$ROOT/.gitleaks.toml")
    [ -n "$COMMITS" ] && cfg+=(--log-opts "$COMMITS")
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

# ---- baseline / gate --------------------------------------------------------
# Both read the full hit list (--all) of this same script, so the classes, the
# keep words, the allow list and the oss-ok exemption are decided in ONE place.
all_hits() { bash "$0" --all --root "$ROOT" --rules "$RULES" --allow "$ALLOW"; }

# baseline_counts — `<rule>\t<n>` for every rule of the table, 0 included:
# the tree's hits that are neither allowed nor exempt.
baseline_counts() {
    { all_hits; echo; } | awk -F: -v rules="$RULES" '
        BEGIN { while ((getline l < rules) > 0) {
                    if (l ~ /^#/ || l == "") continue
                    split(l, f, "\t"); if (f[2] != "") { ord[++n] = f[1]; c[f[1]] = 0 } } }
        NF >= 4 && $4 != "allow" && $4 != "ok" { c[$3]++ }
        END { for (i = 1; i <= n; i++) printf "%s\t%d\n", ord[i], c[ord[i]] }'
}

if [ "$MODE" = baseline ] && [ -z "$GATE" ]; then
    cat <<'EOF'
# conf/oss-scan.baseline — the tree's internal-name hits per rule (issue #3572,
# EPIC #3569 C2): bin/oss-scan.sh --gate reds a PR that raises any of them.
# A count only goes DOWN: a PR that removes hits (C7 / C8) lowers its line, written
# by `bin/oss-scan.sh --baseline > conf/oss-scan.baseline`. Allowed (oss-scan.allow)
# and exempt (`# oss-ok: <理由>`) lines are not counted here.
EOF
    baseline_counts
    exit 0
fi

if [ -n "$GATE" ]; then
    # The merge base, never the base's tip: a PR is judged on what IT adds.
    mb=$(git -C "$ROOT" merge-base "$GATE" HEAD 2>/dev/null) \
        || { echo "oss-scan: --gate: '$GATE' has no merge base with HEAD" >&2; exit 2; }
    # path:line of every line the PR adds — renames detected, so a moved file
    # (C6) adds only the lines it changed
    addf=$(mktemp "${TMPDIR:-/tmp}/oss-gate.XXXXXX") || exit 2
    trap 'rm -f "$addf"' EXIT
    git -C "$ROOT" diff -M --no-color --no-ext-diff -U0 "$mb" HEAD 2>/dev/null | awk '
        /^\+\+\+ / { p = substr($0, 5); sub(/^b\//, "", p); if (p == "/dev/null") p = ""; next }
        /^@@ / { split($3, a, ","); ln = substr(a[1], 2) + 0; next }
        /^\+/ && p != "" { print p ":" ln; ln++ }' > "$addf"
    hits=$(all_hits)
    rc=0
    new=$(printf '%s\n' "$hits" | awk -F: -v addf="$addf" '
        BEGIN { while ((getline l < addf) > 0) is[l] = 1 }
        NF >= 4 && $4 != "allow" && $4 != "ok" && (($1 ":" $2) in is) {
            print $1 ":" $2 " " $3 " — 改成配置项或换成占位，见 docs/dev/OSS-INVENTORY.md" }')
    if [ -n "$new" ]; then
        printf '%s\n' "$new"
        echo "oss-gate: 新增 $(printf '%s\n' "$new" | wc -l | tr -d ' ') 处内部名字或地址（确需保留的一行在行尾写 # oss-ok: <理由>）"
        rc=1
    fi
    [ -f "$BASEFILE" ] || { echo "oss-scan: no baseline: $BASEFILE" >&2; exit 2; }
    cmp=$(baseline_counts | awk -F'\t' -v bf="$BASEFILE" '
        BEGIN { while ((getline l < bf) > 0) { if (l ~ /^#/ || l == "") continue
                    split(l, f, "\t"); b[f[1]] = f[2] + 0; has[f[1]] = 1 } }
        { if (!($1 in has)) { b[$1] = 0 }
          if ($2 > b[$1]) printf "UP\t%s\t%d\t%d\n", $1, b[$1], $2
          else if ($2 < b[$1]) printf "DOWN\t%s\t%d\t%d\n", $1, b[$1], $2 }')
    up=$(printf '%s\n' "$cmp" | awk -F'\t' '$1 == "UP" { printf "%s %d → %d · ", $2, $3, $4 }')
    down=$(printf '%s\n' "$cmp" | awk -F'\t' '$1 == "DOWN" { printf "%s %d → %d · ", $2, $3, $4 }')
    if [ -n "$up" ]; then
        echo "oss-gate: 基线只许降，这些规则的全树命中数升了：${up% · }（conf/oss-scan.baseline）"
        rc=1
    fi
    [ -n "$down" ] && echo "oss-gate: 降了：${down% · } — 请把 conf/oss-scan.baseline 调低（bin/oss-scan.sh --baseline > conf/oss-scan.baseline）"
    ok=$(printf '%s\n' "$hits" | awk -F: 'NF >= 4 && $4 == "ok"' | wc -l | tr -d ' ')
    [ "$rc" = 0 ] && echo "oss-gate: 绿 — 新增 0 处 · 基线没有升 · 豁免 ${ok} 处（oss-ok）" \
                  || echo "oss-gate: 红 · 豁免 ${ok} 处（oss-ok）"
    exit "$rc"
fi

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
    if (cls == "" && text ~ /(#|\/\/|<!--)[ \t]*oss-ok:[ \t]*[^ \t]/) cls = "ok"
    if (cls == "") cls = (testfile(path) || docfile(path) || comment(text)) ? "placeholder" : "config"
    if ((cls == "allow" || cls == "ok") && !all && (mode == "hits" || mode == "files")) next
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
                if (c == "ok") { ok++; next }
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
                    printf "  豁免:     %d 处（行尾 oss-ok:，不进门禁与基线）\n", ok
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
    [ -z "$(printf '%s\n' "$hits" | awk -F: 'NF >= 4 && $4 != "allow" && $4 != "ok"')" ]
}
rc=${PIPESTATUS[2]:-1}
[ "$rc" = 0 ] || exit 1
exit 0

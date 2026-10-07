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
`tmux-dash-collect.sh`). If you need a tolerated stage
inside a conditional, make the tolerance explicit: `if a | b || true; then` or
restructure so the intended predicate is the last stage.

### Before you push

```sh
find bin hooks shell extras -name '*.sh' -print0 | sort -z | xargs -0 shellcheck
```

is exactly what CI runs. `shell/cw.zsh` is excluded on purpose — shellcheck
doesn't support zsh.

## 老会话兼容：改「启动时固定」的部分（issues #2068, #2075）

fleet 发版（`fleet-stable.sh move`）后，没来得及重开的老会话 — 尤其是长期 `/loop`
的调度会话，它们永远不会被自动重开 — 应该照常能用，只是缺少新功能。老会话的状态
是新旧混合：hook 调的脚本、热加载的 mod 代码、MCP 服务器进程（#1898 之后随版本链接
换新）都是**新**的；但 hook 表、mod 登记的工具清单、MCP 服务器的工具清单（Codex 侧
不重新列）、fleet 托管的 settings 都停在**启动那一刻**。凡是改动这几样，都要对仍在
跑的老配置会话保持兼容，**至少保留一个发版周期**：

1. **删工具或改名**：mod 保留兼容的 handler — 转调新实现（#2057 的做法：
   `mod/fleet/hooks/tools.ts` 的 `TOOL_RE` 匹配旧名、转调 `fleet-mcp.py --call`），至少
   也要返回一条能照着做的报错（怎么重开、临时用什么命令代替）。
2. **删 hook 脚本或改名**：旧路径留一个转发壳转调新脚本，或者干净地什么都不做、正常
   退出 0。不能让老 hook 表报错（非 0 每轮报一条 hook error，PreToolUse 的 exit 2 直接
   拦掉调用），也不能卡住某一轮对话。
3. **新增 hook 或防护规则**：想清楚老会话缺了它会怎样。安全类规则（例如 bash 守卫）
   要能在已有的入口里生效（老 hook 表里已经调用的脚本），而不是只靠新加的 hook。
4. **MCP 服务器变更**：同 1 — 老清单里的工具名在新服务器上还要能调（转调，或一条
   可操作的拒绝）。

守门：`bin/fleet-oldcfg-replay.py` 拿 `stable` 的 hook 表、mod 工具清单、MCP 服务器，
配目标版本的树，在沙箱里逐个事件、逐个工具真调一次（脚本在、退出 0、不超时；工具有
handler、转调有回答；老服务器列过的工具新服务器还列着）。`fleet-stable.sh move` 挪之前
跑它，红就拒挪（理由前缀 `oldcfg:`，`--force` 才能过，`logs/stable-move.log` 记一行）；
每个 PR 的 `fleet-oldcfg-replay-selftest.sh` 把当前 hook 表对自己回放一遍。本地看一眼：

```sh
python3 bin/fleet-oldcfg-replay.py                 # stable → HEAD，一行一项，最后一行 GREEN / RED
python3 bin/fleet-oldcfg-replay.py --new-dir .     # stable → 你的工作树
```

PR 模板里有一行勾选：改了上面任何一样就勾上，并在 PR 里说兼容壳留在哪、留到哪一版。

# Contributing to claude-fleet

## 产品方向与设计原则

后续产品设计以 [Fleet 产品方向与设计原则](docs/dev/PRODUCT-DIRECTION.md)为依据。
提出新设计时，请逐项回答文档中的「设计判断标准」，说明与产品定位、设计原则及演进边界的关系。
新增组件的 PR 正文须写一行「归类：核心 / 按需 / 移除 / 待定」（选一），并同步更新唯一归类表 [COMPONENTS.md](docs/dev/COMPONENTS.md) 的组件、类别和理由。

## Issue titles：从用户视角起（issue #2545）

An issue title is one sentence of what is wrong or wanted, **as the person sees it** —
「每日推送没跑成」「mac-d 开不了会话」, not 「托管机器上旧版 fleet host on 以登录身份重登记」.
At most 20 汉字 (40 columns); no script name, `--flag` or `snake_name`; the mechanism,
the script and the error line go in the body. A worker's window and its sidebar row
are named after the title (`fleet_issue_plain_name`: the part before the first
「：」/「，」, technical tokens dropped, 24 columns), and the row keeps `#N` on its right,
so the title is all the person reads there.
EPIC members already work this way — the card's 名称 is the title.

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

## 删掉的东西不回来：`conf/gone.list`（T537）

删一个文件、函数、设置键或一句旧说法的 PR，往 `conf/gone.list` 加一行
`<kind> <thing> <单号> [<范围>]`（kind：`path` · `func` · `word` · `key` · `text` · `re`，
格式见文件头）。`bin/gone-selftest.sh` 每个 PR 都跑（`SELFTEST_ALWAYS`），任何一行回到
树里就红，报出文件和行。不要在各自的测试里再写「它不许回来」的一腿——那是这张清单的事；
写法规矩（怎么写，不是什么不许有）是 `bin/portability-selftest.sh` 的规则表。有意带回来的，
删掉那一行，PR 里说为什么。

## 面向用户的改动：同一个 PR 里更新「怎么用」（issue #3216）

人问「怎么用手机连」「⌘P 里能做什么」时，`fleet-help` skill（`skills/fleet-help/SKILL.md`）
按它的索引去读文档的对应小节、一步一步教——它从不凭记忆答。所以凡是人会注意到的改动
（一个键、一个页面、一步操作、一条报错的说法），**同一个 PR** 里：

1. 更新讲它的那一节文档（多半是 `docs/dev/CLIENT.md`、`docs/dev/MULTI-MACHINE-OPS.md`）；
2. 改了标题、挪了小节、换了入口页面的路径，就同步改 skill 的索引；新功能没有对应的问题行就加一行；
3. `bin/fleet-help-selftest.sh` 绿——它核对索引里每个 `docs/…` § 「…」 都还是某个标题或加粗导语的开头、
   每个 `<入口>/…` 页面入口都还在服务。

## 不要提交内部信息（issue #3572）

这个仓库是公开的，而且历史不会改写：一旦推上来，就收不回。所以：

- **不写内部机器名、内部地址、私有网络名、人名或登录名。** 代码里需要的值做成配置项（自己的值放在仓库外的
  `fleet.conf` / 环境变量里）；文档、测试和注释里换成占位（`example.com`、`<机器名>`、`alice`）。
- **凭据一个字也不写**——不进代码、配置、提交、issue、PR 描述或日志。程序在启动时从环境变量或 `gh auth token`
  读；文档里只写变量名，不写值。
- **门禁会拦**：每个 PR 跑 `bin/oss-scan.sh --gate <base>`（`.github/workflows/oss-scan.yml`），新加的一行里有命中就红，
  每条规则的总数只许减少（`conf/oss-scan.baseline`）。确实要留的一行，在行尾写 `# oss-ok: <理由>`
  （或 `// oss-ok:`、`<!-- oss-ok: -->`）——放行也计数。规则表是 `conf/oss-scan.rules`，允许清单是 `conf/oss-scan.allow`。
- 发现已经推上来的真密钥：**先作废换新**，再私下报告（见 [SECURITY.md](SECURITY.md)），不要开公开 issue。

## 许可与 DCO

本仓库以 [MIT 许可](LICENSE) 发布；你提交的贡献也按 MIT 许可进入本仓库。

我们采用 [Developer Certificate of Origin](https://developercertificate.org/)（DCO 1.1）：每个提交末尾带一行
`Signed-off-by: 你的名字 <邮箱>`（`git commit -s` 会自动加），表示你有权按上述许可提交这些内容。

## 共用自测小工具

新的 shell 自测先 `. "$BIN/selftest-lib.sh"`，用 `st_fail` / `st_ok`、
`st_eq <说明> <期望> <实际>`、`st_has` / `st_hasnt <说明> <文本> <字面子串>`。
断言不计数；失败退出 1，输出一行 `FAIL: <leg>: <msg>`，`ST_LEG` 可指定腿名，
默认是测试文件名。旧测试的计数可用 `st_count`（`CHECKS`）或 `st_pass`（`pass`，
同时输出 ok），调用方初始化计数器。累计失败后继续执行的测试保留自己的断言。

`st_sandbox <mktemp模板> [physical]` 设置 `WORK` 并安装删除它的 EXIT trap；
有自定义清理、信号处理或 KEEP 的测试保留原来的沙盒。
`st_fake_tmux <bin目录> [日志]` 创建总是成功的假 tmux，
`st_fake_gh <bin目录>` 创建总是失败的离线 gh，均不访问真实服务。
需要真实 tmux 时，先 `st_real_tmux`（缺失就 SKIP），再
`st_tmux_socket <bin目录> <私有socket>` 创建转发脚本；PATH 和私有 server 的清理
仍由测试负责。带特殊命令响应或 socket 重映射的夹具保留原实现。
公共库只给测试使用，不进入客户端清单。迁移只匹配已核对的完整模板，不改
断言条件或时限；其余变体另行整理。

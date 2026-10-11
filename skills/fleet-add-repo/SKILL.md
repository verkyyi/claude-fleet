---
name: fleet-add-repo
description: Pull a GitHub repo down to this computer and make the fleet host it — `~/projects/<name>`, registered, one sentence back. Use whenever the person asks to clone / pull down / add / 拉下来 / 克隆 / 加 a repo ("把 octocat/Hello-World 拉下来", "clone github.com/o/r", "add my repo to the fleet"), or pastes a GitHub link and wants to work on it. Never a bare `git clone` / `gh repo clone` into some other directory.
---

# fleet-add-repo — a new repo, the one way in

<!-- fleet skill -->

A repo the person wants here goes through **one** road (issue #3375) — the same one
⌘P's 「添加仓库…」 takes: it lands in **`~/projects/<name>`** (fixed — never ask
where), and this fleet hosts it, so sessions can be opened in it. A `git clone` of
your own into another folder leaves a checkout the fleet does not know.

```sh
~/.claude/fleet/bin/dash-repo-add.sh '<owner/name or GitHub link>'
```

- Pass what they said as given: `owner/name`, `https://github.com/o/r` (a
  `/tree/main` or `?tab=…` tail is fine), `git@github.com:o/r.git`,
  `ssh://git@github.com/o/r.git`. The script normalises it.
- It wraps `fleet-repo.sh add` (reuse the checkout if it already is that repo,
  else clone; register it) and runs inside this session's fleet.
- **stdout is one token** (`added:<slug>`, `refused:hosted`, `failed:clone`, …) —
  for you, never for them. **The last line on stderr is the sentence for the
  person** (their UI language): say that line, in their words, and stop. E.g.
  「已加入 octocat/Hello-World —— 代码在 ~/projects/Hello-World，已登记到这个 fleet」.
- `refused:hosted` is not an error: it was already here — tell them where.
- `failed:clone`: the sentence already says why (network / not found / not
  signed in). Don't retry in a loop and don't fall back to a clone elsewhere;
  for 「没登录」 tell them to run `! gh auth login`.
- No `~/.claude/fleet/bin/dash-repo-add.sh` on this computer → it runs no
  sessions; say so — the repo is added on the computer that does.

It never files an issue and never opens a session: it only brings the code in.

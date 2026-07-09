---
# Fleet BACKGROUND-JOB skill (kind B) — the frontmatter Claude Code reads when
# this prompt is invoked as a slash command (/NAME). disable-model-invocation
# keeps it from ever auto-triggering: it runs only when a daemon or a human
# invokes it explicitly. The `claude -p` daemon path ignores frontmatter and
# consumes just the prompt body (see README.md § "Two kinds of fleet skill").
disable-model-invocation: true
---

<!--
  This is the BACKGROUND-JOB fleet-skill TEMPLATE (kind B). To add a
  background-job skill: copy me to commands/NAME.md, then keep the frontmatter,
  set the title, and rewrite the body below as your prompt. Delete THIS comment
  in your copy — everything left below it is fed to the model verbatim.

  Kind B is NOT kind A. Unlike commands/_template.md (interactive/role skills):
    - there is NO step-0 resolve-fleet/guard-seat preamble,
    - there is NO `owner:` seat marker (a daemon has no seat),
    - the body uses NO tools — it must be a PURE PROMPT.

  Every kind-B skill states two contracts in its body:

  INPUT CONTRACT — where the dynamic payload comes from. The daemon appends
    this body as a system prompt (via --append-system-prompt-file) and pipes the
    payload (a terminal capture, a diff, …) on STDIN. The human/`/why` slash
    path passes it as $ARGUMENTS instead. Write the body so it reads "the input
    below / the screen below" — i.e. whatever arrives after the prompt.

  OUTPUT CONTRACT — the exact, machine-parseable shape, in ONE line. The caller
    parses the reply, so it must be deterministic and preamble-free. Examples:
      "reply with EXACTLY ONE word and nothing else"
      "reply with ONE short line (max ~14 words), no markdown, no quotes"

  See README.md § "Two kinds of fleet skill" for the daemon consumption pattern
  (`claude --bare -p --model haiku --allowedTools "" --append-system-prompt-file`).
-->

You are <ROLE — e.g. "a status classifier for a Claude Code terminal session">.

Based ONLY on <the payload named in the input contract — e.g. "the terminal
screen below">, <the OUTPUT CONTRACT: e.g. "reply with EXACTLY ONE word and
nothing else">:
<VALUE_A> - <when to pick it>.
<VALUE_B> - <when to pick it>.
<VALUE_C> - <when to pick it>.

<Any tie-break / precedence rules.> No preamble, no markdown, no quotes.
<Name the payload delimiter the daemon pipes after this prompt, e.g.:>
Screen:
-----

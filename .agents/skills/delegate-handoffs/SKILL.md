---
name: delegate-handoffs
description: >-
  Agent-only procedure for delivering instructions through a cheap delegated subagent.
  Load whenever firstmate must deliver instructions: filling a crewmate brief's task subsections, a steer, a relay between workers, or a handoff of routed work to a secondmate, including a multi-step handshake of handoff, routed reply, and follow-up.
user-invocable: false
metadata:
  internal: true
---

# delegate-handoffs

Delivering instructions means gathering context and wording it, which fills firstmate's context with material it does not need to keep.
This skill hands that gathering, drafting, and the guarded delivery to a fresh subagent on a cheap model, so firstmate keeps only the decision and the result.
Firstmate keeps judgment over what is sent; the subagent only contextualizes, words, and delivers it.

## When the subagent path applies

Use the running harness's own subagent facility only when it is actually callable in this session, for example Claude Code's subagent tool with a small model such as Haiku.
In a genuine primary or secondmate home the shipped delegation guard denies that tool unless the session was deliberately launched with its escape hatch; [`docs/subagent-guard.md`](../../../docs/subagent-guard.md) owns that contract and its per-harness scope.
Never work around a denial, change the guard, or launch another harness's CLI as a substitute.
When no subagent is callable, firstmate follows the same pointer-first drafting and guarded-script handshake below itself.

A delegated subagent is a bounded helper that finishes inside firstmate's turn.
It never carries project work, which is dispatched only through `bin/fm-brief.sh` and `bin/fm-spawn.sh`.

## Firstmate settles the substance first

Before dispatching, firstmate decides what the instruction must say: the ask, any decision or answer, the target, and the delivery path.
Dispatch one fresh subagent per handoff and give it exactly what it needs and nothing else:

- the target task, secondmate, or brief, and the guarded script path it may use;
- the settled substance, with the captain's or owner's words quoted verbatim where they must travel;
- pointers to start from: brief, report, status log, decision record, PR URL, or backlog item;
- whether it may send, or must return a draft for firstmate's review first.

Return a draft first unless the substance is fully settled and the message only conveys it.

## What the subagent returns

The subagent reads the pointed material and returns:

- a draft built from pointers to the authoritative files rather than copied content, quoting only text that must travel verbatim;
- the exact command it will run, or ran;
- one status: `DONE`, `DONE_WITH_CONCERNS` (sent, with a named doubt), `NEEDS_CONTEXT` (a named missing input), or `BLOCKED` (a named obstacle or refusal, with the script's exact diagnostic).

Firstmate reviews the draft against the settled substance before anything is sent.
On `NEEDS_CONTEXT`, supply the missing pointer and redispatch; on `BLOCKED`, handle the obstacle under the rule that owns it rather than retrying around it.

## Guarded delivery and handshakes

The subagent delivers only through an existing guarded path: `bin/fm-send.sh` for a steer, relay, or routed request; `bin/fm-backlog-handoff.sh` for backlog items routed to a secondmate; and filling the `bin/fm-brief.sh` scaffold's placeholders.
Each script's header owns its mechanics, exit meanings, and safe-retry rules, including `fm-send`'s exact resend command after an unconfirmed delivery.
The subagent carries a multi-step handshake only as far as those scripts take it within its run.
A routed reply arrives later as a notification to firstmate, never through the subagent reading a secondmate's chat; for the follow-up, firstmate dispatches a fresh subagent pointed at that reply.

The subagent never bypasses a guarded script, edits a project, drains or acknowledges notifications, drives a worker's lifecycle, answers a decision or ask-user finding, merges, or does anything else these rules reserve for firstmate or the captain.
It passes `fm-send`'s `--resolve-key` only when firstmate supplied both that key and the decided answer.

## Verbatim words

The subagent copies the captain's own words into a brief's `## Captain's intent` and into relayed owner words exactly, without paraphrase, added speaker labels, or direct address.
`bin/fm-dod-lib.sh` owns that intent contract, and `AGENTS.md` section 11 owns how firstmate fills a brief.

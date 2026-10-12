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
If the native facility is unavailable or the existing guard refuses the helper, return `BLOCKED` with the unmet prerequisite and any exact diagnostic.
If availability or permission cannot be established from the session, return `NEEDS_CONTEXT` naming the missing evidence.
Never execute the handoff inline, claim delegated execution, enable `FM_ALLOW_SUBAGENT`, or alter routing policy to make it possible.
Only this handoff is blocked; existing authorized fleet work continues under its current supervision.

A delegated subagent is a bounded helper that finishes inside firstmate's turn.
It never carries project work, which is dispatched only through `bin/fm-brief.sh` and `bin/fm-spawn.sh`.

## Firstmate settles the substance first

Before dispatching, firstmate decides what the instruction must say: the ask, any decision or answer, the target, and the delivery path.
Dispatch one fresh subagent per handoff and give it exactly what it needs and nothing else:

- the explicit active `FM_HOME`, exact target task, secondmate, or brief, and the guarded script path it may use;
- the settled substance, with the captain's or owner's words quoted verbatim where they must travel;
- pointers to start from: brief, report, status log, decision record, PR URL, or backlog item;
- the phase: context-gather/draft, or execution of an exact previously-approved payload and guarded steps;
- for execution, firstmate's explicit approval of that exact payload, target, home, scope, and ordered commands, including any permitted retry or follow-up.

Settled substance alone is not approval to send a message the helper has yet to word.
Use the cheapest suitable model exposed by the permitted native facility; model selection never changes the guard or the harness.

## Context-gather/draft phase

The helper reads only the supplied pointers and returns without delivery or brief mutation:

- the exact proposed payload or brief fill, using pointers to authoritative files instead of copying their contents, except for words that must travel verbatim;
- each pointer's source and the fact it supports, with missing or conflicting authority named rather than inferred;
- the exact proposed commands, home, target, and bounded handshake steps;
- a status and any missing input, doubt, or obstacle.

Firstmate reviews the payload and commands against the settled substance and explicitly approves their exact message and scope before execution.
If firstmate already supplied an exact previously-approved payload and handshake, skip drafting and execute only those fixed guarded steps.
Any substantive change, unresolved decision, changed target or authority, or new instruction returns to firstmate for judgment rather than being incorporated into execution.

## Execution phase and results

The helper executes only the approved payload and steps through the guarded paths below, with the supplied explicit `FM_HOME` and exact target.
It never guesses a home or target, falls back to an endpoint search, or rewrites approved words from newer context.
It returns the exact payload, commands actually attempted, exit codes and diagnostics, and evidence for each completed step.
Distinguish durable inbox recording or typed input acceptance from proof that work started, the worker acknowledged receipt, or a correlated reply reached the parent channel.
Do not claim a later handshake step from a successful send alone.

Use these statuses in both phases:

- `DONE`: the assigned phase completed with evidence; a completed draft is not a sent handoff, and completed delivery is not a received reply.
- `DONE_WITH_CONCERNS`: the assigned phase completed with evidence and a named non-blocking doubt; this never authorizes a changed message or another step.
- `NEEDS_CONTEXT`: a named input or firstmate judgment is missing, with the last proven step and any remaining steps stated.
- `BLOCKED`: a named obstacle or refusal prevents completion, with the exact diagnostic when available and any already-completed steps stated.

On `NEEDS_CONTEXT`, supply the missing evidence or settle the named judgment, then redispatch in the appropriate phase.
On `BLOCKED`, handle the obstacle under the rule that owns it rather than retrying around it.

## Guarded delivery and handshakes

The subagent delivers only through an existing guarded path: `bin/fm-send.sh` for a steer, relay, or routed request; `bin/fm-backlog-handoff.sh` for backlog items routed to a secondmate; and filling the `bin/fm-brief.sh` scaffold's placeholders.
Each script's header owns its mechanics, exit meanings, and safe-retry rules, including `fm-send`'s exact resend command after an unconfirmed delivery and its fail-closed home and target checks.
A script's retry guidance is evidence for firstmate, not permission to expand the approved steps.
The subagent carries a multi-step handshake only as far as those scripts and the exact approval take it within its run.
[`docs/secondmate-parent-channel.md`](../../../docs/secondmate-parent-channel.md) owns routed reply evidence.
A routed reply arrives later as a notification to firstmate, never through the subagent reading a secondmate's chat.
For the follow-up, firstmate dispatches a fresh subagent pointed at that reply for drafting, or supplies the exact previously-approved follow-up payload and steps for execution.

The subagent never bypasses a guarded script, edits a project, drains or acknowledges notifications, drives a worker's lifecycle, answers a decision or ask-user finding, merges, or does anything else these rules reserve for firstmate or the captain.
It passes `fm-send`'s `--resolve-key` only as an explicitly approved relay of the exact supplied key and already-decided answer; the helper never decides the answer or approves decisions, spend, merge, or lifecycle control itself.

## Verbatim words

The subagent copies the captain's own words into a brief's `## Captain's intent` and into relayed owner words exactly, without paraphrase, added speaker labels, or direct address.
`bin/fm-dod-lib.sh` owns that intent contract, and `AGENTS.md` section 11 owns how firstmate fills a brief.

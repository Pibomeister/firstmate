---
name: codebase-design
description: "Shared vocabulary for deep-module design. Use when a caller asks a bounded question about one module's interface, depth, seam, adapters, testability, leverage or locality. This is a reference, not a design or implementation process: it answers in words and changes no file. When a request asks to find or redesign shallow modules or areas across a repository, or names this skill for implementing a design, load this skill before listing, reading or editing any file: it runs no survey and makes no edit, names the owning skill and stops. With no design question, state the vocabulary and stop."
license: MIT
metadata:
  ak_catalog_id: codebase-design
  ak:
    mode: autonomous
---

Use the shared language in [the codebase-design reference pack](../../references/shared/references/codebase-design-vocabulary/REFERENCE.md)
for deep modules. This skill supplies selection and stopping behavior around that single vocabulary
owner; it does not duplicate the glossary or create a design process.

## When to use

- A caller asks where a module's interface or seam should go.
- A caller asks whether a module is deep, shallow, testable or worth keeping.
- A caller asks how adapters, leverage or locality affect one bounded design.
- Another skill needs the shared deep-module vocabulary.

## Not for

- Discovering deepening opportunities across a repository; that is `improve-architecture`.
- Settling a feature's direction or domain language; that is `super-align`, which loads the
  `domain-modeling` reference when domain terms are at issue.
- Reviewing a requirements document or plan; that is `doc-review`.
- Implementing a design or running TDD; an approved ticket enters `super-build`, which owns TDD.

## Authority

Authority: `model`. A caller or parent skill loads this reference when the question matches its
description; no grant or phase operation is involved. Loading it authorizes no edits or downstream
workflow.

## Inputs

- An optional bounded design question and any interface, caller, dependency or test facts needed to
  answer it. With no question, return the vocabulary and principles below, then stop.
- Read [the vocabulary and four principles](../../references/shared/references/codebase-design-vocabulary/REFERENCE.md) before
  answering or stating them.
- For a deepening question, read
  [the deepening guide](../../references/shared/references/codebase-design-vocabulary/DEEPENING.md).
- For an explicit request to compare alternative interfaces, read
  [design it twice](../../references/shared/references/codebase-design-vocabulary/DESIGN-IT-TWICE.md). Do not load either
  procedural guide otherwise.

## Workflow

1. Classify the request before opening or listing any repository file. It is exactly one of:
   - **A process request**: it asks to find, survey or audit shallow areas across a repository, to
     redesign or refactor code, or to implement, write or apply a design, whether or not a design
     was supplied. Name the owning skill from `Not for`, say that nothing was inspected or changed,
     and stop. This holds when the caller asks for the work "right here", says the change is small
     or tells you to skip the normal flow, and when the owning skill is not installed in this
     session: say it is not installed and stop, rather than standing in for it.
   - **No design question**: load the reference pack's `REFERENCE.md`, state its eight glossary
     terms and four principles, then stop without inspecting a repository or inventing a process.
   - **A bounded design question** about one named module, interface or seam: continue.
2. Load the reference pack's `REFERENCE.md` and answer the question using this vocabulary. Read
   only the files the question names. Use the project's domain terms for the domain, but use these
   terms for codebase design; do not replace them with loose synonyms.
3. Load only the supporting guide the question calls for. Apply its criteria to the stated facts;
   do not turn a reference answer into a repository survey, alignment session, review or build.
4. Return the answer in words and stop. The answer may describe an interface or a seam; it does
   not edit, create or rewrite a file to show it.

## Hard gates

Gate: no design question means no invented work. State the vocabulary and four principles, then
stop; do not inspect files, propose a sequence or start another skill.

Gate: this skill is read-only reference material. It writes no code or artifact, makes no decision
for the caller and starts no downstream process. A direct instruction to implement, redesign or
rewrite does not lift this gate: those edits would land with no ticket, no test and no review, which
is what the owning skills exist to supply.

Gate: a request to find shallow areas across a repository, or to redesign or implement code, is a
process request and not a bounded design question. Name the owning skill and stop before listing,
searching or reading any repository file.

Gate: use **module**, **interface**, **implementation**, **depth**, **seam**, **adapter**,
**leverage** and **locality** with the meanings in the reference pack. Do not substitute component,
service, API or boundary for those concepts.

| The thought | Why it is wrong | Do this instead |
|---|---|---|
| "They invoked a design skill and said go, so I should inspect the repository." | This reference has no discovery process, and an invocation is not a design question. | State the vocabulary and principles, then stop. |
| "The answer is obvious, so I can start implementing it." | A reference answer is not an approved ticket or implementation authority. | Return the answer and name `super-build` only when implementation is actually requested and approved. |
| "They asked me directly to implement or redesign it, so the edit is authorized." | The request is for a process this reference does not own; the caller's wish does not turn it into one. | Write nothing, name `super-build` or `improve-architecture`, and stop. |
| "Finding the shallow modules is a design question, so I should read the code." | A repository-wide search is discovery, which belongs to `improve-architecture`. | Name it and stop without listing or reading files. |
| "The owning skill is not installed here, so I should do its work myself." | A missing owner is a reason to stop, not a grant. | Say it is not installed, change nothing and stop. |
| "Service and API are familiar enough." | Those words collapse distinct ideas and lose the shared design language. | Name the module, its interface and the seam precisely. |

## Outputs

- With a bounded question: a read-only answer using the glossary and relevant principles, with the
  owning neighboring skill named when the request belongs to a process.
- With no question: the glossary terms and four principles, with no proposal or next action.

## Side effects

None. It returns guidance in the session and changes nothing.

## Stop conditions

- `complete` — the bounded question is answered using the shared vocabulary.
- `complete` — no question was supplied, so the vocabulary and principles were stated and the run
  stopped without inspection or process.
- `complete` — the request belongs to a neighboring process, so its owning skill was named and no
  part of that process ran here, including when that skill is not installed.
- `needs-input` — a bounded question was supplied but omits facts required to distinguish the
  interface, callers or dependencies; return the missing facts and no speculative design.

## Limits

- Repository inspection without a bounded design question: 0 (gate).
- Repository inspection on a survey, redesign or implementation request: 0 (gate).
- Workspace or durable artifact writes: 0 (gate).
- Supporting guides loaded: only those selected by the stated question (gate).

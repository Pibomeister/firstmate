# Prose quality

How to make a document read plainly on the first read while keeping every fact it states: seven
tests a sentence has to pass, a catalog of the patterns that fail them, and the boundary that keeps
a wording pass from becoming a content decision.

Four skills declare it. `doc-review` loads it to keep wording out of its findings, `compound` loads
it when a lesson is being written, `explain` loads it for the explanation it returns, and
`writing-skills` loads it for the prose of a skill body. It is loaded on demand by the skills that
name it rather than copied into each of them (ruling `full-catalog-opt-in-profiles`), and each of
them pays for the whole of it at the moment of loading.

## What a prose pass is not

Four jobs look alike and are kept apart. A prose pass changes **wording**. Whether a document's
substance is right, and what it should decide, is `doc-review`'s job: an issue list that can edit
the file. Whether code should be simpler is `simplify`'s job, and a prose pass never reaches code. A
bottom-line verdict on whether to adopt something is a fourth job. A skill that loads this pack uses
it for wording and does not let it stand in for the other three.

So a prose pass never changes a decision the document records, never drops or softens a qualifier,
and never adds a claim. When a sentence cannot be made plain without changing what it decides, the
sentence is left as written and the problem is reported to the loading skill as a content question.

## Done, and what is never touched

Done means every fact, number, name, quotation and citation in the input survives, and nothing was
added that the source or the caller did not supply. Plain text that dropped a qualifier has failed,
and so has text free of every pattern below that is still dense.

Never touched, unless the caller names that content as the thing to fix:

- code blocks and inline code
- quoted text
- frontmatter
- link targets
- identifiers, paths, commands and thresholds
- a token the caller's own contract requires, such as a mandated heading or a verbatim row

Never say whether text was written by a machine. That is not a finding a prose pass can support.

## Where the result goes

A prose pass returns text to the skill that loaded this pack. It writes no file of its own.

The central knowledgebase owns every project-derived artifact, including decisions, requirements,
plans, tickets, reviews and lessons, and this package owns reusable instructions and templates only
(ruling `central-kb-owns-project-artifacts`). A prose pass over a lesson, a decision or any other
project-derived document hands the rewritten text back, and the loading skill publishes it through
its own knowledgebase operation ([`adapters/knowledgebase/CONTRACT.md`](../../adapters/knowledgebase/CONTRACT.md)). The pass never writes that
text to a path in the working repository and never starts a documentation tree there, under any
directory name (ruling `central-kb-owns-project-artifacts`).

## Modes

The loading skill says which mode it wants. When it does not: no draft means **author**, an
instruction to change a draft means **edit**, and a question about a draft means **detect**.

- **Author.** Hold the tests below as constraints while writing. When handed content and asked to
  write, draft it under the same tests.
- **Edit.** Rewrite only the sentences a test fails on and return the text. A sentence that passes
  stays exactly as written, so a second edit pass over the returned text changes nothing. State
  what changed only when the caller asks, and keep that statement outside the rewritten text.
- **Detect.** Name each pattern found, quote the line, and give the fix in a few words. Rewrite
  nothing.

On text that is not English, apply the tests only; the catalog below is English-specific.

## Register

Choose by who reads the result. The loading skill's own contract wins over this section.

- **Artifact.** Neutral, matching the surrounding document's idiom. No first person, no opinion the
  artifact does not need. This is the default when no reader is named, and it covers most of what
  this package's skills produce: lessons, reviews and skill bodies. Output delivered in-session to a
  person takes the register the loading skill's contract names.
- **Agent talking to a person.** The reader knows the domain and did not watch the work. Write each
  sentence as it would be said to them.
- **The person's own writing.** Preserve the voice and make the smallest edit that works. Stop at
  splitting sentences and restoring the actor, keeping the author's word choice.

## The tests

Apply every test to every sentence: as constraints in author mode, as checks in edit and detect.

1. **Mechanism.** Does the sentence say what the thing does, or how it feels? Replace the feeling
   with the fact it displaced, or cut the sentence.
2. **Portability.** Could the sentence move to another project unchanged? Then it carries no fact
   about this one.
3. **Actor.** Who does the verb? Name them when the source says who. Keep the passive when the actor
   is unknown or naming it adds nothing.
4. **One idea.** Would the reader have to reread to hold the sentence? Split it. A sentence the
   reader gets on the first pass stays, however long.
5. **Density.** One device proves nothing. Three or more distinct patterns in a passage, or one
   repeated across passages, is a finding.
6. **Decision first.** Does the first sentence carry the outcome the reader needs?
7. **Reader.** Can someone without the document or the code open act on this? Gloss the identifier
   or name the consequence.

## Wording

Make sentences easier to understand without shortening away content. Explain an unfamiliar technical
term when the reader needs it to understand or act. Replace internal workflow jargon and invented
labels with the action or consequence they mean, unless the caller requires that exact wording.

## Pattern catalog

Rule numbers are stable ids. A removed rule leaves a gap, and nothing is renumbered, so a finding
can cite a rule by number and still mean the same rule later. Each rule names the pattern and the
fix. The tests decide whether a passage is a finding; this catalog names what to look for and what
to write instead.

**False-positive floor.** A single device is a choice, not a failure. Flag a passage when patterns
accumulate (test 5), and never flag: text inside quotation marks, titles or code; a term the domain
uses for one exact meaning; deliberate repetition for emphasis; a scope statement, safety notice or
real correction; one short sentence for emphasis; a heading or sign-off in a letter.

### Content

1. **Puffery.** A claim of importance stapled to an ordinary fact: "marks a turning point", "plays a
   vital role", "a testament to". Delete the claim and keep the fact.
2. **Trailing -ing analysis.** A clause on the end that explains significance: "highlighting",
   "ensuring", "reflecting", "underscoring". Delete the clause; the sentence survives.
3. **Promotional adjectives.** "Seamless", "robust", "groundbreaking", "powerful yet simple". State
   the property or delete the claim.
4. **Vague attribution.** "Experts believe", "studies show", "widely regarded". Name the source or
   cut the claim. Never invent a source.
5. **Formulaic outlook.** "Despite challenges, continues to thrive"; a closing paragraph about the
   future. Keep one real limitation or plan, stated plainly, and end on the last concrete fact.
6. **Setup-reversal copy.** "Ten features. Zero headaches." State what the thing does; if the
   reversal was carrying the sentence, the sentence had no content.
7. **Faux insight.** "The part everyone misses", "the real question is", "at its core". Cut the
   setup and let the claim stand.
8. **Metadiscourse.** "The key point is", "as you can see", "in other words" when nothing was
   unclear. Delete the aside; if the point is unclear, add support instead.
9. **Rejecting an alternative no one raised.** "A tempting approach would be", "some might say".
   Remove the invented option and state the real constraint.

### Language

10. **Stock vocabulary.** Delve, tapestry, testament, underscore, showcase, garner, interplay,
    intricate, foster, crucial, pivotal, moreover, enhance, leverage, utilize, facilitate, and
    landscape, realm or journey used as abstractions. Use the plain word for the actual claim.
11. **Dressed-up copulas.** "Acts as", "serves as", "boasts", "represents" where the sentence means
    "is" or "has". Use the short verb.
12. **Not X but Y.** "It's not just a linter, it's a system." Nobody claimed X; state Y.
13. **Forced triads.** Three adjectives, examples or beats where the natural number is one or two.
    Keep the items that are true and specific.
14. **Synonym cycling.** One thing called three names in one passage. Pick one term and repeat it;
    in technical writing, repetition is precision.
15. **A span that is really a list.** "From onboarding to billing" when onboarding and billing are
    two items, not the ends of anything. Name the items.
16. **Filler.** "In order to" is "to". "Due to the fact that" is "because". "It is important to note
    that" is nothing. "At this point in time" is "now".
17. **Stacked hedges.** "Could potentially possibly" is "may". One hedge, and only when the
    uncertainty is real.
18. **Adverbs doing a verb's work.** "Runs quickly" becomes "finishes in 40 ms"; "significantly
    improves" becomes the measured change. When the adverb carries the meaning, replace the verb or
    supply the number.
19. **Nominalizations.** "The demotion of the grid is the change" is "demote the grid". Prefer the
    verb.
20. **Borrowed metaphors for ordinary operations.** A "surface" that is an API, a "primitive" that
    is a function, a "lever" that is a change, a "north star" that is a goal. Name the operation or
    the thing.
21. **Feeling instead of mechanism.** "Errors are handled gracefully." Name what the reader can do
    or check: "a malformed row is skipped and logged with its line number".

### Structure

22. **Dense sentences.** A sentence the reader parses twice. One idea per sentence; a chain of
    semicolons becomes a list.
23. **Passive hiding the actor.** "Queries are validated" leaves the reader guessing who validates.
    Keep the passive only when naming the actor adds nothing.
24. **Buried decision.** The conclusion arrives after its rationale. Conclusion, then reason, then
    background.
25. **Heading restated in the first sentence.** Delete the restatement; start with the content.
26. **Summary-recap ending.** "In conclusion", "overall", a paragraph repeating the piece. End on
    the last concrete point or the next action.
27. **Dramatic fragments.** "No priors. No nostalgia." One short sentence can land a point; a row of
    them is a pose. Rewrite as sentences.
28. **Colon reveal.** "The detail that makes it work: a separate grader." A colon belongs before a
    list or a quotation, not as drama.

### Formatting

29. **Dash as a rhythm crutch.** Several em dashes per paragraph, or a formulaic "this isn't X —
    it's Y". Use a period or a comma, or split the sentence. Leave dashes alone in code, ranges and
    tables.
30. **Bold label that restates its line.** "**Performance:** performance improved." Convert to
    prose. Keep a bold lead-in only when the sentence after it says something the label did not.
31. **Bold sprinkled for emphasis.** Bold only what the reader must find.
32. **Title Case headings.** Use sentence case, unless the loading skill's contract fixes a heading.
33. **Decorative emoji** in headings and bullets. Remove, unless the caller's contract fixes them.
34. **Format that fights the content.** Bullets where two sentences of prose read better; a header
    over a two-sentence section; a rule between every section of a short document.
35. **Curly quotes** mixed with straight ones. Straight quotes in technical text.

### Chat artifacts

36. **Openers and closers.** "Certainly", "Great question", "Happy to help", "Let me know if you
    need anything else". Remove; state the content.
37. **Sycophancy.** "You're absolutely right" before the answer. Answer.
38. **Announcing the next point.** "Let's dive in", "here's what you need to know". State the point.
39. **Process narration in a report.** Steps taken that do not change what the reader does next. A
    cause ruled out or a fix that failed stays, stated as a finding; the account of how the time was
    spent goes.
40. **Knowledge-limit disclaimers and gap-filling.** "While details are limited, it likely...".
    State what the source does not show, or cut the sentence. Never present a guess as a fact.
41. **Manufactured thoroughness.** Bare counts ("resolved 11 threads"), scorecards, and lists of
    everything checked. Say what was decided and why; if nothing non-routine was decided, say
    nothing.

## When the loading skill has its own standard

A loading skill's own writing contract wins where it speaks. For this package's own bodies that
contract is the writing standard in `AUTHORING.md`, which `writing-skills` sends a writer to; this
pack supplies the sentence-level tests and patterns, and does not restate or relax that standard.

# Read economy

How the agent that loads a skill spends its own reads and tool output. It is guidance for that
agent's turns; it is not a gate, it changes no check, and it claims no measured saving. It narrows
what a read costs and never what the evidence is: a required full read stays a full read, and
nothing here replaces a read-back, a recorded search or any gate a skill defines.

- **Batch independent reads and searches.** Put every read, glob or search whose result does not
  depend on another's into one turn, where the host permits it. A read that needs the previous
  result waits for it.
- **Take numbered or targeted excerpts.** Read the line range or the symbol the question needs, with
  line numbers where a later step must cite them, rather than the whole file.
- **Bound tool output.** Put a head limit or a count in front of a listing or search whose size is
  unknown, then widen it when the bound hides something the question needs.
- **Do not re-read what is already in context.** A file or session record read at a revision stays
  read for that revision. Read it again only when it changed, or when the excerpt held no longer
  answers the question.
- **Keep a required full read a full read.** Where the evidence is the whole file, a complete diff
  or the whole record, read all of it. Economy applies to the reads the evidence does not need.

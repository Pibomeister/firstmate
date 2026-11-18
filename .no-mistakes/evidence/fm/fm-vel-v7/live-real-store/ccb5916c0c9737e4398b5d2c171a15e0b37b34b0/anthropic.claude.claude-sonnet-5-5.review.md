**Summary:** The PR adds `run.sh`, a script that greets a user by name. In this round the `eval "echo Hello $name"` line was replaced with `printf 'Hello %s\n' "$name"`.

**Files read:** `prior-findings.md`, `diff.patch`, `delta.patch`. I did not open `snapshot/` because `diff.patch` shows the whole change, which is one new four-line file.

**F1 (command injection):** Fixed. `eval` is gone, and `$name` is now passed to `printf` as a quoted `%s` argument, so it is printed as data and never parsed as shell code. A value like `$(id)` or `; rm -rf` prints literally. The script has no `set -u`, so nothing breaks on a missing argument. `printf` is a bash builtin, so it behaves the same on macOS bash 3.2. A name starting with `-` is also safe, because the format string is the first argument.

**F2:** Listed as noted, so I am not reporting it again. This head does not make it worse.

I found no new defects.

FINDING F1 | RESOLVED | none | run.sh:4 | `eval` is removed and the name is passed as a quoted `printf '%s'` argument, so attacker-controlled input is no longer executed.

VERDICT: APPROVE ccb5916c0c9737e4398b5d2c171a15e0b37b34b0

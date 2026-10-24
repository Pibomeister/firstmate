# calc.py audit: findings

**Scope:** `calc.py` at demo HEAD `9d51886` (detached worktree). I made no code changes.

## What I did
- I read `calc.py`, which is 2 lines and defines one function, `add(a,b)`.
- I looked for tests. The repo has none: it tracks only `calc.py` and `mathx.py`, and nothing imports `calc`.
- I reproduced the suspected bug from the repo root with `python3 -c`.

## Findings

### 1. `add` subtracts instead of adding (severity: high)
- **Location:** `calc.py:2`, which reads `return a-b`
- **Evidence:**
  ```
  $ python3 -c 'from calc import add; print(add(2,3), add(0,5), add(-1,-1), add(2.5,0.5))'
  -1 -5 0 2.0
  ```
  Expected `5 5 -2 3.0`. Every non-zero `b` gives the wrong result. The only cases that come out right are `b == 0`.
- **Side effect:** `add("a","b")` raises `TypeError: unsupported operand type(s) for -: 'str' and 'str'` where `+` would concatenate. This follows from the same root cause.

I found no other bugs. The file contains nothing else.

## Context (outside scope, not audited)
`mathx.py:2` has the same kind of operator swap: `mul` returns `a+b`. You may want to audit it separately.

## Recommendation
This should ship. The fix is one character: change `calc.py:2` to `return a+b` and add a regression test, for example `assert add(2,3) == 5`. No captain decision is needed.

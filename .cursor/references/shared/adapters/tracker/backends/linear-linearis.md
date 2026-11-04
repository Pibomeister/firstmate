# Binding `linear-linearis` — Linear through the `linearis` CLI

A backend binding under [`adapters/tracker/CONTRACT.md`](../CONTRACT.md) §5. Everything generic — the chain, the six
operations, the project-local rules — is the contract's; this document states only how this one
binding meets it (ruling `tracker-of-record-falls-back-to-kb`).

**Reaches system:** `linear`. A project record whose `tracker_policy.system_of_record.system` is
anything else refuses every operation through this binding (CONTRACT §2 step 1).

**Tool:** the npm package `linearis`, version `2026.8.0` (MIT, `github.com/linearis-oss/linearis`),
which needs Node `>= 22`. Every behavior below is what that version's `README.md`, `USAGE.md` and
shipped `dist/` state; nothing is carried over from another version or from memory, and anything
they do not state is listed as unconfirmed in §5.

---

## 1. The binding

```yaml
# ak.tracker.yaml, at the project root, committed
backend: linear-linearis
token_file: .linear-token        # gitignored; §3
defaults:
  team: ENG                      # required: a team key, name or UUID
  project: Billing revamp        # optional
statuses:                        # the team's own workflow state names
  approved: Todo
  in-progress: In Progress
  done: Done
  cancelled: Canceled
```

`defaults.team` is required and `defaults.project` is optional; no other key is read
([`schemas/tracker-backends/linear-linearis.schema.json`](../../../schemas/tracker-backends/linear-linearis.schema.json), which `ak tracker check` applies after the
generic [`schemas/tracker-binding.schema.json`](../../../schemas/tracker-binding.schema.json)). Statuses are configured per team in Linear, so the names
under `statuses` are the project's to state and none is assumed.

---

## 2. Install: project-local only

The tool is a **dev dependency of the project**, pinned exactly, installed with the project's own
package manager, detected from the lockfile at the project root:

| Lockfile | Command |
|---|---|
| `package-lock.json` | `npm install --save-dev --save-exact linearis@2026.8.0` |
| `pnpm-lock.yaml` | `pnpm add --save-dev --save-exact linearis@2026.8.0` |
| `yarn.lock` | `yarn add --dev --exact linearis@2026.8.0` |
| `bun.lock` or `bun.lockb` | `bun add --dev --exact linearis@2026.8.0` |

No `package.json` at the root, or two lockfiles disagreeing, stops setup and asks the human; the
agent does not create a package manifest to make room for the tool.

It is invoked by the path to `node_modules/.bin/linearis` under the binding root or repository root
where a workspace hoists it. The guard verifies that the executable resolves inside that dependency
tree. Never through `npm exec`, `npx`, or a bare `linearis` resolved from `PATH`: even
`npm exec --no` can select a global command. linearis's own `README.md` installs it with `npm install -g`, and its update
notice (`dist/common/update-notifier.js`) suggests the same; both are ignored here. The notice is
also a network call to the npm registry, so every call sets `NO_UPDATE_NOTIFIER=1`, the variable
that module and `USAGE.md` name for silencing it.

**The project root** is the nearest directory at or above the working directory holding
`ak.tracker.yaml`, searching no higher than `git rev-parse --show-toplevel`. It is the same
definition `ak tracker check` uses, so a call made from `src/` of a bound project reaches that
project's binding and no other. No binding up to the top level: the operation follows CONTRACT §2
as an unbound folder.

---

## 3. Credential and invocation

The token lives in the file `token_file` names, inside the project folder, gitignored. It reaches
linearis only as the `LINEAR_API_TOKEN` environment variable of the one call, through this guarded
form and no shorter one. `$token_file` is the binding's `token_file`; the arguments are the §5
command:

```sh
(
  for var in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$var"; done
  top="$(git rev-parse --show-toplevel)" && top="$(cd "$top" && pwd -P)" || exit 1
  root="$(pwd -P)"
  case "$root/" in "$top"/*) ;; *) echo "refused: $root is not inside $top" >&2; exit 1 ;; esac
  until [ -f "$root/ak.tracker.yaml" ]; do
    if [ "$root" = "$top" ] || [ "$root" = / ]; then
      echo "refused: no ak.tracker.yaml at or above $(pwd -P) inside $top" >&2; exit 1
    fi
    root="$(dirname "$root")"
  done
  cd "$root" || exit 1
  [ -f "$token_file" ] || { echo "refused: $token_file is absent" >&2; exit 1; }
  token="$(tr -d '\r' < "$token_file")"
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  [ -n "$token" ] || { echo "refused: $token_file is blank" >&2; exit 1; }
  case "$token" in *[[:space:]]*) echo "refused: $token_file holds more than one line or word" >&2; exit 1 ;; esac
  binary="$root/node_modules/.bin/linearis"
  [ -x "$binary" ] || binary="$top/node_modules/.bin/linearis"
  [ -x "$binary" ] || { echo "refused: linearis is not installed in this project" >&2; exit 1; }
  resolved="$(realpath "$binary")" || exit 1
  case "$resolved" in
    "$root/node_modules/"*|"$top/node_modules/"*) ;;
    *) echo "refused: linearis resolves outside this project's dependencies" >&2; exit 1 ;;
  esac
  version="$(NO_UPDATE_NOTIFIER=1 "$binary" --version)" || exit 1
  [ "$version" = "2026.8.0" ] || { echo "refused: linearis $version installed, 2026.8.0 required" >&2; exit 1; }
  home="$(mktemp -d)" || exit 1
  trap 'rm -rf "$home"' EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  linearis_rc=0
  output="$(LINEAR_API_TOKEN="$token" HOME="$home" XDG_CONFIG_HOME="$home" NO_UPDATE_NOTIFIER=1 "$binary" <command> 2>"$home/stderr")" || linearis_rc=$?
  errors="$(cat "$home/stderr")"
  [ -z "$errors" ] || printf '%s\n' "$errors" >&2
  if [ "$linearis_rc" -eq 0 ]; then printf '%s\n' "$output"; exit 0; fi
  printf '%s\n' "$output" >&2
  case "$output$errors" in
    *AUTHENTICATION_REQUIRED*|*'Authentication required, not authenticated'*|*'No API token found'*) exit 42 ;;
  esac
  exit "$linearis_rc"
)
```

Each line is load-bearing:

- **The subshell** makes every `exit` a refusal of this call, not of the operator's shell, and
  scopes the `unset` and the `trap`.
- **`GIT_*` is unset first.** A git hook, or anything else that sets `GIT_DIR` or `GIT_WORK_TREE`,
  would otherwise make `--show-toplevel` name another repository; `ak tracker check` strips the same
  variables.
- **`cd` to the binding root, or stop.** The working directory must be inside the top level, both
  resolved with `pwd -P`, and the upward search stops at the top level or at `/`, whichever comes
  first — it cannot walk past either. The token file and the binary are the project's only when
  resolved from that root.
- **The binary is resolved by path and checked with `realpath`.** A same-named global command on
  `PATH`, or a symlink from the project's `.bin` to a global executable, cannot satisfy the guard.
- **The token is read once**, with CR and surrounding whitespace stripped, so a file saved on
  Windows or ending in a blank line is neither a different token nor a blank one passed through. A
  file holding whitespace *inside* the token — two lines, two words — is refused rather than
  passed on to be rejected by Linear as a bad token.
- **The temporary home is removed on any exit** by the `EXIT` trap. The signal traps turn a hangup,
  an interrupt or a termination into an ordinary `exit`, because some shells (dash among them) skip
  the `EXIT` trap when a signal kills the shell outright. A repository whose top level is `/` is
  refused by the prefix check; bind a project that lives below it.
- **A prefix assignment, not `env`.** `env LINEAR_API_TOKEN=… cmd` puts the token in `env`'s own
  arguments, which the process list shows to every user of the machine; a prefix assignment sets it
  in the child's environment only. linearis's `--api-token` is never used for the same reason.
- **`HOME` and `XDG_CONFIG_HOME` point at an empty directory.** linearis's global stores live
  under them, so with nothing there to read, no path through its resolution order reaches the
  operator's global login — even if the token check above were bypassed.
- **stdout remains result JSON.** The temporary home's `stderr` file keeps warnings out of a
  successful response. On failure the guard prints both streams to stderr and maps the observed
  authentication messages to exit `42`; other exit codes pass through. `linearis_rc` also works in
  zsh, where `status` is read-only.

**Preflight, before every call.** The operation refuses — and linearis is not started — unless all
of these hold. The guarded form performs the first three; the fourth is checked once per session:

1. An `ak.tracker.yaml` exists at or above the working directory, inside the repository.
2. `token_file` exists and contains a non-whitespace character.
3. The resolved project-local linearis path prints exactly `2026.8.0`, the version every behavior in
   this document was read from. Any other installed version refuses, newer included: nothing here
   is known to hold for it.
4. `node --version` is `v22` or later.

The token check and the empty home are what keep the call in this project. linearis resolves a
token in this order:
`--api-token`, then `LINEAR_API_TOKEN`, then its encrypted store, then the deprecated
`~/.linear_api_token` (`README.md`, `USAGE.md`). The store is `~/.linearis/token`, or on Linux
under `$XDG_CONFIG_HOME/linearis/` (`dist/common/token-storage.js`) — the operator's global login,
which may belong to another workspace entirely. The environment check in `dist/common/auth.js` is a
truthiness test, so an **empty** `LINEAR_API_TOKEN` is treated as absent and resolution moves on to
the global store. A blank token file is therefore refused exactly as a missing one is, and the
empty home makes the global store unreachable anyway.

**Verified offline at `2026.8.0`** by `research/probes/linearis-guard.sh`, which extracts the
guarded form above from this file, runs it under `sh` and `zsh` where available, installs the package exactly into a scratch project and routes
every request to a dead proxy (with `NODE_USE_ENV_PROXY=1`, without which Node's `fetch` ignores
the proxy variables and the request reaches Linear), so no call can reach Linear:

| Run | Result |
|---|---|
| Guarded form, `token_file` absent, called from a subdirectory | Refused by the guard, exit `1`; no temporary home made, so linearis was never reached |
| Guarded form, `token_file` blank (`" \r\n\t"`) | Refused, exit `1` |
| Guarded form, `token_file` holding two lines | Refused, exit `1` |
| Guarded form, caller's `GIT_DIR` and `GIT_WORK_TREE` naming another repository | The binding in the working directory's repository is the one found |
| Guarded form, no `ak.tracker.yaml` up to the top level, one in the repository's parent | Refused at the top level; the parent's binding is not reached |
| linearis, `LINEAR_API_TOKEN=""`, `HOME` and `XDG_CONFIG_HOME` empty | `{"error":"No API token found. …"}`, exit `1` |
| Control: linearis, `LINEAR_API_TOKEN=""`, `HOME` holding a `~/.linear_api_token` | Warned that `~/.linear_api_token` is deprecated and used it: the global fallback is real |
| Guarded form, padded project token, operator `HOME` holding that global token | No deprecation warning; the request stopped at the proxy (`fetch failed`), so the project token was the one sent |
| Every guarded run | The temporary home is gone afterwards |
| Negative control: `npm exec --no` in another project with linearis only on `PATH` | Prints `2026.8.0`; this is why the guard invokes a checked project path |
| Guarded success under zsh with a fake local linearis | Result JSON only on stdout, exit `0` |
| Guarded auth rejection under zsh with a fake local linearis | Rejection on stderr, exit `42` |

Removing the `GIT_*` unset, the `trap` or the inner-whitespace refusal from the form above turns the
matching row red; the probe was run that way once to confirm it can fail.

**Exit codes** (`README.md`, "Exit codes"; `dist/common/errors.js`):

| Exit | Meaning | Result |
|---|---|---|
| `0` | Result JSON on stdout | The operation's result |
| `42` | The guard recognized an authentication rejection in linearis's output | Refusal, `needs-input`: the operator replaces the token. Never retried, never a fall to the knowledgebase (CONTRACT §5) |
| `2` | Invalid invocation, with a usage envelope | `failed`: the mapping in §5 is wrong for this version. Not retried with guessed flags |
| `1` | Application error: not found, API rejection | `failed`, with linearis's message |

`README.md` lists a rejected token under `42`, but at `2026.8.0` the observed Linear rejection
is exit `1` with `{"error":"Authentication required, not authenticated"}`. The guard classifies
that message and exits `42`; other exit-`1` errors remain `failed`.

---

## 4. Setup, when a human asks for it

Setup is not a skill (CONTRACT §5). When a human asks to bind this project to Linear, the agent
performs these steps in order and stops at the first that fails:

1. **Detect the package manager** from the lockfile, per §2.
2. **Install** `linearis@2026.8.0` as an exact dev dependency with that manager.
3. **Verify Node** is `>= 22`.
4. **Have the human supply the token.** The human writes it into the token file themselves — for
   example with an editor, or by pasting at a prompt that does not echo — and says when it is done.
   The agent never asks for the token in the conversation, never prints the file, and never runs
   `linearis auth login`, whose store is the global one §3 exists to avoid.
5. **Write the binding**, `ak.tracker.yaml`, with the team and optional project the human names.
6. **Gitignore the secret**: add the token file's path to the project's `.gitignore` and commit
   that rule, since an uncommitted rule protects only this checkout. Then confirm with
   `ak tracker check`, or where `ak` is not on hand with the plain-git checks in
   [the tracker-of-record reference](../../../references/tracker-of-record/REFERENCE.md).
   A token file already tracked or found in history stops setup, and the human is told to rotate
   the token: untracking it does not remove it from history.
7. **Verify with a read-only call**, `teams read <team>`, through the guarded form in §3. Exit `0` with the
   team's JSON confirms the token, the tool and the team key together; exit `42` returns to step 4.

---

## 5. Operation mapping

Commands are as `linearis usage` and `linearis issues usage` print them at `2026.8.0`. The scope
flags `--team` and, where set, `--project` come from the binding's `defaults` and are passed to
**`issues create` and `issues list` only** (CONTRACT §5 rule 5). **`issues update` never passes
`--team` or `--project`**: on `update` they are not a filter but a change, and they would move the
issue to that team or project.
Issues are identified by UUID or `ABC-123`, and an issue's permalink is the `url` field of any read
(`USAGE.md`).

| Operation | Command | Native? |
|---|---|---|
| `createTicket` | `issues create <title> --team <team> [--project <project>] [--description <text>] [--status <status>]` | Yes |
| `linkRecord` | `attachments create <issue> --url <url> --title <title>` | Yes. Documented as idempotent: the same URL on the same issue updates the existing attachment |
| `addBlockingEdge` | `issues update <blocked> --blocked-by <blocker>`, or `issues relations add <blocker> --blocks <blocked>` | Yes |
| `claimTicket` | `issues read <issue>`, then `issues update <issue> --assignee <user>` | Yes, as assignment. `<user>` accepts `me` |
| `updateStatus` | `issues update <issue> --status <status>`, with `<status>` taken from the binding's `statuses`; the resolution text as `issues discuss <issue> --body <text>` | Yes |
| `readTickets` | `issues list --team <team> [--project <project>] [--state-type <type>] [--has-blockers] [--unassigned] [--limit <n>] [--after <cursor>]`, and `issues relations list <issue>` for edges | Yes |

**Unconfirmed at `2026.8.0`** — not stated by the documents, and not observable without a Linear
workspace and token, so no rule here depends on them:

- **Output field names.** Which JSON fields carry an issue's identifier, assignee, workflow state,
  relations and last-updated time. `readTickets` must return a revision, and `claimTicket` must see
  an existing assignee to refuse; both read those fields, and their names are taken from a real
  response at setup rather than assumed here.
- **Replay safety of `createTicket`.** linearis documents no client-supplied idempotency key for
  `issues create`. Runner §5 requires a write's key to be read back; carrying the key in the
  description would work only if `issues search` matches description text, which `USAGE.md` calls
  "full-text search" without saying which fields it covers. Until that is confirmed, a create whose
  outcome is unknown is not replayed.
- **Exit codes beyond `0`, `1`, `2` and `42`.** None is documented; any other is `failed`.
- **Whether a rejected status transition** exits `1` or something else, and with what message.

**Known limitation: live round-trip unverified at `2026.8.0`.** No run of `list`, `create`,
`update` or `discuss` against a real Linear workspace backs this document; the offline table in §3
is the whole of what was executed. In particular, that `issues update` without scope flags leaves an
issue in its team and project is what `USAGE.md` states, not something observed.

# Tracker of record

What an agent needs, inside an installed plugin, to decide which ticket system a project uses and to
reach it without leaking or borrowing a credential. The contract this condenses is
[`adapters/tracker/CONTRACT.md`](../../adapters/tracker/CONTRACT.md), which does not ship with the plugin; the rules below are that
contract's §2 and §5 and the `linear-linearis` binding's setup and invocation, restated so the
plugin carries them (ruling `tracker-of-record-falls-back-to-kb`). `wayfind` loads it before its
first ticket operation.

## Which system is the record

Configuration decides, never reachability. Two inputs: the project record's
`tracker_policy.system_of_record.system` says *which* system; the project folder's
`ak.tracker.yaml` says *how this checkout reaches it*. The binding's backend states the system it
reaches (`linear-linearis` reaches `linear`), and that id is compared with the record's **exactly**
— no case folding, no aliases. `knowledgebase` is reserved for the knowledgebase's own `ticket`
records.

1. **The folder binds a backend** and the record names the system it reaches, or there is no
   record: that backend is the system of record. A record naming any other system, the
   knowledgebase included, refuses every operation.
2. **No binding**, and the record names `knowledgebase` or there is no record: the knowledgebase's
   `ticket` records, through its adapter.
3. **Otherwise every operation refuses** with `needs-input`: no binding while the record names an
   external system, or no binding and no knowledgebase.

It never ends in a scratch file, a `tickets/` directory or any other record in the working
repository. A bound backend that is unreachable is `failed`; one that rejects the credential is
`needs-input`. Neither drops to step 2.

**The project folder** is the nearest directory at or above the working directory holding
`ak.tracker.yaml`, searching no higher than `git rev-parse --show-toplevel`. None there: unbound.

## Rules every binding obeys

1. **The tool is project-local**: a pinned dependency of the project, invoked from its own
   dependency tree. Never a global install, never a same-named tool on `PATH`.
2. **The credential is project-local**: read from `token_file` for each call and passed as a prefix
   assignment in the call's environment. Never on a command line, `env`'s included.
3. **No fallback to a global credential.** `token_file` absent or blank refuses before the tool
   runs. Where the tool reads a global store under the home directory, the call points `HOME`
   (and `XDG_CONFIG_HOME`) at an empty directory.
4. **A rejected credential is `needs-input`**, never retried and never a fall to the knowledgebase.
5. **Scope flags create and list, never update.** Creating and listing pass the binding's
   `defaults`; an operation on an existing ticket never does, because a scope on an update moves
   the ticket. A status `statuses` does not map is refused, not guessed.
6. **Nothing token-bearing is committed, printed or echoed.** `ak.tracker.yaml` is committed and
   holds no secret; `token_file` is gitignored by a `.gitignore` in the project.

## Setting up `linear-linearis`, when a human asks

Setup is an operator task, not a skill. Stop at the first step that fails.

1. Detect the package manager from the root lockfile; no `package.json`, or two lockfiles, stops
   and asks the human.
2. Install `linearis@2026.8.0` as an exact dev dependency (`npm install --save-dev --save-exact`,
   `pnpm add --save-dev --save-exact`, `yarn add --dev --exact`, `bun add --dev --exact`).
3. Check `node --version` is `v22` or later.
4. The human writes the token into the token file themselves and says when. Never ask for it in
   the conversation, never print the file, never run `linearis auth login`.
5. Write `ak.tracker.yaml`: `backend: linear-linearis`, `token_file`, `defaults.team` (required),
   `defaults.project` (optional), `statuses` in the team's own names.
6. Gitignore the token file in the project's `.gitignore` and commit that rule, then run the check
   below: an uncommitted rule protects only this checkout. A token file
   that is tracked or in history stops setup: tell the human to rotate the token.
7. Verify with `teams read <team>` through the guarded call. Exit `42` goes back to step 4.

## The guarded call

`$token_file` is the binding's `token_file`; replace `<command>` with the linearis command.

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

The `realpath` check refuses a global command on `PATH` and symlinks that escape the project's
dependency tree. The guard keeps stderr warnings out of successful result JSON, and `linearis_rc`
works in zsh, whose `status` parameter is read-only. Exit `0` is the result JSON. The guard maps linearis's authentication rejection, including its
observed exit-`1` message, to `42`: `needs-input`. Exit `2` is a wrong invocation, `failed` and
not retried with guessed flags. Other exit-`1` application errors are `failed`.

| Operation | linearis command |
|---|---|
| create | `issues create <title> --team <team> [--project <project>] [--description <text>] [--status <status>]` |
| link a record | `attachments create <issue> --url <url> --title <title>` |
| blocking edge | `issues relations add <blocker> --blocks <blocked>` |
| claim | `issues read <issue>`, then `issues update <issue> --assignee me` if unassigned |
| update status | `issues update <issue> --status <mapped status>`; resolution via `issues discuss <issue> --body <text>` |
| read | `issues list --team <team> [--project <project>] …`; `issues relations list <issue>` |

`issues update` never carries `--team` or `--project`. A create whose outcome is unknown is not
replayed: linearis offers no idempotency key. Live round-trips against Linear are unverified at
`2026.8.0`.

## Checking the secret with plain git

Where `ak tracker check` is not on hand, from the project folder, with `$f` the token file:

```sh
printf './%s\0' "$f" | git check-ignore -q -z --stdin --no-index     # exit 0: ignored
printf './%s\0' "$f" | git check-ignore -v -z --stdin --no-index | tr '\0' '\n'
#   source, line, pattern, path: the source must be a .gitignore in the repository, and a
#   pattern starting with ! un-ignores the file, so it does not count. The ./ prefix matters:
#   stdin paths are still pathspecs, and ':(top)x' would otherwise be checked as 'x'.
tmp=$(mktemp -d) && git clone -q --template= . "$tmp" && git -C "$tmp" -c core.excludesFile=/dev/null check-ignore -q --no-index "./$f"
#   exit 0: the committed rules ignore it. A clone checks out the committed branch head, so a
#   rule that is only in the working tree or only staged does not count. Run from the repository
#   top, or prefix $f with the project folder's path from it; then rm -rf "$tmp".
git --literal-pathspecs ls-files --error-unmatch -- "$f"            # exit 0: tracked, refuse
git --literal-pathspecs log --all --full-history --format=%h -1 -- "$f"   # any output: in history, rotate
```

`--all` covers every commit reachable from a ref, not unreachable objects. The token file must be
readable by its owner only (no group or other bits; `chmod 600` sets that), as checked by both
`ak tracker check` and `ak doctor`.

#!/usr/bin/env bash
# fm-claims.sh - check the claims a mate makes in its own status log against
# independent sources and record each verdict in the task's claim ledger.
#
# Usage:
#   fm-claims.sh scan <task-id>...
#   fm-claims.sh scan --all
#
# docs/claim-ledger.md owns the ledger and failure-class record formats, the
# claim kinds, and what each verdict means. This header owns the commands,
# the extraction and check rules, and the tunables.
#
# scan reads state/<task>.status and state/<task>.meta, extracts claims, judges
# each claim that is due, and appends one record per verdict to
# state/<task>.claims.jsonl. --all scans every task that has a .meta record.
# It prints one line per recorded verdict:
#   <task> <claim-id> <kind> <verdict> line=<n>: <reason>
# and exits 3 when it recorded at least one refuted verdict, else 0; exit 3 is
# a result to act on, not an error. A refusal on any task (exit 1) outranks 3.
# A claim id hashes the task id, the status log's first line (a relaunch keeps
# the log, while a reused task id starts a fresh one), the line number, the
# line bytes and the kind. A claim is due when it has no record yet, or when its newest record is
# unverifiable, has fewer than FM_CLAIMS_MAX_ATTEMPTS attempts, and is at least
# FM_CLAIMS_RETRY_SECS old. tests-green, pr-ready and order are due only while
# their line is the newest line carrying that kind. alive is judged on every
# scan while its line is the newest mate line, and gains a record only when
# its verdict changes.
#
# Extraction reads only the task's own status log, never chat or terminal text.
# Mate lines are working:, paused:, done:, blocked: and needs-decision: lines
# other than the verifier's own claim-refuted- blockers; the newest of them is
# the newest mate line. Claims come from working:, paused: and done: lines:
#   ship done: reporting the no-mistakes CI-ready PR  -> pushed pr-ready tests-green order
#   ship done: reporting a published Gerrit change    -> pushed order
#   other ship done: in no-mistakes mode (the handoff) -> committed
#   ship done: in direct-PR mode -> pushed order, plus pr-ready when it names a PR
#   ship done: in local-only mode -> committed order
#   a done: line from a scout, or at or below the meta's promoted_status_lines
#   (written while the task was a scout), yields no claim of any kind
#   free text with no hedge word (not, never, will, before, until, unless,
#   once, if, pending, waiting, n't, ...):
#     "committed <sha>" or "committed as <sha>" -> committed;
#     "pushed", not "pushed back/on/off/through/along/ahead/for/forward", with
#       a git cue (a sha after "pushed" or "committed", the task branch, or
#       origin, branch, remote or upstream within 40 characters after
#       "pushed") -> pushed, with the sha after "pushed", else after
#       "committed";
#     test, tests, checks or CI, then up to three of are, is, all, now, have,
#       has, both, fully, still, again, ci, checks, tests, suite, unit,
#       integration, e2e, required, then pass, passed, passes, green, or
#       "are/is passing", with no failure or intent word (fail, red, broken,
#       flaky, but, except, no, locally, make, get, fix, try, so, main,
#       master, ...) -> tests-green;
#     a PR URL with "opened" or "created" -> pr-opened, with "ready" -> pr-ready
#   A sha is the next word after edge punctuation is trimmed: 7 to 40 hex
#   characters holding a digit and a letter, and not 16 long (a claim id).
#   the newest mate line, when it is working: or paused: -> alive
#
# Checks. Every network read is bounded by FM_CLAIMS_NET_TIMEOUT seconds, runs
# with prompts disabled, and yields unverifiable when it times out or fails.
# Each remote branch head is read at most once per task per scan.
#   committed   git in the local copy, or in the project clone once the copy is
#               gone: the named commit (HEAD for a done:) exists and is on the
#               task branch (a named commit that exists off the branch is
#               unverifiable: history may have been rewritten); for free text
#               the commit is not already in the base branch, else (or when
#               the base cannot be read) unverifiable; for a done: the
#               branch carries a commit of its own and, while the line is the
#               newest mate line, the local copy is clean.
#   pushed      the claimed commit is the named sha, else the branch head at
#               the line's [at=] stamp from the branch reflog; a done: line
#               falls back to HEAD, any other line is unverifiable. The remote
#               branch head (gh api on GitHub, git ls-remote elsewhere) must
#               contain it, by local ancestry or the GitHub compare API: a
#               remote behind the commit, or without it, refutes; diverged is
#               unverifiable. A GitHub 404 counts as no branch only when the
#               repository itself reads; when the branch is gone and the
#               task's PR merged, the PR head stands in, and when a PR named by
#               the claim or recorded for the task cannot be read as merged or
#               not merged, the claim is unverifiable. A free-text claim
#               that origin does not carry is unverifiable rather than refuted
#               unless its note names origin, when it names another remote,
#               the no-mistakes gate, Gerrit or refs/for, or the task delivers
#               through no-mistakes or a review server. For a ship done: the
#               custody gate fm_dod_accept_ship_done (bin/fm-dod-lib.sh) runs
#               too: it alone decides a published Gerrit change or an external
#               review; only a named Gerrit change it accepts verifies,
#               because no other review server is read, and elsewhere it never
#               verifies by itself. The custody gate reads the line's first
#               4096 bytes.
#   pr-opened   gh pr view: the PR exists and is the task's PR.
#   pr-ready    gh pr view: the task's PR, open or merged, not a draft, and in
#               direct-PR mode its head contains the branch head at the line's
#               [at=] stamp (a done: falls back to HEAD): a PR head behind it
#               refutes, and an unreadable or diverged one is unverifiable.
#               A PR is the task's PR when it is the recorded pr=, or its head
#               branch is the task branch and it is on the recorded PR's
#               repository, else on origin's when origin is on GitHub. A
#               missing PR refutes; another PR refutes a done: claim and leaves
#               a free-text claim unverifiable; with neither reference to
#               compare, the claim is unverifiable.
#   tests-green gh pr checks for the claimed PR when it is the task's (a named
#               PR that is not is unverifiable), else the recorded PR (any
#               failed or cancelled check refutes, all passed or skipped
#               verifies); else the task branch's no-mistakes run
#               (bin/fm-nm-run-lib.sh) at HEAD: passed or passed-with-skips
#               with a completed test or ci step verifies, a failed test or ci
#               step refutes, passed-with-override never verifies; else a
#               current AgentKit verify gate at HEAD verifies. A free-text
#               claim is judged at the branch head at its [at=] stamp instead
#               of HEAD (unreadable is unverifiable). PR checks count only
#               while the PR is at the claim's head. Failed checks or a failed
#               ci step refute free text only when it names CI, checks or a PR
#               URL.
#   order       rules recognized in data/<task>/brief.md, each checked against
#               the task's actions. A prohibition rule is recognized only when
#               never, not, no or don't comes before its phrase on the same
#               line, in the same sentence:
#                 ship-branch ("ship branch"): the local copy is on the task branch;
#                 clean-worktree ("worktree clean"): no uncommitted change, judged
#                   only while the line is the newest mate line;
#                 commit-nothing-after-run ("commit nothing after", no-mistakes
#                   mode): fm_dod_nm_custody_returned, or no commit on HEAD
#                   beyond the run's head;
#                 no-default-push ("push to the default branch"): when HEAD
#                   carries a commit of the task's own (a commit-family entry
#                   in the branch reflog, else any commit beyond the base) and
#                   no PR named by the done: or recorded for the task is merged,
#                   the remote default branch does not contain HEAD; a default
#                   branch that contains HEAD is unverifiable while such a PR
#                   cannot be read;
#                 no-version-bump ("bump a version"): no version field or
#                   VERSION file changed between the base and HEAD.
#               Any refuted rule refutes. Otherwise the claim is verified only
#               with a current AgentKit verify gate at HEAD, for everything the
#               rules cannot read.
#   alive       a dead agent endpoint refutes; an unread steering message older
#               than FM_CLAIMS_STEER_GRACE_SECS refutes. For working:, terminal
#               output newer than FM_CLAIMS_OUTPUT_FRESH_SECS (the monitor's
#               per-window output marker, read only while the monitor's beat
#               state/.last-watcher-beat is that fresh, the window's poll
#               count state/.count-<window> is within fm_poll_derived_grace,
#               and never for a second mate) or at least FM_CLAIMS_CPU_ACTIVE_PCT CPU across processes
#               whose working directory is in the local copy (an absolute,
#               existing directory) verifies, and both measured stale and idle
#               refutes. For paused:, a live endpoint or a process in the copy
#               verifies. A verified alive closes every open blocker of an
#               alive claim, with the claim-refuted-cleared note and
#               via=fm-claims-scan.
# The AgentKit gate is `node <ak-gate.mjs> check --gates verify --json
# --project <local copy>`; it is current when it answers ok at HEAD with no
# notes (a marker-only record carries a note and never counts).
#
# A refuted verdict, after its ledger record, appends the reopening blocker to
# the status log, then a failure-class occurrence to
# data/failure-classes/claim-refuted-<kind>.jsonl. Both use the words in
# bin/fm-claims-lib.sh. Both are skipped when the claim's blocker is still open
# (an alive claim can be refuted again). The blocker is skipped when the log is
# gone or a mate done: line arrived during the scan. A failed blocker
# append withholds the occurrence and fails the scan; every scan first
# finishes each refuted claim that has no occurrence yet. Every append starts
# on a fresh line.
#
# fm-send --resolve-key claim-refuted-<claim-id> is the operator close of a
# blocker. The refuted verdict stays.
#
# Refuses (exit 1) without jq, on a task id that is not path safe
# (fm_task_id_path_safe), a named task with neither status log nor metadata,
# a symlinked status, meta, ledger, or failure-class file, a malformed
# tunable, or a per-task lock (state/.claims-<task>.lock) that stays held. An
# unknown subcommand or argument prints this usage and exits 2.
#
# Environment: FM_HOME selects the home; FM_STATE_OVERRIDE, FM_DATA_OVERRIDE
# and FM_CONFIG_OVERRIDE override its directories. Tunables and defaults:
# FM_CLAIMS_NET_TIMEOUT 20, FM_CLAIMS_MAX_ATTEMPTS 3, FM_CLAIMS_RETRY_SECS 300,
# FM_CLAIMS_OUTPUT_FRESH_SECS 900, FM_CLAIMS_CPU_ACTIVE_PCT 1.0,
# FM_CLAIMS_STEER_GRACE_SECS 900. The AgentKit gate script is the absolute
# path in FM_CLAIMS_AK_GATE, else the first line of config/agentkit-gate;
# with neither, the AgentKit check cannot verify anything. FM_CLAIMS_NOW
# overrides the current epoch (tests only).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-claims: %s\n' "$*" >&2
  exit 1
}

cl_uint() {  # <value>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

NET_TIMEOUT=${FM_CLAIMS_NET_TIMEOUT:-20}
MAX_ATTEMPTS=${FM_CLAIMS_MAX_ATTEMPTS:-3}
RETRY_SECS=${FM_CLAIMS_RETRY_SECS:-300}
OUTPUT_FRESH_SECS=${FM_CLAIMS_OUTPUT_FRESH_SECS:-900}
CPU_ACTIVE_PCT=${FM_CLAIMS_CPU_ACTIVE_PCT:-1.0}
STEER_GRACE_SECS=${FM_CLAIMS_STEER_GRACE_SECS:-900}
cl_uint "$NET_TIMEOUT" && [ "$NET_TIMEOUT" -gt 0 ] || die "FM_CLAIMS_NET_TIMEOUT must be a positive whole number of seconds"
cl_uint "$MAX_ATTEMPTS" && [ "$MAX_ATTEMPTS" -gt 0 ] || die "FM_CLAIMS_MAX_ATTEMPTS must be a positive whole number"
cl_uint "$RETRY_SECS" || die "FM_CLAIMS_RETRY_SECS must be a whole number of seconds"
cl_uint "$OUTPUT_FRESH_SECS" || die "FM_CLAIMS_OUTPUT_FRESH_SECS must be a whole number of seconds"
cl_uint "$STEER_GRACE_SECS" || die "FM_CLAIMS_STEER_GRACE_SECS must be a whole number of seconds"
[[ $CPU_ACTIVE_PCT =~ ^[0-9]+([.][0-9]+)?$ ]] || die "FM_CLAIMS_CPU_ACTIVE_PCT must be a non-negative number"
NOW=${FM_CLAIMS_NOW:-$(date +%s)}
cl_uint "$NOW" || die "FM_CLAIMS_NOW must be a whole epoch"

# Pending replies load the backend, marker, classifier, and timeout helpers.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-claims-lib.sh
. "$SCRIPT_DIR/fm-claims-lib.sh"

export GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 GH_NO_UPDATE_NOTIFIER=1

CL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-claims.XXXXXX") || die "cannot create a temporary directory"
CL_LOCK=
cl_cleanup() {
  [ -z "$CL_LOCK" ] || fm_lock_release "$CL_LOCK" || true
  rm -rf "$CL_TMP"
}
trap cl_cleanup EXIT

# jq helpers for every record: null for an empty value, and the one-line,
# secret-free, bounded form of any text taken from a status line.
CL_JQ_DEFS=$(cat <<'JQ'
def n(x): if x == "" then null else x end;
def clean:
  gsub("[[:cntrl:]]"; " ")
  | gsub("gh[pousr]_[A-Za-z0-9]{20,}"; "[redacted]")
  | gsub("github_pat_[A-Za-z0-9_]{20,}"; "[redacted]")
  | gsub("sk-[A-Za-z0-9_-]{16,}"; "[redacted]")
  | gsub("[sr]k_(live|test)_[A-Za-z0-9]{8,}"; "[redacted]")
  | gsub("xox[abposr]-[A-Za-z0-9-]{10,}"; "[redacted]")
  | gsub("(AKIA|ASIA)[0-9A-Z]{16}"; "[redacted]")
  | gsub("AIza[0-9A-Za-z_-]{16,}"; "[redacted]")
  | gsub("glpat-[A-Za-z0-9_-]{8,}"; "[redacted]")
  | gsub("npm_[A-Za-z0-9]{8,}"; "[redacted]")
  | gsub("eyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}(\\.[A-Za-z0-9_-]*)?"; "[redacted]")
  | gsub("(?<h>hooks\\.slack\\.com/services/)\\S+"; "\(.h)[redacted]")
  | gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----.*"; "[redacted]")
  | gsub("(?<k>authorization\\s*[=:]\\s*)((bearer|basic|token)\\s+)?\\S+"; "\(.k)[redacted]"; "i")
  | gsub("(?<k>bearer\\s+)\\S{8,}"; "\(.k)[redacted]"; "i")
  | gsub("(?<k>Basic\\s+)(?=[A-Za-z0-9+/=]*[A-Z0-9=])[A-Za-z0-9+/=]{8,}"; "\(.k)[redacted]")
  | gsub("(?<k>(password|passwd|pwd|secret|token|api[_-]?key|[_-]key)\\s*[=:]\\s*)\\S+"; "\(.k)[redacted]"; "i")
  | gsub("(?<k>(password|passwd|pwd|secret|token|api[_-]?key)\\s+is\\s+)\\S+"; "\(.k)[redacted]"; "i")
  | gsub("(?<k>\\b(password|passwd|pwd|secret|token)\\s+)(\\S{16,}|(?=\\S*[0-9])\\S{6,})"; "\(.k)[redacted]"; "i")
  | gsub("(?<s>://)[^/@\\s]+@"; "\(.s)[redacted]@")
  | if length > 200 then .[0:197] + "..." else . end;
JQ
)

CL_HEDGE_RE="(^|[^[:alnum:]])(not|never|will|won'?t|before|until|unless|once|if|pending|waiting|about to|going to|should|would|could|cannot|tbd|todo)([^[:alnum:]]|$)|n't([^[:alnum:]]|$)"
CL_PUSHED_RE='(^|[^[:alnum:]])pushed([^[:alnum:]]|$)'
CL_PUSH_VOID_RE='(^|[^[:alnum:]])pushed[[:space:]]+(back|on|off|through|along|ahead|for|forward)([^[:alnum:]]|$)'
CL_PUSH_CUE_RE='(^|[^[:alnum:]])pushed[^.;]{0,40}[^[:alnum:]](origin|branch|remote|upstream)([^[:alnum:]]|$)'
CL_TESTS_WORD='(are|is|all|now|have|has|both|fully|still|again|ci|checks|tests|suite|unit|integration|e2e|required)'
CL_TESTS_RE="(^|[^[:alnum:]])(tests?|checks|ci)([[:space:]]+$CL_TESTS_WORD){0,3}[[:space:]]+((pass|passed|passes|green)|(are|is)[[:space:]]+passing)([^[:alnum:]]|$)"
CL_TESTS_CONTRARY_RE='(^|[^[:alnum:]])(fail|fails|failed|failing|failure|failures|red|broken|flaky|except|but|no|locally|make|making|get|getting|fix|fixing|try|trying|so|main|master)([^[:alnum:]]|$)'
CL_CI_SUBJECT_RE='(^|[^[:alnum:]])(ci|checks)([^[:alnum:]]|$)'
CL_OPENED_RE='(^|[^[:alnum:]])(opened|created)([^[:alnum:]]|$)'
CL_READY_RE='(^|[^[:alnum:]])ready([^[:alnum:]]|$)'
CL_PR_URL_RE='https://[^/@[:space:]]+/[^[:space:]]*/(pull|pulls|merge_requests)/[0-9]+'
# A note longer than this is cut before it reaches a record.
CL_NOTE_MAX=2000

cl_net() {  # <command...>
  fm_run_timed "$NET_TIMEOUT" "$@" </dev/null
}

cl_sha256() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# The one-line, secret-free, bounded form of <text>.
cl_clean() {  # <text>
  jq -rn --arg s "$1" "$CL_JQ_DEFS"' $s | clean' 2>/dev/null || printf '%s' "[unreadable]"
}

# Appends a newline when <file> ends inside a line, so the next append starts
# a line of its own.
cl_nl_guard() {  # <file>
  [ -s "$1" ] || return 0
  [ -z "$(tail -c 1 "$1" 2>/dev/null)" ] || printf '\n' >> "$1"
}

# The verdict of the check in progress. Every checker ends by calling this.
# The reason and every observed string are cleaned here, so stdout, the
# blocker, and every record carry only the clean form.
cl_set() {  # <verdict> <checker> <reason> [<observed-key> <value>]...
  CL_VERDICT=$1
  CL_CHECKER=$2
  CL_REASON=$(cl_clean "$3")
  shift 3
  CL_OBSERVED=$(jq -cn "$CL_JQ_DEFS"'$ARGS.positional as $a
    | reduce range(0; $a | length; 2) as $i ({}; .[$a[$i]] = (if $a[$i + 1] == "" then null else ($a[$i + 1] | clean) end))' \
    --args -- "$@") || CL_OBSERVED='{}'
}

# --- task context ------------------------------------------------------------

cl_task_load() {  # <task-id>
  local f
  T_TASK=$1
  if ! fm_task_id_path_safe "$T_TASK"; then
    echo "fm-claims: task id '$T_TASK' must match [A-Za-z0-9._-]+ and not start with a dot" >&2
    return 1
  fi
  T_STATUS="$STATE/$T_TASK.status"
  T_META="$STATE/$T_TASK.meta"
  T_LEDGER="$STATE/$T_TASK.claims.jsonl"
  for f in "$T_STATUS" "$T_META" "$T_LEDGER"; do
    if [ -L "$f" ]; then
      echo "fm-claims: refusing the symlinked $f" >&2
      return 1
    fi
  done
  T_KIND=$(fm_meta_get "$T_META" kind)
  [ ! -f "$T_META" ] || T_KIND=${T_KIND:-ship}
  T_MODE=$(fm_meta_get "$T_META" mode)
  T_BRANCH=$(fm_meta_get "$T_META" branch)
  T_WT=$(fm_meta_get "$T_META" worktree)
  T_PROJECT=$(fm_meta_get "$T_META" project)
  T_PR=$(fm_meta_get "$T_META" pr)
  T_BASE=$(fm_meta_get "$T_META" base_branch)
  T_HARNESS=$(fm_meta_get "$T_META" harness)
  T_MODEL=$(fm_meta_get "$T_META" model)
  T_GEN=$(fm_meta_get "$T_META" spawn_gen)
  T_PROMOTED=$(fm_meta_get "$T_META" promoted_status_lines)
  cl_uint "$T_PROMOTED" || T_PROMOTED=0
  T_FORGE=$(fm_meta_get "$T_META" forge)
  T_BACKEND=$(fm_backend_of_meta "$T_META")
  CL_PRV_URL=
  CL_NM_READ=
  CL_AK_READ=
  CL_RH_CACHE=
  CL_GH_REPO_READ=
}

cl_wt_ok() {
  [ -n "$T_WT" ] && [ -d "$T_WT" ] && git -C "$T_WT" rev-parse --git-dir >/dev/null 2>&1
}

cl_head() {
  git -C "$T_WT" rev-parse --verify -q HEAD 2>/dev/null
}

# The repository to read: the local copy, or the project clone once it is gone.
cl_repo() {
  if cl_wt_ok; then
    printf '%s' "$T_WT"
  elif [ -n "$T_PROJECT" ] && git -C "$T_PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s' "$T_PROJECT"
  else
    return 1
  fi
}

cl_base_ref() {  # <repo>
  local repo=$1 origin_head ref
  if [ -n "$T_BASE" ]; then
    set -- "refs/remotes/origin/$T_BASE" "refs/heads/$T_BASE"
  else
    origin_head=$(git -C "$repo" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || origin_head=
    set -- ${origin_head:+"$origin_head"} refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master
  fi
  for ref in "$@"; do
    if git -C "$repo" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s' "$ref"
      return 0
    fi
  done
  return 1
}

# The task branch as a ref in <repo>: the local branch, else its remote copy.
cl_branch_ref() {  # <repo>
  local ref
  [ -n "$T_BRANCH" ] || return 1
  for ref in "refs/heads/$T_BRANCH" "refs/remotes/origin/$T_BRANCH"; do
    if git -C "$1" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1; then
      printf '%s' "$ref"
      return 0
    fi
  done
  return 1
}

cl_dirty_count() {  # <repo>
  local out
  out=$(git -C "$1" status --porcelain 2>/dev/null) || return 1
  if [ -z "$out" ]; then
    printf 0
  else
    printf '%s\n' "$out" | wc -l | tr -d ' '
  fi
}

# --- forge reads -------------------------------------------------------------

# Sets CL_GH_HOST and CL_GH_SLUG from <repo>'s origin when it is a GitHub host.
cl_github_origin() {  # <repo>
  local url re
  CL_GH_HOST=
  CL_GH_SLUG=
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  url=${url%/}
  url=${url%.git}
  re='^(https://([^/@]+@)?|ssh://git@|git@)([A-Za-z0-9.-]+)(:[0-9]+)?[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$'
  [[ $url =~ $re ]] || return 1
  fm_github_host_allowed "${BASH_REMATCH[3]}" || return 1
  CL_GH_HOST=${BASH_REMATCH[3]}
  CL_GH_SLUG="${BASH_REMATCH[5]}/${BASH_REMATCH[6]}"
}

# gh api read: 0 with stdout, 4 when the forge answers not found, 1 otherwise.
cl_gh_api() {  # <path> <jq-filter>
  local out
  command -v gh >/dev/null 2>&1 || return 1
  if out=$(cl_net gh api --hostname "$CL_GH_HOST" "$1" --jq "$2" 2>"$CL_TMP/err"); then
    printf '%s' "$out"
    return 0
  fi
  grep -q 'HTTP 404' "$CL_TMP/err" 2>/dev/null && return 4
  return 1
}

# 0 when the GitHub repository CL_GH_SLUG itself reads. One read per task.
cl_gh_repo_readable() {
  if [ -z "$CL_GH_REPO_READ" ]; then
    CL_GH_REPO_READ=1
    cl_gh_api "repos/$CL_GH_SLUG" '.full_name' >/dev/null && CL_GH_REPO_READ=0
  fi
  return "$CL_GH_REPO_READ"
}

# Sets CL_RH and CL_RH_SRC: 0 when origin has <branch>, 4 when it has none,
# 1 when the remote could not be read. A GitHub 404 means no branch only when
# the repository itself reads. Each answer is kept for the rest of the task's
# scan.
cl_remote_head() {  # <repo> <branch>
  local key="$1$CL_US$2" row rc
  row=$(printf '%s' "$CL_RH_CACHE" | awk -F"$CL_US" -v r="$1" -v b="$2" '$1 == r && $2 == b { print; exit }')
  if [ -n "$row" ]; then
    IFS=$CL_US read -r _ _ rc CL_RH CL_RH_SRC <<EOF
$row
EOF
    cl_github_origin "$1" || true
    return "$rc"
  fi
  cl_remote_head_read "$1" "$2"
  rc=$?
  CL_RH_CACHE="${CL_RH_CACHE}$key$CL_US$rc$CL_US$CL_RH$CL_US$CL_RH_SRC"$'\n'
  return "$rc"
}

cl_remote_head_read() {  # <repo> <branch>
  local out rc
  CL_RH=
  if cl_github_origin "$1"; then
    CL_RH_SRC=gh-remote-head
    out=$(cl_gh_api "repos/$CL_GH_SLUG/git/ref/heads/$2" 'if type == "object" then .object.sha else "" end')
    rc=$?
    case "$rc" in
      0) ;;
      4) cl_gh_repo_readable && return 4; return 1 ;;
      *) return 1 ;;
    esac
  else
    CL_RH_SRC=git-ls-remote
    out=$(cl_net git -C "$1" ls-remote origin "refs/heads/$2" 2>/dev/null) || return 1
    out=${out%%[[:space:]]*}
  fi
  [ -n "$out" ] || return 4
  fm_pr_head_valid "$out" || return 1
  CL_RH=$out
}

# 0 when <head> contains <commit>; 1 when it does not: <head> is behind the
# commit or the commit is unknown; 3 when the two have diverged (history was
# rewritten); 2 when unknown. Uses local objects first, then the GitHub
# compare API (cl_github_origin first).
cl_contains() {  # <repo> <commit> <head>
  local full rc st
  full=$(git -C "$1" rev-parse --verify -q "$2^{commit}" 2>/dev/null) || full=
  [ -z "$full" ] || [ "$full" != "$3" ] || return 0
  if [ -n "$full" ] && git -C "$1" cat-file -e "$3^{commit}" 2>/dev/null; then
    git -C "$1" merge-base --is-ancestor "$full" "$3" 2>/dev/null
    rc=$?
    case "$rc" in
      0) return 0 ;;
      1)
        git -C "$1" merge-base --is-ancestor "$3" "$full" 2>/dev/null && return 1
        return 3 ;;
    esac
  fi
  [ -n "${CL_GH_SLUG:-}" ] || return 2
  st=$(cl_gh_api "repos/$CL_GH_SLUG/compare/${full:-$2}...$3" '.status')
  rc=$?
  case "$rc" in
    0) ;;
    4) return 1 ;;
    *) return 2 ;;
  esac
  case "$st" in
    ahead|identical) return 0 ;;
    behind) return 1 ;;
    diverged) return 3 ;;
  esac
  return 2
}

# Sets CL_PR_STATE, CL_PR_DRAFT, CL_PR_HEAD, CL_PR_BRANCH for a GitHub PR:
# 0 when read, 4 when the forge has no such PR, 1 otherwise. One read per URL
# per task.
cl_pr_view() {  # <url>
  local out rc=1
  if [ "$CL_PRV_URL" = "$1" ]; then
    return "$CL_PRV_RC"
  fi
  CL_PR_STATE='' CL_PR_DRAFT='' CL_PR_HEAD='' CL_PR_BRANCH=''
  if command -v gh >/dev/null 2>&1; then
    if out=$(cl_net gh pr view "$1" --json state,isDraft,headRefOid,headRefName \
      --jq '[.state, (.isDraft | tostring), .headRefOid, .headRefName] | @tsv' 2>"$CL_TMP/err"); then
      IFS=$'\t' read -r CL_PR_STATE CL_PR_DRAFT CL_PR_HEAD CL_PR_BRANCH <<EOF
$out
EOF
      case "$CL_PR_STATE" in OPEN|CLOSED|MERGED) rc=0 ;; esac
    elif grep -qiE 'could not resolve to a ?pull ?request|HTTP 404' "$CL_TMP/err" 2>/dev/null; then
      rc=4
    fi
  fi
  CL_PRV_URL=$1
  CL_PRV_RC=$rc
  return "$rc"
}

cl_github_pr() {  # <url>
  [ -n "$1" ] && ( fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] )
}

# After cl_pr_view read <url>: 0 when it is the task's PR, 1 when it is not,
# 2 when that cannot be told, with CL_PR_FOREIGN naming why. The recorded pr=
# is the task's PR. Any other PR must be on the task branch and on the
# reference repository: the recorded PR's repository, else origin's when
# origin is on GitHub. With neither reference it cannot be told.
cl_pr_is_task() {  # <url>
  local repo host slug ref_host ref_slug ref_name
  CL_PR_FOREIGN=
  [ -z "$T_PR" ] || [ "$1" != "$T_PR" ] || return 0
  if [ -n "$T_BRANCH" ] && [ "$CL_PR_BRANCH" != "$T_BRANCH" ]; then
    CL_PR_FOREIGN="PR $1 is on branch $CL_PR_BRANCH, not the task branch $T_BRANCH"
    return 1
  fi
  if ! fm_pr_url_parse "$1"; then
    CL_PR_FOREIGN="PR $1 could not be parsed"
    return 2
  fi
  host=$FM_PR_HOST slug="$FM_PR_OWNER/$FM_PR_REPO"
  if [ -n "$T_PR" ] && fm_pr_url_parse "$T_PR"; then
    ref_host=$FM_PR_HOST ref_slug="$FM_PR_OWNER/$FM_PR_REPO" ref_name="the recorded PR's repository"
  elif repo=$(cl_repo) && cl_github_origin "$repo"; then
    ref_host=$CL_GH_HOST ref_slug=$CL_GH_SLUG ref_name="origin's repository"
  else
    CL_PR_FOREIGN="no recorded PR and no GitHub origin show whether PR $1 is the task's"
    return 2
  fi
  if [ "$(printf '%s %s' "$host" "$slug" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s %s' "$ref_host" "$ref_slug" | tr '[:upper:]' '[:lower:]')" ]; then
    CL_PR_FOREIGN="PR $1 is not on $ref_name $ref_slug"
    return 1
  fi
  return 0
}

# 0 when <candidate-url> or the recorded PR reads as the task's merged PR, with
# CL_PR_* holding it; 1 when every such PR read as not merged, or there is none;
# 2 when one could not be read as either, with CL_PR_UNREAD naming it.
cl_task_pr_merged() {  # <candidate-url>
  local url rc=1
  CL_PR_UNREAD=
  for url in "$1" "$T_PR"; do
    [ -n "$url" ] || continue
    if cl_github_pr "$url"; then
      cl_pr_view "$url"
      case "$?" in
        0) ;;
        4) continue ;;
        *) rc=2 CL_PR_UNREAD=$url; continue ;;
      esac
      cl_pr_is_task "$url"
      case "$?" in
        0) [ "$CL_PR_STATE" != MERGED ] || return 0 ;;
        2) rc=2 CL_PR_UNREAD=$url ;;
      esac
    else
      rc=2 CL_PR_UNREAD=$url
    fi
  done
  return "$rc"
}

# --- no-mistakes and AgentKit reads -------------------------------------------

# 0 when the task branch's no-mistakes run was read into CL_NM_OUT. One read
# per task.
cl_nm_read() {
  local branch
  if [ -z "$CL_NM_READ" ]; then
    CL_NM_READ=no
    CL_NM_OUT=
    if command -v no-mistakes >/dev/null 2>&1 && cl_wt_ok \
      && CL_NM_OUT=$(fm_nm_run_checked "$T_WT" "$NET_TIMEOUT" axi status </dev/null) \
      && printf '%s\n' "$CL_NM_OUT" | grep -q '^run:'; then
      branch=$(fm_nm_strip_quotes "$(fm_nm_field "$CL_NM_OUT" branch)")
      if [ -z "$T_BRANCH" ] || [ "$branch" = "$T_BRANCH" ]; then
        CL_NM_READ=yes
      fi
    fi
  fi
  [ "$CL_NM_READ" = yes ]
}

# The status of <step> in the read run's steps table, or empty.
cl_nm_step() {  # <step>
  paste -d "$CL_US" <(fm_nm_table_column "$CL_NM_OUT" steps step) <(fm_nm_table_column "$CL_NM_OUT" steps status) \
    | awk -F"$CL_US" -v s="$1" '$1 == s { print $2; exit }'
}

cl_nm_head() {
  local head
  head=$(fm_nm_branch_sync_nested "$CL_NM_OUT" pipeline current_head)
  [ -n "$head" ] || head=$(fm_nm_strip_quotes "$(fm_nm_field "$CL_NM_OUT" head_sha)")
  [ -n "$head" ] || head=$(fm_nm_strip_quotes "$(fm_nm_field "$CL_NM_OUT" head)")
  printf '%s' "$head"
}

cl_ak_gate() {
  local path=${FM_CLAIMS_AK_GATE:-} file="$CONFIG/agentkit-gate"
  if [ -z "$path" ] && [ -f "$file" ] && [ ! -L "$file" ]; then
    IFS= read -r path < "$file" || true
  fi
  path=$(fm_nm_trim "$path")
  case "$path" in /*) ;; *) return 1 ;; esac
  [ -f "$path" ] || return 1
  printf '%s' "$path"
}

# 0 when the AgentKit verify gate is current at HEAD with no notes, 1 when it
# answered and is not, 2 when it could not answer. A note marks evidence the
# gate itself does not count as proof, such as a marker-only record.
# CL_AK_NOTE explains. One read per task.
cl_ak_verify() {
  local gate out ok rev head notes
  if [ -n "$CL_AK_READ" ]; then
    return "$CL_AK_READ"
  fi
  CL_AK_READ=2
  if ! gate=$(cl_ak_gate); then
    CL_AK_NOTE="no AgentKit gate is configured"
  elif ! command -v node >/dev/null 2>&1; then
    CL_AK_NOTE="node is not installed, so the AgentKit gate cannot run"
  elif ! cl_wt_ok || ! head=$(cl_head); then
    CL_AK_NOTE="the local copy is gone, so the AgentKit gate cannot run"
  else
    out=$(cl_net node "$gate" check --gates verify --json --project "$T_WT" 2>/dev/null) || true
    ok=$(printf '%s' "$out" | jq -r 'if type == "object" and (.ok | type) == "boolean" then (.ok | tostring) else "" end' 2>/dev/null) || ok=
    rev=$(printf '%s' "$out" | jq -r '.head.revision // "" | strings' 2>/dev/null) || rev=
    notes=$(printf '%s' "$out" | jq -r 'if (.notes // null) == null or .notes == [] or .notes == "" then "" else "notes" end' 2>/dev/null) || notes=notes
    if [ "$ok" = true ] && [ "$rev" = "$head" ] && [ -n "$notes" ]; then
      CL_AK_NOTE="AgentKit verify gate at ${head:0:12} carries notes, so it is not proof"
      CL_AK_READ=1
    elif [ "$ok" = true ] && [ "$rev" = "$head" ]; then
      CL_AK_NOTE="AgentKit verify gate is current at ${head:0:12}"
      CL_AK_READ=0
    elif [ "$ok" = true ] || [ "$ok" = false ]; then
      CL_AK_NOTE="AgentKit verify gate is not current at ${head:0:12}"
      CL_AK_READ=1
    else
      CL_AK_NOTE="the AgentKit gate gave no readable answer"
    fi
  fi
  return "$CL_AK_READ"
}

# --- checks ------------------------------------------------------------------

# 0 when HEAD carries a commit the task made on its branch: a commit-family
# entry in the branch reflog that HEAD contains, else any commit beyond the
# base. 1 when it carries none, 2 when neither can be read. A push to the
# default branch by remote name moves the local base ref onto HEAD, so the
# reflog is read first.
cl_head_has_own_commit() {  # <repo> <head>
  local repo=$1 head=$2 log='' s subj base ahead
  [ -z "$T_BRANCH" ] || log=$(git -C "$repo" log -g --format="%H$CL_US%gs" "refs/heads/$T_BRANCH" 2>/dev/null) || log=
  while IFS=$CL_US read -r s subj; do
    case "$subj" in
      commit:*|'commit ('*|cherry-pick:*)
        git -C "$repo" merge-base --is-ancestor "$s" "$head" 2>/dev/null && return 0 ;;
    esac
  done <<EOF
$log
EOF
  if base=$(cl_base_ref "$repo") && ahead=$(git -C "$repo" rev-list --count "$base..$head" 2>/dev/null); then
    [ "$ahead" = 0 ] && return 1
    return 0
  fi
  [ -n "$log" ] && return 1
  return 2
}

# The task branch's head at <line>'s [at=] stamp, from the branch reflog.
cl_claim_head() {  # <repo> <line>
  local at head
  [ -n "$T_BRANCH" ] || return 1
  at=$(status_line_at_epoch "$2") || return 1
  cl_uint "$at" || return 1
  head=$(git -C "$1" log -g --date=unix --format='%H %gd' "refs/heads/$T_BRANCH" 2>/dev/null \
    | awk -v at="$at" '{ s = $2; sub(/.*@\{/, "", s); sub(/\}$/, "", s); if (s ~ /^[0-9]+$/ && s + 0 <= at + 0) { print $1; exit } }')
  fm_pr_head_valid "$head" || return 1
  printf '%s' "$head"
}

cl_check_committed() {  # <sha> <origin> <line-number>
  local sha=$1 origin=$2 ln=$3 repo full bref dirty own base
  if ! repo=$(cl_repo); then
    cl_set unverifiable git-local "the task's local copy and project clone are both unreadable"
    return
  fi
  if [ -n "$sha" ]; then
    if ! full=$(git -C "$repo" rev-parse --verify -q "$sha^{commit}" 2>/dev/null); then
      cl_set refuted git-local "commit $sha does not exist in the task's repository" sha "$sha"
      return
    fi
  elif [ "$repo" = "$T_WT" ] && full=$(cl_head); then
    :
  else
    cl_set unverifiable git-local "the local copy is gone, so the committed head cannot be read"
    return
  fi
  if [ -n "$T_BRANCH" ]; then
    if ! bref=$(cl_branch_ref "$repo"); then
      cl_set unverifiable git-local "the task branch $T_BRANCH is not in the task's repository" sha "$full"
      return
    fi
    if ! git -C "$repo" merge-base --is-ancestor "$full" "$bref" 2>/dev/null; then
      cl_set unverifiable git-local "commit ${full:0:12} exists but is not on the task branch $T_BRANCH; its history may have been rewritten" sha "$full" branch_head "$(git -C "$repo" rev-parse "$bref" 2>/dev/null)"
      return
    fi
  fi
  if [ "$origin" != "done" ]; then
    if ! base=$(cl_base_ref "$repo"); then
      cl_set unverifiable git-local "the base branch could not be read to tell commit ${full:0:12} from base history" sha "$full"
      return
    fi
    if git -C "$repo" merge-base --is-ancestor "$full" "$base" 2>/dev/null; then
      cl_set unverifiable git-local "commit ${full:0:12} is already in the base branch, so it is not shown to be the task's own" sha "$full"
      return
    fi
  fi
  if [ "$origin" = "done" ]; then
    cl_head_has_own_commit "$repo" "$full"
    own=$?
    if [ "$own" = 1 ]; then
      cl_set refuted git-local "the task branch carries no commit of its own beyond its base" sha "$full"
      return
    fi
    if [ "$ln" = "$CL_NEWEST" ] && [ "$repo" = "$T_WT" ] && dirty=$(cl_dirty_count "$repo") && [ "$dirty" != 0 ]; then
      cl_set refuted git-local "the local copy has $dirty uncommitted path(s)" sha "$full" dirty_paths "$dirty"
      return
    fi
  fi
  cl_set verified git-local "commit ${full:0:12} is on ${T_BRANCH:-the local copy}" sha "$full"
}

# 0 when a ship done: is decided by a review server rather than by origin's
# branch: a published Gerrit change or an external review.
cl_review_server_done() {  # <note>
  fm_dod_note_reports_published_change "$1" || fm_dod_note_reports_uploaded_review "$1" \
    || [ "$T_FORGE" = gerrit ] || [ "$T_FORGE" = external ]
}

# 0 when a ship done: names a Gerrit change, the one review server the custody
# gate reads.
cl_gerrit_done() {  # <note>
  local url
  [ "$T_FORGE" != external ] && url=$(fm_dod_pr_url_from_done_note "$1") \
    && ( fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = gerrit ] )
}

# 0 when a free-text push may have gone somewhere other than origin's branch:
# the note names another remote of <repo>, the no-mistakes gate or a review
# server, or the task delivers through no-mistakes or a review server. 1 when
# the note names origin.
cl_push_elsewhere() {  # <note> <repo>
  local note=$1 re r
  shopt -s nocasematch
  re='(^|[^[:alnum:]])origin([^[:alnum:]]|$)'
  if [[ $note =~ $re ]]; then
    shopt -u nocasematch
    return 1
  fi
  re='(^|[^[:alnum:]])(gate|gerrit|refs/for|no-mistakes)([^[:alnum:]]|$)'
  if [[ $note =~ $re ]]; then
    shopt -u nocasematch
    return 0
  fi
  shopt -u nocasematch
  for r in $(git -C "$2" remote 2>/dev/null); do
    [ "$r" = origin ] && continue
    printf '%s' "$note" | grep -Fwiq -- "$r" && return 0
  done
  [ "${T_MODE:-no-mistakes}" = no-mistakes ] || [ "$T_FORGE" = gerrit ] || [ "$T_FORGE" = external ]
}

# The line is cut to 4096 bytes before the custody gate reads it: no PR or
# review URL is that long, and the gate's parsing slows sharply on a huge line.
cl_check_pushed() {  # <sha> <origin> <line> <pr-url>
  local sha=$1 origin=$2 line=${3:0:4096} url=${4:-} dod_reason='' custody='' repo named rc src note
  local elsewhere="; the push may have gone to the no-mistakes gate or a review server"
  note=$(status_line_note "$line")
  if [ "$origin" = "done" ] && [ "$T_MODE" != local-only ] \
    && fm_dod_should_gate_ship_done "$T_KIND" "$T_MODE" "$line"; then
    if dod_reason=$(fm_dod_accept_ship_done "$T_KIND" "$T_MODE" "$T_WT" "$T_PROJECT" "$line" "$STATE" "$T_TASK" "$T_META" </dev/null); then
      custody=accepted
    else
      custody=refused
    fi
    if cl_review_server_done "$note"; then
      if [ "$custody" = accepted ] && cl_gerrit_done "$note"; then
        cl_set verified dod-custody "the custody gate read the Gerrit change and confirms it"
      elif [ "$custody" = accepted ]; then
        cl_set unverifiable dod-custody "the custody gate accepted the review report, but the review server was not read"
      else
        cl_set unverifiable dod-custody "the custody gate could not confirm the change on its review server" dod_refusal "$dod_reason"
      fi
      return
    fi
  fi
  if ! repo=$(cl_repo); then
    cl_set unverifiable remote-head "the task's local copy and project clone are both unreadable" custody "$custody" dod_refusal "$dod_reason"
    return
  fi
  named=$sha
  if [ -z "$named" ] && ! named=$(cl_claim_head "$repo" "$line"); then
    if [ "$origin" = "done" ] && [ "$repo" = "$T_WT" ] && named=$(cl_head); then
      :
    else
      cl_set unverifiable remote-head "the claim names no commit and the branch head at its time could not be read" custody "$custody"
      return
    fi
  fi
  if [ -z "$T_BRANCH" ]; then
    cl_set unverifiable remote-head "the task records no branch to look up on origin" sha "$named" custody "$custody"
    return
  fi
  cl_remote_head "$repo" "$T_BRANCH"
  rc=$?
  src=$CL_RH_SRC
  if [ "$rc" = 4 ]; then
    cl_task_pr_merged "$url"
    case "$?" in
      0)
        if ! fm_pr_head_valid "$CL_PR_HEAD"; then
          cl_set unverifiable gh-pr-view "origin has no branch $T_BRANCH and the merged PR's head could not be read" sha "$named" custody "$custody"
          return
        fi
        CL_RH=$CL_PR_HEAD
        src=gh-pr-view
        rc=0 ;;
      2)
        cl_set unverifiable "$src" "origin has no branch $T_BRANCH and whether PR $CL_PR_UNREAD merged could not be read" sha "$named" custody "$custody"
        return ;;
    esac
  fi
  case "$rc" in
    4)
      if [ "$origin" != "done" ] && cl_push_elsewhere "$note" "$repo"; then
        cl_set unverifiable "$src" "origin has no branch $T_BRANCH$elsewhere" sha "$named" remote_head ""
        return
      fi
      cl_set refuted "$src" "origin has no branch $T_BRANCH" sha "$named" remote_head "" custody "$custody" dod_refusal "$dod_reason"
      return ;;
    0) ;;
    *)
      cl_set unverifiable "$src" "origin's branch $T_BRANCH could not be read" sha "$named" custody "$custody" dod_refusal "$dod_reason"
      return ;;
  esac
  cl_contains "$repo" "$named" "$CL_RH"
  rc=$?
  case "$rc" in
    0) cl_set verified "$src" "origin/$T_BRANCH at ${CL_RH:0:12} contains ${named:0:12}" sha "$named" remote_head "$CL_RH" custody "$custody" ;;
    1)
      if [ "$origin" != "done" ] && cl_push_elsewhere "$note" "$repo"; then
        cl_set unverifiable "$src" "origin/$T_BRANCH at ${CL_RH:0:12} does not contain ${named:0:12}$elsewhere" sha "$named" remote_head "$CL_RH"
      else
        cl_set refuted "$src" "origin/$T_BRANCH at ${CL_RH:0:12} does not contain ${named:0:12}" sha "$named" remote_head "$CL_RH" custody "$custody" dod_refusal "$dod_reason"
      fi ;;
    3) cl_set unverifiable "$src" "origin/$T_BRANCH at ${CL_RH:0:12} has diverged from ${named:0:12}; history may have been rewritten" sha "$named" remote_head "$CL_RH" custody "$custody" ;;
    *) cl_set unverifiable "$src" "whether origin/$T_BRANCH at ${CL_RH:0:12} contains ${named:0:12} could not be read" sha "$named" remote_head "$CL_RH" custody "$custody" ;;
  esac
}

# Reads <url> for a PR claim: 0 with the PR read and the task's PR; 1 after
# setting the verdict. A PR that is not the task's refutes a done: claim and
# leaves a free-text claim unverifiable; one that cannot be told is
# unverifiable.
cl_pr_claim_read() {  # <url> <origin>
  local url=$1 origin=$2 rc task
  if ! cl_github_pr "$url"; then
    cl_set unverifiable gh-pr-view "the claimed PR ${url:-(none)} is not a GitHub pull request URL" pr "$url"
    return 1
  fi
  cl_pr_view "$url"
  rc=$?
  case "$rc" in
    4) cl_set refuted gh-pr-view "the forge has no PR $url" pr "$url"; return 1 ;;
    0) ;;
    *) cl_set unverifiable gh-pr-view "PR $url could not be read" pr "$url"; return 1 ;;
  esac
  cl_pr_is_task "$url"
  task=$?
  [ "$task" != 0 ] || return 0
  if [ "$task" = 2 ]; then
    cl_set unverifiable gh-pr-view "$CL_PR_FOREIGN" pr "$url" pr_branch "$CL_PR_BRANCH"
  elif [ "$origin" = "done" ]; then
    cl_set refuted gh-pr-view "$CL_PR_FOREIGN" pr "$url" pr_branch "$CL_PR_BRANCH"
  else
    cl_set unverifiable gh-pr-view "$CL_PR_FOREIGN, so the claim is not about the task's PR" pr "$url" pr_branch "$CL_PR_BRANCH"
  fi
  return 1
}

cl_check_pr_opened() {  # <pr-url> <origin>
  local url=$1
  cl_pr_claim_read "$url" "$2" || return
  cl_set verified gh-pr-view "PR $url exists ($CL_PR_STATE) on ${CL_PR_BRANCH}" pr "$url" pr_state "$CL_PR_STATE"
}

cl_check_pr_ready() {  # <pr-url> <origin> <line>
  local url=$1 origin=$2 line=$3 head repo rc
  [ -n "$url" ] || url=$T_PR
  cl_pr_claim_read "$url" "$origin" || return
  set -- pr "$url" pr_state "$CL_PR_STATE" pr_draft "$CL_PR_DRAFT" pr_head "$CL_PR_HEAD" pr_branch "$CL_PR_BRANCH"
  case "$CL_PR_STATE" in
    CLOSED) cl_set refuted gh-pr-view "PR $url is closed without merging" "$@"; return ;;
    MERGED) cl_set verified gh-pr-view "PR $url is merged" "$@"; return ;;
  esac
  if [ "$CL_PR_DRAFT" = true ]; then
    cl_set refuted gh-pr-view "PR $url is still a draft" "$@"
    return
  fi
  if [ "$T_MODE" = direct-PR ]; then
    if ! repo=$(cl_repo) || ! { head=$(cl_claim_head "$repo" "$line") \
      || { [ "$origin" = "done" ] && [ "$repo" = "$T_WT" ] && head=$(cl_head); }; }; then
      cl_set unverifiable gh-pr-view "the branch head at the claim's time could not be read to compare with PR $url" "$@"
      return
    fi
    cl_github_origin "$repo" || true
    cl_contains "$repo" "$head" "$CL_PR_HEAD"
    rc=$?
    case "$rc" in
      0) ;;
      1) cl_set refuted gh-pr-view "PR $url is at ${CL_PR_HEAD:0:12}, which does not contain the claimed head ${head:0:12}" "$@" sha "$head"; return ;;
      *) cl_set unverifiable gh-pr-view "whether PR $url at ${CL_PR_HEAD:0:12} contains the claimed head ${head:0:12} could not be told" "$@" sha "$head"; return ;;
    esac
  fi
  cl_set verified gh-pr-view "PR $url is open and ready at ${CL_PR_HEAD:0:12}" "$@"
}

# A ship done: is judged at HEAD. A free-text claim is judged at the branch
# head at its [at=] stamp. PR checks, a no-mistakes run, and an AgentKit gate
# count only at the claim's head. Failed checks and
# a failed ci step refute free text only when it names CI, checks or a PR,
# because a bare "tests pass" may describe a local run.
cl_check_tests_green() {  # <pr-url> <origin> <line>
  local url=$1 origin=$2 out pass fail pending outcome nmhead pending_note='' ak test_st ci_st step
  local note at_head='' pr_want='' ci_subject=1 repo head
  if [ "$origin" != "done" ]; then
    note=$(status_line_note "$3")
    note=${note:0:$CL_NOTE_MAX}
    shopt -s nocasematch
    [ -n "$url" ] || [[ $note =~ $CL_CI_SUBJECT_RE ]] || ci_subject=0
    shopt -u nocasematch
    if ! repo=$(cl_repo) || ! at_head=$(cl_claim_head "$repo" "$3"); then
      cl_set unverifiable gh-pr-checks "the branch head at the claim's time could not be read" pr "$url"
      return
    fi
    pr_want=$at_head
  elif cl_wt_ok; then
    pr_want=$(cl_head) || pr_want=
  fi
  if [ -n "$url" ] && [ "$url" != "$T_PR" ]; then
    if ! cl_github_pr "$url" || ! cl_pr_view "$url"; then
      cl_set unverifiable gh-pr-checks "the named PR $url could not be read" pr "$url"
      return
    fi
    if ! cl_pr_is_task "$url"; then
      cl_set unverifiable gh-pr-checks "$CL_PR_FOREIGN, so the claim is not about the task's PR" pr "$url"
      return
    fi
  fi
  [ -n "$url" ] || url=$T_PR
  if ! cl_github_pr "$url" || ! command -v gh >/dev/null 2>&1; then
    :
  elif [ -z "$pr_want" ] || ! cl_pr_view "$url" || [ "$CL_PR_HEAD" != "$pr_want" ]; then
    pending_note="PR $url is not shown to be at the claim's head${pr_want:+ ${pr_want:0:12}}"
  else
    out=$(cl_net gh pr checks "$url" --json bucket \
      --jq '[.[].bucket] | [(map(select(. == "pass" or . == "skipping")) | length), (map(select(. == "fail" or . == "cancel")) | length), (map(select(. == "pending")) | length)] | @tsv' 2>"$CL_TMP/err") || true
    IFS=$'\t' read -r pass fail pending <<EOF
$out
EOF
    if cl_uint "${pass:-}" && cl_uint "${fail:-}" && cl_uint "${pending:-}"; then
      if [ "$fail" -gt 0 ] && [ "$ci_subject" = 1 ]; then
        cl_set refuted gh-pr-checks "$fail check(s) failed or were cancelled on PR $url" pr "$url" passed "$pass" failed "$fail" pending "$pending"
        return
      fi
      if [ "$fail" -gt 0 ]; then
        pending_note="$fail check(s) failed on PR $url, but the claim may describe a local run"
      elif [ "$pending" -eq 0 ] && [ "$pass" -gt 0 ]; then
        cl_set verified gh-pr-checks "all $pass check(s) passed on PR $url" pr "$url" passed "$pass" failed 0 pending 0
        return
      elif [ "$pending" -gt 0 ]; then
        pending_note="$pending check(s) still pending on PR $url"
      fi
    fi
  fi
  if cl_nm_read; then
    outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$CL_NM_OUT" outcome)")
    nmhead=$(cl_nm_head)
    test_st=$(cl_nm_step test)
    ci_st=$(cl_nm_step ci)
    if { [ -z "$at_head" ] && fm_nm_head_matches_worktree "$T_WT" "$nmhead"; } \
      || { [ -n "$at_head" ] && [ "$(fm_nm_resolve_commit "$T_WT" "$nmhead")" = "$at_head" ]; }; then
      case "$outcome" in
        passed|passed-with-skips)
          if [ "$test_st" = completed ] || [ "$ci_st" = completed ]; then
            cl_set verified no-mistakes-run "the no-mistakes run at ${nmhead:0:12} passed ($outcome)" run_head "$nmhead" outcome "$outcome" test_step "$test_st" ci_step "$ci_st"
            return
          fi ;;
        failed)
          if [ "$test_st" = failed ] || { [ "$ci_st" = failed ] && [ "$ci_subject" = 1 ]; }; then
            step=ci
            [ "$test_st" != failed ] || step='test'
            cl_set refuted no-mistakes-run "the no-mistakes run at ${nmhead:0:12} failed its $step step" run_head "$nmhead" outcome "$outcome" test_step "$test_st" ci_step "$ci_st"
            return
          fi ;;
      esac
    fi
  fi
  cl_ak_verify
  ak=$?
  if [ "$ak" = 0 ] && { [ -z "$at_head" ] || { head=$(cl_head) && [ "$head" = "$at_head" ]; }; }; then
    cl_set verified agentkit-verify "$CL_AK_NOTE"
    return
  fi
  cl_set unverifiable gh-pr-checks+no-mistakes-run+agentkit-verify \
    "${pending_note:-no check, no-mistakes run, or AgentKit verify gate confirms it}; $CL_AK_NOTE" pr "$url"
}

# Order rules. Each sets R_VERDICT (verified, refuted, unverifiable, or skip
# when it does not apply) and R_REASON.
cl_rule_ship_branch() {
  local cur
  R_VERDICT=skip R_REASON=
  [ -n "$T_BRANCH" ] || return 0
  if ! cl_wt_ok; then
    R_VERDICT=unverifiable R_REASON="the local copy is gone"
  elif cur=$(git -C "$T_WT" symbolic-ref -q --short HEAD 2>/dev/null); then
    if [ "$cur" = "$T_BRANCH" ]; then
      R_VERDICT=verified R_REASON="on $T_BRANCH"
    else
      R_VERDICT=refuted R_REASON="the local copy is on $cur, not the ship branch $T_BRANCH"
    fi
  else
    R_VERDICT=unverifiable R_REASON="the local copy's HEAD is detached"
  fi
}

cl_rule_clean_worktree() {  # <line-number>
  local dirty
  R_VERDICT=skip R_REASON=
  [ "$1" = "$CL_NEWEST" ] || return 0
  if ! cl_wt_ok || ! dirty=$(cl_dirty_count "$T_WT"); then
    R_VERDICT=unverifiable R_REASON="the local copy is unreadable"
  elif [ "$dirty" = 0 ]; then
    R_VERDICT=verified R_REASON="clean"
  else
    R_VERDICT=refuted R_REASON="the local copy has $dirty uncommitted path(s)"
  fi
}

cl_rule_commit_nothing_after_run() {
  local nmhead head after
  R_VERDICT=skip R_REASON=
  case "$T_MODE" in no-mistakes|'') ;; *) return 0 ;; esac
  if ! cl_wt_ok || ! head=$(cl_head); then
    R_VERDICT=unverifiable R_REASON="the local copy is gone"
    return 0
  fi
  if R_REASON=$(fm_dod_nm_custody_returned "$T_WT" </dev/null); then
    R_VERDICT=verified R_REASON="HEAD carries the passed run's result"
    return 0
  fi
  R_VERDICT=unverifiable
  cl_nm_read || return 0
  nmhead=$(cl_nm_head)
  fm_pr_head_valid "$nmhead" || return 0
  git -C "$T_WT" cat-file -e "$nmhead^{commit}" 2>/dev/null || return 0
  after=$(git -C "$T_WT" rev-list --count "$nmhead..$head" 2>/dev/null) || return 0
  if [ "$after" != 0 ]; then
    R_VERDICT=refuted R_REASON="HEAD has $after commit(s) after the no-mistakes run head ${nmhead:0:12}"
  fi
}

cl_rule_no_default_push() {  # <candidate-url>
  local repo head default own rc merged
  R_VERDICT=skip R_REASON=
  if ! cl_wt_ok || ! head=$(cl_head); then
    R_VERDICT=unverifiable R_REASON="the local copy is gone"
    return 0
  fi
  repo=$T_WT
  cl_head_has_own_commit "$repo" "$head"
  own=$?
  case "$own" in
    1) return 0 ;;
    2) R_VERDICT=unverifiable R_REASON="whether HEAD carries a commit of the task's own could not be read"; return 0 ;;
  esac
  cl_task_pr_merged "$1"
  merged=$?
  [ "$merged" != 0 ] || return 0
  default=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || default=
  default=${default#origin/}
  if [ -z "$default" ] && cl_github_origin "$repo"; then
    default=$(cl_gh_api "repos/$CL_GH_SLUG" '.default_branch') || default=
  fi
  if [ -z "$default" ]; then
    R_VERDICT=unverifiable R_REASON="the default branch could not be named"
    return 0
  fi
  cl_remote_head "$repo" "$default"
  rc=$?
  if [ "$rc" != 0 ]; then
    R_VERDICT=unverifiable R_REASON="origin's $default could not be read"
    return 0
  fi
  cl_contains "$repo" "$head" "$CL_RH"
  case "$?" in
    0)
      if [ "$merged" = 2 ]; then
        R_VERDICT=unverifiable R_REASON="origin's default branch $default contains HEAD ${head:0:12}, and whether PR $CL_PR_UNREAD merged could not be read"
      else
        R_VERDICT=refuted R_REASON="origin's default branch $default contains HEAD ${head:0:12} with no merged PR"
      fi ;;
    1|3) R_VERDICT=verified R_REASON="$default does not contain HEAD" ;;
    *) R_VERDICT=unverifiable R_REASON="whether $default contains HEAD could not be read" ;;
  esac
}

cl_rule_no_version_bump() {
  local repo head base mb files f
  R_VERDICT=unverifiable R_REASON=
  if ! cl_wt_ok || ! head=$(cl_head); then
    R_REASON="the local copy is gone"
    return 0
  fi
  repo=$T_WT
  if ! base=$(cl_base_ref "$repo") || ! mb=$(git -C "$repo" merge-base "$base" "$head" 2>/dev/null); then
    R_REASON="the base branch could not be resolved"
    return 0
  fi
  files=$(git -C "$repo" diff --name-only "$mb" "$head" 2>/dev/null) || { R_REASON="the diff could not be read"; return 0; }
  while IFS= read -r f; do
    case "${f##*/}" in
      VERSION|version.txt)
        R_VERDICT=refuted R_REASON="$f changed"
        return 0 ;;
      package.json|Cargo.toml|pyproject.toml|plugin.json|marketplace.json)
        if git -C "$repo" diff -U0 "$mb" "$head" -- "$f" 2>/dev/null \
          | grep -Eq '^[+-][[:space:]]*"?version"?[[:space:]]*[:=]'; then
          R_VERDICT=refuted R_REASON="the version field in $f changed"
          return 0
        fi ;;
    esac
  done <<EOF
$files
EOF
  R_VERDICT=verified R_REASON="no version field changed"
}

# 0 when <brief> forbids <phrase>: a negation comes before it on the same line,
# in the same sentence. Without that, the phrase may be an instruction to do it.
cl_brief_forbids() {  # <brief> <phrase>
  printf '%s\n' "$1" | grep -Eiq "(^|[^[:alnum:]_])(never|not|no|don't)[^[:alnum:]_]([^.;:]*[^[:alnum:]_])?$2"
}

cl_check_order() {  # <line-number> <candidate-url>
  local ln=$1 url=$2 brief="$DATA/$T_TASK/brief.md" text='' rule refuted='' unknown='' held='' ak
  if [ -f "$brief" ] && [ ! -L "$brief" ]; then
    text=$(cat "$brief" 2>/dev/null) || text=
  fi
  for rule in ship-branch clean-worktree commit-nothing-after-run no-default-push no-version-bump; do
    case "$rule" in
      ship-branch) printf '%s' "$text" | grep -qi 'ship branch' || continue; cl_rule_ship_branch ;;
      clean-worktree) printf '%s' "$text" | grep -qi 'worktree clean' || continue; cl_rule_clean_worktree "$ln" ;;
      commit-nothing-after-run) printf '%s' "$text" | grep -qi 'commit nothing after' || continue; cl_rule_commit_nothing_after_run ;;
      no-default-push) cl_brief_forbids "$text" 'push to the default branch' || continue; cl_rule_no_default_push "$url" ;;
      no-version-bump) cl_brief_forbids "$text" 'bump a version' || continue; cl_rule_no_version_bump ;;
    esac
    case "$R_VERDICT" in
      refuted) refuted="${refuted:+$refuted; }$rule: $R_REASON" ;;
      unverifiable) unknown="${unknown:+$unknown; }$rule: $R_REASON" ;;
      verified) held="${held:+$held }$rule" ;;
    esac
  done
  if [ -n "$refuted" ]; then
    cl_set refuted order-rules "broke an order rule - $refuted" rules_held "$held" rules_unverifiable "$unknown"
    return
  fi
  cl_ak_verify
  ak=$?
  if [ "$ak" = 0 ] && [ -z "$unknown" ]; then
    cl_set verified order-rules+agentkit-verify "order rules hold (${held:-none recognized}) and $CL_AK_NOTE" rules_held "$held"
    return
  fi
  cl_set unverifiable order-rules+agentkit-verify "${unknown:+$unknown; }$CL_AK_NOTE" rules_held "$held" rules_unverifiable "$unknown"
}

# Sets CL_CPU and CL_PROCS for processes whose working directory is inside
# the local copy; 1 when that cannot be measured, including when the copy is
# not an absolute, existing directory other than the root.
cl_cpu_in_wt() {
  local listing pids wt=${T_WT%/}
  case "$wt" in /?*) ;; *) return 1 ;; esac
  [ -d "$wt" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  listing=$( (cd / && cl_net lsof -nP -a -u "$(id -u)" -d cwd -Fn 2>/dev/null) )
  case $? in 124|137) return 1 ;; esac
  [ -n "$listing" ] || return 1
  pids=$(printf '%s\n' "$listing" | awk -v wt="$wt" -v self="$$" '
    /^p/ { pid = substr($0, 2) }
    /^n/ { p = substr($0, 2); if ((p == wt || index(p, wt "/") == 1) && pid != self) print pid }' | sort -u | paste -sd, -)
  CL_PROCS=0
  CL_CPU=0
  [ -n "$pids" ] || return 0
  CL_PROCS=$(printf '%s\n' "$pids" | tr ',' '\n' | wc -l | tr -d ' ')
  CL_CPU=$( (cd / && ps -o %cpu= -p "$pids" 2>/dev/null) | awk '{ s += $1 } END { printf "%.1f", s + 0 }')
}

# Sets CL_OUT_AGE from the monitor's per-window output marker, which it
# rewrites only when the agent's terminal output changes (bin/fm-watch.sh
# names the window: the terminal on orca, else the window). 1 for a second
# mate, whose idle window is healthy; while the monitor's beat is older than
# the freshness window, because a stopped monitor stops the marker too; and
# unless the monitor's per-window poll count was written within the poll
# grace (fm_poll_derived_grace), because a window whose capture keeps failing
# leaves the marker aging under a fresh beat.
cl_output_age() {
  local src marker m beat key count
  [ "$T_KIND" != secondmate ] || return 1
  beat=$(fm_path_mtime "$STATE/.last-watcher-beat") || return 1
  cl_uint "$beat" || return 1
  [ $((NOW - beat)) -le "$OUTPUT_FRESH_SECS" ] || return 1
  src=
  [ "$T_BACKEND" != orca ] || src=$(fm_meta_get "$T_META" terminal)
  [ -n "$src" ] || src=$(fm_meta_get "$T_META" window)
  [ -n "$src" ] || return 1
  key=$(window_key "$src")
  count=$(fm_path_mtime "$STATE/.count-$key") || return 1
  cl_uint "$count" || return 1
  [ $((NOW - count)) -le "$(fm_poll_derived_grace)" ] || return 1
  marker="$STATE/.hash-$key"
  [ -f "$marker" ] || return 1
  m=$(fm_path_mtime "$marker") || return 1
  cl_uint "$m" || return 1
  CL_OUT_AGE=$((NOW - m))
}

cl_check_alive() {  # <verb>
  local verb=$1 target ep rec m age out_ok=0 cpu_ok=0
  target=$(fm_backend_target_of_meta "$T_META")
  ep=unknown
  if [ -n "$target" ]; then
    ep=$(fm_run_timed_fn "$NET_TIMEOUT" fm_backend_agent_alive "$T_BACKEND" "$target" </dev/null 2>/dev/null) || ep=unknown
  fi
  if [ "$ep" = dead ]; then
    cl_set refuted endpoint "the agent's endpoint ($T_BACKEND) is gone" endpoint dead
    return
  fi
  if rec=$(fm_task_inbox_oldest_unhandled "$STATE" "$T_TASK") && m=$(fm_path_mtime "$rec") && cl_uint "$m"; then
    age=$((NOW - m))
    if [ "$age" -gt "$STEER_GRACE_SECS" ]; then
      cl_set refuted task-inbox "steering message ${rec##*/} has been unread for ${age}s" endpoint "$ep" unread_steer_age "$age"
      return
    fi
  fi
  cl_output_age && out_ok=1
  cl_cpu_in_wt && cpu_ok=1
  set -- endpoint "$ep" output_age "${CL_OUT_AGE:-}" cpu_pct "${CL_CPU:-}" procs "${CL_PROCS:-}"
  [ "$out_ok" = 1 ] || set -- endpoint "$ep" output_age "" cpu_pct "${CL_CPU:-}" procs "${CL_PROCS:-}"
  [ "$cpu_ok" = 1 ] || set -- "$@" cpu_pct ""
  if [ "$verb" = paused ]; then
    if [ "$ep" = alive ] || { [ "$cpu_ok" = 1 ] && [ "$CL_PROCS" -gt 0 ]; }; then
      cl_set verified endpoint+cpu "the paused agent is still present" "$@"
    else
      cl_set unverifiable endpoint+cpu "the paused agent's presence could not be read" "$@"
    fi
    return
  fi
  if [ "$out_ok" = 1 ] && [ "$CL_OUT_AGE" -le "$OUTPUT_FRESH_SECS" ]; then
    cl_set verified terminal-output "terminal output changed ${CL_OUT_AGE}s ago" "$@"
  elif [ "$cpu_ok" = 1 ] && awk -v c="$CL_CPU" -v t="$CPU_ACTIVE_PCT" 'BEGIN { exit !(c + 0 >= t + 0) }'; then
    cl_set verified cpu "processes in the local copy use ${CL_CPU}% CPU" "$@"
  elif [ "$out_ok" = 1 ] && [ "$cpu_ok" = 1 ]; then
    cl_set refuted terminal-output+cpu "no terminal output for ${CL_OUT_AGE}s and ${CL_CPU}% CPU in the local copy" "$@"
  else
    cl_set unverifiable terminal-output+cpu "terminal output age or CPU use could not be read" "$@"
  fi
}

# <origin> is the candidate's origin: done for a structured ship done:, the
# verb for alive, and <verb>-text for a free-text claim.
cl_judge() {  # <kind> <line-number> <line> <sha> <pr> <origin>
  CL_VERDICT=unverifiable CL_CHECKER=none CL_REASON='' CL_OBSERVED='{}'
  CL_OUT_AGE='' CL_CPU='' CL_PROCS=''
  case "$1" in
    committed) cl_check_committed "$4" "$6" "$2" ;;
    pushed) cl_check_pushed "$4" "$6" "$3" "$5" ;;
    pr-opened) cl_check_pr_opened "$5" "$6" ;;
    pr-ready) cl_check_pr_ready "$5" "$6" "$3" ;;
    tests-green) cl_check_tests_green "$5" "$6" "$3" ;;
    order) cl_check_order "$2" "$5" ;;
    alive) cl_check_alive "$6" ;;
  esac
}

# --- extraction --------------------------------------------------------------

# Candidate and ledger-state rows separate fields with the unit separator, a
# non-whitespace IFS character, so an empty field never collapses into the next.
CL_US=$'\037'

cl_cand_add() {  # <line-number> <kind> <sha> <pr> <origin>
  CL_CAND="${CL_CAND}$1$CL_US$2$CL_US$3$CL_US$4$CL_US$5"$'\n'
}

# The sha in the word that directly follows <word> in <note>, after an
# optional "as": once edge punctuation is trimmed, 7 to 40 hex characters
# holding a digit and a letter, and not 16 long, the claim-id shape. Matches
# <word> without regard to case when the caller set nocasematch.
cl_sha_after() {  # <note> <word>
  local re="(^|[^[:alnum:]])$2([[:space:]]+as)?[[:space:]]+([^[:space:]]+)" w
  [[ $1 =~ $re ]] || return 1
  w=${BASH_REMATCH[3]}
  w=${w#"${w%%[[:alnum:]]*}"}
  w=${w%"${w##*[[:alnum:]]}"}
  [[ $w =~ ^[0-9A-Fa-f]{7,40}$ && $w =~ [A-Fa-f] && $w =~ [0-9] ]] || return 1
  [ "${#w}" != 16 ] || return 1
  printf '%s' "$w" | tr 'A-F' 'a-f'
}

cl_done_kinds() {  # <note>
  case "${T_MODE:-no-mistakes}" in
    no-mistakes)
      if fm_dod_note_reports_ci_ready "$1"; then
        echo "pushed pr-ready tests-green order"
      elif fm_dod_note_reports_published_change "$1"; then
        echo "pushed order"
      else
        echo committed
      fi ;;
    direct-PR)
      if fm_dod_note_has_pr_reference "$1"; then echo "pushed pr-ready order"; else echo "pushed order"; fi ;;
    local-only) echo "committed order" ;;
  esac
}

cl_freetext() {  # <line-number> <note> <origin> <kinds-already-taken>
  local ln=$1 note=$2 origin=$3 have=" $4 " csha psha url=''
  shopt -s nocasematch
  if [[ $note =~ $CL_HEDGE_RE ]]; then
    shopt -u nocasematch
    return 0
  fi
  [[ $note =~ $CL_PR_URL_RE ]] && url=${BASH_REMATCH[0]}
  csha=$(cl_sha_after "$note" committed) || csha=
  if [ -n "$csha" ] && [[ $have != *" committed "* ]]; then
    cl_cand_add "$ln" committed "$csha" "" "$origin-text"
  fi
  psha=$(cl_sha_after "$note" pushed) || psha=$csha
  if [[ $note =~ $CL_PUSHED_RE ]] && ! [[ $note =~ $CL_PUSH_VOID_RE ]] && [[ $have != *" pushed "* ]] \
    && { [ -n "$psha" ] || [[ $note =~ $CL_PUSH_CUE_RE ]] || { [ -n "$T_BRANCH" ] && [[ $note == *"$T_BRANCH"* ]]; }; }; then
    cl_cand_add "$ln" pushed "$psha" "$url" "$origin-text"
  fi
  if [[ $note =~ $CL_TESTS_RE ]] && ! [[ $note =~ $CL_TESTS_CONTRARY_RE ]] && [[ $have != *" tests-green "* ]]; then
    cl_cand_add "$ln" tests-green "" "$url" "$origin-text"
  fi
  if [ -n "$url" ] && [[ $note =~ $CL_OPENED_RE ]]; then
    cl_cand_add "$ln" pr-opened "" "$url" "$origin-text"
  fi
  if [ -n "$url" ] && [[ $note =~ $CL_READY_RE ]] && [[ $have != *" pr-ready "* ]]; then
    cl_cand_add "$ln" pr-ready "" "$url" "$origin-text"
  fi
  shopt -u nocasematch
}

# Reads the status log into CL_LINES, sets CL_GEN to the hash of its first
# line, sets CL_NEWEST to the newest mate line (working:, paused:, done:,
# blocked: or needs-decision:, other than the verifier's own claim-refuted-
# blockers), and fills CL_CAND with one "<line-number> <kind> <sha> <pr>
# <origin>" row per claim (cl_cand_add).
cl_extract() {
  local line i verb note kinds k url newest_verb=''
  CL_LINES=()
  CL_CAND=
  CL_NEWEST=0
  CL_GEN=
  [ -f "$T_STATUS" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    CL_LINES+=("$line")
  done < "$T_STATUS"
  CL_GEN=$(cl_sha256 "${CL_LINES[0]:-}")
  for ((i = 1; i <= ${#CL_LINES[@]}; i++)); do
    line=${CL_LINES[$((i - 1))]}
    case "$line" in *:*) ;; *) continue ;; esac
    status_line_verb "$line" verb
    case "$verb" in working|paused|done|blocked|needs-decision) ;; *) continue ;; esac
    if [ "$verb" = blocked ]; then
      case "${line%%:*}" in *"[key=claim-refuted-"*) continue ;; esac
    fi
    CL_NEWEST=$i
    newest_verb=$verb
    case "$verb" in working|paused|done) ;; *) continue ;; esac
    note=$(status_line_note "$line")
    note=${note:0:$CL_NOTE_MAX}
    kinds=
    if [ "$verb" = "done" ] && [ "$T_KIND" = ship ] && [ "$i" -gt "$T_PROMOTED" ]; then
      kinds=$(cl_done_kinds "$note")
      url=$(fm_dod_pr_url_from_done_note "$note") || url=
      for k in $kinds; do
        cl_cand_add "$i" "$k" "" "$url" "done"
      done
    fi
    [ "$verb" = "done" ] && { [ "$T_KIND" = scout ] || [ "$i" -le "$T_PROMOTED" ]; } && continue
    cl_freetext "$i" "$note" "$verb" "$kinds"
  done
  case "$newest_verb" in
    working|paused) cl_cand_add "$CL_NEWEST" alive "" "" "$newest_verb" ;;
  esac
}

cl_newest_of_kind() {  # <kind>
  printf '%s' "$CL_CAND" | awk -F"$CL_US" -v k="$1" '$2 == k && $1 + 0 > m { m = $1 + 0 } END { print m + 0 }'
}

# Newest record per claim id as "<id> <verdict> <attempt> <checked_at> <kind>
# <line> <reason>" rows (CL_US-separated), tolerating malformed lines, unknown
# members, and duplicates.
cl_ledger_state() {
  [ -f "$T_LEDGER" ] || return 0
  jq -rR 'fromjson? // empty
    | select(type == "object" and (.id | type) == "string")
    | [.id, (.verdict // ""), (.attempt // 0), (.checked_at // 0), (.kind // ""),
       ((.evidence | if type == "object" then .line else null end) // 0), (.reason // "")]
    | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' \
    "$T_LEDGER" 2>/dev/null | awk -F"$CL_US" '
      !($1 in last) { order[++n] = $1 }
      { last[$1] = $0 }
      END { for (i = 1; i <= n; i++) print last[order[i]] }'
}

cl_state_lookup() {  # <claim-id>
  local id verdict attempt at kind
  S_VERDICT='' S_ATTEMPT=0 S_AT=0 S_KIND=''
  while IFS=$CL_US read -r id verdict attempt at kind _; do
    if [ "$id" = "$1" ]; then
      S_VERDICT=$verdict
      cl_uint "$attempt" && S_ATTEMPT=$attempt
      cl_uint "$at" && S_AT=$at
      S_KIND=$kind
      return 0
    fi
  done <<EOF
$CL_STATE
EOF
}

# --- consequences ------------------------------------------------------------

cl_record() {  # <id> <kind> <line-number> <line> <line-sha> <sha> <pr> <attempt>
  local note at corr
  note=$(status_line_note "$4")
  note=${note:0:$CL_NOTE_MAX}
  at=$(status_line_at_epoch "$4") || at=
  cl_uint "$at" || at=
  corr=$(fm_pending_reply_extract_corr "$4")
  cl_nl_guard "$T_LEDGER"
  jq -cn \
    --arg id "$1" --arg kind "$2" --arg ln "$3" --arg lsha "$5" \
    --arg sha "${CL_SUBJECT_SHA:-$6}" --arg pr "$7" --arg attempt "$8" \
    --arg now "$NOW" --arg task "$T_TASK" --arg mk "$T_KIND" --arg h "$T_HARNESS" \
    --arg m "$T_MODEL" --arg g "$T_GEN" --arg time "$at" --arg claim "$note" \
    --arg corr "$corr" --arg branch "$T_BRANCH" --arg path "state/$T_TASK.status" \
    --arg verdict "$CL_VERDICT" --arg checker "$CL_CHECKER" --arg reason "$CL_REASON" \
    --argjson observed "$CL_OBSERVED" \
    "$CL_JQ_DEFS"'
    {v: 1, id: $id, checked_at: ($now | tonumber), task: $task, mate: $task,
     mate_kind: n($mk), harness: n($h), model: n($m), spawn_gen: n($g),
     time: (if $time == "" then null else ($time | tonumber) end), kind: $kind,
     claim: ($claim | clean),
     evidence: {source: "status", path: $path, line: ($ln | tonumber), line_sha256: $lsha, corr: n($corr)},
     subject: {sha: n($sha), branch: n($branch), pr: n($pr | clean)},
     verdict: $verdict, checker: $checker, reason: ($reason | clean),
     attempt: ($attempt | tonumber), observed: $observed}' >> "$T_LEDGER"
}

# Appends the reopening blocker for a refuted claim and sets CL_REOPEN to
# opened. Leaves CL_REOPEN skipped, with nothing appended, when the log is gone
# or a mate done: line, which restates the work, arrived after the scan read
# the log. 1 when the append fails.
cl_reopen() {  # <claim-id> <kind> <line-number>
  local line verb
  CL_REOPEN=skipped
  [ -f "$T_STATUS" ] && [ ! -L "$T_STATUS" ] || return 0
  while IFS= read -r line; do
    status_line_verb "$line" verb
    [ "$verb" != "done" ] || return 0
  done <<EOF
$(tail -n +$((${#CL_LINES[@]} + 1)) "$T_STATUS" 2>/dev/null)
EOF
  fm_cap_line_var "blocked [at=$NOW] [key=$(fm_claims_reopen_key "$1")]: $(fm_claims_reopen_note "$2" "$3" "$CL_REASON" "state/$T_TASK.claims.jsonl")"
  cl_nl_guard "$T_STATUS"
  printf '%s\n' "$FM_LINE_CAP_LINE" >> "$T_STATUS" || return 1
  CL_REOPEN=opened
}

cl_failure_class() {  # <claim-id> <kind> <line-number>
  local dir="$DATA/failure-classes" key="claim-refuted-$2" file reopen_key=''
  file="$dir/$key.jsonl"
  mkdir -p "$dir" || { echo "fm-claims: cannot create $dir" >&2; return 1; }
  if [ -L "$file" ]; then
    echo "fm-claims: refusing the symlinked $file" >&2
    return 1
  fi
  [ "$CL_REOPEN" = opened ] && reopen_key=$(fm_claims_reopen_key "$1")
  cl_nl_guard "$file"
  jq -cn --arg now "$NOW" --arg key "$key" --arg task "$T_TASK" --arg id "$1" --arg kind "$2" \
    --arg reason "$CL_REASON" --arg evidence "state/$T_TASK.status:$3" --arg ledger "state/$T_TASK.claims.jsonl" \
    --arg reopen "$CL_REOPEN" --arg reopen_key "$reopen_key" \
    "$CL_JQ_DEFS"'
    {v: 1, event: "occurrence", ts: ($now | tonumber), key: $key, task: $task, mate: $task,
     claim_id: $id, kind: $kind, reason: ($reason | clean), evidence: $evidence, ledger: $ledger,
     reopen: $reopen, reopen_key: n($reopen_key)}' >> "$file"
}

# Finishes every refuted claim whose failure-class occurrence is missing,
# because an earlier scan stopped after its ledger record or could not append
# its blocker. 1 when a consequence still could not be written.
cl_reconcile() {
  local id verdict attempt at kind ln reason file rc=0
  while IFS=$CL_US read -r id verdict attempt at kind ln reason; do
    [ "$verdict" = refuted ] || continue
    fm_claims_id_valid "$id" || continue
    case "$kind" in committed|pushed|pr-opened|pr-ready|tests-green|order|alive) ;; *) continue ;; esac
    cl_uint "$ln" || ln=0
    file="$DATA/failure-classes/claim-refuted-$kind.jsonl"
    if [ -f "$file" ] && grep -qF "\"claim_id\":\"$id\"" "$file" 2>/dev/null; then
      continue
    fi
    CL_REASON=$reason
    if grep -qF "[key=$(fm_claims_reopen_key "$id")]" "$T_STATUS" 2>/dev/null; then
      CL_REOPEN=opened
    elif ! cl_reopen "$id" "$kind" "$ln"; then
      echo "fm-claims: could not append the blocker to $T_STATUS" >&2
      rc=1
      continue
    fi
    cl_failure_class "$id" "$kind" "$ln" || rc=1
  done <<EOF
$CL_STATE
EOF
  return "$rc"
}

# Appends the resolved line that closes claim-refuted-<claim-id>. The close is
# this home's own bookkeeping, so it is appended the way fm-send --resolve-key
# appends one: stamped, and self-announced so it does not wake the session
# that wrote it (bin/fm-wake-lib.sh). 1 when the append fails.
cl_close_blocker() {  # <claim-id> <extra>
  local note
  note=$(fm_claims_cleared_note "$T_TASK" "$1" fm-claims-scan "$2")
  fm_cap_line_var "resolved [key=$(fm_claims_reopen_key "$1")]: $note" "$((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))"
  cl_nl_guard "$T_STATUS"
  fm_wake_status_append_self_announced "$STATE" "$T_STATUS" "$FM_LINE_CAP_LINE"
  [ "$?" != 2 ]
}

# 0 when the blocker of <claim-id> is open in the status log.
cl_blocker_open() {  # <claim-id>
  status_open_decisions "$T_STATUS" 2>/dev/null | cut -f1 | grep -qxF "$(fm_claims_reopen_key "$1")"
}

# Closes every open blocker of an alive claim once the agent reads alive
# again. Uses the ledger state read at scan start.
cl_close_alive_blockers() {  # <extra>
  local open key rest id
  open=$(status_open_decisions "$T_STATUS" 2>/dev/null) || return 0
  while IFS=$'\t' read -r key rest; do
    case "$key" in claim-refuted-*) ;; *) continue ;; esac
    id=${key#claim-refuted-}
    fm_claims_id_valid "$id" || continue
    cl_state_lookup "$id"
    [ "$S_KIND" = alive ] || continue
    cl_close_blocker "$id" "$1" || return 1
    printf '%s %s cleared\n' "$T_TASK" "$id"
  done <<EOF
$open
EOF
}

# --- commands ----------------------------------------------------------------

cl_time_sensitive() {  # <kind>
  case "$1" in tests-green|pr-ready|order) return 0 ;; esac
  return 1
}

# Scans one task; 3 when it recorded a refuted verdict, 1 on a refusal.
cl_scan_task() {  # <task-id>
  local ln kind sha url origin line line_sha id attempt prev prev_attempt rc=0
  cl_task_load "$1" || return 1
  if [ ! -f "$T_STATUS" ]; then
    [ -f "$T_META" ] && return 0
    echo "fm-claims: $T_TASK has neither a status log nor metadata" >&2
    return 1
  fi
  CL_LOCK="$STATE/.claims-$T_TASK.lock"
  if ! fm_state_lock_acquire "$CL_LOCK"; then
    CL_LOCK=
    return 1
  fi
  cl_extract
  CL_STATE=$(cl_ledger_state)
  cl_reconcile || rc=1
  while IFS=$CL_US read -r ln kind sha url origin <&3; do
    [ -n "$ln" ] || continue
    line=${CL_LINES[$((ln - 1))]}
    line_sha=$(cl_sha256 "$line")
    id=$(cl_sha256 "$T_TASK"$'\n'"$CL_GEN"$'\n'"$ln"$'\n'"$line_sha"$'\n'"$kind")
    id=${id:0:16}
    cl_state_lookup "$id"
    attempt=1
    if [ "$kind" = alive ]; then
      [ "$ln" = "$CL_NEWEST" ] || continue
    else
      if [ -n "$S_VERDICT" ]; then
        [ "$S_VERDICT" = unverifiable ] || continue
        [ "$S_ATTEMPT" -lt "$MAX_ATTEMPTS" ] || continue
        [ $((NOW - S_AT)) -ge "$RETRY_SECS" ] || continue
        attempt=$((S_ATTEMPT + 1))
      fi
      if cl_time_sensitive "$kind" && [ "$ln" != "$(cl_newest_of_kind "$kind")" ]; then
        continue
      fi
    fi
    CL_SUBJECT_SHA=
    cl_judge "$kind" "$ln" "$line" "$sha" "$url" "$origin"
    if [ "$kind" = alive ]; then
      prev=$S_VERDICT prev_attempt=$S_ATTEMPT
      if [ "$CL_VERDICT" = verified ]; then
        cl_close_alive_blockers "$CL_REASON" || { echo "fm-claims: could not append to $T_STATUS" >&2; rc=1; }
      fi
      [ "$CL_VERDICT" != "$prev" ] || continue
      attempt=$((prev_attempt + 1))
    fi
    CL_SUBJECT_SHA=$(printf '%s' "$CL_OBSERVED" | jq -r '.sha // empty' 2>/dev/null) || CL_SUBJECT_SHA=
    if ! cl_record "$id" "$kind" "$ln" "$line" "$line_sha" "$sha" "${url:-}" "$attempt"; then
      echo "fm-claims: could not append to $T_LEDGER" >&2
      rc=1
      continue
    fi
    printf '%s %s %s %s line=%s: %s\n' "$T_TASK" "$id" "$kind" "$CL_VERDICT" "$ln" "$CL_REASON"
    if [ "$CL_VERDICT" = refuted ]; then
      if ! cl_blocker_open "$id"; then
        if ! cl_reopen "$id" "$kind" "$ln"; then
          echo "fm-claims: could not append the blocker to $T_STATUS" >&2
          rc=1
          continue
        fi
        cl_failure_class "$id" "$kind" "$ln" || rc=1
      fi
      [ "$rc" = 1 ] || rc=3
    fi
  done 3<<EOF
$CL_CAND
EOF
  fm_lock_release "$CL_LOCK" || true
  CL_LOCK=
  return "$rc"
}

cmd_scan() {
  local task overall=0 rc tasks=() meta
  [ "$#" -gt 0 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || die "jq is required"
  if [ "$1" = --all ]; then
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    for meta in "$STATE"/*.meta; do
      [ -e "$meta" ] || continue
      task=${meta##*/}
      tasks+=("${task%.meta}")
    done
  else
    for task in "$@"; do
      case "$task" in -*) usage >&2; exit 2 ;; esac
      tasks+=("$task")
    done
  fi
  [ "${#tasks[@]}" -gt 0 ] || exit 0
  for task in "${tasks[@]}"; do
    cl_scan_task "$task"
    rc=$?
    case "$rc" in
      0) ;;
      3) [ "$overall" = 1 ] || overall=3 ;;
      *) overall=1 ;;
    esac
  done
  exit "$overall"
}

cmd=${1:-}
[ "$#" -eq 0 ] || shift
case "$cmd" in
  scan) cmd_scan "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

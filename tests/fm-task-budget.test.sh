#!/usr/bin/env bash
# Task-budget behavior through public spawn, counter-reader, and watcher interfaces.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TEST_BASH=${FM_TEST_BASH:-${BASH:-bash}}
PATH="$(dirname "$TEST_BASH"):$PATH"
export PATH
TMP_ROOT=$(fm_test_tmproot fm-task-budget)

test_spawn_records_explicit_budget() {
  local dir="$TMP_ROOT/spawn" home proj wt fakebin out
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" budget
  fm_git_worktree "$proj" "$wt" budget-fixture
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake" codex)
  if ! out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" budget "$proj" --scout \
    --budget-inclusive-hard 40000000 --budget-inclusive-stop 32000000 \
    --budget-fresh-hard 1500000 --budget-fresh-stop 1200000); then
    printf '%s\n' "$out" >&2
    fail 'spawn accepts explicit numeric budget limits'
  fi
  assert_grep 'budget_inclusive_hard=40000000' "$home/state/budget.meta" 'inclusive hard cap recorded'
  assert_grep 'budget_inclusive_stop=32000000' "$home/state/budget.meta" 'inclusive stop recorded'
  assert_grep 'budget_fresh_hard=1500000' "$home/state/budget.meta" 'fresh hard cap recorded'
  assert_grep 'budget_fresh_stop=1200000' "$home/state/budget.meta" 'fresh stop recorded'
  python3 - "$home" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);meta=dict(line.split('=',1) for line in (p/'state/budget.meta').read_text().splitlines() if '=' in line)
marker=meta['budget_launch_marker'];launch=(p/'data/budget/launch-brief.md').read_text()
assert marker and marker in launch.splitlines(), 'launch marker must reach the actual initial message'
PY
  pass 'spawn records all four explicit budget limits'
}

make_counter_case() {
  local dir=$1 harness=$2
  mkdir -p "$dir/state" "$dir/native/project" "$dir/wt" "$dir/config"
  printf 'harness=%s\nkind=scout\nspawn_gen=s1\nworktree=%s\n' "$harness" "$dir/wt" > "$dir/state/task.meta"
  "$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" seed - "$harness" "$dir/wt" "$dir/native" \
    FM_BUDGET_LAUNCH_fixture1 40000000 32000000 1500000 1200000 >> "$dir/state/task.meta"
}

write_native() {
  python3 - "$1" "$2" <<'PY'
import datetime,json,pathlib,sys
d=pathlib.Path(sys.argv[1]);harness=sys.argv[2]
now=datetime.datetime.now(datetime.timezone.utc).isoformat()
meta=dict(line.split('=',1) for line in (d/'state/task.meta').read_text().splitlines() if '=' in line)
marker=meta.get('budget_launch_marker','FM_BUDGET_LAUNCH_fixture1')
def row(value): return json.dumps(value)+'\n'
if harness=='claude':
 def usage(mid,i,w,o,r):
  return {'type':'assistant','sessionId':'main','cwd':str(d/'wt'),'isSidechain':False,'timestamp':now,'message':{'id':mid,'usage':{'input_tokens':i,'cache_creation_input_tokens':w,'output_tokens':o,'cache_read_input_tokens':r}}}
 events=[{'type':'user','sessionId':'main','cwd':str(d/'wt'),'timestamp':now,'message':{'role':'user','content':marker}}]
 events += [usage('one',11,17,5,101),usage('one',11,17,7,101),usage('two',3,4,2,20)]
else:
 events=[{'type':'session_meta','payload':{'id':'main','timestamp':now,'cwd':str(d/'wt'),'source':'cli'}}]
 events += [{'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':marker}]}}]
 def usage(i,c,o):
  return {'type':'event_msg','payload':{'type':'token_count','info':{'total_token_usage':{'input_tokens':i,'cached_input_tokens':c,'cache_write_input_tokens':30,'output_tokens':o,'reasoning_output_tokens':4,'total_tokens':i+o}}}}
 events += [usage(1000,900,10),usage(2000,1800,30),usage(2000,1800,30)]
(d/'native/project/main.jsonl').write_text(''.join(map(row,events)))
PY
}

assert_usage() {
  printf '%s\n' "$1" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="ok",r; assert (r["inclusive"],r["fresh"])==(int(sys.argv[1]),int(sys.argv[2])),r' "$2" "$3" \
    || fail 'native counter totals match the fixed fresh/inclusive definition'
}

test_native_counters_deduplicate() {
  local dir out harness
  for harness in claude codex; do
    dir="$TMP_ROOT/$harness"
    make_counter_case "$dir" "$harness"
    write_native "$dir" "$harness"
    out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta") \
      || fail "measure $harness native counters"
    if [ "$harness" = claude ]; then assert_usage "$out" 165 44
    else assert_usage "$out" 2030 230; fi
    pass "$harness native usage is normalized and deduplicated"
  done
}

test_stop_line_dry_run_then_enforce_once() {
  local dir="$TMP_ROOT/stop" out
  make_counter_case "$dir" codex
  write_native "$dir" codex
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/control.log"
printf '%s\n' 'interrupt-delivered task harness=codex backend=tmux verified=agent-alive cancel=unconfirmed'
SH
  python3 - "$dir/state/task.meta" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text().replace('budget_inclusive_stop=32000000','budget_inclusive_stop=2030')
p.write_text(s)
PY
  out=$("$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir" 2>&1) \
    || fail 'dry-run watcher check'
  assert_contains "$out" 'budget-would-pause' 'default dry-run logs a threshold crossing'
  [ ! -e "$dir/control.log" ] || fail 'dry-run invoked lifecycle control'
  [ ! -e "$dir/state/task.status" ] || fail 'dry-run raised a decision'
  out=$("$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir" 2>&1)
  [ -z "$out" ] || fail 'unchanged dry-run repeated its event'
  printf 'enforce\n' > "$dir/config/budget-enforcement"
  "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir"
  "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] || fail 'unchanged enforcement repeated interrupt'
  assert_grep 'task interrupt' "$dir/control.log" 'exact task interrupt requested'
  assert_grep 'cancel=unconfirmed' "$dir/state/task.status" 'actual cancellation proof preserved'
  [ "$(wc -l < "$dir/state/task.status" | tr -d ' ')" = 1 ] || fail 'budget decision duplicated'
  pass 'default dry-run and opt-in enforcement are durable and deduplicated'
}

test_relaunch_keeps_native_consumption() {
  local dir="$TMP_ROOT/relaunch" record out
  make_counter_case "$dir" codex
  write_native "$dir" codex
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  assert_usage "$out" 2030 230
  record=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" seed "$dir/state/task.meta" claude "$dir/wt" "$dir/native" \
    FM_BUDGET_LAUNCH_fixture2 40000000 32000000 1500000 1200000) || fail 'relaunch retains measured prior usage'
  printf 'harness=claude\nkind=scout\nspawn_gen=s2\nworktree=%s\n%s\n' "$dir/wt" "$record" > "$dir/state/task.meta"
  write_native "$dir" claude
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  assert_usage "$out" 2195 274
  # Finalization is retry-safe, and a second replacement retains both exact sources.
  cp "$dir/native/project/main.jsonl" "$dir/native/project/claude.jsonl"
  record=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" seed "$dir/state/task.meta" codex "$dir/wt" "$dir/native" \
    FM_BUDGET_LAUNCH_fixture3 40000000 32000000 1500000 1200000)
  record=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" seed "$dir/state/task.meta" codex "$dir/wt" "$dir/native" \
    FM_BUDGET_LAUNCH_fixture3 40000000 32000000 1500000 1200000)
  printf 'harness=codex\nkind=scout\nspawn_gen=s3\nworktree=%s\n%s\n' "$dir/wt" "$record" > "$dir/state/task.meta"
  write_native "$dir" codex
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  assert_usage "$out" 4225 504
  pass 'native allocation consumption survives a harness switch'
}

test_relaunch_with_unknown_prior_usage_still_launches() {
  local dir="$TMP_ROOT/relaunch-pending" record
  make_counter_case "$dir" codex
  # The first incarnation died before writing any native session.
  record=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" seed "$dir/state/task.meta" codex "$dir/wt" "$dir/native" \
    FM_BUDGET_LAUNCH_fixture2 40000000 32000000 1500000 1200000 2> "$dir/seed.err") \
    || fail "relaunch seed refused after the old agent was stopped: $(cat "$dir/seed.err")"
  assert_contains "$record" 'budget_prior_inclusive=0' 'unknown prior usage is not carried'
  assert_contains "$record" 'budget_launch_marker=FM_BUDGET_LAUNCH_fixture2' 'replacement binding is seeded'
  assert_grep 'budget-unknown task=task prior incarnation usage not carried over' "$dir/seed.err" \
    'unknown prior usage is reported'
  printf 'harness=pi\nkind=scout\nspawn_gen=s1\nworktree=%s\n' "$dir/wt" > "$dir/state/other.meta"
  "$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" seed - pi "$dir/wt" "" FM_BUDGET_LAUNCH_fixture1 \
    40000000 32000000 1500000 1200000 >> "$dir/state/other.meta"
  "$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" seed "$dir/state/other.meta" codex "$dir/wt" "$dir/native" \
    FM_BUDGET_LAUNCH_fixture3 40000000 32000000 1500000 1200000 > /dev/null 2>&1 \
    || fail 'relaunch from an unsupported-harness budget refused'
  pass 'relaunch never strands a task on unmeasurable prior usage'
}

test_bound_log_folds_appended_records_only() {
  local harness dir out
  for harness in claude codex; do
    dir="$TMP_ROOT/incremental-$harness"
    make_counter_case "$dir" "$harness"
    write_native "$dir" "$harness"
    out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
    if [ "$harness" = claude ]; then assert_usage "$out" 165 44; else assert_usage "$out" 2030 230; fi
    python3 - "$dir/native/project/main.jsonl" "$harness" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);lines=p.read_text().splitlines();last=json.loads(lines[-1])
# Overwrite an already-folded usage record in place; only appended bytes are read again.
lines[2]='#'*len(lines[2])
p.write_text(''.join(line+'\n' for line in lines))
if sys.argv[2]=='claude':
 last['message']['usage']['output_tokens']=12  # A later snapshot of message 'two'.
 rows=[last,dict(last,message={'id':'three','usage':{'input_tokens':1,'output_tokens':1}})]
else:
 last['payload']['info']['total_token_usage'].update(input_tokens=3000,cached_input_tokens=2700,output_tokens=45,total_tokens=3045)
 rows=[last]
with p.open('a') as f:f.write(''.join(json.dumps(row)+'\n' for row in rows))
PY
    out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
    if [ "$harness" = claude ]; then assert_usage "$out" 177 56; else assert_usage "$out" 3045 345; fi
  done
  pass 'bound native logs fold appended records into retained totals'
}

test_ordinary_watcher_checks_budget() {
  local dir out
  dir=$(make_case watcher-budget)
  make_counter_case "$dir" codex
  write_native "$dir" codex
  mkdir -p "$dir/data" "$dir/projects"
  python3 - "$dir/state/task.meta" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('budget_inclusive_stop=32000000','budget_inclusive_stop=2030'))
PY
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_PROJECTS_OVERRIDE="$dir/projects" FM_BACKEND=tmux \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" PATH="$dir/fakebin:$PATH" \
    FM_WATCH_ONCE=1 FM_WATCH_HANDLING_SUCCESSOR=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$TEST_BASH" "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2>&1 \
    || fail "ordinary watcher completes: $(cat "$dir/watch.out")"
  out=$(cat "$dir/watch.out")
  assert_contains "$out" 'budget-would-pause' 'ordinary watcher observes the native stop line'
  [ ! -e "$dir/state/task.status" ] || fail 'ordinary watcher dry-run raised a decision'
  pass 'ordinary watcher cycle runs the native budget check'
}

test_invalid_budget_sources_stay_unknown() {
  local dir="$TMP_ROOT/invalid" out
  make_counter_case "$dir" codex
  write_native "$dir" codex
  python3 - "$dir/state/task.meta" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('budget_prior_inclusive=0','budget_prior_inclusive=-1'))
PY
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  printf '%s\n' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="unknown",r' \
    || fail 'negative prior usage must not undercount the task'
  pass 'invalid prior consumption never becomes a smaller known total'
}

test_bad_native_shapes_are_unknown() {
  local shape dir harness out failures=
  for shape in negative-cache-write bad-usage-object counter-reset; do
    dir="$TMP_ROOT/shape-$shape"; harness=codex
    [ "$shape" != bad-usage-object ] || harness=claude
    make_counter_case "$dir" "$harness"
    write_native "$dir" "$harness"
    python3 - "$dir/native/project/main.jsonl" "$shape" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);rows=[json.loads(line) for line in p.read_text().splitlines()]
if sys.argv[2]=='negative-cache-write': rows[-1]['payload']['info']['total_token_usage']['cache_write_input_tokens']=-1
elif sys.argv[2]=='bad-usage-object': rows[-1]['message']['usage']=[]
else: rows[-1]['payload']['info']['total_token_usage'].update(input_tokens=500,cached_input_tokens=450,output_tokens=5,total_tokens=505)
p.write_text(''.join(json.dumps(row)+'\n' for row in rows))
PY
    if out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta" 2>&1) && \
      printf '%s\n' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="unknown"' 2>/dev/null; then
      :
    else
      failures="$failures $shape"
    fi
  done
  [ -z "$failures" ] || fail "malformed native usage must return unknown:$failures"
  pass 'malformed native shapes and counter resets are explicit unknowns'
}

test_codex_thread_token_records() {
  local dir="$TMP_ROOT/codex-thread" out
  make_counter_case "$dir" codex
  write_native "$dir" codex
  python3 - "$dir/native/project/main.jsonl" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);rows=[json.loads(line) for line in p.read_text().splitlines()]
for i,row in enumerate(rows[2:],2):
 u=row['payload']['info']['total_token_usage']
 rows[i]={'type':'token_usage_record','payload':{'response_id':'response-'+str(i),'thread_token_usage':u,'usage':u,'turn_token_usage':u}}
p.write_text(''.join(json.dumps(row)+'\n' for row in rows))
PY
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  assert_usage "$out" 2030 230
  pass 'Codex native thread-token records use cumulative thread totals once'
}

test_measure_defers_to_existing_meta_lock() {
  local dir="$TMP_ROOT/locked" lock out
  make_counter_case "$dir" codex
  write_native "$dir" codex
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  lock=$(fm_meta_lock_path "$dir/state/task.meta")
  fm_lock_try_acquire "$lock" || fail 'fixture holds task metadata lock'
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  fm_lock_release "$lock"
  printf '%s\n' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="unknown"' \
    || fail 'measurement must defer to a concurrent task metadata writer'
  [ ! -e "$dir/state/task.budget" ] || fail 'contended measurement mutated budget state'
  pass 'public measurement respects the existing task metadata lock'
}

test_unknown_diagnostic_is_attributed_and_deduplicated() {
  local dir="$TMP_ROOT/unknown" out
  make_counter_case "$dir" codex
  write_native "$dir" codex
  printf '{broken\n' >> "$dir/native/project/main.jsonl"
  printf 'enforce\n' > "$dir/config/budget-enforcement"
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir" 2>&1)
  assert_contains "$out" 'budget-unknown task=task harness=codex' 'unknown telemetry names its task and harness'
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir" 2>&1)
  [ -z "$out" ] || fail 'unchanged unknown telemetry repeated its diagnostic'
  [ ! -e "$dir/state/task.status" ] || fail 'unknown telemetry raised a speculative budget stop'
  pass 'unknown telemetry is attributed and logged once without interruption'
}

test_fresh_stop_and_native_identity_edges() {
  local dir="$TMP_ROOT/edges" out
  make_counter_case "$dir" codex
  write_native "$dir" codex
  cp "$dir/native/project/main.jsonl" "$dir/native/project/history.jsonl"
  python3 - "$dir/native/project/history.jsonl" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);rows=[json.loads(line) for line in p.read_text().splitlines()]
rows[0]['payload']['timestamp']='2000-01-01T00:00:00Z'
p.write_text(''.join(json.dumps(row)+'\n' for row in rows))
PY
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  assert_usage "$out" 2030 230
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir" 2>&1)
  [ -z "$out" ] || fail 'usage below both stop lines caused an event'
  python3 - "$dir/state/task.meta" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('budget_fresh_stop=1200000','budget_fresh_stop=230'))
PY
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir" 2>&1)
  assert_contains "$out" 'budget-would-pause' 'fresh stop triggers at exact equality independently'
  cp "$dir/native/project/main.jsonl" "$dir/native/project/newer.jsonl"
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  assert_usage "$out" 2030 230
  printf '{' >> "$dir/native/project/main.jsonl"
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  assert_usage "$out" 2030 230
  printf 'broken\n' >> "$dir/native/project/main.jsonl"
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  printf '%s\n' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="unknown"' \
    || fail 'malformed complete native record must be unknown'
  pass 'fresh stop, historical exclusion, retained binding, and partial records are handled'

  dir="$TMP_ROOT/ambiguous"
  make_counter_case "$dir" codex
  write_native "$dir" codex
  cp "$dir/native/project/main.jsonl" "$dir/native/project/other.jsonl"
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  printf '%s\n' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="unknown" and "ambiguous" in r["reason"],r' \
    || fail 'unbound ambiguous sessions must not pick the newest file'
  pass 'ambiguous native session discovery stays unknown'
}

test_claimed_interrupt_is_not_replayed_after_crash() {
  local dir="$TMP_ROOT/crash" out
  make_counter_case "$dir" codex
  write_native "$dir" codex
  cp -R "$ROOT/bin" "$dir/bin"
  printf 'enforce\n' > "$dir/config/budget-enforcement"
  python3 - "$dir/state/task.meta" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('budget_inclusive_stop=32000000','budget_inclusive_stop=2030'))
PY
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'claimed\n' >> "$FM_HOME/control.log"
read -r owner < "$FM_STATE_OVERRIDE/.meta-task.lock/pid"
case "$owner" in ''|*[!0-9]*) exit 1 ;; esac
kill -KILL "$owner"
SH
  if "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir" > "$dir/killed.out" 2>&1; then
    fail 'fixture failed to interrupt its own helper before completion recording'
  fi
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'completed\n' >> "$FM_HOME/control.log"
printf '%s\n' 'interrupt-delivered task harness=codex backend=tmux verified=agent-alive cancel=confirmed'
SH
  "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] || fail 'uncertain attempt was replayed blindly'
  assert_grep 'interrupt=uncertain:' "$dir/state/task.status" 'uncertain completion is explicit'
  python3 - "$dir/native/project/main.jsonl" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);row=json.loads(p.read_text().splitlines()[-1]);u=row['payload']['info']['total_token_usage']
u.update(input_tokens=3000,cached_input_tokens=2700,output_tokens=45,total_tokens=3045)
with p.open('a') as f:f.write(json.dumps(row)+'\n')
PY
  "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] || fail 'later native usage re-interrupted the same stop-line episode'
  [ "$(wc -l < "$dir/state/task.status" | tr -d ' ')" = 1 ] || fail 'continued usage duplicated the open budget decision'
  printf 'resolved: [key=budget-stop] continue\n' >> "$dir/state/task.status"
  python3 - "$dir/native/project/main.jsonl" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);row=json.loads(p.read_text().splitlines()[-1]);u=row['payload']['info']['total_token_usage']
u.update(input_tokens=4000,cached_input_tokens=3600,output_tokens=60,total_tokens=4060)
with p.open('a') as f:f.write(json.dumps(row)+'\n')
PY
  "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] || fail 'work after the answered decision was re-interrupted'
  pass 'crash uncertainty is preserved and one stop-line episode interrupts at most once'
}

test_deferred_interrupt_records_delivered_outcome() {
  local dir="$TMP_ROOT/deferred"
  make_counter_case "$dir" codex
  write_native "$dir" codex
  cp -R "$ROOT/bin" "$dir/bin"
  printf 'enforce\n' > "$dir/config/budget-enforcement"
  python3 - "$dir/state/task.meta" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('budget_inclusive_stop=32000000','budget_inclusive_stop=2030'))
PY
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'busy\n' >> "$FM_HOME/control.log"
echo 'error: another lifecycle action is already running for task' >&2
exit 1
SH
  "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir"
  [ ! -e "$dir/state/task.status" ] || fail 'a deferred interrupt opened the budget-stop decision'
  "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 2 ] || fail 'a deferred interrupt was not retried'
  [ ! -e "$dir/state/task.status" ] || fail 'a deferred retry opened the budget-stop decision'
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'delivered\n' >> "$FM_HOME/control.log"
printf '%s\n' 'interrupt-delivered task harness=codex backend=tmux verified=agent-alive cancel=confirmed'
SH
  "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir"
  "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 3 ] || fail 'a delivered interrupt was repeated'
  [ "$(wc -l < "$dir/state/task.status" | tr -d ' ')" = 1 ] || fail 'budget-stop decision was not opened exactly once'
  assert_grep 'interrupt=interrupt-delivered task' "$dir/state/task.status" 'decision records the delivered outcome'
  pass 'a deferred interrupt retries and its one decision records the delivered outcome'
}

spawn_reuse() {  # <home> <wt> <fakebin> <project>
  fm_test_run_spawn "$1" "$2" "$3" reuse "$4" --scout \
    --budget-inclusive-hard 40000000 --budget-inclusive-stop 32000000 \
    --budget-fresh-hard 1500000 --budget-fresh-stop 1200000
}

in_reuse_home() {  # <home> <wt> <fakebin> <command...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX=fake,1,0 \
    PATH="$fakebin:$PATH" "$@"
}

test_teardown_retires_budget_state_for_id_reuse() {
  local dir="$TMP_ROOT/reuse" home proj wt fakebin out
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" reuse
  fm_git_worktree "$proj" "$wt" reuse-fixture
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake" codex)
  out=$(spawn_reuse "$home" "$wt" "$fakebin" "$proj") || fail "first budgeted spawn failed: $out"
  # The previous incarnation claimed an interrupt and recorded a diagnostic.
  python3 - "$home/state/reuse.meta" current <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);meta=dict(line.split('=',1) for line in p.read_text().splitlines() if '=' in line)
limits=[40000000,32000000,1500000,1200000]
started=meta['budget_started_at'] if sys.argv[2]=='current' else '0'
episode={'allocation':[started,limits],'limits':limits,'key':'budget-stop-old','attempt':{'outcome':'old interrupt'},
 'sample':{'inclusive':1,'fresh':1,'observed_at':'then'}}
p.with_suffix('.budget').write_text(json.dumps({'sequence':1,'episode':episode})+'\n')
p.with_suffix('.budget-diagnostic').write_text('old')
PY
  printf 'report\n' > "$home/data/reuse/report.md"
  out=$(in_reuse_home "$home" "$wt" "$fakebin" "$ROOT/bin/fm-captain-hold.sh" complete reuse --none 2>&1) \
    || fail "captain-call inventory: $out"
  out=$(in_reuse_home "$home" "$wt" "$fakebin" "$ROOT/bin/fm-teardown.sh" reuse 2>&1) || fail "teardown failed: $out"
  [ ! -e "$home/state/reuse.budget" ] || fail 'teardown left the task budget state'
  [ ! -e "$home/state/reuse.budget-diagnostic" ] || fail 'teardown left the task budget diagnostic'
  fm_test_spawn_brief "$home" reuse
  out=$(spawn_reuse "$home" "$wt" "$fakebin" "$proj") || fail "reused task id spawn failed: $out"
  # Budget state left by an older allocation must not replay into the new one.
  python3 - "$home/state/reuse.meta" stale <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
limits=[40000000,32000000,1500000,1200000]
episode={'allocation':['0',limits],'limits':limits,'key':'budget-stop-old','attempt':{'outcome':'old interrupt'},
 'sample':{'inclusive':1,'fresh':1,'observed_at':'then'}}
p.with_suffix('.budget').write_text(json.dumps({'sequence':1,'episode':episode})+'\n')
PY
  printf 'enforce\n' > "$home/config/budget-enforcement"
  "$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" tick "$home/state/reuse.meta" "$home/config" "$home" > /dev/null 2>&1
  if [ -e "$home/state/reuse.status" ] && grep -q 'budget-stop-old' "$home/state/reuse.status"; then
    fail 'a previous allocation budget decision replayed into the reused task id'
  fi
  pass 'teardown retires budget state and a reused task id starts a clean allocation'
}

test_invalid_limits_refuse_before_provisioning() {
  local values out
  for values in '10 11 10 9' '10 9 10 11' '0 0 10 9' '01 1 10 9' '10 9 10 1.5' '9223372036854775808 1 10 1'; do
    # Fixture values are deliberate whitespace-separated arguments, never user input.
    # shellcheck disable=SC2086
    if "$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" validate $values >/dev/null 2>&1; then
      fail "invalid budget was accepted: $values"
    fi
  done
  if out=$(FM_HOME="$TMP_ROOT" "$TEST_BASH" "$ROOT/bin/fm-spawn.sh" task "$TMP_ROOT/missing-project" --scout \
    --budget-inclusive-hard 10 --budget-inclusive-hard 11 2>&1); then
    fail 'duplicate budget flag accepted'
  fi
  assert_contains "$out" 'duplicate --budget-inclusive-hard' 'duplicate flags refuse before project provisioning'
  pass 'invalid and duplicate numeric limits refuse before provisioning'
}

test_observer_never_binds_worker_budget() {
  local harness dir out
  for harness in codex claude; do
    dir="$TMP_ROOT/observer-$harness"
    make_counter_case "$dir" "$harness"
    write_native "$dir" "$harness"
    python3 - "$dir/native/project/main.jsonl" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.rename(p.with_name('worker.pending'))
p.write_text(p.with_name('worker.pending').read_text().replace('FM_BUDGET_LAUNCH_fixture1','observer prompt'))
PY
    out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
    printf '%s\n' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="pending"' \
      || fail "$harness observer captured the worker source"
    mv "$dir/native/project/worker.pending" "$dir/native/project/worker.jsonl"
    out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
    if [ "$harness" = claude ]; then assert_usage "$out" 165 44; else assert_usage "$out" 2030 230; fi
    printf '%s\n' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["source"].endswith("/worker.jsonl")' \
      || fail 'actual worker source was not retained'
  done
  pass 'post-launch observer sessions cannot capture the worker binding'
}

test_invalid_native_session_ids() {
  local harness dir out
  for harness in codex claude; do
    dir="$TMP_ROOT/session-id-$harness"
    make_counter_case "$dir" "$harness"
    write_native "$dir" "$harness"
    python3 - "$dir/native/project/main.jsonl" "$harness" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);rows=[json.loads(line) for line in p.read_text().splitlines()]
if sys.argv[2]=='codex':del rows[0]['payload']['id']
else:
 for row in rows:row['sessionId']=123
p.write_text(''.join(json.dumps(row)+'\n' for row in rows))
PY
    out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
    printf '%s\n' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]!="ok"' \
      || fail "$harness invalid session id accepted"
  done
  pass 'native binding requires a nonempty string session id'
}

test_claimed_attempt_survives_missing_telemetry() {
  local failure dir out
  for failure in missing corrupt; do
    dir="$TMP_ROOT/recover-$failure"
    make_counter_case "$dir" codex
    write_native "$dir" codex
    cp -R "$ROOT/bin" "$dir/bin"
    printf 'enforce\n' > "$dir/config/budget-enforcement"
    python3 - "$dir" <<'PY'
import pathlib,sys
d=pathlib.Path(sys.argv[1]);p=d/'state/task.meta';p.write_text(p.read_text().replace('budget_inclusive_stop=32000000','budget_inclusive_stop=2030'))
PY
    # Simulate the process stopping after prepare has durably claimed the action.
    out=$(python3 "$dir/bin/fm-task-budget.py" prepare "$dir/state/task.meta" "$dir/config")
    [ "$out" = interrupt ] || fail 'fixture did not persist its lifecycle claim'
    if [ "$failure" = missing ]; then rm "$dir/native/project/main.jsonl"
    else printf '{broken\n' >> "$dir/native/project/main.jsonl"; fi
    cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'unexpected replay\n' >> "$FM_HOME/control.log"
SH
    "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir" > "$dir/recovered.out" 2>&1
    "$TEST_BASH" "$dir/bin/fm-task-budget.sh" tick "$dir/state/task.meta" "$dir/config" "$dir" >> "$dir/recovered.out" 2>&1
    assert_grep 'interrupt=uncertain:' "$dir/state/task.status" 'lost telemetry cannot hide a claimed action'
    [ "$(wc -l < "$dir/state/task.status" | tr -d ' ')" = 1 ] || fail 'recovery duplicated its decision'
    [ ! -e "$dir/control.log" ] || fail 'recovery blindly replayed its interrupt'
    assert_grep 'budget-unknown task=task harness=codex' "$dir/recovered.out" 'telemetry failure stays visible separately'
  done
  pass 'claimed attempts reconcile once even when native telemetry disappears or corrupts'
}

test_live_guard_requires_stop_capability() {
  local dir="$TMP_ROOT/live-capability" tool out
  mkdir -p "$dir"
  for tool in dirname pwd tmux bash; do ln -s "$(command -v "$tool")" "$dir/$tool"; done
  printf '#!/bin/sh\nexit 99\n' > "$dir/claude"
  chmod +x "$dir/claude"
  if out=$(PATH="$dir:/usr/bin:/bin" FM_TASK_BUDGET_LIVE_E2E=1 "$TEST_BASH" "$ROOT/tests/fm-task-budget-live-e2e.test.sh" 2>&1); then
    fail 'Claude counter-only capability cannot pass the complete stop guard'
  fi
  assert_contains "$out" 'codex is not installed' 'guard diagnoses the required stop harness before spending tokens'
  pass 'live guard refuses a counter-only installation without stop verification'
}

test_native_context_precedes_launch() {
  local dir="$TMP_ROOT/context" out
  make_counter_case "$dir" codex
  write_native "$dir" codex
  python3 - "$dir/native/project/main.jsonl" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);rows=[json.loads(line) for line in p.read_text().splitlines()]
rows.insert(1,{'type':'response_item','payload':{'type':'message','role':'user','content':[
 {'type':'input_text','text':'# AGENTS.md instructions\n\n<INSTRUCTIONS>project context</INSTRUCTIONS>'},
 {'type':'input_text','text':'<environment_context>workspace context</environment_context>'}]}})
p.write_text(''.join(json.dumps(row)+'\n' for row in rows))
PY
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$dir/state/task.meta")
  assert_usage "$out" 2030 230
  pass 'native repository context can precede the initial worker launch prompt'
}

test_claude_initial_carrier_has_marker() {
  local dir="$TMP_ROOT/claude-carrier" home proj wt fakebin launch fixture_path out
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" carrier
  fm_git_worktree "$proj" "$wt" carrier-fixture
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake" claude)
  # The sandbox HOME must not send a version-manager shim to another config.
  ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$fakebin/python3"
  fixture_path=$(printf '%s\n' "$PATH" | tr ':' '\n' | sed '/\/mise\/shims$/d' | paste -sd : -)
  PATH="$fixture_path" FM_FAKE_LAUNCH_LOG="$dir/launch.sh" fm_test_run_spawn "$home" "$wt" "$fakebin" carrier "$proj" --scout \
    --budget-inclusive-hard 40000000 --budget-inclusive-stop 32000000 \
    --budget-fresh-hard 1500000 --budget-fresh-stop 1200000 > "$dir/spawn.out" \
    || fail "Claude budget spawn failed: $(cat "$dir/spawn.out")"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
python3 - "$@" <<'PY'
import json,os,pathlib,sys
pathlib.Path(os.environ['FM_BUDGET_CAPTURE']).write_text(json.dumps(sys.argv[1:]))
PY
SH
  launch=$(cat "$dir/launch.sh")
  fm_eval_launch "$launch" "$wt" "$fakebin" "FM_BUDGET_CAPTURE=$dir/args.json"
  python3 - "$dir/args.json" "$home" "$dir/prompt-doorbell" <<'PY'
import datetime,hashlib,json,pathlib,sys
args=json.load(open(sys.argv[1]));home=pathlib.Path(sys.argv[2]);meta=dict(line.split('=',1) for line in (home/'state/carrier.meta').read_text().splitlines() if '=' in line)
prompt=args[-1];assert len(prompt.splitlines())==1, 'the complete initial message must remain a canonical doorbell'
assert meta['budget_launch_fingerprint']==hashlib.sha256(prompt.encode()).hexdigest()
doorbells=[line for line in prompt.splitlines() if line.startswith(': Firstmate operational input waiting:')]
assert len(doorbells)==1, 'the record-backed doorbell must remain intact'
pathlib.Path(sys.argv[3]).write_text(prompt)
native=pathlib.Path(meta['budget_log_root'])/'fixture/main.jsonl';native.parent.mkdir(parents=True)
base={'sessionId':'carrier-session','cwd':meta['worktree'],'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat()}
rows=[dict(base,type='user',message={'role':'user','content':prompt}),dict(base,type='assistant',message={'id':'one','usage':{'input_tokens':11,'cache_creation_input_tokens':17,'output_tokens':7,'cache_read_input_tokens':101}})]
native.write_text(''.join(json.dumps(row)+'\n' for row in rows))
rows[0]['message']['content']='independent observer'
native.with_name('observer.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
PY
  [ "$("$ROOT/bin/fm-operational-input.sh" doorbell-kind < "$dir/prompt-doorbell")" = launch-brief ] \
    || fail 'budget launch changed the operational record doorbell'
  if command -v bun >/dev/null 2>&1; then
    FM_OP_MODULE="$ROOT/.claude/mods/firstmate-calm/lib/fm-operational-input.ts" FM_OP_PROMPT="$dir/prompt-doorbell" \
      bun -e 'const m = await import(process.env.FM_OP_MODULE); const text = await Bun.file(process.env.FM_OP_PROMPT).text(); const p = m.firstmateOperationalDoorbellPath(text); if (!p || m.firstmateOperationalRecordKind(await Bun.file(p).text()) !== "launch-brief") throw new Error("complete carrier failed TypeScript classifier");' \
      || fail 'complete launch argument fails the TypeScript operational mirror'
  else
    printf '# Bun absent: TypeScript mirror check not exercised\n'
  fi
  out=$("$TEST_BASH" "$ROOT/bin/fm-task-budget.sh" measure "$home/state/carrier.meta")
  assert_usage "$out" 136 35
  pass 'production Claude initial argv carries the marker and its valid record doorbell'
}

case "${FM_TEST_ONLY:-all}" in
  all|spawn) test_spawn_records_explicit_budget ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|counter) test_native_counters_deduplicate ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|stop) test_stop_line_dry_run_then_enforce_once ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|relaunch) test_relaunch_keeps_native_consumption ;;
esac
case "${FM_TEST_ONLY:-all}" in all|relaunch-unknown) test_relaunch_with_unknown_prior_usage_still_launches ;; esac
case "${FM_TEST_ONLY:-all}" in all|incremental) test_bound_log_folds_appended_records_only ;; esac
case "${FM_TEST_ONLY:-all}" in all|deferred) test_deferred_interrupt_records_delivered_outcome ;; esac
case "${FM_TEST_ONLY:-all}" in all|reuse)test_teardown_retires_budget_state_for_id_reuse ;; esac
case "${FM_TEST_ONLY:-all}" in
  all|watcher) test_ordinary_watcher_checks_budget ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|invalid) test_invalid_budget_sources_stay_unknown ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|shape) test_bad_native_shapes_are_unknown ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|thread) test_codex_thread_token_records ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|lock) test_measure_defers_to_existing_meta_lock ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|unknown) test_unknown_diagnostic_is_attributed_and_deduplicated ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|edges) test_fresh_stop_and_native_identity_edges ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|crash) test_claimed_interrupt_is_not_replayed_after_crash ;;
esac
case "${FM_TEST_ONLY:-all}" in
  all|limits) test_invalid_limits_refuse_before_provisioning ;;
esac
case "${FM_TEST_ONLY:-all}" in all|observer) test_observer_never_binds_worker_budget ;; esac
case "${FM_TEST_ONLY:-all}" in all|session-id) test_invalid_native_session_ids ;; esac
case "${FM_TEST_ONLY:-all}" in all|recovery) test_claimed_attempt_survives_missing_telemetry ;; esac
case "${FM_TEST_ONLY:-all}" in all|live-capability) test_live_guard_requires_stop_capability ;; esac
case "${FM_TEST_ONLY:-all}" in all|context) test_native_context_precedes_launch ;; esac
case "${FM_TEST_ONLY:-all}" in all|claude-carrier) test_claude_initial_carrier_has_marker ;; esac

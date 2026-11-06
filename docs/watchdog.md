# Assistant watchdog

`bin/fm-watchdog.sh` is a per-machine assistant that keeps firstmate captains and second mates moving when nobody is watching.
It catches the stalls an external supervisor otherwise has to clear by hand: frozen panes, timer loops after compaction, blocking dialogs, unsent input, unread input, unanswered decisions, quota floors, low context, and dead away daemons.
It acts with the cheapest step that can work, and it calls a cheap model only for a judgment a script cannot make.
It writes a short status file an outside reader can check every 40 minutes or so.

The script header owns the commands and files.
This page owns the behavior, the boundaries, and the `config/watchdog` keys.

## Where it runs

The watchdog runs outside every agent session, as a launchd agent on macOS or a systemd user service on Linux.
It is never hosted in a terminal pane, so a frozen captain cannot freeze it.

```sh
FM_HOME=<home> bin/fm-watchdog.sh render-launchd > ~/Library/LaunchAgents/$(FM_HOME=<home> bin/fm-watchdog.sh manager-name).plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/$(FM_HOME=<home> bin/fm-watchdog.sh manager-name).plist
FM_HOME=<home> bin/fm-watchdog.sh manager-status
```

`render-launchd` also creates `state/watchdog`, because launchd does not create the parent directory of its log file.
The rendered unit captures the current `PATH`, so render it from a shell that can run `claude`, `agy`, `tmux`, `orca`, `herdr`, and `jq`.
`run` holds a single-instance lock per owner home, so a second copy exits at once.
`once` runs one pass, and `scan` prints what the watchdog sees without acting.

## What it watches

The owner home's `config/watchdog` lists the homes to watch in `homes`; an absent key means the owner home alone.
Each listed home also brings the second mates registered in its `data/secondmates.md`.
The watchdog acts only on recorded endpoints: a home's `state/heartbeat.json` terminal, or for a second mate without its own heartbeat, the parent's `state/<id>.meta`.
Each home's recorded ship and scout workers are also read for a permission dialog, from that home's `state/<id>.meta` when `kind` is `ship` or `scout`.
That read uses the same dialog detector and the same away-session page as the home pane.
The watchdog does not answer, nudge, or restart a worker pane.
A worker endpoint that is no longer present is not read as a dialog.
It never lists or sweeps a shared terminal namespace.

Each pass reads only existing records and the recorded pane:

- the pane capture, its composer state, and the backend's busy verdict;
- the session lock holder, its liveness, its instance identity, and its CPU time between passes;
- the session transcript's age and its last assistant texts and tool calls;
- the wake queue, captain inbox notes, and open decision records;
- the heartbeat age, the away record, and the away daemon's pid;
- the context left, from the heartbeat, else the pane's auto-compact footer.

Pane signatures ignore digits and spinner glyphs, so a ticking clock does not hide a frozen pane.
Dialogs are read from the visible screen only where the backend gives a viewport capture (tmux, herdr, zellij, rex, and tern), so a dismissed dialog left in scrollback is not read as showing.
Other backends fall back to the last 60 captured rows.

## Symptoms and the action ladder

Each home gets at most one symptom per pass, in this order.
A home whose restart awaits pickup gets no action at all until that restart closes, and its health line reads `RESTART-AWAITING-PICKUP`.

| Symptom | Proof | Action |
| --- | --- | --- |
| Agent gone | Lock owner dead: the lock pid has exited and the shared lock contract does not prove the recorded session live | Restart once the transcript has been quiet for `frozen-secs`. Nothing is typed into the endpoint of a dead holder, and the other checks wait until it is live again. |
| Blocking dialog | Dialog structure on the visible screen | Feedback survey: press `0`. Model picker: the judge picks an option that keeps work going without spending, signing in, or buying; a picker that names an owner-reserved category or whose text looks like a secret is held as a gap and no model sees it. Words count from the rows below a rule above the options, or from all the last rows when no rule proves the boundary, so a picker under conversation with such a word also holds. A permission phrase counts across those same rows, so an unproven dialog with such a phrase is left alone and reported, and gets no key. Model and limit words count from the ruled rows above the options, or else from the paragraph above the options. An option label never counts. Only a row that opens by stating the limit or the switch proves a limit picker, such as `You have hit your weekly limit`, `Usage limit reached`, or `Switch to another model`. A bare model name, the word credits, or a bare `rate limit`, `usage limit`, `limit reached`, or `limit resets` does not. A usage-limit picker is not judged and gets no key: the watchdog writes a ledger row and a gap that names the eligible candidate from `reroute-candidates` when `quota-axi` and `bin/fm-quota-reroute.sh` find one. A recorded ship or scout worker pane of that home gets this same usage-limit handling, once per home or worker per `nudge-secs`, and the watchdog sends it no key. Any other picker is an unproven question: it gets no key and is reported as a gap. Permission: never answered, reported as a gap. While the home's away record is in away mode, not quiet mode, the owner is also paged through the home's alert channels, because nobody else will answer the dialog. The page carries no dialog text. A recorded ship or scout worker pane of that home gets this same permission page, with its own `nudge-secs` window, and the watchdog sends it no key. The ledger row records which dialog fired, with its text withheld when it looks like a secret. With alerts off or no channel, the page is recorded as refused and reported as a gap. The judge is asked about a picker at most once per `nudge-secs`, including in dry-run, and each answer comes from the pane of that pass. After two keys in an hour that leave the dialog showing, no more keys are pressed, no judge is asked, and the gap is reported. |
| Restart requested | `state/.watchdog-restart-request`, or context left at or below `restart-at-percent`. A heartbeat percent counts only for the current session and under `watcher-stale-secs`. | This applies only while a restart can run. Restart off, an escalated home, `do-not-touch`, no activity source, no `restart-command`, a backend with no launcher, a missing lock holder or mismatched anchor, or a time inside `restart-secs` is a gap, and the symptoms below still act. So is low context when the composer cannot take the nudge. A stable draft is handled as unsent input first, so the nudge can be delivered. Low context first nudges the session to write a full `data/handoff-*.md` and then `state/.watchdog-restart-request`. A handoff newer than the nudge plus the request file allows the restart after `restart-quiet-secs` of quiet. After `handoff-wait-secs` without both, the restart uses the lean handoff and the status file records the gap. A request with no earlier nudge restarts after the quiet time. The wait starts only when the nudge is delivered, and a nudge older than twice `handoff-wait-secs` no longer counts, so a later low asks again. |
| Timer loop | Three of the last five assistant texts repeat with only timer tools between them. A rapid burst is recovered without waiting input when the transcript has moved within `rapid-loop-secs`; older repeats need input that has waited `owed-input-secs`. An old burst with no waiting input is no loop. | Nudge, then restart, without claiming input is waiting. Near repeats go to the judge first, and only once input has waited `owed-input-secs`, with the recent assistant texts and tool calls. Events that look like a secret or name an owner-reserved category go to no model and leave the near repeat unconfirmed, with a reported gap. Only a `LOOP` answer takes this row. Any other answer, or no answer, leaves the rows below to run. An answer stands for `owed-input-secs`, and after that for as long as those events stay the same. |
| Frozen | Pane and transcript unchanged for `frozen-secs` while input has waited as long | Nudge, then restart. A running turn holds instead. |
| Unsent input | The composer holds the same pending text on two passes with no running turn | Press Enter once per two hours, unless a row from the first prompt row to the end of the window names a merge, deploy, release, publish, or force push; that refusal is reported as a gap. Rule and footer rows hide nothing from this check, and conversation rows above the first prompt row do not count. Enter also needs the whole draft proven. A bordered last prompt row needs a closed box with both borders inside the window. A plain last prompt row needs two equal rules of 40 or more characters at column 0 around it. Draft rows sit indented under the prompt glyph, so such a rule is the harness's. Any other draft gets no Enter and a reported gap: a plain or bare composer, an indented composer such as Grok or Cursor, a left-bar composer, a Claude composer on a named session whose top rule carries a title, a paste placeholder, or a draft taller than the read window or the capture. These are reported gaps and not supported coverage. |
| Unread input | Input has waited `owed-input-secs` with no running turn | Nudge. |

The frozen, agent-gone, and restart paths need a session transcript, and only the Claude transcript layout is read.
A subject with no readable transcript has no activity source, so those restarts are unavailable for it; its health line reads `NO-ACTIVITY-SOURCE` instead of `ok`, and the status file lists the gap.
A subject with no recorded terminal endpoint, such as a primary with no trusted lock session or a heartbeat whose terminal fields are unknown or whose session is not the one holding the lock, has no pane view; its health line reads `NO-ENDPOINT` instead of `ok`, and the status file lists the gap.

These checks run on every pass as well:

- An away record with a dead away daemon gets a nudge to re-arm it.
- A watcher heartbeat older than `watcher-stale-secs` is reported as a gap.
- Decisions open longer than `decision-secs` get one rolled-up nudge per home.
  A window later, the oldest unsettled decision goes to a council of blind seats, at most `council-per-pass` per home per pass and once per decision per `council-secs`.
  A unanimous `PROCEED` writes a ruling file under `data/watchdog/rulings/` and nudges the session to apply it; anything short of unanimity holds.
- A task whose latest status is a quota pause or block, or a pane showing a usage-limit picker, gets a ledger row and a gap that names the eligible candidate from `reroute-candidates` when `quota-axi` and `bin/fm-quota-reroute.sh` find one.
  A recorded ship or scout worker pane of that home gets the same usage-limit handling, once per home or worker per `nudge-secs`.
  The Signals paragraph in [`bin/fm-quota-reroute.sh`](../bin/fm-quota-reroute.sh) owns Claude-tooling and seed exemption.
  The verb header in [`bin/fm-control.sh`](../bin/fm-control.sh) owns close policy.
  The watchdog never changes the runtime.
  The live runbook is [`verification/quota-reroute.md`](verification/quota-reroute.md).

A nudge is written as a record-backed operational input in the subject's own home and typed into its pane as the record's doorbell.
It is never a captain inbox note, so a session cannot mistake it for the owner.
The text says it comes from the automated watchdog.

## Restart

A restart needs every one of these:

- `restart=on` and `mode=act`;
- a running-turn verdict of no and a measured CPU rate below `cpu-busy-pct`, where an unknown reading of either one holds;
- at least two independent kinds of signal, from rendered, filesystem, kernel, and records;
- a live lock holder that matches its recorded instance, or a dead holder, which gets no signal;
- an endpoint that is not on `do-not-touch`;
- fewer than `max-restarts` restarts for that home in the last day;
- at least `restart-secs` since the last restart of that home, for any symptom; a sooner restart holds and is reported as a gap.

A primary restart writes a lean handoff under `data/watchdog/handoffs/`, stops the old session process, and opens a new terminal on the same backend with `restart-command` and a prompt naming the handoff.
A muse `restart-command` with no approval-off flag is launched with `--yolo` added, as the key table states, and the restart's ledger row says `--yolo added by default`.
A proven draft goes into the handoff as an unsubmitted note, from the prompt row down to the last long rule below it. A rule with draft text below it stays in the note. A draft in a closed box runs from the box's first prompt row to its last body row, keeping inner rules and quoted rows. A non-empty Orca draft field also goes in, marked as an unsent draft or a harness suggestion. A draft proven present whose boundary is not proven, such as a plain composer or a paste placeholder on a composer that is not unknown, becomes a gap line in the handoff and the status file; Enter is still never pressed on it. An unknown composer, an empty capture, or a failed read with no draft text is no lost draft: the handoff says the composer state was unknown and no draft was seen.
On tmux the new window joins the old session; when that session closed with the old session process, a new session takes its place.
The new session proves it took over by running the `pickup <token>` command from that prompt after it holds the session lock; pickup also moves the [captain record](#captain-record).
The next pass marks the restart done only when that pickup record exists, a new live process holds the lock, and the away daemon runs again when the home is away.
A second mate restart goes through its parent with `bin/fm-control.sh <id> relaunch --note-file <handoff>`, which owns checkpoint and rollback.
A captain quit on purpose leaves the same dead lock as a crash, so the watchdog restarts it. To stop a home from being restarted, list it in `do-not-touch`.
Restarting `max-restarts` times in a day stops further restarts for that home, writes `state/watchdog/escalated/<home-basename>-<path-cksum>`, and files a self-heal issue; remove that file after review to re-enable restarts.

## Hard boundaries

The watchdog never merges, never deploys, never spends beyond existing caps, never messages the owner except the away permission page below, never accepts a `merge #...` autosuggestion, never tears down work, never types into panes on the `do-not-touch` list, and owner-reserved holds stay held.

- No typed text or pressed Enter can carry a merge, deploy, release, publish, or force-push word. A letter before the word does not change this, so `redeploy`, `automerge`, `prerelease`, and `republish` are refused; `emerge` and `submerge` are not merge words. Text with `push` followed later, on one row or across joined rows, by `--force`, `--force-with-lease`, a `-f` flag, or a `+` refspec such as `+main` is a force-push. The guard also reads a multi-row text joined with spaces and joined with nothing, so a continued command, a soft wrap, or a split word is refused; a handoff keeps the original rows.
- A decision keyed `captain-hold-*`, listed in `reserved-keys`, or naming money, merges, releases, deploys, credentials, security, production data, or deletion in its task, key, or summary is never nudged, put to council, or answered; it appears as a held gap.
- A decision whose task, key, or summary looks like a secret is held the same way, with no council and no ruling file. The gap omits a task or key name that looks like a secret.
- A nudge whose text names a merge, deploy, or release word is not sent and appears as a held gap.
- A nudge goes out only onto a composer read as empty. An unknown composer, an Orca draft, or a failed draft read holds the nudge as a gap. A held nudge counts toward `max-nudges`, so a frozen session still reaches the restart proof with nothing typed. A stable clean draft gets Enter once before that ladder.
- Model calls stop once the metered spend of the last day reaches `daily-max-usd`; each Claude call also carries `--max-budget-usd` from `judge-call-max-usd`.
- The only outward actions are a rate-limited self-heal issue through `bin/fm-self-heal-issue.sh`, on the repository named in `issue-repo` and under that script's own publication gate, and the away permission page.
- The away permission page goes only to the home's own [alert channels](wedge-alarm.md#channels), at most once per `nudge-secs` for the home pane and once per `nudge-secs` for each recorded ship or scout worker pane, and carries no dialog text.
- A restart stops one session process and opens a new terminal; it never removes a worktree, branch, file, or task.
- `tests/fm-watchdog.test.sh` proves each boundary with its own case.

Every action is rate-limited and recorded in `state/watchdog/actions.tsv` as `pending` before it runs, then closed as `done` or `failed`.
Dry-run and refused actions are recorded too.

## The judge

`models` is an ordered list of `harness:model` entries, tried in turn until one gives an answer in the expected form.
`claude:<model>` runs `claude -p` with no tools, no settings, no MCP servers, and no saved session.
Its account is `claude-config-dir`, or else the owner's `config/claude-account`, where `ordinary` means `CLAUDE_CONFIG_DIR` is unset.
An invalid pin makes this model unavailable.
`agy:<model>` runs `agy -p` with slash commands disabled.
Every call is bounded by `judge-timeout-secs`, its prompt by `judge-max-chars`, and every call is logged in `state/watchdog/model-calls.tsv` with its tokens and cost when the CLI reports them.
With no model available, the watchdog still takes every deterministic action and reports each skipped judgment as a gap.

## Status file

`data/watchdog/status.md` is rewritten atomically after every pass and stays under 40 lines.
It holds the update time, a `STALE IF NOT UPDATED BY` line, the model state and the spend of the last day, one health line per home, the actions since the last read, and the open gaps.
Each health line ends with that home's captain from the [captain record](#captain-record): its lock pid, its `alive` verdict, its terminal, and its last move time.
A reader runs `ack-read` after reading, so the next status lists only newer actions.

## Captain record

Each `once` or `scan` pass rewrites `<home>/state/watchdog/captain` for every watched home, atomically, as `key=value` lines.
It is the durable answer to which process and which terminal are that home's live captain, so an outside supervisor never has to infer it from pane titles, tab state, or screen text.

| Key | Meaning |
| --- | --- |
| `owner` | `session:<id>` for the lock's recorded session, else `pid:<pid>`, else `none` |
| `lock_pid` | The pid on the session lock's first line |
| `session` | The lock's recorded session id |
| `alive` | `live`, `dead`, `unconfirmed`, or `none` |
| `backend`, `target` | The captain's terminal, empty while it is not proven |
| `moved_at` | Epoch of the last move to a new owner or a new terminal |
| `lock_at` | Newest mtime of `state/.lock` and `state/.lock-session` when this record was written |
| `checked_at` | Epoch of this write |
| `source` | `watchdog` for a pass, `pickup` for a restarted session |

`live` means the lock pid runs and matches its recorded instance, or the shared lock contract proves the recorded session live, as for a Codex session whose first-line pid has exited.
`dead` means the lock pid has exited and nothing proves the session live, whatever its old pane still shows.
`unconfirmed` means the pid runs but does not match its recorded instance and nothing else proves it, so the pid may belong to another process; a restart refuses and sends it no signal.
`none` means no lock holder is recorded.
A heartbeat proves the terminal only when it names the session that holds the lock and its generated time is not older than `lock_at`.
It must also be written inside the lock owner: its writer's harness anchor pid is the lock pid, or its writer's trusted session id is the recorded session.
A heartbeat written outside the owner, such as by an away daemon in its own detached terminal, proves no terminal.
So a retired pane is never named, even when a resumed session keeps the same session id in a new terminal.
A second mate whose heartbeat names another session, or none, uses its parent's record of its endpoint.
A heartbeat older than `lock_at` leaves the terminal empty, unproven, for a second mate too.
An unchanged owner keeps the recorded terminal while none is proven now, but only while `lock_at` is unchanged.
After a lock rewrite the old terminal is never carried forward, and the terminal stays empty until a fresh heartbeat proves it.
A new owner stamps `moved_at` with `lock_at`.
Under the same owner, a proven terminal that differs from that owner's last proven terminal stamps `moved_at` with the pass time.
The watchdog keeps that last proven terminal and its owner in its private per-home subjects record, so an unproven window neither loses a move nor names the old pane.
A new owner's first proven terminal is not a move, because the last proven terminal of the previous owner is never compared.
A terminal that only becomes known is not a move, and a lock rewrite proven back on the same terminal, such as a Codex helper re-anchor, is not a move.
`pickup` rewrites the record at once with the new lock pid, the terminal the restarted session runs in, `lock_at`, and a `moved_at` stamp.
A supervisor that restarts captains itself treats a `live` record, or a `moved_at` newer than its own evidence, as a captain already in place.
A pane the record does not name is not the live captain, and an empty terminal means the captain's pane is not proven yet.

## Configuration (config/watchdog)

`config/watchdog` is local and gitignored, with one `key=value` per line.
The last line for a key wins, and `#` lines are comments.
An absent file means dry-run on the owner home alone.

| Key | Default | Meaning |
| --- | --- | --- |
| `homes` | the owner home | Comma-separated homes to watch, each with its registered second mates |
| `mode` | `dry-run` | `act` takes actions; anything else records them as `dry-run` |
| `restart` | `off` | `on` allows restarts when `mode=act` |
| `restart-command` | none | Starts a new captain session and appends the prompt as one argument. When the command word, after any leading `NAME=value`, `env`, `exec`, or `command` and again after `&&`, `||`, `;`, or `|`, is `muse`, `muse-bin`, or `muse-bin-*`, or a path ending in one of them, with one layer of surrounding quotes removed, and the command carries none of `--yolo`, `--disable-approval`, `--approval-mode never`, or `--approval-mode=never`, `--yolo` is inserted as the first argument after the first such word. Any other command runs unchanged, even when another word names muse. |
| `do-not-touch` | none | Comma-separated homes, home names, or terminal targets never typed into or restarted |
| `models` | `claude:haiku,agy:gemini-3.8-flash-low` | Ordered judge models; empty disables the judge |
| `council-seats` | the `models` list | Comma-separated blind council seats |
| `daily-max-usd` | `1.00` | Metered model spend cap over the last day |
| `judge-call-max-usd` | `0.05` | Per-call Claude budget |
| `judge-max-chars` | `6000` | Prompt size bound |
| `judge-timeout-secs` | `120` | Per-call time bound |
| `claude-config-dir` | the owner home's `config/claude-account`, then the inherited environment and the CLI's own default | Claude config directory for judge calls |
| `claude-config-dirs` | none | Extra Claude config directories searched for session transcripts |
| `reserved-keys` | none | Comma-separated decision keys always held for the owner |
| `reroute-candidates` | none | Comma-separated `harness:model` candidates for quota reroute nudges |
| `issue-repo` | none | `owner/repo` for self-heal issues; empty reports a gap instead |
| `interval-secs` | `120` | Seconds between passes in `run` |
| `frozen-secs` | `900` | Quiet time that counts as frozen |
| `owed-input-secs` | `900` | Wait that counts as unread input |
| `decision-secs` | `1800` | Wait before an open decision is nudged |
| `rapid-loop-secs` | `180` | Span inside which repeats count as a rapid loop |
| `restart-at-percent` | `8` | Context left that requests a restart |
| `restart-quiet-secs` | `120` | Quiet time before a requested restart |
| `handoff-wait-secs` | `600` | Time a low-context session has to write its full handoff and restart request |
| `pickup-secs` | `600` | Time a restart has to prove its pickup |
| `max-nudges` | `2` | Nudges for one symptom in two hours before a restart |
| `max-restarts` | `2` | Restarts in a day before the loop stops and escalates |
| `cpu-busy-pct` | `15` | CPU rate of the lock holder that counts as busy |
| `nudge-secs` | `900` | Minimum time between nudges for one symptom, between judge calls about a model-switch picker, and between away permission pages for one home pane or one worker pane |
| `key-secs` | `120` | Minimum time between dialog keys |
| `enter-secs` | `300` | Minimum time between recorded decisions on unsent input; a real Enter goes at most once in two hours |
| `council-secs` | `21600` | Minimum time between councils on one decision |
| `council-per-pass` | `1` | Councils per home per pass |
| `quota-secs` | `600` | Quota park age before a reroute nudge |
| `restart-secs` | `7200` | Minimum time between restarts of one home |
| `watcher-stale-secs` | `900` | Heartbeat age reported as a stale watcher |
| `relaunch-timeout-secs` | `900` | Bound on a second mate relaunch |
| `call-timeout-secs` | `20` | Bound on each pane capture |
| `key-settle-secs` | `2` | Wait after a key before checking its effect |

## Verification

`tests/fm-watchdog.test.sh` drives every symptom, ladder step, and boundary against real tmux panes on a private socket, real lock holders, and real records, with fake model CLIs.
`tests/fm-watchdog-live.test.sh` reads real installed Claude Code panes without spending tokens; [`verification/runtime-backends.md`](verification/runtime-backends.md) records its dated results.

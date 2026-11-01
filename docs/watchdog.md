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
| Agent gone | Lock holder dead | Restart once the transcript has been quiet for `frozen-secs`. Nothing is typed into the endpoint of a dead holder, and the other checks wait until it is live again. |
| Blocking dialog | Dialog structure on the visible screen | Feedback survey: press `0`. Model or limit picker: the judge picks an option that keeps work going without spending, signing in, or buying; a picker that names an owner-reserved category is held as a gap and no model sees it. Words count from the rows below a rule above the options, or from all the last rows when no rule proves the boundary, so a picker under conversation with such a word also holds. A permission phrase counts across those same rows, so an unproven dialog with such a phrase is left alone and reported, and gets no key. Model and limit words count from the ruled rows above the options, or else from the paragraph above the options. An option label never counts. Only a row that opens by stating the limit or the switch proves a limit picker, such as `You have hit your weekly limit`, `Usage limit reached`, or `Switch to another model`. A bare model name, the word credits, or a bare `rate limit`, `usage limit`, `limit reached`, or `limit resets` does not. Any other picker is an unproven question: it gets no key and is reported as a gap. Permission: never answered, reported as a gap. After two keys in an hour that leave the dialog showing, no more keys are pressed and the gap is reported. |
| Restart requested | `state/.watchdog-restart-request`, or context left at or below `restart-at-percent`. A heartbeat percent counts only for the current session and under `watcher-stale-secs`. | This applies only while a restart can run. Restart off, an escalated home, `do-not-touch`, no activity source, no `restart-command`, a backend with no launcher, a missing lock holder or mismatched anchor, or a time inside `restart-secs` is a gap, and the symptoms below still act. So is low context when the composer cannot take the nudge. A stable draft is handled as unsent input first, so the nudge can be delivered. Low context first nudges the session to write a full `data/handoff-*.md` and then `state/.watchdog-restart-request`. A handoff newer than the nudge plus the request file allows the restart after `restart-quiet-secs` of quiet. After `handoff-wait-secs` without both, the restart uses the lean handoff and the status file records the gap. A request with no earlier nudge restarts after the quiet time. The wait starts only when the nudge is delivered, and a nudge older than twice `handoff-wait-secs` no longer counts, so a later low asks again. |
| Timer loop | Three of the last five assistant texts repeat with only timer tools between them, and either all repeats fall inside `rapid-loop-secs` or input has waited `owed-input-secs` | Nudge, then restart. Near repeats go to the judge first. |
| Frozen | Pane and transcript unchanged for `frozen-secs` while input has waited as long | Nudge, then restart. A running turn holds instead. |
| Unsent input | The composer holds the same pending text on two passes with no running turn | Press Enter once per two hours, unless a row from the first prompt row to the end of the window names a merge, deploy, release, publish, or force push; that refusal is reported as a gap. Rule and footer rows hide nothing from this check, and conversation rows above the first prompt row do not count. Enter also needs the whole draft proven. A bordered last prompt row needs a closed box with both borders inside the window. A plain last prompt row needs two equal rules of 40 or more characters at column 0 around it. Draft rows sit indented under the prompt glyph, so such a rule is the harness's. Any other draft gets no Enter and a reported gap: a plain or bare composer, an indented composer such as Grok or Cursor, a left-bar composer, a Claude composer on a named session whose top rule carries a title, a paste placeholder, or a draft taller than the read window or the capture. These are reported gaps and not supported coverage. |
| Unread input | Input has waited `owed-input-secs` with no running turn | Nudge. |

The frozen, agent-gone, and restart paths need a session transcript, and only the Claude transcript layout is read.
A subject with no readable transcript has no activity source, so those restarts are unavailable for it; its health line reads `NO-ACTIVITY-SOURCE` instead of `ok`, and the status file lists the gap.

These checks run on every pass as well:

- An away record with a dead away daemon gets a nudge to re-arm it.
- A watcher heartbeat older than `watcher-stale-secs` is reported as a gap.
- Decisions open longer than `decision-secs` get one rolled-up nudge per home.
  A window later, the oldest unsettled decision goes to a council of blind seats, at most `council-per-pass` per home per pass and once per decision per `council-secs`.
  A unanimous `PROCEED` writes a ruling file under `data/watchdog/rulings/` and nudges the session to apply it; anything short of unanimity holds.
- A task whose latest status is a quota pause or block gets a nudge to reroute it, naming the eligible candidate from `reroute-candidates` when `quota-axi` and `bin/fm-quota-choose.sh` find one.

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
A proven draft goes into the handoff as an unsubmitted note, from the prompt row down to the last long rule below it. A rule with draft text below it stays in the note. A draft in a closed box runs from the box's first prompt row to its last body row, keeping inner rules and quoted rows. A non-empty Orca draft field also goes in, marked as an unsent draft or a harness suggestion. A draft proven present whose boundary is not proven, such as a plain composer or a paste placeholder on a composer that is not unknown, becomes a gap line in the handoff and the status file; Enter is still never pressed on it. An unknown composer, an empty capture, or a failed read with no draft text is no lost draft: the handoff says the composer state was unknown and no draft was seen.
On tmux the new window joins the old session; when that session closed with the old session process, a new session takes its place.
The new session proves it took over by running the `pickup <token>` command from that prompt after it holds the session lock.
The next pass marks the restart done only when that pickup record exists, a new live process holds the lock, and the away daemon runs again when the home is away.
A second mate restart goes through its parent with `bin/fm-control.sh <id> relaunch --note-file <handoff>`, which owns checkpoint and rollback.
A captain quit on purpose leaves the same dead lock as a crash, so the watchdog restarts it. To stop a home from being restarted, list it in `do-not-touch`.
Restarting `max-restarts` times in a day stops further restarts for that home, writes `state/watchdog/escalated/<home-basename>-<path-cksum>`, and files a self-heal issue; remove that file after review to re-enable restarts.

## Hard boundaries

The watchdog never merges, never deploys, never spends beyond existing caps, never messages the owner directly, never accepts a `merge #...` autosuggestion, never tears down work, never types into panes on the `do-not-touch` list, and owner-reserved holds stay held.

- No typed text or pressed Enter can carry a merge, deploy, release, publish, or force-push word. A letter before the word does not change this, so `redeploy`, `automerge`, `prerelease`, and `republish` are refused; `emerge` and `submerge` are not merge words. Text with `push` followed later, on one row or across joined rows, by `--force`, `--force-with-lease`, a `-f` flag, or a `+` refspec such as `+main` is a force-push. The guard also reads a multi-row text joined with spaces and joined with nothing, so a continued command, a soft wrap, or a split word is refused; a handoff keeps the original rows.
- A decision keyed `captain-hold-*`, listed in `reserved-keys`, or naming money, merges, releases, deploys, credentials, security, production data, or deletion in its task, key, or summary is never nudged, put to council, or answered; it appears as a held gap.
- A nudge whose text names a merge, deploy, or release word is not sent and appears as a held gap.
- A nudge goes out only onto a composer read as empty. An unknown composer, an Orca draft, or a failed draft read holds the nudge as a gap. A held nudge counts toward `max-nudges`, so a frozen session still reaches the restart proof with nothing typed. A stable clean draft gets Enter once before that ladder.
- Model calls stop once the metered spend of the last day reaches `daily-max-usd`; each Claude call also carries `--max-budget-usd` from `judge-call-max-usd`.
- The only outward action is a rate-limited self-heal issue through `bin/fm-self-heal-issue.sh`, on the repository named in `issue-repo` and under that script's own publication gate.
- A restart stops one session process and opens a new terminal; it never removes a worktree, branch, file, or task.
- `tests/fm-watchdog.test.sh` proves each boundary with its own case.

Every action is rate-limited and recorded in `state/watchdog/actions.tsv` as `pending` before it runs, then closed as `done` or `failed`.
Dry-run and refused actions are recorded too.

## The judge

`models` is an ordered list of `harness:model` entries, tried in turn until one gives an answer in the expected form.
`claude:<model>` runs `claude -p` with no tools, no settings, no MCP servers, and no saved session.
`agy:<model>` runs `agy -p` with slash commands disabled.
Every call is bounded by `judge-timeout-secs`, its prompt by `judge-max-chars`, and every call is logged in `state/watchdog/model-calls.tsv` with its tokens and cost when the CLI reports them.
With no model available, the watchdog still takes every deterministic action and reports each skipped judgment as a gap.

## Status file

`data/watchdog/status.md` is rewritten atomically after every pass and stays under 40 lines.
It holds the update time, a `STALE IF NOT UPDATED BY` line, the model state and the spend of the last day, one health line per home, the actions since the last read, and the open gaps.
A reader runs `ack-read` after reading, so the next status lists only newer actions.

## Configuration (config/watchdog)

`config/watchdog` is local and gitignored, with one `key=value` per line.
The last line for a key wins, and `#` lines are comments.
An absent file means dry-run on the owner home alone.

| Key | Default | Meaning |
| --- | --- | --- |
| `homes` | the owner home | Comma-separated homes to watch, each with its registered second mates |
| `mode` | `dry-run` | `act` takes actions; anything else records them as `dry-run` |
| `restart` | `off` | `on` allows restarts when `mode=act` |
| `restart-command` | none | Command that starts a new captain session; the prompt is appended as one argument |
| `do-not-touch` | none | Comma-separated homes, home names, or terminal targets never typed into or restarted |
| `models` | `claude:haiku,agy:gemini-3.8-flash-low` | Ordered judge models; empty disables the judge |
| `council-seats` | the `models` list | Comma-separated blind council seats |
| `daily-max-usd` | `1.00` | Metered model spend cap over the last day |
| `judge-call-max-usd` | `0.05` | Per-call Claude budget |
| `judge-max-chars` | `6000` | Prompt size bound |
| `judge-timeout-secs` | `120` | Per-call time bound |
| `claude-config-dir` | the home's `config/claude-account` | Claude config directory for judge calls |
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
| `nudge-secs` | `900` | Minimum time between nudges for one symptom |
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

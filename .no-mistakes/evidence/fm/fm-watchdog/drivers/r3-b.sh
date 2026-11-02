. /tmp/wdt/lib.sh
clearpane() { tmux send-keys -t "$T" Escape; sleep 1; tmux send-keys -t "$T" C-c; sleep 2; }
settle() { for i in 1 2 3 4 5 6 7 8; do s=$(wd scan | awk -v sub_="$1" '$1=="subject"&&$2==sub_{f=1;next} $1=="subject"{f=0} f&&/pane_static/{print $1}'); s=${s#pane_static=}; s=${s%s}; [ "${s:-0}" -ge 6 ] && return 0; sleep 4; done; return 1; }
echo "revision: $(git -C $REPO rev-parse HEAD); date: $(date -u +%FT%TZ)"
A="still waiting on the timer armed alpha"; B="still waiting on the timer armed beta"; C="still waiting on the timer armed gamma"
hdr "N1 near loop, real haiku, real Claude TUI pane: LOOP, ladder nudge, no second model call for the same evidence"
mkr n1 "models=claude:haiku"; transcript 3000 600 "$A" "$B" "$C"; owe 3000; wd scan | sed -n 4p; pass_once; led | cut -c1-140; calls; typed; stat_ | sed -n 1,2p; clearpane; pass_once; echo "model calls now: $(calls | wc -l | tr -d ' ')"
hdr "N2 adversarial: no model; near loop + static pane reaches frozen recovery"
mkr n2; transcript 3000 600 "$A" "$B" "$C"; owe 3000; settle n2; pass_once; led | cut -c1-140; stat_ | sed -n 1,2p; stat_ | grep -i unconfirmed; typed
hdr "N3 adversarial: daily cap spent; near loop + static pane reaches frozen recovery, no call spends"
mkr n3 "models=claude:haiku
daily-max-usd=0"; transcript 3000 600 "$A" "$B" "$C"; owe 3000; settle n3; pass_once; led | cut -c1-140; echo "model call rows: $(calls | wc -l | tr -d ' ')"; stat_ | sed -n 1,2p; typed
hdr "N4 near repeats showing real progress, real haiku says WORK; deterministic recovery still runs"
mkr n4 "models=claude:haiku"; transcript 3000 600 "Waiting for the CI run now: build job passed" "Waiting for the CI run now: test job passed, lint running" "Waiting for the CI run now: every job passed, opening the PR and picking up the next ticket"; owe 3000; settle n4; pass_once; led | cut -c1-140; calls; stat_ | sed -n 1,2p; typed

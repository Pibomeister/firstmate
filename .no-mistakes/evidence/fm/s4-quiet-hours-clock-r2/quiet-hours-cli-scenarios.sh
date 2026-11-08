#!/usr/bin/env bash
# Drives bin/fm-quiet-hours.sh against a disposable FM_HOME under TZ=Asia/Tokyo.
set -u
cd "$1"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-qh.XXXXXX"); mkdir -p "$LAB/config"
export FM_HOME="$LAB" TZ=Asia/Tokyo
unset FM_CONFIG_OVERRIDE
ep() { TZ=${Z:-America/Costa_Rica} date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
show() { ZN=${Z:-America/Costa_Rica}; e=$(ep "$1"); out=$(bin/fm-quiet-hours.sh at "$e"); rc=$?
  f=$(sed -E 's/.*(ends|next)=([0-9]+).*/\2/' <<<"$out"); 
  printf '%-22s %-20s rc=%s %-45s -> %s\n' "$ZN" "$1" "$rc" "$out" "$(TZ=$ZN date -r "$f" '+%a %F %T')"; }
echo "host TZ=$TZ, home=$LAB (no config/escalation -> default zone)"
for t in "2026-11-03 21:59:59" "2026-11-03 22:00:00" "2026-11-04 07:59:59" "2026-11-04 08:00:00" \
         "2026-11-06 16:59:59" "2026-11-06 17:00:00" "2026-11-06 23:00:00" "2026-11-07 03:00:00" \
         "2026-11-08 12:00:00" "2026-11-09 07:59:59" "2026-11-09 08:00:00" "2026-11-05 12:00:00"; do show "$t"; done
echo "--- fixed-clock seam (no epoch arg): FM_TEST_SEAM=1 FM_NOW=Sat 03:00 CR"
FM_TEST_SEAM=1 FM_NOW=$(ep "2026-11-07 03:00:00") bin/fm-quiet-hours.sh at; echo "rc=$?"
echo "--- config key quiet-hours-zone=Europe/Berlin (DST end 2026-10-25)"
printf 'quiet-hours-zone = Europe/Berlin\n' > "$LAB/config/escalation"
Z=Europe/Berlin show "2026-11-03 22:00:00"; Z=Europe/Berlin show "2026-10-24 23:30:00"
echo "--- adversarial"
printf 'quiet-hours-zone=../../etc/passwd\n' > "$LAB/config/escalation"; bin/fm-quiet-hours.sh at 0; echo "traversal rc=$?"
printf 'quiet-hours-zone=Mars/Olympus\n' > "$LAB/config/escalation"; bin/fm-quiet-hours.sh at 0; echo "unknown zone rc=$?"
rm "$LAB/config/escalation"
bin/fm-quiet-hours.sh at 12abc; echo "bad epoch rc=$?"
bin/fm-quiet-hours.sh at 1 2; echo "two args rc=$?"
bin/fm-quiet-hours.sh bogus >/dev/null 2>&1; echo "unknown subcommand rc=$?"
rm -rf "$LAB"

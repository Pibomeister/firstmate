#!/usr/bin/env bash
# Fake Claude idle screen with the session survey; reads one raw key.
clear
printf 'some work\n● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n'
stty -echo -icanon min 1
k=$(dd bs=1 count=1 2>/dev/null)
clear
printf 'some work\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\nGOT_KEY=[%s]\n' "$k"
sleep 600

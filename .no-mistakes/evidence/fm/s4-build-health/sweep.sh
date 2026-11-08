. "$ROOT/bin/fm-context-footer-lib.sh"; . "$ROOT/bin/fm-warm-compact-lib.sh"; . "$ROOT/bin/fm-context-reading-lib.sh"; . "$ROOT/bin/fm-compact-point-lib.sh"
mk(){ jq -nc --argjson t "$1" '{type:"assistant",timestamp:"2026-11-08T00:00:00Z",message:{model:"m",content:[{type:"text",text:"x"}],usage:{input_tokens:2,cache_read_input_tokens:($t-1002),cache_creation_input_tokens:1000,output_tokens:5}}}' > "$T/t.jsonl"; }
mism=0; n=0
for w in 3 100000 200000 167000; do for u in 1002 1003 2000 50000 91000 91001 91500 92000 99999 100000 120000 170001 199999 200000 250000; do
  mk $u; d=$(fm_context_derived_percent "$T/t.jsonl" $w); c=$(fm_compact_left_percent $u $w); n=$((n+1))
  [ "$d" = "$c" ] || { mism=$((mism+1)); echo "MISMATCH w=$w u=$u derived=$d compact=$c"; }
  case "$w:$u" in 100000:91500|100000:100000|100000:120000|100000:50000|200000:170001) echo "w=$w used=$u derived=$d compact_left=$c";; esac
done; done; echo "cases=$n mismatches=$mism"

F1 | open | security | run.sh:4 | `eval "echo Hello $name"` runs attacker-controlled input as shell code (command injection); replace with `printf 'Hello %s\n' "$name"` and drop `eval`.
F2 | noted | none | run.sh:3 | A missing argument silently prints "Hello " and exits 0; validate with `name=${1:?usage: run.sh <name>}`.

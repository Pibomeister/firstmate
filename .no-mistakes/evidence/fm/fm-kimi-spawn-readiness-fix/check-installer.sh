#!/bin/bash
set -eu
V=$PWD/.kimi-validation
LAB=$V/installer-home
mkdir -p "$LAB/.kimi-code"
export HOME=$LAB UV_PYTHON_INSTALL_DIR=$V/python FM_KIMI_PYTHON_PREFIXES=''
printf '# Disposable settings; no credentials.\n[ui]\nshow_usage = true\n' > "$LAB/.kimi-code/config.toml"
cp "$LAB/.kimi-code/config.toml" "$V/installer-original.toml"
printf 'Default interpreter: '
python3 --version
printf 'Default interpreter tomllib: '
if python3 -c 'import tomllib' 2>/dev/null; then echo available; else echo unavailable; fi
printf 'Fallback interpreter: '
"$V/python/cpython-3.12.12-macos-aarch64-none/bin/python3" --version
bin/fm-kimi-turnend-hook.sh install
cat "$LAB/.kimi-code/config.toml"
cp "$LAB/.kimi-code/config.toml" "$V/installed-once.toml"
bin/fm-kimi-turnend-hook.sh install
cmp "$V/installed-once.toml" "$LAB/.kimi-code/config.toml"
printf 'Second install preserved config bytes.\n'
bin/fm-kimi-turnend-hook.sh remove
cmp "$V/installer-original.toml" "$LAB/.kimi-code/config.toml"
[ ! -e "$LAB/.kimi-code/fm-turn-end.sh" ]
[ ! -e "$LAB/.kimi-code/fm-turn-end.d" ]
printf 'Remove restored original config bytes and removed hook and registry.\n'
printf '[broken\n' > "$LAB/.kimi-code/config.toml"
cp "$LAB/.kimi-code/config.toml" "$V/installer-malformed.toml"
rc=0
bin/fm-kimi-turnend-hook.sh install || rc=$?
[ "$rc" -ne 0 ]
cmp "$V/installer-malformed.toml" "$LAB/.kimi-code/config.toml"
printf 'Malformed config refusal preserved original bytes, exit=%s.\n' "$rc"

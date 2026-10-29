#!/bin/bash
set -eu
export HOME=$PWD/.kimi-validation/regression-home UV_PYTHON_INSTALL_DIR=$PWD/.kimi-validation/python FM_KIMI_PYTHON_PREFIXES=''
rc=0
printf 'BASE 12f3759, default Python 3.9.6, real workspace uv Python 3.12 available:\n'
bash .kimi-validation/base-kimi-hook.sh install || rc=$?
printf 'base_exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
[ ! -e "$HOME/.kimi-code/fm-turn-end.sh" ]
printf '\nTARGET e153b52, identical environment:\n'
bin/fm-kimi-turnend-hook.sh install
printf 'target_exit=0\n'
[ -x "$HOME/.kimi-code/fm-turn-end.sh" ]
cat "$HOME/.kimi-code/config.toml"
bin/fm-kimi-turnend-hook.sh remove

#!/usr/bin/env bash
# Host run request R0: read-only preflight on the Mac Mini.
# Changes nothing: no start, install, mount or write outside stdout.
# Inspects the existing Colima profile without starting or editing it.
set -u
ROOT="${FIXTURE_HOST_ROOT:-/Users/picazosmacmini/factory-vfs-pilot}"
say() { printf '\n## %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1 | sed 's/^/  /'; }

say "OS"; run sw_vers; run uname -m; run df -h "$HOME"
say "Tools"; for t in bash git curl tar shasum pgrep docker colima limactl; do printf '%-8s %s\n' "$t" "$(command -v "$t" || echo MISSING)"; done
run bash --version
say "git resolution (Seatbelt reads /opt and /usr/local, not /Library/Developer)"
run git --version
for g in /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do [ -x "$g" ] && echo "present: $g"; done
xcode-select -p 2>&1 | sed 's/^/  xcode-select: /'
say "macOS vfs prerequisites"; for p in /sbin/mount_nfs /usr/bin/sandbox-exec; do [ -x "$p" ] && echo "ok $p" || echo "MISSING $p"; done
say "Staging root"; [ -e "$ROOT" ] && run ls -la "$ROOT" || echo "absent (expected before R1): $ROOT"
say "Existing NFS/FUSE mounts mentioning vfs"; mount | grep -i -e vfs -e factory-vfs-pilot || echo "none"
say "Colima (inspect only)"
run colima version
run colima list
for p in $(colima list -j 2>/dev/null | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'); do
    echo "--- profile $p config (read-only)"
    for f in "$HOME/.colima/$p/colima.yaml" "$HOME/.colima/_templates/default.yaml"; do [ -f "$f" ] && { echo "file: $f"; sed 's/^/  /' "$f"; }; done
done
say "Docker contexts"; run docker context ls
echo; echo "preflight done; nothing was changed"

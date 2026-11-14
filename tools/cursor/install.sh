#!/usr/bin/env bash
# Cloud Agent install: pin Bun to the version CI uses, then frozen-lockfile deps.
# Same pin as .github/workflows/ci.yml oven-sh/setup-bun bun-version.
# Linux zips and hashes are tools/cursor/bun-v1.3.14.sha256 (SHASUMS256.txt on that tag).
# May append one marked PATH line to the first of ~/.bash_profile,
# ~/.bash_login, ~/.profile that exists (bash -l order; ~/.profile if none
# exist), only when ~/.bun/bin/bun is 1.3.14 and a login shell cannot already
# find that version.
# Never replaces an existing ~/.bun/bin/bun that is not the pin. Cloud Agent
# tool shells are not login shells; they run .cursor/bin/ak, which finds the
# pin at ~/.bun/bin/bun without bun on PATH.
set -euo pipefail
PIN=1.3.14
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUMS=$HERE/bun-v${PIN}.sha256
export PATH="${HOME}/.bun/bin:${PATH}"
BASH_BIN=$(command -v bash)
if [ -f "${HOME}/.bash_profile" ]; then
  dest=${HOME}/.bash_profile
elif [ -f "${HOME}/.bash_login" ]; then
  dest=${HOME}/.bash_login
else
  dest=${HOME}/.profile
fi

need_cmd() {
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "need $c on PATH to download bun $PIN" >&2
      exit 1
    fi
  done
}

install_bun() {
  need_cmd curl unzip sha256sum
  arch=$(uname -m)
  case $arch in
    x86_64) asset=bun-linux-x64.zip ;;
    aarch64 | arm64) asset=bun-linux-aarch64.zip ;;
    *)
      echo "unsupported uname -m '$arch'. Need x86_64 or aarch64." >&2
      exit 1
      ;;
  esac
  expected=$(awk -v a="$asset" '$2 == a { print $1 }' "$SUMS")
  if [ -z "$expected" ]; then
    echo "no sha256 for $asset in $SUMS" >&2
    exit 1
  fi
  url="https://github.com/oven-sh/bun/releases/download/bun-v${PIN}/${asset}"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/$asset" "$url"
  got=$(sha256sum "$tmp/$asset" | awk '{ print $1 }')
  if [ "$got" != "$expected" ]; then
    echo "bun $asset checksum mismatch: got $got want $expected" >&2
    exit 1
  fi
  echo "bun $asset sha256 $got ok" >&2
  unzip -o -q "$tmp/$asset" -d "$tmp/out"
  src=$(find "$tmp/out" -type f -name bun -print -quit)
  if [ -z "$src" ]; then
    echo "bun zip $asset had no bun binary" >&2
    exit 1
  fi
  mkdir -p "${HOME}/.bun/bin"
  cp -a "$src" "${HOME}/.bun/bin/bun"
  chmod +x "${HOME}/.bun/bin/bun"
}

home_bun_is_pin() {
  bun_bin=${HOME}/.bun/bin/bun
  [ -x "$bun_bin" ] && [ "$("$bun_bin" --version)" = "$PIN" ]
}

ensure_home_bun() {
  if home_bun_is_pin; then
    return 0
  fi
  home_bin=${HOME}/.bun/bin/bun
  if [ -e "$home_bin" ]; then
    echo "leaving $home_bin in place: not the pinned ${PIN}" >&2
    return 0
  fi
  install_bun
}

# Cloud Agent install/start are bash -l. Stock Ubuntu ~/.bashrc returns early
# when not interactive, so PATH belongs in the login file bash actually reads.
persist_login_path() {
  if ! home_bun_is_pin; then
    return 0
  fi
  if login_finds_bun; then
    return 0
  fi
  marker="# agent-kit bun PATH"
  line='export PATH="$HOME/.bun/bin:$PATH"'
  if [ -f "$dest" ] && grep -Fqx "$marker" "$dest"; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  printf '\n%s\n%s\n' "$marker" "$line" >>"$dest"
  echo "appended bun PATH to $dest" >&2
}

login_finds_bun() {
  u=$(id -un)
  env -i HOME="$HOME" USER="$u" LOGNAME="$u" TERM="${TERM:-dumb}" \
    "$BASH_BIN" -l -c 'command -v bun >/dev/null && [ "$(bun --version)" = "'"$PIN"'" ]'
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

ensure_home_bun
persist_login_path

if ! command -v bun >/dev/null 2>&1; then
  echo "bun is not on PATH after install" >&2
  exit 1
fi
if [ "$(bun --version)" != "$PIN" ]; then
  echo "bun $(bun --version) is not the pinned ${PIN}" >&2
  exit 1
fi
if ! login_finds_bun; then
  echo "bun $PIN is not on PATH in a login shell ($dest)" >&2
  exit 1
fi

cd "$ROOT"
# Firstmate has no bun.lock. Skip frozen-lockfile deps that agent-kit v0.1.106
# (e1716acf) always ran here.
if [ -f bun.lock ]; then
  bun install --frozen-lockfile
fi

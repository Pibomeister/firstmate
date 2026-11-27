#!/usr/bin/env bash
# Pin Factory-AI/vfs v1.1.1 (source rev 4852148c) and record what was built.
#
# Usage:
#   pin-vfs.sh release [DEST]   download the v1.1.1 release asset for this
#                               OS/arch, verify it against the pinned sha256,
#                               unpack it into DEST/bin (default ./vfs-pin).
#   pin-vfs.sh source  [DEST]   clone the source at the pinned rev and build
#                               it with cargo (needs the pinned nightly Rust
#                               toolchain already present; never installs it).
#   pin-vfs.sh record  VFS_BIN [DEST]
#                               only record an existing binary.
#
# Writes DEST/pin-<os>-<arch>.json and prints it. Touches nothing outside DEST.
# Portable to macOS bash 3.2 and Linux; needs curl, tar (xz), git for source.
set -euo pipefail

VFS_REPO="https://github.com/Factory-AI/vfs"
VFS_TAG="v1.1.1"
VFS_REV="4852148cecde9c5413b51e4184eac55015bfe766"
RUST_TOOLCHAIN="nightly-2026-08-07"   # from rust-toolchain.toml at VFS_REV

# Published in the v1.1.1 release's sha256.sum (fetched 2026-11-27).
asset_sha256() {
    case "$1" in
        vfs-cli-aarch64-apple-darwin.tar.xz)       echo 2be3e2cf076671cedf9899cf92276755a95dfdd444faa26b5c0ded7874b3aadb ;;
        vfs-cli-x86_64-apple-darwin.tar.xz)        echo ee829645eabe86bfbd2d1f3690bef9ab1f28602dbb217f2d878d4ea42e59cc30 ;;
        vfs-cli-aarch64-unknown-linux-gnu.tar.xz)  echo f89b44600f7533f852c68fba22e85468d6c6b98bb4c42514e396df7b5add829e ;;
        vfs-cli-x86_64-unknown-linux-gnu.tar.xz)   echo e1f945f644d9468bc469b423089581983ea12343322b28d994cbe36d470d59b9 ;;
        source.tar.gz)                             echo 74ec6d607e03784cffe606b24e039a0d4e0d1a9bd5901db91e865266f0775aaf ;;
        *) return 1 ;;
    esac
}

die() { echo "pin-vfs: $*" >&2; exit 1; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

target_triple() {
    local os arch
    os="$(uname -s)"; arch="$(uname -m)"
    case "$arch" in arm64|aarch64) arch=aarch64 ;; x86_64|amd64) arch=x86_64 ;; *) die "unsupported arch $arch" ;; esac
    case "$os" in
        Darwin) echo "$arch-apple-darwin" ;;
        Linux)  echo "$arch-unknown-linux-gnu" ;;
        *) die "unsupported OS $os (vfs supports Linux and macOS only)" ;;
    esac
}

record() {
    local bin="$1" dest="$2" method="$3" asset="${4:-}" asset_sha="${5:-}"
    [ -x "$bin" ] || die "not executable: $bin"
    local version_json bin_sha os arch osver out
    version_json="$("$bin" version --json)"
    bin_sha="$(sha256_of "$bin")"
    os="$(uname -s)"; arch="$(uname -m)"
    if [ "$os" = Darwin ]; then osver="$(sw_vers -productVersion 2>/dev/null || true) ($(sw_vers -buildVersion 2>/dev/null || true))"
    else osver="$(uname -r)"; fi
    case "$version_json" in
        *"\"commit\":\"$VFS_REV\""*) ;;
        *) die "binary does not report pinned commit $VFS_REV: $version_json" ;;
    esac
    case "$version_json" in
        *'"version":"1.1.1"'*) ;;
        *) die "binary does not report version 1.1.1: $version_json" ;;
    esac
    mkdir -p "$dest"
    out="$dest/pin-$(echo "$os" | tr 'A-Z' 'a-z')-$arch.json"
    cat > "$out" <<JSON
{"pinnedTag":"$VFS_TAG","pinnedRev":"$VFS_REV","method":"$method","asset":"$asset","assetSha256":"$asset_sha","binarySha256":"$bin_sha","os":"$os","osVersion":"$osver","arch":"$arch","recordedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","vfsVersion":$version_json}
JSON
    cat "$out"
}

mode="${1:-}"; shift || true
case "$mode" in
    release)
        dest="${1:-./vfs-pin}"
        triple="$(target_triple)"
        asset="vfs-cli-$triple.tar.xz"
        want="$(asset_sha256 "$asset")" || die "no pinned sha for $asset"
        mkdir -p "$dest/download" "$dest/bin"
        curl --proto '=https' --tlsv1.2 -fsSL -o "$dest/download/$asset" \
            "$VFS_REPO/releases/download/$VFS_TAG/$asset"
        got="$(sha256_of "$dest/download/$asset")"
        [ "$got" = "$want" ] || die "asset sha256 mismatch: got $got want $want"
        tar -xJf "$dest/download/$asset" -C "$dest/bin"
        bin="$dest/bin/vfs-cli-$triple/vfs"
        record "$bin" "$dest" release "$asset" "$got"
        ;;
    source)
        dest="${1:-./vfs-pin}"
        command -v cargo >/dev/null 2>&1 || die "cargo not on PATH; building from source needs Rust $RUST_TOOLCHAIN (an install this script will not do)"
        mkdir -p "$dest"
        [ -d "$dest/src/.git" ] || git clone --quiet "$VFS_REPO.git" "$dest/src"
        git -C "$dest/src" fetch --quiet --tags origin
        git -C "$dest/src" checkout --quiet --detach "$VFS_REV"
        [ "$(git -C "$dest/src" rev-parse HEAD)" = "$VFS_REV" ] || die "checkout is not at $VFS_REV"
        [ "$(git -C "$dest/src" rev-list -n1 "$VFS_TAG")" = "$VFS_REV" ] || die "tag $VFS_TAG does not point at $VFS_REV"
        (cd "$dest/src" && cargo "+$RUST_TOOLCHAIN" build --release --locked -p vfs-cli --bin vfs)
        record "$dest/src/target/release/vfs" "$dest" source "" ""
        ;;
    record)
        bin="${1:?usage: pin-vfs.sh record VFS_BIN [DEST]}"
        record "$bin" "${2:-./vfs-pin}" record "" ""
        ;;
    *) sed -n '2,16p' "$0"; exit 2 ;;
esac

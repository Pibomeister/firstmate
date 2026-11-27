# vfs pin

Machine-readable form: [`pin.json`](pin.json). Script: [`scripts/pin-vfs.sh`](scripts/pin-vfs.sh).

## Source revision

| Item | Value | Evidence |
|---|---|---|
| Repository | https://github.com/Factory-AI/vfs | |
| Tag | `v1.1.1` | |
| Source revision | `4852148cecde9c5413b51e4184eac55015bfe766` | `git rev-list -n1 v1.1.1` and `git rev-parse 4852148c` in a fresh clone both print it; `git tag --points-at 4852148c` prints `v1.1.1` |
| Tag object | lightweight tag, type `commit`, sha `4852148c…` | `gh api repos/Factory-AI/vfs/git/ref/tags/v1.1.1` |
| Release | published 2026-08-10T23:44:42Z, `targetCommitish` `4852148c…` | `gh release view v1.1.1 -R Factory-AI/vfs` |
| Commit | 2026-08-10, "release: cut 1.1.1 with the turso 0.7.2 engine upgrade" | `git log -1 4852148c` |
| Toolchain | `nightly-2026-08-07` | `rust-toolchain.toml` at the revision |
| Supported targets | aarch64/x86_64 Linux (gnu), aarch64/x86_64 macOS; no Windows target | `dist-workspace.toml`; README "No other platforms are supported" |

The release binaries are what the pin uses. Their sha256 values are copied from the release's own `sha256.sum` into `pin-vfs.sh`, which refuses any asset that does not match. The binary itself must report `"commit":"4852148c…"` and `"version":"1.1.1"` or the script stops.

## Builds recorded

| Platform | Where | Method | Binary sha256 | Status |
|---|---|---|---|---|
| x86_64-unknown-linux-gnu | WSL2 Ubuntu 26.04.1 on this Windows machine (kernel 6.18.58.1-microsoft-standard-WSL2) | `pin-vfs.sh release` (download, sha256 match `e1f945f6…`) | `59ad43e636758125f5c98132ba1a29a0f2087d349780acafc692781503184a57` | recorded |
| aarch64-apple-darwin | Mac Mini, native | `pin-vfs.sh release` | | pending host run R1 |
| aarch64-unknown-linux-gnu | Linux container on the Mac Mini | `pin-vfs.sh fetch` on the host, `pin-vfs.sh record` in the container | | pending host run R3 |
| any | | `pin-vfs.sh source` (cargo build at the revision) | | not run: needs the Rust nightly toolchain installed (Needs Eduardo's named OK) |

`vfs version --json` from the recorded binary:

```json
{"version":"1.1.1","commit":"4852148cecde9c5413b51e4184eac55015bfe766","artifactVersion":"0.8","minSupportedArtifactVersion":"0.0","features":{"uidSquashRun":true,"pack":true,"checkpoint":true,"seed":true,"adopt":true,"adoptRemote":true,"branch":true,"history":true}}
```

Evidence: `evidence/wsl2-linux-x86_64/pin-linux-x86_64.release.json`.

## Why no build on Windows

vfs has no Windows target (upstream deleted it), and this machine has no Rust toolchain. Installing one is out of scope without a named OK. WSL2 Ubuntu was already present and runs the published Linux x86_64 build, so the Linux pin and the Linux fixture legs were recorded there without installing anything.

## Not established by this pin

- That the release binary is byte-reproducible from source. Only a source build (`pin-vfs.sh source`) can compare against it, and that needs the toolchain.
- Anything about arm64. The Mac Mini and its Linux container are arm64; the only recorded binary is x86_64.

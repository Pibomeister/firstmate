# Host run requests (Mac Mini)

For the coordinator to relay through Hermes. Run them in order; each one needs the previous one's result. Nothing here has been run on the Mac Mini.

Common facts:

- Checkout: the branch `fleet/vfs-phase0` of `Pibomeister/firstmate` (any path; below `$PHASE0` is its `fleet/shared-workspace/phase0` directory). Getting it there is the only step outside the staging root.
- Staging root: `/Users/picazosmacmini/factory-vfs-pilot` (override with `FIXTURE_HOST_ROOT`). Every script writes only under it, except R2's Colima profile and R3's image, which live in Colima's own store.
- Fixture size: the bundle is about 300 KiB; the whole root stays well under the 10 GiB cap.
- Return to the coordinator: the `evidence/` directory under the staging root (it holds `checks.tsv`, logs and pin JSON per run).

```sh
git clone --branch fleet/vfs-phase0 --depth 1 https://github.com/Pibomeister/firstmate.git ~/factory-vfs-pilot-src
PHASE0=~/factory-vfs-pilot-src/fleet/shared-workspace/phase0
```

Undo for the checkout: `rm -rf ~/factory-vfs-pilot-src`.

## R0: read-only preflight (no review needed beyond "may read")

```sh
bash "$PHASE0/host/00-preflight-macos.sh" | tee ~/factory-vfs-pilot-preflight.txt
```

- Access: reads `sw_vers`, tool paths, `mount`, `colima list`, each existing profile's `~/.colima/<profile>/colima.yaml`, `docker context ls`. Starts, installs, mounts and writes nothing (apart from the `tee` file).
- Undo: `rm ~/factory-vfs-pilot-preflight.txt`.
- Decides: whether `git` resolves somewhere the Seatbelt profile can read (`/opt/homebrew/bin/git`), and what the existing Colima profile is before R2.

## R1: native macOS stopped fixture (qualify this first)

```sh
bash "$PHASE0/host/10-native-stopped.sh"
```

- Access: creates `/Users/picazosmacmini/factory-vfs-pilot/{bases,state,mount,outbox,artifacts,evidence,bin}`; downloads `vfs-cli-aarch64-apple-darwin.tar.xz` from the GitHub v1.1.1 release (network, once) and refuses it unless sha256 is `2be3e2cf076671cedf9899cf92276755a95dfdd444faa26b5c0ded7874b3aadb`; runs vfs from that folder only (no install, no PATH change, no `~/.cargo`). Machine A and B are `state/home-a` and `state/home-b`; `vfs run` NFS-mounts under `state/home-*/.vfs/run/*/mnt` and unmounts on exit.
- Produces: `evidence/pin-darwin.json`, `evidence/checks.tsv`, and `outbox/p0-stopped-1` (the Mac-packed bundle R3 uses).
- Undo: `bash "$PHASE0/host/99-undo.sh" native` (unmounts any leftover vfs mount under the root, then deletes the root).
- Pass: exit 0 and no `FAIL` row in `evidence/checks.tsv`.

## R2: dedicated Colima profile (review: new VM)

```sh
bash "$PHASE0/host/00-preflight-macos.sh"   # re-check the existing profile is untouched
bash "$PHASE0/host/20-colima-profile.sh"
```

- Access: creates a **new** Colima profile `factory-vfs-pilot` (arm64, vz, 2 CPU, 4 GiB RAM, 20 GiB disk, docker runtime). The existing profile is never started, stopped or edited. The VM mounts only the staging root (`--mount /Users/picazosmacmini/factory-vfs-pilot:w`). Colima switches the current docker context on start; the script restores the previous one and later steps use `--context colima-factory-vfs-pilot` explicitly. Network: VM image download.
- Undo: `bash "$PHASE0/host/99-undo.sh" colima` (stops and deletes only `factory-vfs-pilot`, restores the recorded docker context).

## R3: Mac -> Linux container receiver

Run `tier0` first. Run a tier 1 variant only after its options are reviewed and only if `tier0` passed.

```sh
bash "$PHASE0/host/30-container-receiver.sh" tier0
# after review, and only if tier0 passed:
bash "$PHASE0/host/30-container-receiver.sh" tier1a
# only if tier1a failed for lack of capabilities:
bash "$PHASE0/host/30-container-receiver.sh" tier1b
# only if the VM enforces AppArmor (see evidence/colima-vm-facts.txt) and tier1b was refused by it:
bash "$PHASE0/host/30-container-receiver.sh" tier1c
```

- Access, every tier: downloads `vfs-cli-aarch64-unknown-linux-gnu.tar.xz` on the host and refuses it unless sha256 is `f89b44600f7533f852c68fba22e85468d6c6b98bb4c42514e396df7b5add829e`; builds image `factory-vfs-pilot/receiver:phase0` from `ubuntu:24.04` plus `git fuse3 ca-certificates procps util-linux coreutils` (network at build only). The container runs `--rm --network none --pids-limit 512 --memory 2g --cpus 2 --security-opt no-new-privileges`, with its working tree on a 1 GiB tmpfs and only these mounts: `outbox` read-only, the Linux vfs binary read-only, the Phase 0 scripts read-only, `evidence/container-<tier>` read-write. Never `--privileged`.
- `tier0`: `--cap-drop ALL`, no device. Runs bundle verification, policy, version floor, base at pin, wrong-base refusal, adopt, status, integrity, offline read, re-adopt refusal, and all negative checks. Resume is recorded as `SKIP`.
- Tier 1 adds, **flagged for review**:
  - `--device /dev/fuse` (FUSE mounts for `vfs run`).
  - `--cap-add SYS_ADMIN` (mounting FUSE, the user and mount namespaces `vfs run` creates, and `mount --make-rshared /` inside the container's own mount namespace, which `vfs run` requires). `SYS_ADMIN` is broad; it is confined here by `--network none`, no host paths beyond the four listed, tmpfs working tree, and a throwaway container.
  - `tier1a` keeps every other capability dropped. `tier1b` restores Docker's default set. `tier1c` additionally sets `apparmor=unconfined`.
  Tier 1 also runs the Linux live-checkpoint leg.
- Undo: `bash "$PHASE0/host/99-undo.sh" container` (the container is already `--rm`; this removes the image).
- Pass: exit 0 and no `FAIL` row in `evidence/container-<tier>/checks.tsv`; `tier0` must show `B-resume-state SKIP`, tier 1 must show it `PASS`.

## Full undo

```sh
bash "$PHASE0/host/99-undo.sh" all && rm -rf ~/factory-vfs-pilot-src ~/factory-vfs-pilot-preflight.txt
```

## Not requested

- Installing vfs, Rust, Homebrew packages or anything else on the Mac Mini.
- Touching the existing Colima profile.
- A privileged container, host networking, or any bind mount outside the staging root.
- A backup destination (none chosen yet).

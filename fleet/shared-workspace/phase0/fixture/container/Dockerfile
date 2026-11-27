# Linux receiver (machine B) for the Phase 0 fixture. No vfs inside the image:
# the pinned, sha256-verified binary is bind-mounted read-only at /opt/vfs.
# Record the resolved base digest (host/30 writes receiver-image.txt) and pin
# it here by digest once it is known.
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends git fuse3 ca-certificates procps util-linux coreutils \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /srv

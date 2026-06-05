# syntax=docker/dockerfile:1.7
# Claude Code workstation: ttyd + tmux + claude CLI, browser-accessible.
# Build target is linux/arm64 by default (Raspberry Pi / Apple Silicon /
# Ampere); flip the GHA workflow's `platforms:` to add amd64 if you need it.

# Pinned to the arm64 manifest digest of node:22-bookworm-slim. The GHA
# workflow only builds linux/arm64; this digest is what was current at the
# build SHA. Bump together with TTYD_VERSION / kubectl / etc. when you want
# to roll forward to a fresher Debian + Node patch set.
FROM node:22-bookworm-slim@sha256:6710aea4dbb47f7d74f6b604b5e9e86ef39627121be69407b2c3552605f2033d

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        fd-find \
        git \
        gnupg \
        gosu \
        jq \
        less \
        locales \
        openssh-client \
        procps \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        tmux \
        vim \
        wget \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# ttyd — no Debian package on bookworm-slim, pull static binary from upstream.
ARG TTYD_VERSION=1.7.7
RUN ARCH=$(case "$TARGETARCH" in arm64) echo aarch64 ;; amd64) echo x86_64 ;; esac) \
    && curl -fsSL -o /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ARCH}" \
    && chmod +x /usr/local/bin/ttyd

# kubectl — pinned by version. Was previously `stable.txt` (whichever k8s
# release was current at build time), which defeated the SHA-pin promise
# because two builds of the same source SHA could land different kubectl
# versions. Bump explicitly when you want to roll forward.
ARG KUBECTL_VERSION=v1.36.1
RUN curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod +x /usr/local/bin/kubectl

# gh CLI — official Debian package.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /usr/share/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# sops + age — for editing SOPS-encrypted files in GitOps repos.
ARG SOPS_VERSION=3.9.0
ARG AGE_VERSION=1.2.0
RUN curl -fsSL -o /usr/local/bin/sops \
        "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${TARGETARCH}" \
    && chmod +x /usr/local/bin/sops \
    && curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${TARGETARCH}.tar.gz" \
        | tar xz -C /tmp \
    && mv /tmp/age/age /tmp/age/age-keygen /usr/local/bin/ \
    && rm -rf /tmp/age

# Claude Code CLI is intentionally NOT baked into the image. The npm global
# install we used to do here can never self-update (root-owned, and the image
# is SHA-pinned anyway), so it inevitably went stale next to the native
# install on the home PVC. Instead, entrypoint.sh bootstraps the native
# installer into ~/.local/share/claude on first boot of a fresh PVC; from
# then on the CLI auto-updates itself in place, surviving pod restarts.

# Seafile CLI client (seaf-cli + seafile-daemon) for the sync sidecar.
# Bookworm's seafile-cli is 8.0.10 — Seafile's client/server compat is
# generous across majors, so a v8 client syncs against a v12 server fine
# for the standard library-sync use case. We previously tried the upstream
# linux-clients.seafile.com apt repo for a newer version, but that server
# is intermittently offline and breaks CI builds.
RUN apt-get update \
    && apt-get install -y --no-install-recommends seafile-cli \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged user; UID 1000 is the conventional first-user slot and is what
# the entrypoint drops to via gosu.
# node:22-bookworm-slim pre-creates a `node` user at UID 1000, so reclaim that
# slot before adding `claude`.
RUN userdel -r node 2>/dev/null || true \
    && useradd -u 1000 -m -s /bin/bash claude

# tmux config installed system-wide so it's still readable after a volume
# mounted on /home/claude shadows any user-level dotfiles on first boot.
COPY tmux.conf /etc/tmux.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY seafile-sync.sh /usr/local/bin/seafile-sync.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/seafile-sync.sh

EXPOSE 7681

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

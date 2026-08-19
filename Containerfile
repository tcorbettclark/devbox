#syntax=docker/dockerfile:1
#
# Build:
#   cp ~/.ssh/id_ed25519.pub ./authorized_keys     # your PUBLIC key (not secret)
#   container build --target devbox -t devbox:latest .
#
# Create + run a machine:
#   sudo container system dns create machine       # once; enables <name>.machine
#   container machine create --home-mount=none --name devbox1 devbox:latest
#
# Connect
#   ssh devbox1.machine
#
# ── base ─────────────────────────────────────────────────────────────────────
FROM debian:stable-slim AS base

ENV container=container
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
# User-local bins on PATH for non-fish contexts and for RUN steps below.
ENV PATH=/home/tcorbettclark/.local/bin:/home/tcorbettclark/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# System packages: systemd + ssh + fish + apt-available CLI tools.
# starship is installed below from its official installer (Debian lags on it).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        openssh-server \
        fish \
        git gh jq ripgrep fd-find fzf \
        curl ca-certificates \
        sqlite3 gettext \
        bat eza tidy \
        build-essential pkg-config \
        less file unzip tar gzip bzip2 xz-utils \
        locales sudo \
    && rm -rf /var/lib/apt/lists/* && \
    # Debian renames some binaries; provide the canonical names.
    command -v bat || ln -s "$(command -v batcat)" /usr/local/bin/bat ; \
    command -v fd  || ln -s "$(command -v fdfind)" /usr/local/bin/fd

# Locale: fish + uv + bun are happier with UTF-8.
RUN sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen

# systemd-as-PID-1 setup.
RUN >/etc/machine-id && >/var/lib/dbus/machine-id
RUN systemctl set-default multi-user.target && \
    systemctl mask \
      dev-hugepages.mount \
      sys-fs-fuse-connections.mount \
      systemd-update-utmp.service \
      systemd-tmpfiles-setup.service \
      console-getty.service

# Non-root user: tcorbettclark (UID 1000), fish login shell, passwordless sudo.
# Toolchains (uv/bun) install into this home during build, so the user must
# exist here. /etc/machine/create-user.sh (below) keeps this setup intact across
# the machine's first-boot provisioning.
RUN useradd -m -u 1000 -s /usr/bin/fish tcorbettclark && \
    passwd -d tcorbettclark && \
    echo 'tcorbettclark ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tcorbettclark && \
    chmod 0440 /etc/sudoers.d/tcorbettclark

# Baked git identity (you're the only user; safe to bake).
RUN printf '[user]\n\tname = Timothy Corbett-Clark\n\temail = timothy@corbettclark.com\n[init]\n\tdefaultBranch = main\n' \
        > /home/tcorbettclark/.gitconfig && \
    chown tcorbettclark:tcorbettclark /home/tcorbettclark/.gitconfig

# Dotfiles (fish config + functions, ghostty, zed) are managed by chezmoi from
# github.com/tcorbettclark/dotfiles. chezmoi isn't in Debian stable (only sid),
# so use the official installer instead of adding sid sources. It drops the
# binary in ~/.local/bin (already on PATH) and runs `init --apply` in one shot.
# The repo is PUBLIC, so the HTTPS clone works at build time without the
# forwarded SSH agent. Re-init over SSH post-boot if you want `chezmoi update`
# to use the agent (git@github.com:tcorbettclark/dotfiles.git).
USER tcorbettclark
RUN sh -c "$(curl -fsLS https://get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply tcorbettclark/dotfiles
USER root

# Authorize the host's SSH key to log in to the machine. This is the PUBLIC
# key only (not secret), dropped into the build context as ./authorized_keys
# (e.g. `cp ~/.ssh/id_ed25519.pub ./authorized_keys`) before building.
COPY --chown=tcorbettclark:tcorbettclark ./authorized_keys /home/tcorbettclark/.ssh/authorized_keys
RUN chmod 700 /home/tcorbettclark/.ssh && \
    chmod 600 /home/tcorbettclark/.ssh/authorized_keys

# Stage the same configs under /etc/skel-dev so /etc/machine/create-user.sh can
# repair them idempotently (cp -an, no clobber) if the machine re-provisions
# the user on first boot. Toolchain dirs (~/.local, ~/.bun) are NOT
# staged — they're already baked into /home/tcorbettclark.
# NOTE: dotfiles (~/.config/fish, ~/.config/zed, ~/.config/ghostty) are NOT
# staged here — chezmoi owns them and applied them at build time for the baked
# user. Only the non-dotfile configs (git identity, ssh pubkey) are staged as a
# repair fallback for /etc/machine/create-user.sh.
RUN mkdir -p /etc/skel-dev/.ssh && \
    cp /home/tcorbettclark/.gitconfig /etc/skel-dev/.gitconfig && \
    cp /home/tcorbettclark/.ssh/authorized_keys /etc/skel-dev/.ssh/authorized_keys

# /etc/machine/create-user.sh: Apple runs this once, as root, on first boot,
# with CONTAINER_USER/UID/GID/HOME/MACHINE_ID set. Replaces the built-in user
# provisioning. Idempotent: if the baked user already exists, just ensure the
# configs are present (no clobber) and ownership is correct.
RUN mkdir -p /etc/machine && \
    printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'USER_="${CONTAINER_USER:-tcorbettclark}"' \
    '# User + home + toolchains are baked into the image. If the machine' \
    '# provisioned a different UID, keep the baked user as-is (home-mount is' \
    '# none, so UID matching the host is irrelevant).' \
    'if ! id -u "$USER_" >/dev/null 2>&1; then' \
    '  groupadd -g "${CONTAINER_GID:-1000}" "$USER_"' \
    '  useradd -u "${CONTAINER_UID:-1000}" -g "$USER_" -M -d "${CONTAINER_HOME:-/home/$USER_}" -s /usr/bin/fish "$USER_"' \
    'fi' \
    'HOME_="$(getent passwd "$USER_" | cut -d: -f6)"' \
    'mkdir -p "$HOME_/.ssh"' \
    '# Fill in any missing non-dotfile configs from the staged skel (do not' \
    '# overwrite). Dotfiles (~/.config/fish, ~/.config/zed, …) are managed by' \
    '# chezmoi and were applied at build time for the baked user — not staged.' \
    'cp -an /etc/skel-dev/. "$HOME_"/ 2>/dev/null || true' \
    'chmod 700 "$HOME_/.ssh"' \
    'chmod 600 "$HOME_/.ssh/authorized_keys" 2>/dev/null || true' \
    'chown -R "$USER_:$USER_" "$HOME_"' \
    'passwd -d "$USER_" 2>/dev/null || true' \
    'echo "$USER_ ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USER_"' \
    'chmod 0440 /etc/sudoers.d/"$USER_"' \
    > /etc/machine/create-user.sh && \
    chmod 0755 /etc/machine/create-user.sh

# starship prompt (system-wide binary; fish sources it via config.fish).
RUN curl -sS https://starship.rs/install.sh | sh -s -- -y

# sshd: pubkey-only, no root, key file in the usual place.
RUN mkdir -p /etc/ssh/sshd_config.d && \
    printf 'PermitRootLogin no\nPubkeyAuthentication yes\nPasswordAuthentication no\nAuthorizedKeysFile .ssh/authorized_keys\nAcceptEnv PI_OLLAMA_KEY\n' \
        > /etc/ssh/sshd_config.d/devbox.conf && \
    mkdir -p /run/sshd && \
    systemctl disable ssh.socket 2>/dev/null || true ; \
    systemctl enable ssh.service

# Default boot is systemd; nothing else to CMD.
CMD ["/sbin/init"]

# ── programming ──────────────────────────────────────────────────────────
FROM base AS programming

USER tcorbettclark
WORKDIR /home/tcorbettclark

# uv installs to ~/.local/bin and manages its own Python interpreters.
# No apt python3; uv fetches whatever Python a project needs.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# One Node (latest LTS), installed straight into ~/.local so bin/node,
# bin/npm, bin/npx, bin/corepack land on PATH and npm's global prefix is
# ~/.local (so `npm i -g <foo>` puts its shim in ~/.local/bin — already PATH).
# arm64 matches Apple Silicon. No fnm/nvm: we want exactly one Node; rebuild
# the image to change it. jq (from base) picks the newest LTS from the dist
# index — same source nvm/fnm themselves use.
RUN mkdir -p ~/.local && \
    NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/index.json \
        | jq -r 'map(select(.lts != false)) | sort_by(.date) | last | .version') && \
    curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-linux-arm64.tar.xz" \
        | tar -xJ -C ~/.local --strip-components=1 && \
    node --version && npm --version && \
    curl -fsSL https://bun.sh/install | bash

# ── llm ──────────────────────────────────
FROM programming AS llm

USER tcorbettclark
WORKDIR /home/tcorbettclark

# pi (the coding agent). Installed globally via npm; its prefix is ~/.local
# (set up in the typescript stage), so `pi` lands in ~/.local/bin (already on
# PATH).
RUN npm install -g @earendil-works/pi-coding-agent && pi --version

# ── dev ──────────────────────────────────────────────────
# Empty-body alias, so 'dev' is always the final complete target.
FROM llm AS devbox

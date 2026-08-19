#syntax=docker/dockerfile:1
#
# Build (the devbox wrapper reads your username, git identity, and dotfiles
# repo from the current user and forwards them as build-args; the Containerfile
# has no defaults and fails fast without them):
#   devbox build
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

# Required build-args (no defaults; the guard below fails fast if any are
# missing). The `devbox` wrapper supplies them from the current user:
# USER_NAME=whoami, GIT_NAME/GIT_EMAIL from `git config`, DOTFILES_REPO=<user>/dotfiles.
ARG USER_NAME
ARG GIT_NAME
ARG GIT_EMAIL
ARG DOTFILES_REPO

# Fail fast with a clear message if any required build-arg is missing (e.g. a
# bare `container build .` without the devbox wrapper).
RUN : "${USER_NAME:?USER_NAME build-arg required}" && \
    : "${GIT_NAME:?GIT_NAME build-arg required}" && \
    : "${GIT_EMAIL:?GIT_EMAIL build-arg required}" && \
    : "${DOTFILES_REPO:?DOTFILES_REPO build-arg required}"

# Promote to ENV so they survive into the programming/llm/devbox stages (ARGs
# are stage-scoped; ENVs inherit across FROM ... AS <child>).
ENV USER_NAME=${USER_NAME}
ENV HOME_DIR=/home/${USER_NAME}

ENV container=container
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
# User-local bins on PATH for non-fish contexts and for RUN steps below.
# Homebrew for Linux installs to /home/linuxbrew/.linuxbrew.
ENV BREW_PREFIX=/home/linuxbrew/.linuxbrew
ENV PATH=${BREW_PREFIX}/bin:${HOME_DIR}/.local/bin:${HOME_DIR}/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# System packages: systemd + ssh + fish + apt-available CLI tools.
# starship is installed below from its official installer (Debian lags on it).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        openssh-server \
        fish \
        git gh jq ripgrep fd-find fzf \
        curl ca-certificates \
        sqlite3 gettext libnss3-tools \
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

# Non-root user (UID 1000), fish login shell, passwordless sudo. Toolchains
# (uv/bun) install into this home during build, so the user must exist here.
# /etc/machine/create-user.sh (below) keeps this setup intact across the
# machine's first-boot provisioning.
RUN useradd -m -u 1000 -s /usr/bin/fish ${USER_NAME} && \
    passwd -d ${USER_NAME} && \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME} && \
    chmod 0440 /etc/sudoers.d/${USER_NAME}

# Baked git identity (you're the only user; safe to bake).
RUN printf '[user]\n\tname = %s\n\temail = %s\n[init]\n\tdefaultBranch = main\n' "${GIT_NAME}" "${GIT_EMAIL}" \
        > ${HOME_DIR}/.gitconfig && \
    chown ${USER_NAME}:${USER_NAME} ${HOME_DIR}/.gitconfig

# Dotfiles (fish config + functions, ghostty, zed) are managed by chezmoi from
# $DOTFILES_REPO (passed as a build-arg, e.g. <user>/dotfiles). chezmoi isn't in
# Debian stable (only sid), so use the official installer instead of adding sid
# sources. It drops the binary in ~/.local/bin (already on PATH) and runs
# `init --apply` in one shot. The repo is PUBLIC, so the HTTPS clone works at
# build time without the forwarded SSH agent. Re-init over SSH post-boot if you
# want `chezmoi update` to use the agent (git@github.com:$DOTFILES_REPO.git).
USER ${USER_NAME}
RUN sh -c "$(curl -fsLS https://get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply ${DOTFILES_REPO}
USER root

# Authorize the host's SSH key to log in to the machine. This is the PUBLIC
# key only (not secret), dropped into the build context as ./authorized_keys
# (e.g. `cp ~/.ssh/id_ed25519.pub ./authorized_keys`) before building.
COPY --chown=${USER_NAME}:${USER_NAME} ./authorized_keys ${HOME_DIR}/.ssh/authorized_keys
RUN chmod 700 ${HOME_DIR}/.ssh && \
    chmod 600 ${HOME_DIR}/.ssh/authorized_keys

# /etc/machine/create-user.sh: Apple runs this once, as root, on first boot.
# Its mere presence suppresses Apple's built-in default, which would re-create
# the user under the host UID and clobber/re-chown the baked home. With a single
# build==create user and --home-mount=none, the baked user/home/configs
# persist, so nothing needs provisioning — just keep sudo + no-password intact.
# We ignore Apple's CONTAINER_* env vars and bake the literal $USER_NAME into
# the script at build time (via an unquoted inner heredoc), so there's no
# runtime env dependency when Apple runs this in its provisioning context.
RUN <<'OUTER'
set -eu
mkdir -p /etc/machine
cat > /etc/machine/create-user.sh <<INNER
#!/bin/sh
set -eu
# User, home, toolchains, and configs are baked at build time and persist
# (home-mount=none). This script only suppresses the built-in default, which
# would re-create the user under the host UID and clobber the home.
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USER_NAME"
chmod 0440 /etc/sudoers.d/"$USER_NAME"
passwd -d "$USER_NAME" 2>/dev/null || true
INNER
chmod 0755 /etc/machine/create-user.sh
OUTER

# Homebrew for Linux (needed for packages Debian lags on, e.g. mkcert).
# Installs to /home/linuxbrew/.linuxbrew (already on PATH via BREW_PREFIX).
USER ${USER_NAME}
RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
USER root

# mkcert: locally-trusted dev certs. libnss3-tools (certutil) was installed
# via apt above so mkcert can install its root CA into the NSS store.
USER ${USER_NAME}
RUN brew install mkcert && mkcert -install
USER root

# Trust github.com inside the machine so `git clone git@github.com:...`
# (and pushes via the forwarded agent) work without an interactive host-key
# prompt. System-wide known_hosts is read by every user's ssh client.
RUN mkdir -p /etc/ssh && \
    ssh-keyscan -t ed25519,ecdsa,rsa github.com >> /etc/ssh/ssh_known_hosts

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

USER ${USER_NAME}
WORKDIR ${HOME_DIR}

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

USER ${USER_NAME}
WORKDIR ${HOME_DIR}

# pi (the coding agent). Installed globally via npm; its prefix is ~/.local
# (set up in the typescript stage), so `pi` lands in ~/.local/bin (already on
# PATH).
RUN npm install -g @earendil-works/pi-coding-agent && pi --version

# ── dev ──────────────────────────────────────────────────
# Empty-body alias, so 'dev' is always the final complete target.
FROM llm AS devbox

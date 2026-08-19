# devbox

Develop inside Apple Containers VMs. Build a ready-to-use image, spin up named
machines, and SSH into them — all through a small `devbox` helper script.

## What's in the box

- **Debian stable-slim** base with **systemd** as PID 1
- **fish** login shell, **starship** prompt, **passwordless sudo**
- SSH access keyed off your public key in `./authorized_keys`
- host mkcert root CA trusted by the machine's NSS store, so mkcert certificates are trusted by the host's Keychain
- CLI tooling: `git`, `gh`, `ripgrep`, `fd`, `fzf`, `jq`, `bat`, `eza`, `sqlite3`
- Chezmoi dotfiles installed from repo on github
- Language toolchains:
  - **uv** (Python; installs to `~/.local/bin`)
  - **Node.js** latest LTS with **npm**/**npx**/**corepack** (installed to `~/.local`,
    npm global prefix `~/.local`)
  - **bun** (JS/TS; installs to `~/.bun/bin`)
- `pi` coding agent installed via npm, with OLLAMA API key passed in over ssh.

## Quick start

```sh
# 1. Build the image (one time)
./devbox build

# 2. Create + start a machine
./devbox create devbox1

# 3. SSH in (agent forwarded, host resolves via <name>.machine DNS)
./devbox ssh devbox1
```

## Usage

```
Usage: devbox <subcommand> [name] [options...]

Subcommands:
  build [--no-cache]           build the image (refreshes ./authorized_keys;
                               --no-cache forces a full rebuild, ignoring layer cache)
  create <name>                create + start machine (--home-mount=none)
  start <name>                 start a stopped machine
  stop <name>                  stop a running machine
  ssh <name>                   ssh <name>.machine (agent forwarded)
  run <name> [args...]         passthrough to `container machine run -n <name>`
  inspect <name>               inspect a machine
  list                         list all machines
  destroy <name>               stop + delete (y/N confirm)
  git-clone <name> <repo>      clone git@github.com:$USER/<repo>.git into <name>.machine
  help                         this message
```

## Requirements

- macOS with Apple Containers (`container` CLI / Container framework)
- An SSH keypair; the public key goes in `./authorized_keys` (refreshed by `devbox build`)
- A git identity (`user.name` / `user.email`); `devbox build` reads it from your
  git config and bakes it into the image
- A chezmoi dotfiles repo (`$USER/dotfiles`) on github.

## License

See [LICENSE](LICENSE).

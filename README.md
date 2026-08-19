# devbox

Develop inside Apple Containers VMs. Build a ready-to-use image, spin up named
machines, and SSH into them — all through a small `devbox` helper script.

## What's in the box

- **Debian stable-slim** base with **systemd** as PID 1
- **fish** login shell, **starship** prompt, **passwordless sudo**
- CLI tooling: `git`, `gh`, `ripgrep`, `fd`, `fzf`, `jq`, `bat`, `eza`, `sqlite3`
- Language toolchains:
  - **uv** (Python; installs to `~/.local/bin`)
  - **Node.js** latest LTS with **npm**/**npx**/**corepack** (installed to `~/.local`,
    npm global prefix `~/.local`)
  - **bun** (JS/TS; installs to `~/.bun/bin`)
- `pi` coding agent installed globally via npm
- SSH access keyed off your public key in `./authorized_keys`

## Quick start

```sh
# 1. Provide your public SSH key (only the public key, never the secret)
cp ~/.ssh/id_ed25519.pub ./authorized_keys

# 2. Build the image
./devbox build

# 3. Create + start a machine
./devbox create devbox1

# 4. SSH in (agent forwarded, host resolves via <name>.machine DNS)
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
  ssh <name>                   ssh <name>.<domain> (agent forwarded)
  run <name> [args...]         passthrough to `container machine run -n <name>`
  inspect <name>               inspect a machine
  list                         list all machines
  destroy <name>               stop + delete (y/N confirm)
  help                         this message
```

## Requirements

- macOS with Apple Containers (`container` CLI / Container framework)
- An SSH keypair; the public key goes in `./authorized_keys`

## License

See [LICENSE](LICENSE).

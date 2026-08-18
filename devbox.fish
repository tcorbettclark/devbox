#!/usr/bin/env fish
#
# devbox.fish — manage Apple `container` development machines for container-play.
#
# All stateful subcommands take the machine NAME as their first argument, so you
# can run several devboxes side by side. `build` and `ls` are global (they don't
# act on a specific machine).
#
# Usage:
#   devbox setup <name> [--image IMG]   one-time per name: create DNS domain `machine`
#                                      (sudo, idempotent) + add a `Host <name>.machine`
#                                      block to ~/.ssh/config (ForwardAgent yes).
#   devbox build [--target T] [--tag T] copy ~/.ssh/id_ed25519.pub → ./authorized_keys,
#                                      then `container build --target T -t T .`.
#   devbox create <name> [--image IMG]  `container machine create --home-mount=none
#                                      --name <name> <IMG>` then start it.
#                                      --home-mount=none is HARDCODED (safety boundary).
#   devbox start <name>                 `container machine start <name>`
#   devbox stop <name>                  `container machine stop <name>`
#   devbox ssh <name>                   `ssh <name>.machine` (uses the ForwardAgent block)
#   devbox run <name> [args...]         passthrough to `container machine run -n <name> [args]`
#                                      e.g. `devbox run mybox -- ls -la`
#                                           `devbox run mybox -e AWS_KEY=x -- aws s3 ls`
#                                           `devbox run mybox`            (interactive shell)
#   devbox status <name>                `container machine inspect <name>`
#   devbox ls                           `container machine ls` (all machines)
#   devbox destroy <name>               stop + delete <name>; prompts y/N
#   devbox help                         this message
#
# Overridable defaults (env vars):
#   DEVBOX_DEFAULT_IMAGE  (default: dev:latest)
#   DEVBOX_DEFAULT_TARGET (default: dev)
#   DEVBOX_DNS_DOMAIN     (default: machine)
#   DEVBOX_SSH_KEY        (default: ~/.ssh/id_ed25519)
#   DEVBOX_USER           (default: tcorbettclark)

# ── defaults ────────────────────────────────────────────────────────────────
set -g _devbox_dir (realpath (dirname (status --current-filename)))
set -gx DEVBOX_DEFAULT_IMAGE  (set -q DEVBOX_DEFAULT_IMAGE;  and echo $DEVBOX_DEFAULT_IMAGE;  or echo dev:latest)
set -gx DEVBOX_DEFAULT_TARGET (set -q DEVBOX_DEFAULT_TARGET; and echo $DEVBOX_DEFAULT_TARGET; or echo dev)
set -gx DEVBOX_DNS_DOMAIN     (set -q DEVBOX_DNS_DOMAIN;     and echo $DEVBOX_DNS_DOMAIN;     or echo machine)
set -gx DEVBOX_SSH_KEY        (set -q DEVBOX_SSH_KEY;        and echo $DEVBOX_SSH_KEY;        or echo "$HOME/.ssh/id_ed25519")
set -gx DEVBOX_USER           (set -q DEVBOX_USER;           and echo $DEVBOX_USER;           or echo tcorbettclark)

# ── helpers ─────────────────────────────────────────────────────────────────
function _devbox_usage
    echo "Usage: devbox <subcommand> [name] [options...]"
    echo
    echo "Subcommands:"
    echo "  setup <name> [--image IMG]   one-time: DNS domain + ~/.ssh/config Host block"
    echo "  build [--target T] [--tag T] build the image (refreshes ./authorized_keys)"
    echo "  create <name> [--image IMG]  create + start machine (--home-mount=none)"
    echo "  start <name>                 start a stopped machine"
    echo "  stop <name>                  stop a running machine"
    echo "  ssh <name>                   ssh <name>.<domain> (agent forwarded)"
    echo "  run <name> [args...]         passthrough to `container machine run -n <name>`"
    echo "  status <name>                inspect a machine"
    echo "  ls                           list all machines"
    echo "  destroy <name>               stop + delete (y/N confirm)"
    echo "  help                         this message"
end

function _devbox_require_name --argument-names cmd
    set -l name $argv[2]
    if test -z "$name"
        echo "Error: '$cmd' requires a machine name." >&2
        echo "Usage: devbox $cmd <name>" >&2
        return 1
    end
    return 0
end

# ── subcommands ─────────────────────────────────────────────────────────────

function _devbox_setup
    set -l name $argv[1]
    _devbox_require_name setup $name; or return
    set -l host $name.$DEVBOX_DNS_DOMAIN

    # 1. DNS domain (global; sudo; idempotent).
    if not contains $DEVBOX_DNS_DOMAIN (container system dns list -q 2>/dev/null)
        echo "Creating DNS domain '$DEVBOX_DNS_DOMAIN' (requires sudo)..."
        sudo container system dns create $DEVBOX_DNS_DOMAIN
        or return
    else
        echo "DNS domain '$DEVBOX_DNS_DOMAIN' already exists."
    end

    # 2. ~/.ssh/config Host block (per name; idempotent — never rewrites existing).
    set -l cfg $HOME/.ssh/config
    if test -f $cfg; and grep -q -x -- "Host $host" $cfg
        echo "SSH config already has 'Host $host'."
    else
        echo "Adding 'Host $host' block to $cfg..."
        mkdir -p $HOME/.ssh
        printf '\nHost %s\n  User %s\n  IdentityFile %s\n  ForwardAgent yes\n  UserKnownHostsFile /dev/null\n  StrictHostKeyChecking no\n' \
            $host $DEVBOX_USER $DEVBOX_SSH_KEY >>$cfg
    end
    echo "Done. Next: devbox build && devbox create $name"
end

function _devbox_build
    argparse --name=devbox-build 't/target=' 'tag=' -- $argv
    or return
    set -l target (set -q _flag_target; and echo $_flag_target; or echo $DEVBOX_DEFAULT_TARGET)
    set -l tag (set -q _flag_tag; and echo $_flag_tag; or echo $DEVBOX_DEFAULT_IMAGE)

    set -l pubkey $DEVBOX_SSH_KEY.pub
    if not test -f $pubkey
        echo "Error: public key not found at $pubkey" >&2
        echo "Set DEVBOX_SSH_KEY or generate a key first." >&2
        return 1
    end

    echo "Copying $pubkey → $_devbox_dir/authorized_keys"
    cp $pubkey $_devbox_dir/authorized_keys
    or return

    echo "Building target '$target' → tag '$tag'..."
    cd $_devbox_dir
    container build --target $target -t $tag .
end

function _devbox_create
    argparse --name=devbox-create 'i/image=' -- $argv
    or return
    set -l name $argv[1]
    _devbox_require_name create $name; or return
    set -l image (set -q _flag_image; and echo $_flag_image; or echo $DEVBOX_DEFAULT_IMAGE)

    echo "Creating machine '$name' from '$image' with --home-mount=none..."
    # --home-mount=none is the safety boundary: never mount the host home dir.
    # `container machine create` boots the machine by default.
    container machine create --home-mount=none --name $name $image
    and echo "Machine '$name' is up. Connect with: devbox ssh $name"
end

function _devbox_start
    set -l name $argv[1]
    _devbox_require_name start $name; or return
    # `container machine` has no `start` subcommand; `run` boots a stopped
    # machine. Run /bin/true so we boot without leaving a shell process behind.
    container machine run -n $name -- /bin/true
    and echo "Machine '$name' started."
end

function _devbox_stop
    set -l name $argv[1]
    _devbox_require_name stop $name; or return
    container machine stop $name
end

function _devbox_ssh
    set -l name $argv[1]
    _devbox_require_name ssh $name; or return
    # `exec` replaces this fish process with ssh; agent forwarding comes from the
    # ~/.ssh/config block added by `devbox setup`.
    exec ssh $name.$DEVBOX_DNS_DOMAIN
end

function _devbox_run
    set -l name $argv[1]
    _devbox_require_name run $name; or return
    set -e argv[1]
    # Forward everything else (including `--`, `-e K=V`, and the command) verbatim.
    container machine run -n $name $argv
end

function _devbox_status
    set -l name $argv[1]
    _devbox_require_name status $name; or return
    container machine inspect $name
end

function _devbox_ls
    container machine ls
end

function _devbox_destroy
    set -l name $argv[1]
    _devbox_require_name destroy $name; or return

    echo "This will STOP and DELETE machine '$name' and its filesystem."
    echo "Any uncommitted work inside is LOST — push to git first."
    read -l -P "Destroy '$name'? [y/N] " confirm
    if not string match -qr '^[yY]$' -- $confirm
        echo "Aborted."
        return
    end
    container machine stop $name 2>/dev/null # ignore error if not running
    container machine delete $name
end

# ── dispatch ────────────────────────────────────────────────────────────────
set -l cmd $argv[1]
set -e argv[1]

switch $cmd
    case setup    ; _devbox_setup $argv
    case build    ; _devbox_build $argv
    case create   ; _devbox_create $argv
    case start    ; _devbox_start $argv
    case stop     ; _devbox_stop $argv
    case ssh      ; _devbox_ssh $argv
    case run      ; _devbox_run $argv
    case status   ; _devbox_status $argv
    case ls       ; _devbox_ls $argv
    case destroy  ; _devbox_destroy $argv
    case help -h --help '' ; _devbox_usage
    case '*'
        echo "Unknown subcommand: '$cmd'" >&2
        echo
        _devbox_usage >&2
        exit 1
end
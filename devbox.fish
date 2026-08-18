#!/usr/bin/env fish
#
# devbox.fish — manage Apple `container` development machines.
#
# ── defaults ────────────────────────────────────────────────────────────────
set -g _devbox_dir (realpath (dirname (status --current-filename)))
set -gx DEVBOX_IMAGE          (set -q DEVBOX_IMAGE;          and echo $DEVBOX_IMAGE;          or echo dev:latest)
set -gx DEVBOX_TARGET         (set -q DEVBOX_TARGET;         and echo $DEVBOX_TARGET;         or echo dev)
set -gx DEVBOX_DNS_DOMAIN     (set -q DEVBOX_DNS_DOMAIN;     and echo $DEVBOX_DNS_DOMAIN;     or echo machine)
set -gx DEVBOX_SSH_KEY        (set -q DEVBOX_SSH_KEY;        and echo $DEVBOX_SSH_KEY;        or echo "$HOME/.ssh/id_ed25519")
set -gx DEVBOX_USER           (set -q DEVBOX_USER;           and echo $DEVBOX_USER;           or echo tcorbettclark)

# ── helpers ─────────────────────────────────────────────────────────────────
function _devbox_usage
    echo "Usage: devbox <subcommand> [name] [options...]"
    echo
    echo "Subcommands:"
    echo "  build [--no-cache]           build the image (refreshes ./authorized_keys;"
    echo "                               --no-cache forces a full rebuild, ignoring layer cache)"
    echo "  create <name>                create + start machine (--home-mount=none)"
    echo "  start <name>                 start a stopped machine"
    echo "  stop <name>                  stop a running machine"
    echo "  ssh <name>                   ssh <name>.<domain> (agent forwarded)"
    echo "  run <name> [args...]         passthrough to `container machine run -n <name>`"
    echo "  inspect <name>               inspect a machine"
    echo "  list                         list all machines"
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

function _setup_dns
    set -l name $argv[1]
    set -l host $name.$DEVBOX_DNS_DOMAIN
    if not contains $DEVBOX_DNS_DOMAIN (container system dns list -q 2>/dev/null)
        echo "Creating DNS domain '$DEVBOX_DNS_DOMAIN' (requires sudo)..."
        sudo container system dns create $DEVBOX_DNS_DOMAIN
        or return
    end
end

function _setup_ssh
    set -l name $argv[1]
    set -l host $name.$DEVBOX_DNS_DOMAIN
    set -l cfgdir $HOME/.ssh/config.d
    set -l cfgfile $cfgdir/$name.machine
    mkdir -p $cfgdir
    if not test -f $cfgfile
        echo "Writing 'Host $host' block to $cfgfile..."
        printf 'Host %s\n  User %s\n  IdentityFile %s\n  ForwardAgent yes\n  UserKnownHostsFile /dev/null\n  StrictHostKeyChecking no\n' \
            $host $DEVBOX_USER $DEVBOX_SSH_KEY >$cfgfile
    end
end

function _delete_ssh_config
    set -l name $argv[1]
    set -l cfgdir $HOME/.ssh/config.d
    set -l cfgfile $cfgdir/$name.machine
    if test -f $cfgfile
        rm -f $cfgfile
        echo "Removed $cfgfile"
    end
end


# ── subcommands ─────────────────────────────────────────────────────────────
function _devbox_build
    argparse --name=devbox-build 'no-cache' -- $argv
    or return

    set -l pubkey $DEVBOX_SSH_KEY.pub
    if not test -f $pubkey
        echo "Error: public key not found at $pubkey" >&2
        echo "Set DEVBOX_SSH_KEY or generate a key first." >&2
        return 1
    end

    echo "Copying $pubkey → $_devbox_dir/authorized_keys"
    cp $pubkey $_devbox_dir/authorized_keys
    or return

    set -l cache_note
    set -l build_args --target $DEVBOX_TARGET -t $DEVBOX_IMAGE
    if set -q _flag_no_cache
        set -a build_args --no-cache
        set cache_note " (no cache; rebuilds every layer)"
    end

    echo "Building target '$DEVBOX_TARGET' → tag '$DEVBOX_IMAGE'$cache_note..."
    cd $_devbox_dir
    container build $build_args .
    and echo "Build completed."
end

function _devbox_create
    set -l name $argv[1]
    _devbox_require_name create $name; or return

    _setup_dns $name
    _setup_ssh $name

    echo "Creating machine '$name' from '$DEVBOX_IMAGE' with --home-mount=none..."
    # --home-mount=none is the safety boundary: never mount the host home dir.
    # `container machine create` boots the machine by default.
    container machine create --home-mount=none --name $name $DEVBOX_IMAGE
    and echo "Machine '$name' is up."
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
    and echo "Machine '$name' stopped."
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

function _devbox_inspect
    set -l name $argv[1]
    _devbox_require_name inspect $name; or return
    container machine inspect $name
end

function _devbox_list
    container machine list
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

    _delete_ssh_config $name
end

# ── dispatch ────────────────────────────────────────────────────────────────
set -l cmd $argv[1]
set -e argv[1]

switch $cmd
    case build    ; _devbox_build $argv
    case create   ; _devbox_create $argv
    case start    ; _devbox_start $argv
    case stop     ; _devbox_stop $argv
    case ssh      ; _devbox_ssh $argv
    case run      ; _devbox_run $argv
    case inspect  ; _devbox_inspect $argv
    case list     ; _devbox_list $argv
    case destroy  ; _devbox_destroy $argv
    case help -h --help '' ; _devbox_usage
    case '*'
        echo "Unknown subcommand: '$cmd'" >&2
        echo
        _devbox_usage >&2
        exit 1
end

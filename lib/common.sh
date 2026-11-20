# shellcheck shell=bash
# Shared helpers for the incus-*-node scripts. Sourced, not executed.

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "$*" >&2; }

# api_exists <api-path>: 0 if it exists, 1 if Incus says "not found".
# Other errors are fatal, so a broken Incus never looks like "does not exist".
api_exists() {
    local err
    if err=$(incus query "$1" 2>&1 >/dev/null); then
        return 0
    fi
    [[ $err == *"not found"* ]] && return 1
    die "incus query $1 failed: ${err#Error: }"
}

instance_exists() { api_exists "/1.0/instances/$1"; }
profile_exists()  { api_exists "/1.0/profiles/$1"; }
network_exists()  { api_exists "/1.0/networks/$1"; }
volume_exists()   { api_exists "/1.0/storage-pools/$1/volumes/custom/$2"; }

require_cmds() {
    local c
    for c; do
        command -v "$c" >/dev/null || die "'$c' is required but not installed"
    done
}

require_profile() {
    profile_exists "$1" || die "profile '$1' not found (run setup.sh first)"
}

# Hostname rules. Also keeps names starting with "-" from becoming options.
check_names() {
    local n
    for n; do
        [[ $n =~ ^[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "invalid instance name: '$n'"
    done
}

# option_value <option> <value...>: print the value, or die if it is missing.
option_value() {
    [[ $# -ge 2 && -n $2 && $2 != -* ]] || die "$1 needs a value"
    printf '%s\n' "$2"
}

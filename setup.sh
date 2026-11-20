#!/usr/bin/env bash
# Create the Incus networks and profiles used by the incus-*-node scripts.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
# shellcheck source=lib/common.sh
source lib/common.sh

# Template variables, replaced as ${NAME} in profiles/*.yaml.
POOL=${POOL:-default}
PXE_GATEWAY=${PXE_GATEWAY:-10.20.0.1}
PXE_PREFIX=${PXE_PREFIX:-24}
MAAS_IP=${MAAS_IP:-10.20.0.2}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
SSH_IDENTITY=""
TEMPLATE_VARS=(POOL PXE_GATEWAY PXE_PREFIX MAAS_IP SSH_PUBLIC_KEY SSH_IDENTITY)

usage() {
    cat <<'EOF'
Usage: setup.sh [--ssh-key FILE]

Create the maas-pxe and kolla-ext networks and load the profiles in profiles/.
Safe to re-run: existing networks are checked and kept, profiles are updated.

Profiles are templates. ${NAME} is replaced with these values:
  POOL             storage pool for VM disks          (default)
  PXE_GATEWAY      host address on maas-pxe           (10.20.0.1)
  PXE_PREFIX       maas-pxe prefix length             (24)
  MAAS_IP          static address of the MAAS VM      (10.20.0.2)
  SSH_PUBLIC_KEY   key allowed to log in to MAAS as ubuntu
  SSH_IDENTITY     matching private key, used by incus-maas-node (set automatically)
Set them in the environment to change them.

The SSH key comes from --ssh-key FILE, else SSH_PUBLIC_KEY, else the first of
~/.ssh/id_ed25519.pub, ~/.ssh/id_ecdsa.pub, ~/.ssh/id_rsa.pub.
EOF
}

key_file=""
while (( $# )); do
    case $1 in
        --ssh-key)   key_file=$(option_value "$@") || exit 1; shift ;;
        --ssh-key=*) key_file=${1#*=} ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

if [[ -z $key_file && -z $SSH_PUBLIC_KEY ]]; then
    for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
        if [[ -r $f ]]; then key_file=$f; break; fi
    done
    [[ -n $key_file ]] || die "no SSH public key found; use --ssh-key FILE or set SSH_PUBLIC_KEY"
fi
if [[ -n $key_file ]]; then
    [[ -r $key_file ]] || die "cannot read SSH key file: $key_file"
    SSH_PUBLIC_KEY=$(head -n1 "$key_file")
    key_file=$(readlink -f "$key_file")
    if [[ $key_file == *.pub && -r ${key_file%.pub} ]]; then
        SSH_IDENTITY=${key_file%.pub}
    fi
fi
# Drop the key comment: free text like "me@laptop: work" would break the YAML.
read -r key_type key_data _ <<<"$SSH_PUBLIC_KEY"
if ! [[ ${key_type:-} =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]+$ && ${key_data:-} =~ ^[A-Za-z0-9+/=]+$ ]]; then
    die "that doesn't look like an SSH public key: ${SSH_PUBLIC_KEY:0:40}..."
fi
SSH_PUBLIC_KEY="$key_type $key_data"
# Goes inside double quotes in the YAML.
[[ $SSH_IDENTITY != *[\"\\]* ]] || die "SSH key path must not contain quotes or backslashes: $SSH_IDENTITY"

# ip_to_int <address>: print an IPv4 address as a number; fail if invalid.
ip_to_int() {
    local a b c d
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
    c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

if ! [[ $PXE_PREFIX =~ ^[0-9]+$ ]] || (( PXE_PREFIX < 8 || PXE_PREFIX > 30 )); then
    die "PXE_PREFIX must be between 8 and 30"
fi
gw=$(ip_to_int "$PXE_GATEWAY") || die "PXE_GATEWAY is not an IPv4 address: $PXE_GATEWAY"
maas=$(ip_to_int "$MAAS_IP") || die "MAAS_IP is not an IPv4 address: $MAAS_IP"
mask=$(( (0xFFFFFFFF << (32 - PXE_PREFIX)) & 0xFFFFFFFF ))
(( (gw & mask) == (maas & mask) )) || die "MAAS_IP $MAAS_IP is not in $PXE_GATEWAY/$PXE_PREFIX"
(( gw != maas )) || die "MAAS_IP and PXE_GATEWAY must differ"
host=$(( maas & ~mask & 0xFFFFFFFF ))
(( host != 0 && host != (~mask & 0xFFFFFFFF) )) \
    || die "MAAS_IP $MAAS_IP is the network or broadcast address of $PXE_GATEWAY/$PXE_PREFIX"
api_exists "/1.0/storage-pools/$POOL" || die "storage pool '$POOL' not found"

# render <file>: replace ${NAME} for each of TEMPLATE_VARS, literally.
render() {
    local content var left
    content=$(<"$1")
    for var in "${TEMPLATE_VARS[@]}"; do
        content=${content//"\${$var}"/"${!var}"}
    done
    left=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' <<<"$content" | sort -u | tr '\n' ' ' || true)
    [[ -z $left ]] || die "$1: unknown template variables: $left"
    printf '%s\n' "$content"
}

# maas-pxe: MAAS does DHCP/PXE, so Incus DHCP is off; NAT gives nodes internet.
if ! network_exists maas-pxe; then
    incus network create maas-pxe ipv4.address="$PXE_GATEWAY/$PXE_PREFIX" \
        ipv4.dhcp=false ipv4.nat=true ipv6.address=none
else
    addr=$(incus network get maas-pxe ipv4.address)
    [[ $addr == "$PXE_GATEWAY/$PXE_PREFIX" ]] \
        || warn "warning: maas-pxe has address $addr, not $PXE_GATEWAY/$PXE_PREFIX; MAAS_IP must be inside it"
    [[ $(incus network get maas-pxe ipv4.dhcp) == false ]] \
        || warn "warning: maas-pxe has Incus DHCP enabled; it will compete with MAAS (incus network set maas-pxe ipv4.dhcp=false)"
fi

# kolla-ext: L2 only, for neutron_external_interface and bonding tests.
# dns.mode=none allows several NICs of one VM on it.
if ! network_exists kolla-ext; then
    incus network create kolla-ext ipv4.address=none ipv6.address=none dns.mode=none
elif [[ $(incus network get kolla-ext dns.mode) != none ]]; then
    incus network set kolla-ext dns.mode=none
    echo "Set dns.mode=none on kolla-ext"
fi

for file in profiles/*.yaml; do
    name=$(basename "$file" .yaml)
    content=$(render "$file")
    # Created with its YAML in one step, so a bad file leaves no empty profile.
    if profile_exists "$name"; then
        incus profile edit "$name" <<<"$content"
        echo "Updated profile $name"
    else
        incus profile create "$name" <<<"$content"
        echo "Created profile $name"
    fi
done

echo "SSH key: ${SSH_PUBLIC_KEY:0:30}...${SSH_PUBLIC_KEY: -20}"
echo "SSH identity for incus-maas-node: ${SSH_IDENTITY:-ssh default}"
echo "Done. Put bin/ on your PATH, or symlink the scripts into ~/.local/bin."

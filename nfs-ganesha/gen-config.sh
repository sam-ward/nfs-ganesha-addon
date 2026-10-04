#!/bin/bash
# Writes ganesha.conf for the add-on options to stdout. Log lines go to stderr.
# Usage: gen-config.sh [options.json] [root] [network-info.json]
#   root prefixes the folder existence check (tests only).
#   network-info.json resolves "auto" in authorized_ips: the Supervisor's
#   /network/info data (or run.sh's routing-table fallback in the same shape),
#   plus a "source" field naming where it came from.
set -e

CONFIG_PATH=${1:-/data/options.json}
ROOT=${2:-/}
NETWORK_INFO=${3:-}

# Prints the network (a.b.c.d/nn) of HA's primary interface, or fails.
# Accepts the Supervisor v1 shape (interface, connected, ipv4.address[]) and
# the v2 one (name, state.connected, state.ipv4.addresses[]).
resolve_auto() {
    local iface cidr ip prefix a b c d n mask
    [ -n "$NETWORK_INFO" ] && [ -s "$NETWORK_INFO" ] || return 1
    read -r iface cidr < <(jq --raw-output '
        [.interfaces[]?
         | select(.primary == true and ((.connected // .state.connected) == true))
         | [(.interface // .name),
            (((.ipv4.address // .state.ipv4.addresses // []) | map(select(test(":") | not)))[0] // empty)]
         | select(length == 2)][0] // empty | join(" ")' "$NETWORK_INFO") || return 1
    [ -n "$cidr" ] || return 1
    ip=${cidr%/*}; prefix=${cidr#*/}
    [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}; d=${BASH_REMATCH[4]}
    [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix >= 8 && prefix <= 32 )) || return 1
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    n=$(( ((a << 24) | (b << 16) | (c << 8) | d) & mask ))
    AUTO_NET="$(( n >> 24 & 255 )).$(( n >> 16 & 255 )).$(( n >> 8 & 255 )).$(( n & 255 ))/${prefix}"
    AUTO_IFACE=$iface
    AUTO_SOURCE=$(jq --raw-output '.source // "network info"' "$NETWORK_INFO")
}

# True if $1 is an entry Ganesha's Clients list can take safely: "*", an IPv4
# address or CIDR, an IPv6 address or CIDR, a netgroup (@name), a host name
# pattern (with * or ?), or a hostname. Anything else could be a typo that
# silently matches no one, or break ganesha.conf.
valid_client() {
    local e=$1 o
    [ "$e" = "*" ] && return 0
    [[ "$e" =~ ^@[A-Za-z0-9._-]+$ ]] && return 0
    if [[ "$e" == *[*?]* ]]; then
        # "]" first: the only way to put a literal ] in a bracket expression.
        [[ "$e" =~ ^[][A-Za-z0-9.*?-]+$ ]]
        return
    fi
    if [[ "$e" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)(/([0-9]+))?$ ]]; then
        for o in 1 2 3 4; do (( BASH_REMATCH[o] <= 255 )) || return 1; done
        [ -z "${BASH_REMATCH[5]}" ] || (( BASH_REMATCH[6] <= 32 ))
        return
    fi
    if [[ "$e" == *:* ]]; then
        [[ "$e" =~ ^[0-9A-Fa-f:.]+(/([0-9]+))?$ ]] || return 1
        [ -z "${BASH_REMATCH[1]}" ] || (( BASH_REMATCH[2] <= 128 ))
        return
    fi
    # A hostname: dot-separated labels of letters, digits and inner hyphens,
    # with at least one letter (an all-numeric entry must be a valid IPv4).
    [[ "$e" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] \
        && [[ "$e" == *[A-Za-z]* ]]
}

# Read the authorized_ips array, blank entries dropped
mapfile -t IP_ENTRIES < <(jq --raw-output \
    '.authorized_ips[]? | strings | gsub("^\\s+|\\s+$"; "") | select(length > 0)' \
    "$CONFIG_PATH")

# Replace "auto" with HA's primary subnet. Never guess: refuse if it can't be resolved.
CLIENTS=()
for entry in "${IP_ENTRIES[@]}"; do
    [ "${entry,,}" != auto ] || entry=auto
    if [ "$entry" != auto ] && ! valid_client "$entry"; then
        echo "[ERROR] authorized_ips entry \"$entry\" is not an IP address, subnet (e.g. 192.168.1.0/24), hostname or pattern, @netgroup, \"auto\" or \"*\". Refusing to start." >&2
        exit 1
    fi
    if [ "$entry" = auto ]; then
        if ! resolve_auto; then
            echo "[ERROR] authorized_ips \"auto\" could not be resolved (no connected primary network with an IPv4 address); set your subnet explicitly, e.g. 192.168.1.0/24. Refusing to start." >&2
            exit 3  # run.sh retries this one while the network comes up
        fi
        echo "[NFS] authorized_ips \"auto\" -> ${AUTO_NET} (primary interface ${AUTO_IFACE}, from ${AUTO_SOURCE})" >&2
        entry=$AUTO_NET
    fi
    [[ " ${CLIENTS[*]} " == *" $entry "* ]] || CLIENTS+=("$entry")
done
# Join with commas for Ganesha
AUTHORIZED_IPS=$(IFS=,; echo "${CLIENTS[*]}")

# Read the export_folders array
EXPORT_FOLDERS=$(jq --raw-output '.export_folders[]? | strings' "$CONFIG_PATH")

# Missing on installs upgraded from <=1.2.x, so fall back to the default.
LOG_LEVEL=$(jq --raw-output '.log_level // "WARN"' "$CONFIG_PATH")
echo "[NFS] Log level: ${LOG_LEVEL}" >&2

# At WARN and quieter, keep 1.2.x's muting of chatty components. At EVENT and
# above the user is debugging, so show everything.
case "$LOG_LEVEL" in
    NULL|FATAL|MAJ|CRIT|WARN)
        LOG_COMPONENTS="COMPONENTS {
        TIRPC = FATAL;
        NFS_CB = FATAL;
        INIT = FATAL;
        DISPATCH = FATAL;
    }" ;;
    *) LOG_COMPONENTS="" ;;
esac

echo "[NFS] Authorized IPs: ${AUTHORIZED_IPS}" >&2
echo "[NFS] Export folders: $(jq --raw-output '.export_folders | join(", ")' "$CONFIG_PATH")" >&2

# An empty client list would give "Clients = ;", so refuse rather than guess.
if [ -z "$AUTHORIZED_IPS" ]; then
    echo "[ERROR] authorized_ips is empty; add at least one IP or subnet. Refusing to start." >&2
    exit 1
fi

cat <<EOF
###################################################
#     NFS-Ganesha Config Generated by Addon       #
###################################################

NFS_CORE_PARAM
{
    NFS_Port = 2049;
    NFS_Protocols = 4;
    Enable_NLM = false;
    Enable_RQUOTA = false;
    # Ganesha 6.x calls prctl(PR_SET_IO_FLUSHER), which needs SYS_RESOURCE
    # (granted in config.yaml). If a platform withholds it, start anyway.
    Allow_Set_Io_Flusher_Fail = true;
}

NFSv4
{
    Grace_Period = 60;
    # Use numeric IDs to avoid ID mapping issues
    Only_Numeric_Owners = true;
}

EXPORT_DEFAULTS
{
    Squash = All_Squash;
    Anonymous_Uid = 0;
    Anonymous_Gid = 0;
}

NFS_KRB5
{
    Active_krb5 = false;
}

LOG {
    Default_Log_Level = ${LOG_LEVEL};
    ${LOG_COMPONENTS}
}
EOF

# Add Exports based on user selection.
# Each option name maps to the folder config.yaml mounts (Path) and the path
# clients mount (Pseudo). As in the Samba add-on, "addons"/"addon_configs" are
# the legacy names of "local_apps"/"app_configs" and stay mountable as aliases.
declare -A FOLDER_PATH=(
    [config]=/homeassistant [ssl]=/ssl [local_apps]=/local_apps
    [app_configs]=/app_configs [backup]=/backup [share]=/share [media]=/media
)
declare -A LEGACY_PSEUDO=([local_apps]=/addons [app_configs]=/addon_configs)
# Fixed export ids: clients' file handles include them, so a folder's id must
# not change when other folders are added or removed. 10-16 follow 1.2.x's
# default order, so installs updated from it keep their ids.
declare -A FOLDER_ID=(
    [config]=10 [ssl]=11 [local_apps]=12 [app_configs]=13
    [backup]=14 [share]=15 [media]=16
)
declare -A LEGACY_ID=([local_apps]=17 [app_configs]=18)

export_block() {  # <id> <path> <pseudo>
    cat <<EOF

EXPORT
{
    Export_Id = $1;
    Path = "$2";
    Pseudo = "$3";
    FSAL { Name = VFS; }
    Access_Type = None;
    CLIENT
    {
        Clients = $AUTHORIZED_IPS;
        Protocols = 4;
        Access_Type = RW;
    }
}
EOF
}

EXPORTED=" "
ALIASES=()

while IFS= read -r FOLDER; do
    case "$FOLDER" in
        addons) FOLDER=local_apps ;;
        addon_configs) FOLDER=app_configs ;;
    esac
    # Only the folders config.yaml maps. An empty name would export "/" itself.
    case "$FOLDER" in
        config|ssl|local_apps|app_configs|backup|share|media) ;;
        "") continue ;;
        *)
            echo "[WARN] Unknown export folder '$FOLDER', skipping..." >&2
            continue
            ;;
    esac
    [[ "$EXPORTED" == *" $FOLDER "* ]] && continue
    DIR=${FOLDER_PATH[$FOLDER]}

    if [ -d "${ROOT%/}$DIR" ]; then
        echo "[NFS] Exporting: /$FOLDER" >&2
        export_block "${FOLDER_ID[$FOLDER]}" "$DIR" "/$FOLDER"
        EXPORTED+="$FOLDER "
        [ -z "${LEGACY_PSEUDO[$FOLDER]:-}" ] || ALIASES+=("$FOLDER")
    else
        echo "[WARN] Directory $DIR does not exist, skipping..." >&2
    fi
done <<< "$EXPORT_FOLDERS"

for FOLDER in "${ALIASES[@]}"; do
    echo "[NFS] Also exporting: ${LEGACY_PSEUDO[$FOLDER]} (${LEGACY_PSEUDO[$FOLDER]} is a legacy path for /$FOLDER; switch clients to /$FOLDER)" >&2
    export_block "${LEGACY_ID[$FOLDER]}" "${FOLDER_PATH[$FOLDER]}" "${LEGACY_PSEUDO[$FOLDER]}"
done

if [ "$EXPORTED" = " " ]; then
    echo "[ERROR] No export folders to share; select at least one in export_folders. Refusing to start." >&2
    exit 1
fi

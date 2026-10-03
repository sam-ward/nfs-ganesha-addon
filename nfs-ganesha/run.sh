#!/bin/bash
set -e

CONFIG_PATH=/data/options.json
SUPERVISOR_API=${SUPERVISOR_API:-http://supervisor}

echo "[NFS] Starting NFS-Ganesha (Debian Mode)..."
# Always logged, so a pasted log shows exactly what is running.
echo "[NFS] App version: ${ADDON_VERSION:-unknown}"
echo "[NFS] Ganesha version: $(/usr/bin/ganesha.nfsd -v 2>&1 | head -1)"

# 1. Rename saved legacy folder names (addons, addon_configs) to the current
# ones, as the Samba add-on does. This run already handles both names, so a
# failure only means trying again next start.
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    if STORED=$(curl -fsS --max-time 5 -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "${SUPERVISOR_API}/addons/self/info" | jq --compact-output '.data.options // empty') \
        && [ -n "$STORED" ] && PAYLOAD=$(/migrate-options.sh <<< "$STORED"); then
        if [ -n "$PAYLOAD" ]; then
            if curl -fsS --max-time 5 -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                    -H "Content-Type: application/json" -d "$PAYLOAD" \
                    "${SUPERVISOR_API}/addons/self/options" > /dev/null; then
                echo "[NFS] Migrated export_folders to the new folder names (addons -> local_apps, addon_configs -> app_configs)"
            else
                echo "[WARN] Could not migrate export_folders to the new folder names; will retry on next start"
            fi
        fi
    else
        echo "[WARN] Could not migrate export_folders (Supervisor API unavailable); will retry on next start"
    fi
fi

# 2. Network info for authorized_ips "auto": the Supervisor's view of HA's
# network, or else the host routing table (we run on the host network).
NETWORK_INFO=/tmp/network-info.json
: > "$NETWORK_INFO"
if jq --exit-status '.authorized_ips | index("auto")' "$CONFIG_PATH" > /dev/null 2>&1; then
    if [ -n "${NETWORK_INFO_OVERRIDE:-}" ]; then
        cp "$NETWORK_INFO_OVERRIDE" "$NETWORK_INFO"   # tests only
    elif [ -n "${SUPERVISOR_TOKEN:-}" ] && RESPONSE=$(curl -fsS --max-time 5 \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_API}/network/info"); then
        jq '.data + {source: "Supervisor"}' <<< "$RESPONSE" > "$NETWORK_INFO" || : > "$NETWORK_INFO"
    else
        DEV=$(ip -j route show default 2>/dev/null | jq --raw-output '.[0].dev // empty')
        if [ -n "$DEV" ]; then
            ip -j -4 addr show dev "$DEV" | jq --arg dev "$DEV" '{source: "routing table",
                interfaces: [{interface: $dev, connected: true, primary: true,
                    ipv4: {address: [.[0].addr_info[] | select(.family == "inet")
                                     | "\(.local)/\(.prefixlen)"]}}]}' > "$NETWORK_INFO" \
                || : > "$NETWORK_INFO"
        fi
    fi
fi

# 3. Build Ganesha Configuration (logs IPs, folders and exports to stderr)
CONF="/etc/ganesha/ganesha.conf"
mkdir -p /etc/ganesha
/gen-config.sh "$CONFIG_PATH" / "$NETWORK_INFO" > "$CONF"

# 4. Start DBUS
echo "[NFS] Starting D-Bus..."
mkdir -p /var/run/dbus
if [ -e /var/run/dbus/pid ]; then rm /var/run/dbus/pid; fi
dbus-daemon --system --fork


# Create rpcbind socket directory so libtirpc can fall back to TCP (HAOS rpcbind)
mkdir -p /run/rpcbind

LOG_LEVEL=$(jq --raw-output '.log_level // "WARN"' "$CONFIG_PATH")

case "$LOG_LEVEL" in
    DEBUG|MID_DEBUG|FULL_DEBUG)
        echo "[NFS] Generated $CONF:"
        sed 's/^/    /' "$CONF"
        ;;
esac

echo "[NFS] Launching Ganesha Daemon..."

# Ganesha logs every log-level change at its always-shown level, about 45
# lines per start. At WARN and quieter, drop those; show everything otherwise.
case "$LOG_LEVEL" in
    NULL|FATAL|MAJ|CRIT|WARN) LOG_FILTER=' :LOG :NULL :LOG: ' ;;
    *) LOG_FILTER='' ;;
esac

# Log straight to stdout so the HA Logs tab gets it. -N applies the level
# before the LOG block is parsed, so early startup errors are visible too.
# Ganesha runs in the background so this script (PID 1) can pass on the
# Supervisor's stop signal; PID 1 ignores SIGTERM unless it traps it.
/usr/bin/ganesha.nfsd -F -L STDOUT -N "NIV_${LOG_LEVEL}" -f "$CONF" \
    > >(if [ -n "$LOG_FILTER" ]; then grep --line-buffered -vF "$LOG_FILTER"; else cat; fi) 2>&1 &
GANESHA_PID=$!

STOPPING=0
trap 'STOPPING=1; kill -TERM "$GANESHA_PID" 2>/dev/null || true' TERM INT

RC=0
wait "$GANESHA_PID" || RC=$?
# A trapped signal interrupts wait; wait again for Ganesha's own exit code.
if [ "$STOPPING" = 1 ]; then
    RC=0
    wait "$GANESHA_PID" || RC=$?
fi

echo "[NFS] Ganesha exited with code ${RC}"
exit "$RC"

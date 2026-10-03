#!/bin/bash
set -e

CONFIG_PATH=/data/options.json

echo "[NFS] Starting NFS-Ganesha (Debian Mode)..."
# Always logged, so a pasted log shows exactly what is running.
echo "[NFS] App version: ${ADDON_VERSION:-unknown}"
echo "[NFS] Ganesha version: $(/usr/bin/ganesha.nfsd -v 2>&1 | head -1)"

# 1. Build Ganesha Configuration (logs IPs, folders and exports to stderr)
CONF="/etc/ganesha/ganesha.conf"
mkdir -p /etc/ganesha
/gen-config.sh "$CONFIG_PATH" > "$CONF"

# 2. Start DBUS
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

# Log straight to stdout so the HA Logs tab gets it. -N applies the level
# before the LOG block is parsed, so early startup errors are visible too.
RC=0
/usr/bin/ganesha.nfsd -F -L STDOUT -N "NIV_${LOG_LEVEL}" -f "$CONF" || RC=$?

echo "[NFS] Ganesha exited with code ${RC}"
exit "$RC"

#!/bin/bash
set -e

CONFIG_PATH=/data/options.json

echo "[NFS] Starting NFS-Ganesha (Debian Mode)..."

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

LOGFILE="/tmp/ganesha.log"
touch $LOGFILE
tail -F $LOGFILE &
TAIL_PID=$!

echo "[NFS] Launching Ganesha Daemon..."

/usr/bin/ganesha.nfsd -F -L $LOGFILE -f $CONF 2>&1 || true

echo "[NFS] Ganesha exited"
kill $TAIL_PID 2>/dev/null || true

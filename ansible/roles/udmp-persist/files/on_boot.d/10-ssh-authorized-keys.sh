#!/bin/sh
set -e

SRC=/data/ssh/authorized_keys
DEST=/root/.ssh/authorized_keys

if [ ! -f "$SRC" ]; then
  echo "ssh-authorized-keys on_boot.d: missing $SRC, skipping" >&2
  exit 0
fi

# /root/.ssh gets wiped by UniFi OS firmware updates, but /data survives them,
# so keep the real copy here and reinstall it on every boot.
mkdir -p /root/.ssh
chmod 700 /root/.ssh
install -m 600 "$SRC" "$DEST"

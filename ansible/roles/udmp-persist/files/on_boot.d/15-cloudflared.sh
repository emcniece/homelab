#!/bin/sh
set -e

CF_DIR=/data/cloudflared
CF_BIN="$CF_DIR/cloudflared"
TOKEN_FILE="$CF_DIR/token"
UNIT_FILE=/etc/systemd/system/cloudflared.service

if [ ! -f "$TOKEN_FILE" ]; then
  echo "cloudflared on_boot.d: missing $TOKEN_FILE, skipping" >&2
  exit 0
fi

# /usr/bin gets wiped by UniFi OS firmware updates but /data survives them,
# so the service runs the binary straight from /data. cloudflared's built-in
# autoupdate replaces this file in place, so updates persist too.
if [ ! -x "$CF_BIN" ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    aarch64) CF_ARCH=arm64 ;;
    x86_64)  CF_ARCH=amd64 ;;
    *) echo "cloudflared on_boot.d: unsupported arch $ARCH" >&2; exit 1 ;;
  esac
  curl -fsSL -o "$CF_BIN.tmp" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
  chmod +x "$CF_BIN.tmp"
  mv "$CF_BIN.tmp" "$CF_BIN"
fi

# Convenience only: keep `cloudflared` on PATH pointing at the live binary.
ln -sfn "$CF_BIN" /usr/bin/cloudflared

# /etc/systemd/system also gets wiped on firmware update, so rewrite the unit
# every boot rather than assuming it's still there.
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=cloudflared
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=$CF_BIN tunnel run --token-file $TOKEN_FILE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared.service

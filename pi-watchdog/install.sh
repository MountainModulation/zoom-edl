#!/usr/bin/env bash
# install.sh — Zoom EDL Watchdog installer
#
# Mirrors the install pattern of the DDNS watchdog.
# Run as root from the directory containing all watchdog files.
#
# Usage: sudo ./install.sh
#
# DO NOT paste this into an SSH session — use scp then run it.

set -euo pipefail

INSTALL_DIR="/opt/zoom-edl-watchdog"
SERVICE="zoom-edl-watchdog"

# ── Preflight ──────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Run as root (sudo ./install.sh)"; exit 1; }

for f in zoom-edl-watchdog.sh watchdog.conf zoom-edl-watchdog.service zoom-edl-watchdog.timer; do
    [[ -f "$f" ]] || { echo "Missing file: $f — run from the pi-watchdog/ directory"; exit 1; }
done

# ── Slack webhook ──────────────────────────────────────────────────────────────
WEBHOOK_FILE="${INSTALL_DIR}/slack-webhook"

mkdir -p "$INSTALL_DIR"

if [[ -f "$WEBHOOK_FILE" ]]; then
    echo "Slack webhook already configured — keeping existing."
else
    echo ""
    echo "Paste your Slack Incoming Webhook URL (input hidden):"
    read -rs WEBHOOK
    echo ""
    [[ -z "$WEBHOOK" ]] && { echo "No webhook entered — aborting."; exit 1; }
    echo "$WEBHOOK" > "$WEBHOOK_FILE"
    chmod 600 "$WEBHOOK_FILE"
    echo "Webhook saved."
fi

# Test the webhook
echo "Sending test Slack message..."
WEBHOOK=$(<"$WEBHOOK_FILE")
PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1]}))" \
          "✅ *zoom-edl-watchdog* — installer test from $(hostname). If you see this, the webhook is working.")
curl -s -m 10 -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$WEBHOOK" | grep -q ok \
    || { echo "Slack test failed — check webhook URL"; exit 1; }
echo "Slack test OK."

# ── Install files ──────────────────────────────────────────────────────────────
echo "Installing to ${INSTALL_DIR}..."

# Back up existing script if present
if [[ -f "${INSTALL_DIR}/zoom-edl-watchdog.sh" ]]; then
    TS=$(date +%Y%m%d-%H%M%S)
    cp "${INSTALL_DIR}/zoom-edl-watchdog.sh" "${INSTALL_DIR}/zoom-edl-watchdog.sh.bak-${TS}"
    echo "Backed up existing script to zoom-edl-watchdog.sh.bak-${TS}"
fi

cp zoom-edl-watchdog.sh "${INSTALL_DIR}/"
cp watchdog.conf        "${INSTALL_DIR}/"
chmod 755 "${INSTALL_DIR}/zoom-edl-watchdog.sh"
chmod 644 "${INSTALL_DIR}/watchdog.conf"
mkdir -p  "${INSTALL_DIR}/state"

# ── Edit the EDL URL in watchdog.conf ─────────────────────────────────────────
echo ""
echo "Enter your GitHub Pages EDL URL"
echo "(e.g. https://YOUR-ORG.github.io/zoom-edl/zoom-edl.txt):"
read -r EDL_URL
if [[ -n "$EDL_URL" ]]; then
    sed -i "s|EDL_URL=.*|EDL_URL=\"${EDL_URL}\"|" "${INSTALL_DIR}/watchdog.conf"
    echo "EDL URL set."
fi

# ── Systemd ────────────────────────────────────────────────────────────────────
cp zoom-edl-watchdog.service /etc/systemd/system/
cp zoom-edl-watchdog.timer   /etc/systemd/system/
chmod 644 /etc/systemd/system/zoom-edl-watchdog.{service,timer}

systemctl daemon-reload
systemctl enable --now "${SERVICE}.timer"

# ── First run ──────────────────────────────────────────────────────────────────
echo "Running watchdog once to verify..."
"${INSTALL_DIR}/zoom-edl-watchdog.sh"

echo ""
echo "Install complete. Timer status:"
systemctl list-timers | grep zoom-edl || true
echo ""
echo "View logs:  journalctl -t zoom-edl-watchdog -n 20"
echo "Force run:  sudo /opt/zoom-edl-watchdog/zoom-edl-watchdog.sh"

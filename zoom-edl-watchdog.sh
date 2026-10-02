#!/usr/bin/env bash
# zoom-edl-watchdog.sh
#
# Watches the GitHub Pages-hosted Zoom EDL and alerts via Slack if:
#   - The file hasn't been updated in STALE_HOURS
#   - The entry count drops by more than DROP_PCT percent (schema break / feed issue)
#   - The EDL URL is unreachable
#
# Mirrors the pattern of ddns-watchdog.sh — same state dir, same Slack
# payload builder, same throttle logic.
#
# Install location: /opt/zoom-edl-watchdog/
# Credentials:      /opt/zoom-edl-watchdog/slack-webhook   (0600)
# Config:           /opt/zoom-edl-watchdog/watchdog.conf
# State:            /opt/zoom-edl-watchdog/state/

set -euo pipefail

SCRIPT_DIR="/opt/zoom-edl-watchdog"
CONF="${SCRIPT_DIR}/watchdog.conf"
WEBHOOK_FILE="${SCRIPT_DIR}/slack-webhook"
STATE_DIR="${SCRIPT_DIR}/state"
LOG_TAG="zoom-edl-watchdog"

# ── Load config ────────────────────────────────────────────────────────────────
[[ -f "$CONF" ]] && source "$CONF"

EDL_URL="${EDL_URL:-https://YOUR-ORG.github.io/zoom-edl/zoom-edl.txt}"
STALE_HOURS="${STALE_HOURS:-8}"           # alert if EDL hasn't changed this long
DROP_PCT="${DROP_PCT:-20}"                # alert if count drops more than this %
REALERT_SECS="${REALERT_SECS:-21600}"    # 6 hours between repeat alerts (same as DDNS watchdog)

# ── Helpers ────────────────────────────────────────────────────────────────────
log() { logger -t "$LOG_TAG" -- "$*"; echo "$*"; }

slack() {
    local icon="$1" msg="$2"
    [[ ! -f "$WEBHOOK_FILE" ]] && { log "slack: no webhook configured"; return; }
    local webhook
    webhook=$(<"$WEBHOOK_FILE")
    local payload
    payload=$(python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1]}))" \
              "${icon} *zoom-edl-watchdog* — ${msg}")
    curl -s -m 10 --retry 2 -X POST -H 'Content-Type: application/json' \
         -d "$payload" "$webhook" >/dev/null || true
}

# Throttle: alert at most once per REALERT_SECS for a given condition key
# Returns 0 (should alert) or 1 (too soon)
should_alert() {
    local key="$1"
    local state_file="${STATE_DIR}/last-alert-${key}"
    local now
    now=$(date +%s)
    if [[ -f "$state_file" ]]; then
        local last
        last=$(<"$state_file")
        (( now - last < REALERT_SECS )) && return 1
    fi
    echo "$now" > "$state_file"
    return 0
}

clear_alert() {
    local key="$1"
    rm -f "${STATE_DIR}/last-alert-${key}"
}

# ── Setup ──────────────────────────────────────────────────────────────────────
mkdir -p "$STATE_DIR"

# ── Fetch the EDL ──────────────────────────────────────────────────────────────
LAST_COUNT_FILE="${STATE_DIR}/last-count"
LAST_FETCH_FILE="${STATE_DIR}/last-fetch"

log "Checking EDL: $EDL_URL"

EDL_CONTENT=$(curl -s -m 20 --retry 2 -f "$EDL_URL" 2>/dev/null || true)

if [[ -z "$EDL_CONTENT" ]]; then
    log "ERROR: Could not fetch EDL from $EDL_URL"
    if should_alert "unreachable"; then
        slack "🚨" "EDL URL is unreachable: \`${EDL_URL}\`"
    fi
    exit 1
fi

clear_alert "unreachable"

# Count non-empty, non-comment lines (actual IP/CIDR entries)
CURRENT_COUNT=$(echo "$EDL_CONTENT" | grep -cE '^[0-9a-fA-F]' || true)
log "EDL entry count: $CURRENT_COUNT"

# ── Staleness check ────────────────────────────────────────────────────────────
# We track whether the content itself has changed, not the HTTP Last-Modified
# header, because GitHub Pages caching can be unreliable.
CONTENT_HASH=$(echo "$EDL_CONTENT" | md5sum | cut -d' ' -f1)
HASH_FILE="${STATE_DIR}/last-hash"
HASH_CHANGED_FILE="${STATE_DIR}/last-hash-change"

if [[ -f "$HASH_FILE" ]]; then
    LAST_HASH=$(<"$HASH_FILE")
    if [[ "$CONTENT_HASH" != "$LAST_HASH" ]]; then
        log "EDL content changed — updating hash and timestamp"
        echo "$CONTENT_HASH" > "$HASH_FILE"
        date +%s > "$HASH_CHANGED_FILE"
        clear_alert "stale"
    fi
else
    # First run
    echo "$CONTENT_HASH" > "$HASH_FILE"
    date +%s > "$HASH_CHANGED_FILE"
fi

NOW=$(date +%s)
if [[ -f "$HASH_CHANGED_FILE" ]]; then
    LAST_CHANGE=$(<"$HASH_CHANGED_FILE")
    HOURS_SINCE=$(( (NOW - LAST_CHANGE) / 3600 ))
    if (( HOURS_SINCE >= STALE_HOURS )); then
        log "STALE: EDL has not changed in ${HOURS_SINCE}h (threshold: ${STALE_HOURS}h)"
        if should_alert "stale"; then
            slack "🚨" "Zoom EDL has not changed in *${HOURS_SINCE} hours*. GitHub Actions may be failing. Check: https://github.com/YOUR-ORG/zoom-edl/actions"
        fi
    else
        log "Freshness OK: last change ${HOURS_SINCE}h ago"
        clear_alert "stale"
    fi
fi

# ── Count drop check ───────────────────────────────────────────────────────────
if [[ -f "$LAST_COUNT_FILE" ]]; then
    LAST_COUNT=$(<"$LAST_COUNT_FILE")
    if (( LAST_COUNT > 0 )); then
        DROP=$(( (LAST_COUNT - CURRENT_COUNT) * 100 / LAST_COUNT ))
        if (( DROP > DROP_PCT )); then
            log "COUNT DROP: was ${LAST_COUNT}, now ${CURRENT_COUNT} (${DROP}% drop)"
            if should_alert "count-drop"; then
                slack "🚨" "Zoom EDL entry count dropped *${DROP}%* (${LAST_COUNT} → ${CURRENT_COUNT}). Zoom may have changed their feed format. Check: \`${EDL_URL}\`"
            fi
        else
            log "Count OK: ${LAST_COUNT} → ${CURRENT_COUNT}"
            clear_alert "count-drop"
        fi
    fi
fi

echo "$CURRENT_COUNT" > "$LAST_COUNT_FILE"
date +%s > "$LAST_FETCH_FILE"

log "Watchdog complete. Entries: ${CURRENT_COUNT}"

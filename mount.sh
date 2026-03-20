#!/opt/homebrew/bin/bash
# Note that this requires an updated version of bash from homebrew!
# SMB Auto-Mount Script
#
# Watches reachability of target IPs via scutil -W -r.
# scutil is kernel-notified on route changes — no polling, no network traffic at rest.
# On each reachability event: settles, re-checks, then mounts or unmounts as needed.
# Mount is via osascript/Finder (silent, DA-managed); password from Keychain.

# ==============================================================================
# CONFIGURATION — Edit these for your setup
# ==============================================================================

# Array of mounts — one entry per line, pipe-delimited:
#   TARGET_IP|SHARE_NAME|MOUNT_PATH|SMB_USER
#
# Add as many entries as you need. Example:
#   "10.0.0.1|documents|/Volumes/documents|alice"
#   "10.0.0.2|photos|/Volumes/photos|bob"
#MOUNTS=(
#    "YOUR_SERVER_IP|YOUR_SHARE_NAME|/Volumes/YOUR_SHARE_NAME|your_username"
#)

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

source "${SCRIPT_DIR}/mount-config.sh"

LOG_FILE="$HOME/Library/Logs/smb-automount.log"

# ==============================================================================
# TUNING — Adjust if needed
# ==============================================================================

SETTLE_DELAY=3        # Seconds to wait after an event before acting (avoids flapping)
MOUNT_COOLDOWN=10     # Minimum seconds between mount attempts
declare -A LAST_MOUNT_TIMES

# ==============================================================================
# FUNCTIONS
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

is_mounted() {
    local mount_path="$1"
    mount 2>/dev/null | grep -q " on ${mount_path} "
}

# Ping with a 2-second timeout
is_reachable() {
    local target_ip="$1"
    ping -c 1 "$target_ip" >/dev/null 2>&1 &
    local pid=$!
    local i=0
    while [ $i -lt 20 ]; do
        sleep 0.1
        if ! kill -0 $pid 2>/dev/null; then
            wait $pid
            return $?
        fi
        i=$((i + 1))
    done
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
    return 1
}

do_mount() {
    local target_ip="$1" share_name="$2" mount_path="$3" smb_user="$4"
    local pass
    pass=$(security find-internet-password -a "${smb_user}" -s "${target_ip}" -w 2>/dev/null)
    if [ -z "$pass" ]; then
        log "[${share_name}] ERROR: No Keychain credential found for ${smb_user}@${target_ip}"
        return 1
    fi

    log "[${share_name}] Mounting smb://${target_ip}/${share_name} via Finder..."
    osascript -e "tell application \"Finder\" to mount volume \"smb://${smb_user}:${pass}@${target_ip}/${share_name}\"" >/dev/null 2>&1

    # osascript mount is async — poll until it appears (up to 5s)
    local i=0
    while [ $i -lt 10 ]; do
        sleep 0.5
        if is_mounted "$mount_path"; then
            log "[${share_name}] Mount complete"
            LAST_MOUNT_TIMES["$mount_path"]=$(date +%s)
            return 0
        fi
        i=$((i + 1))
    done
    log "[${share_name}] ERROR: Mount did not appear within 5s"
    return 1
}

do_unmount() {
    local mount_path="$1" share_name="$2"
    log "[${share_name}] Unmounting ${mount_path}..."
    diskutil unmount force "${mount_path}" >/dev/null 2>&1
    log "[${share_name}] Unmount complete (exit: $?)"
}

handle_mount() {
    local target_ip="$1" share_name="$2" mount_path="$3" smb_user="$4"

    local mounted reachable current

    is_mounted "$mount_path" && mounted=true || mounted=false

    # Re-check reachability after settle (instant route check first)
    current=$(scutil -r "$target_ip" 2>&1)
    if echo "$current" | grep -q "^Reachable"; then
        # Route exists — verify host actually responds before mounting
        is_reachable "$target_ip" && reachable=true || reachable=false
    else
        reachable=false
    fi

    log "[${share_name}] State: reachable=${reachable} mounted=${mounted}"

    if [ "$reachable" = true ] && [ "$mounted" = false ]; then
        local now=$(date +%s)
        local last=${LAST_MOUNT_TIMES["$mount_path"]:-0}
        if [ $((now - last)) -lt $MOUNT_COOLDOWN ]; then
            log "[${share_name}] Mount cooldown active, skipping"
        else
            log "[${share_name}] calling do_mount..."
            do_mount "$target_ip" "$share_name" "$mount_path" "$smb_user"
        fi
    elif [ "$reachable" = false ] && [ "$mounted" = true ]; then
        do_unmount "$mount_path" "$share_name"
    else
        log "[${share_name}] No action needed"
    fi
}

handle_event() {
    local event_line="$1"
    log "Event: ${event_line} — settling ${SETTLE_DELAY}s..."
    sleep "$SETTLE_DELAY"

    for entry in "${MOUNTS[@]}"; do
        IFS='|' read -r target_ip share_name mount_path smb_user <<< "$entry"
        handle_mount "$target_ip" "$share_name" "$mount_path" "$smb_user"
    done
}

# ==============================================================================
# MAIN
# ==============================================================================

log "=== SMB Auto-Mount Agent started (PID $$) ==="
log "Configured mounts: ${#MOUNTS[@]}"

# Collect unique target IPs for watchers
declare -A WATCH_IPS
for entry in "${MOUNTS[@]}"; do
    IFS='|' read -r target_ip _ _ _ <<< "$entry"
    WATCH_IPS["$target_ip"]=1
done

while true; do
    # Watch all unique target IPs and the default route (0.0.0.0).
    # IP watchers catch VPN/tunnel route changes (e.g. Tailscale toggled on/off).
    # The default route watcher catches transport changes (e.g. WiFi on/off) that
    # IP watchers can miss when a tunnel route persists without underlying connectivity.
    while IFS= read -r line; do
        case "$line" in
            Reachable*|"Not Reachable"*)
                handle_event "$line"
                ;;
        esac
    done < <(
        for ip in "${!WATCH_IPS[@]}"; do
            scutil -W -r "$ip" &
        done
        scutil -W -r 0.0.0.0 &
        wait
    )

    # scutil watchers exited unexpectedly — restart after a delay
    log "scutil watchers exited unexpectedly, restarting in 5s..."
    sleep 5
done

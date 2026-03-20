#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/SMBAutoMount"
PLIST_NAME="com.smb.automount"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
LOG_FILE="$HOME/Library/Logs/smb-automount.log"

# ==============================================================================
# Helpers
# ==============================================================================

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ==============================================================================
# Preflight checks
# ==============================================================================

if [[ "$(uname)" != "Darwin" ]]; then
    error "This script is intended for macOS only."
fi

if ! command -v brew &>/dev/null; then
    error "Homebrew is required but not installed. Install it from https://brew.sh"
fi

# ==============================================================================
# Gather configuration
# ==============================================================================

echo ""
echo "macOS SMB Auto-Mount — Installer"
echo "================================="
echo ""
echo "You can configure one or more SMB mounts."
echo ""

# Collect mount entries
MOUNT_ENTRIES=()    # pipe-delimited config lines for mount.sh
KEYCHAIN_ENTRIES=() # "user|server|pass" for Keychain storage

while true; do
    echo "--- Mount $((${#MOUNT_ENTRIES[@]} + 1)) ---"
    read -rp "SMB server IP or hostname: " TARGET_IP
    [[ -z "$TARGET_IP" ]] && error "Server IP/hostname cannot be empty."

    read -rp "SMB share name: " SHARE_NAME
    [[ -z "$SHARE_NAME" ]] && error "Share name cannot be empty."

    read -rp "SMB username: " SMB_USER
    [[ -z "$SMB_USER" ]] && error "Username cannot be empty."

    read -rsp "SMB password: " SMB_PASS
    echo ""
    [[ -z "$SMB_PASS" ]] && error "Password cannot be empty."

    MOUNT_PATH="/Volumes/${SHARE_NAME}"

    MOUNT_ENTRIES+=("${TARGET_IP}|${SHARE_NAME}|${MOUNT_PATH}|${SMB_USER}")
    KEYCHAIN_ENTRIES+=("${SMB_USER}|${TARGET_IP}|${SMB_PASS}")

    echo ""
    read -rp "Add another mount? [y/N]: " ADD_MORE
    [[ "$ADD_MORE" =~ ^[Yy]$ ]] || break
    echo ""
done

echo ""
info "Configured ${#MOUNT_ENTRIES[@]} mount(s):"
for entry in "${MOUNT_ENTRIES[@]}"; do
    IFS='|' read -r ip share mpath user <<< "$entry"
    echo "  smb://${user}@${ip}/${share} -> ${mpath}"
done
echo ""

# ==============================================================================
# 1. Store credentials in Keychain
# ==============================================================================

info "Storing credentials in Keychain..."
for kc_entry in "${KEYCHAIN_ENTRIES[@]}"; do
    IFS='|' read -r kc_user kc_server kc_pass <<< "$kc_entry"
    security add-internet-password \
        -a "$kc_user" \
        -s "$kc_server" \
        -w "$kc_pass" \
        -T "" \
        "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
    echo "  Keychain entry added for ${kc_user}@${kc_server}"
done

# ==============================================================================
# 2. Install sleepwatcher
# ==============================================================================

info "Installing sleepwatcher..."
if brew list sleepwatcher &>/dev/null; then
    echo "  sleepwatcher already installed."
else
    brew install sleepwatcher
fi

if brew services list | grep -q "sleepwatcher.*started"; then
    echo "  sleepwatcher service already running."
else
    brew services start sleepwatcher
fi

# ==============================================================================
# 3. Install mount script
# ==============================================================================

info "Installing mount script to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"

# Build the MOUNTS array block for mount.sh
MOUNTS_BLOCK="MOUNTS=("
for entry in "${MOUNT_ENTRIES[@]}"; do
    MOUNTS_BLOCK+=" \"${entry}\" "
done
MOUNTS_BLOCK+=")"

cp "${SCRIPT_DIR}/mount.sh" "${INSTALL_DIR}/"
echo $MOUNTS_BLOCK > "${INSTALL_DIR}/mount-config.sh"

chmod 700 "${INSTALL_DIR}/mount.sh"
echo "  Installed ${INSTALL_DIR}/mount.sh"

# ==============================================================================
# 4. Install launchd agent
# ==============================================================================

info "Installing launchd agent..."

# Unload existing agent if loaded (ignore errors)
launchctl unload "$PLIST_DEST" 2>/dev/null || true

sed \
    -e "s|/Users/YOUR_USERNAME|${HOME}|g" \
    "${SCRIPT_DIR}/${PLIST_NAME}.plist" > "$PLIST_DEST"

echo "  Installed ${PLIST_DEST}"

launchctl load "$PLIST_DEST"
echo "  Agent loaded."

# ==============================================================================
# 5. Install wake script
# ==============================================================================

info "Installing wake script..."
cp "${SCRIPT_DIR}/wakeup" "$HOME/.wakeup"
chmod 700 "$HOME/.wakeup"
echo "  Installed ~/.wakeup"

# ==============================================================================
# Done
# ==============================================================================

echo ""
info "Installation complete!"
echo ""
echo "  The agent is now running and watching ${#MOUNT_ENTRIES[@]} mount(s)."
echo "  Logs: tail -f ${LOG_FILE}"
echo ""
echo "  To uninstall, run:"
echo "    launchctl unload ${PLIST_DEST}"
echo "    rm ${PLIST_DEST}"
echo "    rm -rf \"${INSTALL_DIR}\""
echo "    rm ~/.wakeup"
echo "    brew services stop sleepwatcher && brew uninstall sleepwatcher"
echo ""

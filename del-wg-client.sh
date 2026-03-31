#!/bin/bash

# === CONFIGURATION ===
# Paths (must match the add-script)
NETDEV_FILE="/etc/systemd/network/90-wg0.netdev"
NETWORK_FILE="/etc/systemd/network/90-wg0.network"
HOSTS_FILE="/etc/hosts"

# Output directory for client configurations (Use argument 1 if provided, otherwise default)
OUT_DIR="${1:-./wg-config}"

# System settings
SYSTEMD_NETWORK_GROUP="systemd-network"
# =====================

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

# Check if required files exist
if [ ! -f "$NETDEV_FILE" ]; then
    echo "Error: $NETDEV_FILE not found."
    exit 1
fi

echo "=== WireGuard Client Removal ==="

# List existing clients
# We search for the "# Client: <Name>" markers created by the add-script
echo "Found Clients:"
echo "--------------------------------"
grep "# Client:" "$NETDEV_FILE" | awk -F": " '{print $2}' | nl
echo "--------------------------------"

# Select Client
read -p "Enter the NAME of the client to delete (exactly as listed above): " CLIENT_NAME

if [ -z "$CLIENT_NAME" ]; then
    echo "Aborted."
    exit 1
fi

# Validation: Check if the client actually exists
if ! grep -q "# Client: $CLIENT_NAME" "$NETDEV_FILE"; then
    echo "Error: Client '$CLIENT_NAME' not found in $NETDEV_FILE."
    exit 1
fi

echo ""
echo "WARNING: The client '$CLIENT_NAME' will be completely removed."
echo "- Remove from $NETDEV_FILE (Peer block)"
echo "- Remove from $NETWORK_FILE (Routes, if any exist)"
echo "- Remove from $HOSTS_FILE (DNS entries)"
echo "- Delete configuration files in $OUT_DIR/$CLIENT_NAME"
echo ""
read -p "Are you sure? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# === CREATE BACKUPS ===
echo "Creating backups of configuration files..."
cp "$NETDEV_FILE" "${NETDEV_FILE}.bak"
cp "$NETWORK_FILE" "${NETWORK_FILE}.bak"
cp "$HOSTS_FILE" "${HOSTS_FILE}.bak"

# === FUNCTION TO DELETE BLOCKS ===
# This function searches for a marker and deletes the corresponding block up to the next empty line
remove_block() {
    local file="$1"
    local marker="$2"
    local offset_start="$3" # How many lines BEFORE the marker does the block start?
    
    # Find the line number of the marker
    local line_num
    line_num=$(grep -nF "$marker" "$file" | cut -d: -f1 | head -n1)

    if [ -z "$line_num" ]; then
        return # Nothing found
    fi

    # Calculate the start line of the block
    local start_line=$((line_num - offset_start))

    # Find the end of the block (the next empty line) using awk
    local end_line
    end_line=$(awk "NR >= $start_line && /^$/ {print NR; exit}" "$file")
    
    # If no empty line is found, default to the end of the file
    if [ -z "$end_line" ]; then
        end_line=$(wc -l < "$file")
    fi

    # Delete the range using sed
    sed -i "${start_line},${end_line}d" "$file"
    echo " -> Removed block in $file."
}

# === Remove Peer from .netdev ===
# Structure in the add-script was:
# [WireGuardPeer]
# # Client: NAME
# ...
#
# The marker is "# Client: NAME". The block starts 1 line before it ([WireGuardPeer]).
echo "Processing $NETDEV_FILE..."
remove_block "$NETDEV_FILE" "# Client: $CLIENT_NAME" 1

# In case the user exists multiple times (shouldn't happen, but looping for safety)
while grep -q "# Client: $CLIENT_NAME" "$NETDEV_FILE"; do
    remove_block "$NETDEV_FILE" "# Client: $CLIENT_NAME" 1
done


# === Remove Routes from .network ===
# Structure in the add-script was:
# # Route to Client: NAME
# [Route]
# Destination=...
#
# The marker is "# Route to Client: NAME". The block starts 0 lines before it (directly at the marker).
if [ -f "$NETWORK_FILE" ]; then
    echo "Processing $NETWORK_FILE..."
    # Since there can be multiple routes for a single client (multiple subnets), we loop
    while grep -q "# Route to Client: $CLIENT_NAME" "$NETWORK_FILE"; do
        remove_block "$NETWORK_FILE" "# Route to Client: $CLIENT_NAME" 0
    done
fi

# === Remove Hosts entries ===
echo "Processing $HOSTS_FILE..."
# Deletes any line containing the client's FQDN (e.g., client.wg.domain.com)
sed -i "/\s${CLIENT_NAME}\./d" "$HOSTS_FILE"
# Deletes any line that ends exactly with the client's name
sed -i "/\s${CLIENT_NAME}$/d" "$HOSTS_FILE"


# === Delete Config Files ===
CLIENT_CONFIG_PATH="$OUT_DIR/$CLIENT_NAME"
if [ -d "$CLIENT_CONFIG_PATH" ]; then
    echo "Deleting configuration folder: $CLIENT_CONFIG_PATH"
    rm -rf "$CLIENT_CONFIG_PATH"
elif [ -f "$OUT_DIR/$CLIENT_NAME.conf" ]; then
    # Fallback for old structure (single files instead of directories)
    rm -f "$OUT_DIR/$CLIENT_NAME.conf"
    rm -f "$OUT_DIR/$CLIENT_NAME.png"
fi


# === Reload ===
echo "Reloading network configuration..."

# Ensure correct permissions (matching the add-script)
if getent group "$SYSTEMD_NETWORK_GROUP" > /dev/null; then
    chown root:"$SYSTEMD_NETWORK_GROUP" "$NETDEV_FILE"
else
    chown root:root "$NETDEV_FILE"
fi
chmod 640 "$NETDEV_FILE"

if networkctl reload; then
    echo "-> Success: Client '$CLIENT_NAME' has been completely removed."
else
    echo "-> Warning: 'networkctl reload' reported an error. Please check 'networkctl status'."
    echo "   (The syntax in .netdev might be corrupted. A backup is available as .netdev.bak)"
fi

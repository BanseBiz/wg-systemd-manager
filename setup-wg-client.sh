#!/usr/bin/env bash

# 1. Determine target directory (default to current working directory)
TARGET_DIR="${1:-$(pwd)}"

# 2. Check if required files exist
if [[ ! -f "$TARGET_DIR/90-wg0.netdev" ]] || [[ ! -f "$TARGET_DIR/90-wg0.network" ]]; then
    echo "Error: '90-wg0.netdev' and/or '90-wg0.network' not found in $TARGET_DIR."
    echo "Please ensure both files are present before running this script."
    exit 1
fi

# 3. Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script modifies system network configurations and must be run as root. Please use sudo."
    exit 1
fi

# 4. Move files to systemd-networkd directory
echo "Moving WireGuard configuration files to /etc/systemd/network/..."
mkdir -p /etc/systemd/network

mv "$TARGET_DIR/90-wg0.netdev" /etc/systemd/network/
mv "$TARGET_DIR/90-wg0.network" /etc/systemd/network/

# Secure the netdev file (contains the WireGuard private key)
chmod 600 /etc/systemd/network/90-wg0.netdev

# 5. Create 20-wired.network for systemd-networkd
echo "Creating /etc/systemd/network/20-wired.network for wired DHCP management..."
cat <<EOF > /etc/systemd/network/20-wired.network
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

# 6. Check for NetworkManager and configure if present
if command -v NetworkManager >/dev/null 2>&1 || systemctl is-active --quiet NetworkManager; then
    echo "NetworkManager detected."
    
    # Configure unmanaged devices
    echo "Configuring NetworkManager to ignore wired and WireGuard interfaces..."
    mkdir -p /etc/NetworkManager/conf.d
    cat <<EOF > /etc/NetworkManager/conf.d/99-unmanaged-wired-wg.conf
[keyfile]
unmanaged-devices=type:ethernet;interface-name:wg0
EOF

    # Configure DNS to use systemd-resolved
    echo "Checking NetworkManager DNS configuration..."
    if ! grep -qRr "dns\s*=\s*systemd-resolved" /etc/NetworkManager/; then
        echo "Updating NetworkManager to use systemd-resolved for DNS..."
        cat <<EOF > /etc/NetworkManager/conf.d/10-dns-resolved.conf
[main]
dns=systemd-resolved
EOF
    else
        echo "NetworkManager is already configured to use systemd-resolved."
    fi
else
    echo "NetworkManager not found. Skipping NetworkManager configurations."
fi

# 7. Check and configure /etc/resolv.conf symlink
echo "Verifying /etc/resolv.conf symlink..."
RESOLV_TARGET="/run/systemd/resolve/stub-resolv.conf"

# Use readlink -f to get the absolute resolved path to handle relative symlinks securely
if [[ "$(readlink -f /etc/resolv.conf)" != "$RESOLV_TARGET" ]]; then
    echo "Setting /etc/resolv.conf to symlink to $RESOLV_TARGET..."
    
    # Create a backup if it's a real file and not a symlink
    if [[ -e /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
        mv /etc/resolv.conf /etc/resolv.conf.bak
        echo "Backed up existing /etc/resolv.conf to /etc/resolv.conf.bak"
    fi
    
    ln -sf "$RESOLV_TARGET" /etc/resolv.conf
else
    echo "/etc/resolv.conf is already correctly symlinked."
fi

# 8. Reload and apply network configuration
echo "--------------------------------------------------------"
echo "Applying configurations and restarting services..."

# Ensure systemd-networkd and systemd-resolved are enabled and started
systemctl enable --now systemd-networkd systemd-resolved
systemctl restart systemd-networkd systemd-resolved

# Restart NetworkManager if it exists to apply conf.d changes
if command -v NetworkManager >/dev/null 2>&1 || systemctl is-active --quiet NetworkManager; then
    systemctl restart NetworkManager
fi

echo "Setup complete! The network configuration has been successfully reloaded."

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

# Set correct ownership and permissions
chown root:systemd-network /etc/systemd/network/90-wg0.netdev
chown root:systemd-network /etc/systemd/network/90-wg0.network

# Secure the netdev file (contains the WireGuard private key)
chmod 600 /etc/systemd/network/90-wg0.netdev
chmod 644 /etc/systemd/network/90-wg0.network

# 5. Create 20-wired.network for systemd-networkd
echo "Creating /etc/systemd/network/20-wired.network for wired DHCP management..."
cat <<EOF > /etc/systemd/network/20-wired.network
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

# Set ownership and permissions for the newly created wired network file
chown root:systemd-network /etc/systemd/network/20-wired.network
chmod 644 /etc/systemd/network/20-wired.network

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

if [[ "$(readlink -f /etc/resolv.conf)" != "$RESOLV_TARGET" ]]; then
    echo "Setting /etc/resolv.conf to symlink to $RESOLV_TARGET..."
    
    if [[ -e /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
        mv /etc/resolv.conf /etc/resolv.conf.bak
        echo "Backed up existing /etc/resolv.conf to /etc/resolv.conf.bak"
    fi
    
    ln -sf "$RESOLV_TARGET" /etc/resolv.conf
else
    echo "/etc/resolv.conf is already correctly symlinked."
fi

# 8. Check and configure SSH Daemon
# Determine the correct SSH service name (sshd on RHEL/Arch, ssh on Debian/Ubuntu)
SSH_SERVICE=""
if systemctl is-enabled sshd >/dev/null 2>&1 || systemctl is-active --quiet sshd; then
    SSH_SERVICE="sshd"
elif systemctl is-enabled ssh >/dev/null 2>&1 || systemctl is-active --quiet ssh; then
    SSH_SERVICE="ssh"
fi

if [[ -n "$SSH_SERVICE" ]]; then
    echo "--------------------------------------------------------"
    echo "SSH Daemon ($SSH_SERVICE) detected."
    
    # Always disable password authentication
    echo "Disabling password authentication globally..."
    sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    
    # Search for and disable in any drop-in config files to prevent overrides
    if ls /etc/ssh/sshd_config.d/*.conf 1> /dev/null 2>&1; then
        sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/*.conf
    fi
    
    # Ensure it exists at least once in the main config
    if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    fi

    # Prompt user for binding to wg0
    read -p "Do you want the SSH daemon to bind ONLY on the wg0 interface? (y/N): " BIND_WG
    if [[ "$BIND_WG" =~ ^[Yy] ]]; then
        # Extract the IP address from the wg0 network file (removes CIDR /24 etc)
        WG_IP=$(grep -m 1 -i "^Address=" /etc/systemd/network/90-wg0.network | cut -d= -f2 | cut -d/ -f1 | tr -d ' ')
        
        if [[ -n "$WG_IP" ]]; then
            echo "Extracted WireGuard IP: $WG_IP"
            echo "Configuring SSH to listen only on $WG_IP..."
            
            # Comment out any existing ListenAddress directives
            sed -i -E 's/^ListenAddress/#ListenAddress # Disabled by setup script/' /etc/ssh/sshd_config
            if ls /etc/ssh/sshd_config.d/*.conf 1> /dev/null 2>&1; then
                sed -i -E 's/^ListenAddress/#ListenAddress # Disabled by setup script/' /etc/ssh/sshd_config.d/*.conf
            fi
            
            # Append the new ListenAddress
            echo "ListenAddress $WG_IP" >> /etc/ssh/sshd_config
        else
            echo "Warning: Could not extract an IP address from 90-wg0.network. Skipping ListenAddress binding."
        fi
    fi
else
    echo "--------------------------------------------------------"
    echo "SSH daemon not detected or not enabled. Skipping SSH configuration."
fi

# 9. Reload and apply configurations
echo "--------------------------------------------------------"
echo "Applying configurations and restarting services..."

systemctl enable --now systemd-networkd systemd-resolved
systemctl restart systemd-networkd systemd-resolved

if command -v NetworkManager >/dev/null 2>&1 || systemctl is-active --quiet NetworkManager; then
    systemctl restart NetworkManager
fi

if [[ -n "$SSH_SERVICE" ]]; then
    systemctl restart "$SSH_SERVICE"
fi

echo "Setup complete! The network and SSH configurations have been successfully reloaded."

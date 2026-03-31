#!/bin/bash

# === CONFIGURATION ===
# Paths to your systemd-networkd files on the SERVER
NETDEV_FILE="/etc/systemd/network/90-wg0.netdev"
NETWORK_FILE="/etc/systemd/network/90-wg0.network" 
HOSTS_FILE="/etc/hosts"

# Output directory for client configurations (Use argument 1 if provided, otherwise default)
OUT_DIR="${1:-./wg-config}"

# Static settings
DOMAIN="wg.example.com"
SERVER_ENDPOINT="123.123.123.123:51820"
SERVER_VPN_IP="10.10.0.1"

# IPv4 Network settings
VPN_SUBNET_PREFIX="10.10.0"
VPN_MASK="24"

# IPv6 Network settings
IPV6_PREFIX="ffff:ffff:ffff:ffff"
IPV6_MASK="64"
# =====================

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

# Check for required tools
if ! command -v wg &> /dev/null || ! command -v qrencode &> /dev/null; then
    echo "Error: 'wg' (wireguard-tools) or 'qrencode' is not installed."
    echo "Please install them: apt install wireguard-tools qrencode"
    exit 1
fi

# Check for existing configuration files
if [ ! -f "$NETDEV_FILE" ]; then
    echo "Error: $NETDEV_FILE not found!"
    exit 1
fi

# Create output directory
echo "Using output directory: $OUT_DIR"
mkdir -p "$OUT_DIR"

echo "=== WireGuard Client Wizard (Split Tunnel / Site-to-Site) ==="
echo "Server Endpoint: $SERVER_ENDPOINT"

# Extract Server Private Key and calculate Public Key
SERVER_PRIV_KEY=$(grep -oP 'PrivateKey=\K.*' "$NETDEV_FILE" | head -1 | tr -d ' ')
if [ -z "$SERVER_PRIV_KEY" ]; then
    echo "Could not read PrivateKey from $NETDEV_FILE."
    exit 1
fi
SERVER_PUB_KEY=$(echo "$SERVER_PRIV_KEY" | wg pubkey)

# Ask for Client Name
read -p "New Client Name (no spaces): " CLIENT_NAME
if [[ ! "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid name. Only letters, numbers, - and _ are allowed."
    exit 1
fi

# Find available IP (Scanning 10.10.0.2 to 254)
CLIENT_IP=""
CLIENT_IPV6=""
echo "Searching for available IP..."

for i in {2..254}; do
    CHECK_IP="${VPN_SUBNET_PREFIX}.${i}"
    if ! grep -q "$CHECK_IP" "$NETDEV_FILE"; then
        CLIENT_IP="$CHECK_IP"
        CLIENT_IPV6="${IPV6_PREFIX}::${i}"
        break
    fi
done

if [ -z "$CLIENT_IP" ]; then
    echo "No free IP found in range ${VPN_SUBNET_PREFIX}.2-254!"
    exit 1
fi

echo "-> Assigned IPv4: $CLIENT_IP"
echo "-> Assigned IPv6: $CLIENT_IPV6"

# Generate Crypto Keys
CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(echo "$CLIENT_PRIV_KEY" | wg pubkey)
PSK=$(wg genpsk)

# Handle Subnets behind the Client (Site-to-Site)
echo "Are there IPv4 subnets behind this client? (e.g., OPNsense LAN)"
read -p "Comma-separated (e.g., 192.168.0.0/24) or Enter for none: " CLIENT_SUBNETS_V4

# AllowedIPs for the SERVER (Traffic the client is allowed to send)
ALLOWED_IPS_SERVER_SIDE="${CLIENT_IP}/32,${CLIENT_IPV6}/128"
if [ -n "$CLIENT_SUBNETS_V4" ]; then
    ALLOWED_IPS_SERVER_SIDE="${ALLOWED_IPS_SERVER_SIDE},${CLIENT_SUBNETS_V4}"
fi

# Persistent Site-to-Site Logic: Collect all existing remote subnets
# This looks at [Route] sections in the .network file to find all subnets managed by other clients
EXISTING_REMOTE_SUBNETS=""
if [ -f "$NETWORK_FILE" ]; then
    # Extracts all 'Destination=' values from the server network file
    EXISTING_REMOTE_SUBNETS=$(grep -oP '^Destination=\K.*' "$NETWORK_FILE" | tr '\n' ',' | sed 's/,$//')
fi

# Combine current VPN subnet with all discovered remote subnets for the new client's config
CLIENT_ALLOWED_IPS="${VPN_SUBNET_PREFIX}.0/${VPN_MASK}, ${IPV6_PREFIX}::/${IPV6_MASK}"
if [ -n "$EXISTING_REMOTE_SUBNETS" ]; then
    CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS}, ${EXISTING_REMOTE_SUBNETS}"
fi

# Update /etc/hosts
FULL_HOSTNAME="${CLIENT_NAME}.${DOMAIN}"
echo "Adding entries to $HOSTS_FILE..."
echo "$CLIENT_IP    $FULL_HOSTNAME $CLIENT_NAME" >> "$HOSTS_FILE"
echo "$CLIENT_IPV6  $FULL_HOSTNAME $CLIENT_NAME" >> "$HOSTS_FILE"

# Add Peer to Server Config (.netdev)
echo "Adding Peer to $NETDEV_FILE..."
cat <<EOT >> "$NETDEV_FILE"

[WireGuardPeer]
# Client: $CLIENT_NAME
PublicKey=$CLIENT_PUB_KEY
PresharedKey=$PSK
AllowedIPs=$(echo $ALLOWED_IPS_SERVER_SIDE | sed 's/,/\nAllowedIPs=/g')
EOT

# Add Static Routes to Server (.network)
if [ -n "$CLIENT_SUBNETS_V4" ] && [ -f "$NETWORK_FILE" ]; then
    echo "Adding static routes to $NETWORK_FILE..."
    IFS=',' read -ra SUBNETS <<< "$CLIENT_SUBNETS_V4"
    for subnet in "${SUBNETS[@]}"; do
        subnet=$(echo "$subnet" | xargs) 
        cat <<EOT >> "$NETWORK_FILE"

# Route to Client: $CLIENT_NAME
[Route]
Destination=$subnet
EOT
    done
fi

# === SERVER RELOAD ===
echo "Fixing file permissions and reloading server..."

if getent group systemd-network > /dev/null; then
    chown root:systemd-network "$NETDEV_FILE"
else
    chown root:root "$NETDEV_FILE"
fi
# 640 = User RW, Group R (Required for systemd-networkd access)
chmod 640 "$NETDEV_FILE"

if networkctl reload; then
    echo "-> Success: Server configuration active."
else
    echo "-> ERROR: 'networkctl reload' failed. Check logs!"
fi

# Select Output Format
echo ""
echo "Select configuration format for the client:"
select FORMAT in "WireGuard-Conf" "Systemd-Networkd" "QR-Code-PNG"; do
    case $FORMAT in
        "WireGuard-Conf")
            FILE_PATH="${OUT_DIR}/${CLIENT_NAME}.conf"
            cat <<EOT > "$FILE_PATH"
[Interface]
Address = ${CLIENT_IP}/${VPN_MASK}, ${CLIENT_IPV6}/${IPV6_MASK}
PrivateKey = ${CLIENT_PRIV_KEY}
DNS = ${SERVER_VPN_IP}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${PSK}
Endpoint = ${SERVER_ENDPOINT}
# SPLIT TUNNEL + REMOTE SUBNETS
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25
EOT
            echo "Config saved to: $FILE_PATH"
            break
            ;;
        
        "Systemd-Networkd")
            CLIENT_DIR="${OUT_DIR}/${CLIENT_NAME}"
            mkdir -p "$CLIENT_DIR"

            NETDEV_CLIENT="${CLIENT_DIR}/90-wg0.netdev"
            NETWORK_CLIENT="${CLIENT_DIR}/90-wg0.network"
            
            # .netdev
            cat <<EOT > "$NETDEV_CLIENT"
[NetDev]
Name=wg0
Kind=wireguard

[WireGuard]
PrivateKey=${CLIENT_PRIV_KEY}

[WireGuardPeer]
PublicKey=${SERVER_PUB_KEY}
PresharedKey=${PSK}
Endpoint=${SERVER_ENDPOINT}
# SPLIT TUNNEL + REMOTE SUBNETS
AllowedIPs=$(echo $CLIENT_ALLOWED_IPS | sed 's/,/\nAllowedIPs=/g' | tr -d ' ')

PersistentKeepalive=25
EOT

            # .network
            cat <<EOT > "$NETWORK_CLIENT"
[Match]
Name=wg0

[Network]
Address=${CLIENT_IP}/${VPN_MASK}
Address=${CLIENT_IPV6}/${IPV6_MASK}
DNS=${SERVER_VPN_IP}
Domains=${DOMAIN}
EOT
            
            echo "Files saved in: $CLIENT_DIR/"
            echo "- 90-wg0.netdev"
            echo "- 90-wg0.network"
            echo ""
            echo "=========================================================="
            echo " IMPORTANT: Installation on Client (Debian/Ubuntu)"
            echo "=========================================================="
            echo "1. Copy files to /etc/systemd/network/"
            echo "2. Set correct permissions:"
            echo ""
            echo "  sudo chown root:systemd-network /etc/systemd/network/90-wg0.netdev"
            echo "  sudo chmod 640 /etc/systemd/network/90-wg0.netdev"
            echo "  sudo chmod 644 /etc/systemd/network/90-wg0.network"
            echo ""
            echo "3. Restart service:"
            echo "  sudo systemctl enable --now systemd-networkd"
            echo "  sudo networkctl reload"
            echo "=========================================================="
            break
            ;;

        "QR-Code-PNG")
            IMG_PATH="${OUT_DIR}/${CLIENT_NAME}.png"
            TEMP_CONF=$(mktemp)
            cat <<EOT > "$TEMP_CONF"
[Interface]
Address = ${CLIENT_IP}/${VPN_MASK}, ${CLIENT_IPV6}/${IPV6_MASK}
PrivateKey = ${CLIENT_PRIV_KEY}
DNS = ${SERVER_VPN_IP}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${PSK}
Endpoint = ${SERVER_ENDPOINT}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25
EOT
            qrencode -t PNG -o "$IMG_PATH" < "$TEMP_CONF"
            rm "$TEMP_CONF"
            echo "QR-Code saved to: $IMG_PATH"
            break
            ;;
        *) echo "Invalid selection";;
    esac
done

echo "Done."
```

#!/bin/bash

# Ensure the script is run with sudo
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)."
   exit 1
fi

echo "--- NFS over WireGuard Automount Generator ---"

read -p "Enter NFS Server Address (e.g., 10.0.0.5:/volume1/share): " NFS_SOURCE
read -p "Enter Local Mount Path (e.g., /mnt/nfs_share): " MOUNT_PATH

# Generate systemd-escaped filenames
UNIT_NAME=$(systemd-escape --suffix=mount --path "$MOUNT_PATH")
AUTOMOUNT_NAME=$(systemd-escape --suffix=automount --path "$MOUNT_PATH")

mkdir -p "$MOUNT_PATH"

# 1. Create the .mount Unit (The actual connection logic)
# Note: This file does NOT have an [Install] section because it is triggered by the automount.
cat <<EOF > /etc/systemd/system/"$UNIT_NAME"
[Unit]
Description=NFS Mount for $MOUNT_PATH via wg0
# BindsTo ensures that if wg0 goes down, systemd forcefully unmounts this share
BindsTo=sys-subsystem-net-devices-wg0.device
After=sys-subsystem-net-devices-wg0.device

[Mount]
What=$NFS_SOURCE
Where=$MOUNT_PATH
Type=nfs
# soft: Returns I/O errors instead of freezing applications if the connection drops
# timeo=50: 5-second timeout per retry (measured in deciseconds)
# retrans=3: Try 3 times before failing
Options=defaults,_netdev,soft,timeo=50,retrans=3
TimeoutSec=10
EOF

# 2. Create the .automount Unit (The listener)
cat <<EOF > /etc/systemd/system/"$AUTOMOUNT_NAME"
[Unit]
Description=Automount listener for $MOUNT_PATH

[Automount]
Where=$MOUNT_PATH
# Unmount the share automatically after 5 minutes of inactivity
TimeoutIdleSec=300

[Install]
WantedBy=multi-user.target
EOF

# 3. Set Permissions and Reload
chmod 644 /etc/systemd/system/"$UNIT_NAME" /etc/systemd/system/"$AUTOMOUNT_NAME"
systemctl daemon-reload

echo "----------------------------------------"
echo "Created: /etc/systemd/system/$UNIT_NAME"
echo "Created: /etc/systemd/system/$AUTOMOUNT_NAME"

# 4. Enable and Start Automount
systemctl enable --now "$AUTOMOUNT_NAME"

if [ $? -eq 0 ]; then
    echo "Success! Automount is active. The share will mount seamlessly when you access '$MOUNT_PATH'."
else
    echo "Error enabling automount. Check 'journalctl -xe' for details."
fi

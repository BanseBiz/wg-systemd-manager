# WireGuard Client Wizard (`add-wg-client.sh`)

## Purpose and Function
This script automates the administration of a WireGuard VPN server that is managed via `systemd-networkd` (rather than the traditional `wg-quick`). It is designed to safely and easily provision new client connections while maintaining complex routing rules.

**Key Features:**
* **Automated IP Management:** Scans the server configuration to find and assign the next available IPv4 and IPv6 addresses.
* **Dynamic Tunnel Modes:** Allows the administrator to choose between a **Split Tunnel** (routing only VPN and site-to-site traffic) or a **Full Tunnel** (routing all client internet traffic through the server).
* **Site-to-Site Persistence:** If a client has a local subnet behind it (e.g., a branch office router), the script automatically adds static routes to the server. Furthermore, it intelligently reads existing remote subnets from the server and includes them in the `AllowedIPs` of all newly created clients, ensuring full mesh-like visibility across your VPN.
* **Pre-Shared Keys (PSK) & Keepalive:** Automatically generates PSKs and configures persistent keepalives for maximum tunnel reliability.
* **Multiple Export Formats:** Outputs the final client configuration as a standard `.conf` file, `systemd-networkd` `.netdev`/`.network` files, or a scannable QR-code PNG.

---

## Dependencies
To run this script successfully, the server must have the following tools installed and operational:

* **Root Privileges:** The script must be run as `root` (or via `sudo`) to read private keys and modify system network files.
* **`wireguard-tools`:** Specifically the `wg` command, used to generate private/public keys and pre-shared keys.
* **`qrencode`:** Required to generate QR-code images for mobile device provisioning.
* **`systemd-networkd`:** The server's networking must be managed by systemd. The script relies on `networkctl reload` to apply changes instantly without dropping the interface.

*(To install missing packages on Debian/Ubuntu: `apt install wireguard-tools qrencode`)*

---

## Files Accessed

The script interacts with several files on the host system to function. It is categorized into files it reads, files it modifies, and files it creates.

### Files Read
* `/etc/systemd/network/90-wg0.netdev`: Reads the server's `PrivateKey` to calculate the public key. Also scans this file to determine which IP addresses are already assigned to existing peers.
* `/etc/systemd/network/90-wg0.network`: Scans for existing `[Route]` blocks to dynamically build the `AllowedIPs` list for Site-to-Site routing. It also checks this file for `IPForward=yes` and `IPMasquerade=` to warn you if Full Tunnel routing might fail.

### Files Modified (Appended)
* `/etc/systemd/network/90-wg0.netdev`: Appends a new `[WireGuardPeer]` block containing the new client's public key, PSK, and allowed IPs.
* `/etc/systemd/network/90-wg0.network`: (If applicable) Appends new `[Route]` blocks if the new client specifies that it has local subnets hidden behind it.
* `/etc/hosts`: Appends the new client's IPv4, IPv6, FQDN (e.g., `clientname.wg.banse.biz`), and hostname for easy local DNS resolution.

### Files Created (Outputs)
By default, the script creates a directory called `./wg-config` (unless a path is passed as the first argument, e.g., `./add-wg-client.sh /custom/path`). Depending on the output format selected during execution, it will create one of the following inside that directory:

* **Standard Config:** `<OUT_DIR>/<client_name>.conf`
* **QR Code:** `<OUT_DIR>/<client_name>.png` (Uses a temporary file via `mktemp` during generation, which is securely deleted immediately after).
* **Systemd Profile:** Creates a subdirectory `<OUT_DIR>/<client_name>/` containing `90-wg0.netdev` and `90-wg0.network` specifically tailored for the client.

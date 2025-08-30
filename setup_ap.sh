#!/bin/bash
set -e

# =======================================
# Smart Wardrobe Setup - Fixed Version
# =======================================

# Ensure root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# Define file locations
SOURCE_DIR="/home/web/smartwardrobe"
SERVER_PATH="${SOURCE_DIR}/setup-server/server.js"
TARGET_DIR="/opt/smartwardrobe"
LOG_DIR="/var/log/smartwardrobe"
CONFIG_DIR="/etc/smartwardrobe"

# Logging setup
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/bootstrap.log"
log() {
    echo "$(date): $1" | tee -a "$LOGFILE"
}

log "Starting Smart Wardrobe setup process..."

# ---------------------------
# Check internet connectivity
# ---------------------------
log "Checking internet connectivity..."
if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
    log "Error: No internet connection. Connect to WiFi first or check Ethernet."
    exit 1
fi

# ---------------------------
# Install required packages
# ---------------------------
log "Installing required packages..."
apt update || { log "Error: apt update failed"; exit 1; }
apt install -y hostapd dnsmasq iptables-persistent netfilter-persistent jq nodejs npm || { log "Error: Package installation failed"; exit 1; }

# ---------------------------
# Detect WiFi interface and validate
# ---------------------------
WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -1)
if [ -z "$WIFI_IFACE" ]; then
    log "Error: No WiFi interface detected. Ensure WiFi is enabled."
    exit 1
fi
log "Using WiFi interface: $WIFI_IFACE"

# ---------------------------
# Stop and disable conflicting services properly
# ---------------------------
log "Stopping and disabling conflicting services..."
systemctl stop wpa_supplicant dhcpcd hostapd dnsmasq NetworkManager 2>/dev/null || true
systemctl disable wpa_supplicant dhcpcd 2>/dev/null || true

# Kill any lingering processes
pkill -f wpa_supplicant || true
pkill -f dhclient || true

# ---------------------------
# Configure hostapd with detected interface
# ---------------------------
log "Setting up access point..."
mkdir -p /etc/hostapd
cat > /etc/hostapd/hostapd.conf << EOF
interface=$WIFI_IFACE
driver=nl80211
ssid=SmartWardrobe-Setup
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=smartwardrobe123
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

# ---------------------------
# Configure dnsmasq with detected interface
# ---------------------------
log "Configuring DHCP server..."
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null || true
cat > /etc/dnsmasq.conf << EOF
interface=$WIFI_IFACE
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
address=/#/192.168.4.1
EOF

# ---------------------------
# Enable forwarding & firewall
# ---------------------------
log "Configuring network settings..."
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-smartwardrobe.conf
sysctl -p /etc/sysctl.d/99-smartwardrobe.conf

# Clear existing rules
iptables -F
iptables -t nat -F

# Setup NAT and forwarding
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i "$WIFI_IFACE" -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i eth0 -o "$WIFI_IFACE" -j ACCEPT

# Save rules
iptables-save > /etc/iptables/rules.v4
systemctl enable netfilter-persistent

# Create directories
mkdir -p "${CONFIG_DIR}"
mkdir -p "${LOG_DIR}"
mkdir -p "${TARGET_DIR}"

# ---------------------------
# Fixed AP Script - Single interface management
# ---------------------------
log "Creating system scripts..."
cat > /usr/local/bin/smartwardrobe-force-ap.sh << 'EOF'
#!/bin/bash
LOGFILE=/var/log/smartwardrobe/system.log
WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -1)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
    echo "$1"
}

if [ -z "$WIFI_IFACE" ]; then
    log "ERROR: No WiFi interface found"
    exit 1
fi

log "Starting AP mode on interface: $WIFI_IFACE"

# Stop NetworkManager completely
log "Stopping NetworkManager"
systemctl stop NetworkManager.service || true
sleep 3

# Kill interfering processes
log "Killing interfering processes"
pkill -f wpa_supplicant || true
pkill -f dhclient || true
pkill -f NetworkManager || true

# Stop services
systemctl stop hostapd.service dnsmasq.service || true
sleep 2

# Configure interface manually
log "Configuring interface $WIFI_IFACE"
ip link set "$WIFI_IFACE" down
ip addr flush dev "$WIFI_IFACE"
ip link set "$WIFI_IFACE" up
ip addr add 192.168.4.1/24 dev "$WIFI_IFACE"

# Wait for interface to be ready
sleep 3

# Start AP services
log "Starting AP services"
systemctl start hostapd.service
sleep 2
systemctl start dnsmasq.service

# Verify services are running
if systemctl is-active hostapd.service >/dev/null && systemctl is-active dnsmasq.service >/dev/null; then
    log "AP mode active - SSID: SmartWardrobe-Setup"
    # Create status file
    echo "ap" > /tmp/smartwardrobe-mode
else
    log "ERROR: AP services failed to start"
    systemctl status hostapd.service >> "$LOGFILE"
    systemctl status dnsmasq.service >> "$LOGFILE"
    exit 1
fi
EOF

chmod +x /usr/local/bin/smartwardrobe-force-ap.sh

# ---------------------------
# Fixed Connection Manager Script
# ---------------------------
cat > /usr/local/bin/smartwardrobe-connection-manager.sh << 'EOF'
#!/bin/bash
CONFIG_FILE="/etc/smartwardrobe/config.json"
LOGFILE="/var/log/smartwardrobe/system.log"
WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -1)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
    echo "$1"
}

check_internet() {
    ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1
    return $?
}

if [ -z "$WIFI_IFACE" ]; then
    log "ERROR: No WiFi interface found"
    exit 1
fi

log "Starting connection manager for interface: $WIFI_IFACE"

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    log "No WiFi config found. Switching to AP mode"
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 0
fi

# Read configuration
SSID=$(jq -r '.ssid // empty' "$CONFIG_FILE" 2>/dev/null)
PASSWORD=$(jq -r '.password // empty' "$CONFIG_FILE" 2>/dev/null)

if [ -z "$SSID" ] || [ -z "$PASSWORD" ]; then
    log "WiFi config invalid. Switching to AP mode"
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 0
fi

log "Attempting to connect to WiFi: $SSID"

# Stop AP services completely
log "Stopping AP services"
systemctl stop hostapd.service dnsmasq.service || true
pkill -f hostapd || true
pkill -f dnsmasq || true

# Clean up interface
log "Cleaning up interface $WIFI_IFACE"
ip addr flush dev "$WIFI_IFACE" || true
ip link set "$WIFI_IFACE" down || true
sleep 2
ip link set "$WIFI_IFACE" up || true

# Start NetworkManager and configure
log "Starting NetworkManager"
systemctl start NetworkManager.service
sleep 5

# Ensure interface is managed
nmcli device set "$WIFI_IFACE" managed yes
nmcli radio wifi on
sleep 3

# Create connection
CONNECTION_NAME="SmartWardrobe-WiFi"
log "Creating WiFi connection: $CONNECTION_NAME"

# Remove existing connection
nmcli con delete "$CONNECTION_NAME" 2>/dev/null || true

# Add new connection
if ! nmcli con add type wifi con-name "$CONNECTION_NAME" ssid "$SSID"; then
    log "Failed to create connection profile"
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 1
fi

# Configure security
if ! nmcli con modify "$CONNECTION_NAME" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASSWORD"; then
    log "Failed to set WiFi security"
    nmcli con delete "$CONNECTION_NAME" 2>/dev/null || true
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 1
fi

# Set to autoconnect
nmcli con modify "$CONNECTION_NAME" autoconnect yes

# Connect with timeout
log "Connecting to $SSID..."
if timeout 60 nmcli con up "$CONNECTION_NAME"; then
    log "WiFi connection established"
    sleep 10
    
    if check_internet; then
        NEW_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}' 2>/dev/null)
        log "Successfully connected to $SSID with internet access. IP: $NEW_IP"
        echo "client" > /tmp/smartwardrobe-mode
        echo "$(date)" > "/etc/smartwardrobe/wifi-connected"
        exit 0
    else
        log "Connected but no internet access"
    fi
else
    log "Failed to connect to WiFi network"
fi

# Cleanup failed connection
nmcli con delete "$CONNECTION_NAME" 2>/dev/null || true
log "Falling back to AP mode"
/usr/local/bin/smartwardrobe-force-ap.sh
exit 1
EOF

chmod +x /usr/local/bin/smartwardrobe-connection-manager.sh

# ---------------------------
# Simplified systemd services with proper dependencies
# ---------------------------
log "Creating system services..."

# Boot manager service
cat > /etc/systemd/system/smartwardrobe-boot.service << 'EOF'
[Unit]
Description=Smart Wardrobe Boot Manager
After=multi-user.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ -f "/etc/smartwardrobe/config.json" ]; then /usr/local/bin/smartwardrobe-connection-manager.sh; else /usr/local/bin/smartwardrobe-force-ap.sh; fi'
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------
# Setup server.js and install dependencies
# ---------------------------
log "Setting up server application..."
if [ -f "${SERVER_PATH}" ]; then
    cp -f "${SERVER_PATH}" "${TARGET_DIR}/server.js"
    log "Copied server.js from ${SERVER_PATH}"
else
    log "Server file not found, using embedded version"
    
fi

# Install npm dependencies
log "Installing npm packages..."
cd "${TARGET_DIR}"
npm init -y >/dev/null 2>&1 || true
npm install --no-fund express >/dev/null 2>&1 || log "Warning: npm install failed"

# ---------------------------
# Web server service
# ---------------------------
cat > /etc/systemd/system/smartwardrobe-server.service << EOF
[Unit]
Description=Smart Wardrobe Setup Web Server
After=smartwardrobe-boot.service
Requires=smartwardrobe-boot.service
ConditionPathExists=${TARGET_DIR}/server.js

[Service]
ExecStart=/usr/bin/node ${TARGET_DIR}/server.js
WorkingDirectory=${TARGET_DIR}
StandardOutput=append:${LOG_DIR}/server.log
StandardError=append:${LOG_DIR}/server.log
User=root
Restart=always
RestartSec=10
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------
# Enable services and final setup
# ---------------------------
log "Enabling services..."
systemctl daemon-reload
systemctl enable smartwardrobe-boot.service smartwardrobe-server.service
systemctl enable hostapd.service dnsmasq.service

# Set permissions
chmod 755 "${TARGET_DIR}/server.js" 2>/dev/null || true

# Start initial services
log "Starting services..."
systemctl start smartwardrobe-boot.service
sleep 5
systemctl start smartwardrobe-server.service

# Final status check
sleep 5
if systemctl is-active smartwardrobe-server.service >/dev/null; then
    log "Server is running successfully"
else
    log "Warning: Server may not have started properly"
    systemctl status smartwardrobe-server.service >> "$LOGFILE"
fi

log "==============================================================="
log "Smart Wardrobe setup complete!"
log "Device starting in AP mode with SSID: SmartWardrobe-Setup"
log "Password: smartwardrobe123"
log ""
log "To configure:"
log "1. Connect to WiFi: SmartWardrobe-Setup"
log "2. Visit: http://192.168.4.1"
log ""
log "Services will auto-start on reboot"
log "==============================================================="

log "Setup complete. Rebooting in 10 seconds..."
sleep 10
reboot
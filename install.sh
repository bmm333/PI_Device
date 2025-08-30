#!/bin/bash
set -e

# =======================================
# Smart Wardrobe Complete Installer
# =======================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/opt/smartwardrobe"
LOG_DIR="/var/log/smartwardrobe"
CONFIG_DIR="/etc/smartwardrobe"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging setup
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/install.log"

log() {
    echo "$(date): $1" | tee -a "$LOGFILE"
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

warn() {
    echo "$(date): WARNING: $1" | tee -a "$LOGFILE"
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo "$(date): ERROR: $1" | tee -a "$LOGFILE"
    echo -e "${RED}[ERROR]${NC} $1"
}

# =======================================
# Pre-flight checks
# =======================================

echo -e "${BLUE}"
echo "=============================================="
echo "   Smart Wardrobe Device Setup"
echo "=============================================="
echo -e "${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root: sudo ./install.sh"
    exit 1
fi

# Check if we're on a Raspberry Pi
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    warn "This doesn't appear to be a Raspberry Pi. Continuing anyway..."
fi

# Check internet connectivity
log "Checking internet connectivity..."
if ! ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1; then
    error "No internet connection detected!"
    echo
    echo "Please connect to internet first:"
    echo "1. Use 'sudo raspi-config' to configure WiFi"
    echo "2. Or connect Ethernet cable"
    echo "3. Then run this script again"
    echo
    exit 1
fi

# Detect WiFi interface
WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -1)
if [ -z "$WIFI_IFACE" ]; then
    error "No WiFi interface detected. WiFi must be available."
    exit 1
fi
log "WiFi interface detected: $WIFI_IFACE"

# Check for ACR122U
if lsusb | grep -qi "072f:2200\|Advanced Card Systems"; then
    log "ACR122U NFC reader detected"
    ACR122U_PRESENT=true
else
    warn "ACR122U not detected. Connect it before running RFID service."
    ACR122U_PRESENT=false
fi

# =======================================
# Install system packages
# =======================================

log "Updating package lists..."
apt update || { error "apt update failed"; exit 1; }

log "Installing system packages..."
PACKAGES="hostapd dnsmasq iptables-persistent netfilter-persistent jq nodejs npm python3-pip libusb-1.0-0-dev libnfc-dev"
apt install -y $PACKAGES || { error "Package installation failed"; exit 1; }

# Install Python packages for ACR122U
if [ "$ACR122U_PRESENT" = true ]; then
    log "Installing Python NFC libraries..."
    pip3 install nfcpy || warn "Failed to install nfcpy - RFID service may not work"
fi

# =======================================
# Stop conflicting services
# =======================================

log "Configuring system services..."
systemctl stop wpa_supplicant dhcpcd NetworkManager hostapd dnsmasq 2>/dev/null || true
systemctl disable wpa_supplicant dhcpcd 2>/dev/null || true

# Kill interfering processes
pkill -f wpa_supplicant || true
pkill -f dhclient || true

# =======================================
# Configure Access Point
# =======================================

log "Setting up access point configuration..."
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

# Configure DHCP
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null || true
cat > /etc/dnsmasq.conf << EOF
interface=$WIFI_IFACE
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
address=/#/192.168.4.1
EOF

# =======================================
# Network configuration
# =======================================

log "Configuring network forwarding..."
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-smartwardrobe.conf
sysctl -p /etc/sysctl.d/99-smartwardrobe.conf

# Configure firewall
iptables -F
iptables -t nat -F
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i "$WIFI_IFACE" -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i eth0 -o "$WIFI_IFACE" -j ACCEPT
iptables-save > /etc/iptables/rules.v4
systemctl enable netfilter-persistent

# =======================================
# Create application directories and copy files
# =======================================

log "Setting up application files..."
mkdir -p "$TARGET_DIR" "$CONFIG_DIR" "$LOG_DIR"

# Copy server files from current directory
if [ -f "$SCRIPT_DIR/server.js" ]; then
    cp "$SCRIPT_DIR/server.js" "$TARGET_DIR/"
    log "Copied server.js from $SCRIPT_DIR"
else
    error "server.js not found in $SCRIPT_DIR"
    echo "Please ensure server.js is in the same directory as this install script"
    exit 1
fi

if [ -f "$SCRIPT_DIR/rfid_service.js" ]; then
    cp "$SCRIPT_DIR/rfid_service.js" "$TARGET_DIR/"
    log "Copied rfid_service.js"
fi

# Set permissions
chmod +x "$TARGET_DIR"/*.js
chown -R root:root "$TARGET_DIR"

# =======================================
# Create system scripts
# =======================================

log "Creating system management scripts..."

# AP Mode script
cat > /usr/local/bin/smartwardrobe-force-ap.sh << EOF
#!/bin/bash
LOGFILE=$LOG_DIR/system.log
WIFI_IFACE=$WIFI_IFACE

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOGFILE"
    echo "\$1"
}

log "Starting AP mode on interface: \$WIFI_IFACE"

# Stop NetworkManager
systemctl stop NetworkManager.service || true
sleep 3

# Kill processes
pkill -f wpa_supplicant || true
pkill -f dhclient || true

# Stop services
systemctl stop hostapd.service dnsmasq.service || true
sleep 2

# Configure interface
ip link set "\$WIFI_IFACE" down
ip addr flush dev "\$WIFI_IFACE"
ip link set "\$WIFI_IFACE" up
ip addr add 192.168.4.1/24 dev "\$WIFI_IFACE"
sleep 3

# Start services
systemctl start hostapd.service
sleep 2
systemctl start dnsmasq.service

if systemctl is-active hostapd.service >/dev/null; then
    log "AP mode active - SSID: SmartWardrobe-Setup"
    echo "ap" > /tmp/smartwardrobe-mode
else
    log "ERROR: AP mode failed to start"
    exit 1
fi
EOF

# WiFi Client script
cat > /usr/local/bin/smartwardrobe-connect-wifi.sh << EOF
#!/bin/bash
CONFIG_FILE="$CONFIG_DIR/config.json"
LOGFILE="$LOG_DIR/system.log"
WIFI_IFACE=$WIFI_IFACE

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOGFILE"
    echo "\$1"
}

check_internet() {
    ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1
}

if [ ! -f "\$CONFIG_FILE" ]; then
    log "No config found, starting AP mode"
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 0
fi

SSID=\$(jq -r '.ssid // empty' "\$CONFIG_FILE" 2>/dev/null)
PASSWORD=\$(jq -r '.password // empty' "\$CONFIG_FILE" 2>/dev/null)

if [ -z "\$SSID" ] || [ -z "\$PASSWORD" ]; then
    log "Invalid config, starting AP mode"
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 0
fi

log "Connecting to WiFi: \$SSID"

# Stop AP mode
systemctl stop hostapd.service dnsmasq.service || true
pkill -f hostapd || true
pkill -f dnsmasq || true

# Clean interface
ip addr flush dev "\$WIFI_IFACE" || true
ip link set "\$WIFI_IFACE" down || true
sleep 2
ip link set "\$WIFI_IFACE" up || true

# Start NetworkManager
systemctl start NetworkManager.service
sleep 5

nmcli device set "\$WIFI_IFACE" managed yes
nmcli radio wifi on
sleep 3

# Create connection
CONNECTION_NAME="SmartWardrobe-WiFi"
nmcli con delete "\$CONNECTION_NAME" 2>/dev/null || true

if nmcli con add type wifi con-name "\$CONNECTION_NAME" ssid "\$SSID" && \
   nmcli con modify "\$CONNECTION_NAME" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "\$PASSWORD" && \
   nmcli con modify "\$CONNECTION_NAME" autoconnect yes && \
   timeout 60 nmcli con up "\$CONNECTION_NAME"; then
    
    sleep 10
    if check_internet; then
        NEW_IP=\$(ip route get 1.1.1.1 | awk '{print \$7; exit}' 2>/dev/null)
        log "Connected to \$SSID successfully. IP: \$NEW_IP"
        echo "client" > /tmp/smartwardrobe-mode
        exit 0
    fi
fi

log "WiFi connection failed, falling back to AP mode"
nmcli con delete "\$CONNECTION_NAME" 2>/dev/null || true
/usr/local/bin/smartwardrobe-force-ap.sh
EOF

chmod +x /usr/local/bin/smartwardrobe-*.sh

# =======================================
# Create systemd services
# =======================================

log "Creating systemd services..."

# Boot manager
cat > /etc/systemd/system/smartwardrobe-boot.service << 'EOF'
[Unit]
Description=Smart Wardrobe Boot Manager
After=multi-user.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ -f "/etc/smartwardrobe/config.json" ]; then /usr/local/bin/smartwardrobe-connect-wifi.sh; else /usr/local/bin/smartwardrobe-force-ap.sh; fi'
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

# Web server service
cat > /etc/systemd/system/smartwardrobe-server.service << EOF
[Unit]
Description=Smart Wardrobe Setup Web Server
After=smartwardrobe-boot.service
Requires=smartwardrobe-boot.service

[Service]
ExecStart=/usr/bin/node $TARGET_DIR/server.js
WorkingDirectory=$TARGET_DIR
StandardOutput=append:$LOG_DIR/server.log
StandardError=append:$LOG_DIR/server.log
User=root
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# RFID service
cat > /etc/systemd/system/smartwardrobe-rfid.service << EOF
[Unit]
Description=Smart Wardrobe RFID Service
After=smartwardrobe-boot.service network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/node $TARGET_DIR/rfid_service.js
WorkingDirectory=$TARGET_DIR
StandardOutput=append:$LOG_DIR/rfid.log
StandardError=append:$LOG_DIR/rfid.log
User=root
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# =======================================
# Enable services
# =======================================

log "Enabling services..."
systemctl daemon-reload
systemctl enable smartwardrobe-boot.service smartwardrobe-server.service
systemctl enable hostapd.service dnsmasq.service

if [ "$ACR122U_PRESENT" = true ]; then
    systemctl enable smartwardrobe-rfid.service
    log "RFID service enabled"
fi

# =======================================
# Add udev rules for ACR122U
# =======================================

if [ "$ACR122U_PRESENT" = true ]; then
    log "Adding ACR122U udev rules..."
    cat > /etc/udev/rules.d/99-acr122u.rules << 'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="072f", ATTRS{idProduct}=="2200", MODE="0666", GROUP="plugdev"
EOF
    udevadm control --reload-rules
    udevadm trigger
fi

# =======================================
# Start services
# =======================================

log "Starting services..."
systemctl start smartwardrobe-boot.service
sleep 5
systemctl start smartwardrobe-server.service

if [ "$ACR122U_PRESENT" = true ]; then
    systemctl start smartwardrobe-rfid.service
fi

# =======================================
# Final verification
# =======================================

sleep 10
log "Verifying installation..."

if systemctl is-active smartwardrobe-server.service >/dev/null; then
    log "Web server is running"
    if curl -s http://localhost >/dev/null; then
        log "Web interface is accessible"
    else
        warn "Web interface not responding"
    fi
else
    error "Web server failed to start"
    systemctl status smartwardrobe-server.service
fi

if [ "$ACR122U_PRESENT" = true ]; then
    if systemctl is-active smartwardrobe-rfid.service >/dev/null; then
        log "RFID service is running"
    else
        warn "RFID service not running - check logs"
    fi
fi

# =======================================
# Installation complete
# =======================================

echo
echo -e "${GREEN}=============================================="
echo "   Installation Complete!"
echo "=============================================="
echo -e "${NC}"
echo
echo "Your Smart Wardrobe device is now running in AP mode:"
echo "  • SSID: SmartWardrobe-Setup"
echo "  • Password: smartwardrobe123"
echo "  • Setup URL: http://192.168.4.1"
echo
echo "To configure:"
echo "1. Connect your phone/laptop to 'SmartWardrobe-Setup' WiFi"
echo "2. Open browser and go to http://192.168.4.1"
echo "3. Enter your home WiFi credentials and API key"
echo "4. Device will automatically switch to your home WiFi"
echo
if [ "$ACR122U_PRESENT" = true ]; then
    echo "RFID Service: Ready to scan tags and send to backend"
else
    echo "RFID Service: Connect ACR122U and restart to enable"
fi
echo
echo "Logs: /var/log/smartwardrobe/"
echo "Config: /etc/smartwardrobe/config.json"
echo
echo "Rebooting in 10 seconds..."
sleep 10
reboot
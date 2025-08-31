#!/bin/bash
set -e

# =======================================
# Smart Wardrobe Complete Installer - ROBUST VERSION
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
chmod 755 "$LOG_DIR"

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
echo "   Smart Wardrobe Device Setup - ROBUST"
echo "=============================================="
echo -e "${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root: sudo ./install.sh"
    exit 1
fi

# Check if required files exist
if [ ! -f "$SCRIPT_DIR/server.js" ]; then
    error "server.js not found in $SCRIPT_DIR"
    echo "Please ensure server.js is in the same directory as this install script"
    exit 1
fi

# Check for RFID service
if [ -f "$SCRIPT_DIR/rfid_service.js" ]; then
    log "rfid_service.js found - RFID support will be enabled"
    RFID_SERVICE_PRESENT=true
else
    warn "rfid_service.js not found - RFID support will be disabled"
    RFID_SERVICE_PRESENT=false
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

# Detect WiFi interface more robustly
WIFI_IFACE=""
for iface in wlan0 wlp* wl*; do
    if ip link show "$iface" >/dev/null 2>&1; then
        WIFI_IFACE="$iface"
        break
    fi
done

if [ -z "$WIFI_IFACE" ]; then
    # Try alternative detection
    WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -1)
fi

if [ -z "$WIFI_IFACE" ]; then
    error "No WiFi interface detected. WiFi must be available."
    echo "Available interfaces:"
    ip link show
    exit 1
fi
log "WiFi interface detected: $WIFI_IFACE"

# Check for ACR122U
if lsusb | grep -qi "072f:2200\|Advanced Card Systems"; then
    log "ACR122U NFC reader detected"
    ACR122U_PRESENT=true
else
    warn "ACR122U not detected. You can connect it later."
    ACR122U_PRESENT=false
fi

# =======================================
# Clean up any existing installation
# =======================================

log "Cleaning up any previous installation..."
systemctl stop smartwardrobe-boot.service smartwardrobe-server.service smartwardrobe-rfid.service 2>/dev/null || true
systemctl disable smartwardrobe-boot.service smartwardrobe-server.service smartwardrobe-rfid.service 2>/dev/null || true
systemctl daemon-reload

# =======================================
# Install system packages
# =======================================

log "Updating package lists..."
apt update || { error "apt update failed"; exit 1; }

log "Installing system packages..."
PACKAGES="hostapd dnsmasq iptables-persistent netfilter-persistent jq nodejs npm python3-pip libusb-1.0-0-dev libnfc-dev pcscd pcsc-tools libccid python3-setuptools python3-dev build-essential"

# Install packages one by one to catch failures
for package in $PACKAGES; do
    log "Installing $package..."
    if ! apt install -y "$package"; then
        warn "Failed to install $package - continuing"
    fi
done

# Install Python packages for RFID if needed
if [ "$RFID_SERVICE_PRESENT" = true ]; then
    log "Installing Python NFC libraries..."
    
    # Try multiple installation methods
    if pip3 install --break-system-packages pyscard 2>/dev/null; then
        log "pyscard installed with --break-system-packages"
    elif pip3 install pyscard 2>/dev/null; then
        log "pyscard installed without --break-system-packages"
    elif pip install pyscard 2>/dev/null; then
        log "pyscard installed with pip"
    else
        warn "Failed to install pyscard - RFID service may not work"
        RFID_SERVICE_PRESENT=false
    fi
    
    # Verify installation
    if python3 -c "import smartcard; print('pyscard working')" 2>/dev/null; then
        log "pyscard verification successful"
    else
        warn "pyscard verification failed - disabling RFID service"
        RFID_SERVICE_PRESENT=false
    fi
fi

# =======================================
# Stop conflicting services and unmask
# =======================================

log "Stopping and unmasking services..."
# First unmask critical services that might be masked
systemctl unmask hostapd.service 2>/dev/null || true
systemctl unmask dnsmasq.service 2>/dev/null || true
systemctl unmask NetworkManager.service 2>/dev/null || true

# Stop conflicting services
systemctl stop wpa_supplicant dhcpcd NetworkManager hostapd dnsmasq 2>/dev/null || true
systemctl disable wpa_supplicant dhcpcd 2>/dev/null || true

# Kill interfering processes
pkill -f wpa_supplicant || true
pkill -f dhclient || true
pkill -f hostapd || true
pkill -f dnsmasq || true

log "Services unmasked and stopped"

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
cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup 2>/dev/null || true
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

# Save iptables rules
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
systemctl enable netfilter-persistent

# =======================================
# Create application directories and copy files
# =======================================

log "Setting up application files..."
mkdir -p "$TARGET_DIR" "$CONFIG_DIR" "$LOG_DIR"
chmod 755 "$TARGET_DIR" "$CONFIG_DIR" "$LOG_DIR"

# Copy server files from current directory
cp "$SCRIPT_DIR/server.js" "$TARGET_DIR/"
log "Copied server.js from $SCRIPT_DIR"

# Copy RFID service if it exists
if [ "$RFID_SERVICE_PRESENT" = true ]; then
    cp "$SCRIPT_DIR/rfid_service.js" "$TARGET_DIR/"
    log "Copied rfid_service.js"
fi

# Set permissions
chmod +x "$TARGET_DIR"/*.js 2>/dev/null || true
chown -R root:root "$TARGET_DIR"

# =======================================
# Create system scripts
# =======================================

log "Creating system management scripts..."

# Force AP Mode script
cat > /usr/local/bin/smartwardrobe-force-ap.sh << EOF
#!/bin/bash
set -e
LOGFILE=$LOG_DIR/system.log
WIFI_IFACE=$WIFI_IFACE

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOGFILE"
    echo "\$1"
}

log "Starting AP mode on interface: \$WIFI_IFACE"

# Stop NetworkManager completely
systemctl stop NetworkManager.service 2>/dev/null || true
sleep 2

# Kill all interfering processes
pkill -f wpa_supplicant || true
pkill -f dhclient || true
pkill -f hostapd || true
pkill -f dnsmasq || true
sleep 2

# Reset the interface completely
ip link set "\$WIFI_IFACE" down 2>/dev/null || true
sleep 1
ip addr flush dev "\$WIFI_IFACE" 2>/dev/null || true
ip link set "\$WIFI_IFACE" up 2>/dev/null || true
sleep 2

# Configure interface for AP mode
if ! ip addr add 192.168.4.1/24 dev "\$WIFI_IFACE" 2>/dev/null; then
    log "Failed to set IP address, trying to flush and retry..."
    ip addr flush dev "\$WIFI_IFACE" 2>/dev/null || true
    sleep 1
    ip addr add 192.168.4.1/24 dev "\$WIFI_IFACE" || {
        log "ERROR: Failed to configure interface IP"
        exit 1
    }
fi

# Start hostapd
log "Starting hostapd..."
if ! systemctl start hostapd.service; then
    log "hostapd failed to start, checking configuration..."
    systemctl status hostapd.service || true
    exit 1
fi
sleep 3

# Start dnsmasq
log "Starting dnsmasq..."
if ! systemctl start dnsmasq.service; then
    log "dnsmasq failed to start, checking configuration..."
    systemctl status dnsmasq.service || true
    exit 1
fi
sleep 2

# Verify services are running
if systemctl is-active hostapd.service >/dev/null && systemctl is-active dnsmasq.service >/dev/null; then
    log "AP mode successfully started - SSID: SmartWardrobe-Setup"
    echo "ap" > /tmp/smartwardrobe-mode
else
    log "ERROR: AP mode services not running properly"
    systemctl status hostapd.service || true
    systemctl status dnsmasq.service || true
    exit 1
fi
EOF

# WiFi Client Connection script
cat > /usr/local/bin/smartwardrobe-connect-wifi.sh << EOF
#!/bin/bash
set -e
CONFIG_FILE="$CONFIG_DIR/config.json"
LOGFILE="$LOG_DIR/system.log"
WIFI_IFACE=$WIFI_IFACE

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOGFILE"
    echo "\$1"
}

check_internet() {
    ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1
}

# Check if config file exists and is valid
if [ ! -f "\$CONFIG_FILE" ]; then
    log "No configuration file found, starting AP mode"
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 0
fi

# Parse configuration
SSID=\$(jq -r '.ssid // empty' "\$CONFIG_FILE" 2>/dev/null)
PASSWORD=\$(jq -r '.password // empty' "\$CONFIG_FILE" 2>/dev/null)

if [ -z "\$SSID" ] || [ -z "\$PASSWORD" ]; then
    log "Invalid configuration, starting AP mode"
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 0
fi

log "Attempting to connect to WiFi: \$SSID"

# Stop AP mode services
systemctl stop hostapd.service dnsmasq.service 2>/dev/null || true
pkill -f hostapd || true
pkill -f dnsmasq || true
sleep 2

# Reset interface
ip addr flush dev "\$WIFI_IFACE" 2>/dev/null || true
ip link set "\$WIFI_IFACE" down 2>/dev/null || true
sleep 1
ip link set "\$WIFI_IFACE" up 2>/dev/null || true
sleep 2

# Start NetworkManager
systemctl start NetworkManager.service
sleep 5

# Configure NetworkManager
nmcli device set "\$WIFI_IFACE" managed yes
nmcli radio wifi on
sleep 3

# Remove any existing connections
CONNECTION_NAME="SmartWardrobe-WiFi"
nmcli con delete "\$CONNECTION_NAME" 2>/dev/null || true
sleep 1

# Create and connect to WiFi
log "Creating WiFi connection..."
if nmcli con add type wifi con-name "\$CONNECTION_NAME" ssid "\$SSID" && \
   nmcli con modify "\$CONNECTION_NAME" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "\$PASSWORD" && \
   nmcli con modify "\$CONNECTION_NAME" autoconnect yes; then
   
   log "Connecting to \$SSID..."
   if timeout 60 nmcli con up "\$CONNECTION_NAME"; then
       sleep 10
       if check_internet; then
           NEW_IP=\$(ip route get 1.1.1.1 | awk '{print \$7; exit}' 2>/dev/null)
           log "Successfully connected to \$SSID. IP: \$NEW_IP"
           echo "client" > /tmp/smartwardrobe-mode
           exit 0
       else
           log "Connected but no internet access"
       fi
   else
       log "Failed to connect to \$SSID"
   fi
else
    log "Failed to create WiFi connection"
fi

# If we get here, WiFi failed - fall back to AP mode
log "WiFi connection failed, falling back to AP mode"
nmcli con delete "\$CONNECTION_NAME" 2>/dev/null || true
systemctl stop NetworkManager.service || true
sleep 2
/usr/local/bin/smartwardrobe-force-ap.sh
EOF

# Make scripts executable
chmod +x /usr/local/bin/smartwardrobe-*.sh

# Create symlink for compatibility
ln -sf /usr/local/bin/smartwardrobe-connect-wifi.sh /usr/local/bin/smartwardrobe-connection-manager.sh

# =======================================
# Create systemd services
# =======================================

log "Creating systemd services..."

# Boot Manager Service
cat > /etc/systemd/system/smartwardrobe-boot.service << EOF
[Unit]
Description=Smart Wardrobe Boot Network Manager
After=multi-user.target systemd-networkd.service
Before=smartwardrobe-server.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ -f "$CONFIG_DIR/config.json" ]; then /usr/local/bin/smartwardrobe-connect-wifi.sh; else /usr/local/bin/smartwardrobe-force-ap.sh; fi'
RemainAfterExit=yes
TimeoutStartSec=120
StandardOutput=append:$LOG_DIR/boot.log
StandardError=append:$LOG_DIR/boot.log

[Install]
WantedBy=multi-user.target
EOF

# Web Server Service - with better startup
cat > /etc/systemd/system/smartwardrobe-server.service << EOF
[Unit]
Description=Smart Wardrobe Web Server
After=smartwardrobe-boot.service network.target
Wants=smartwardrobe-boot.service network.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/node $TARGET_DIR/server.js
WorkingDirectory=$TARGET_DIR
StandardOutput=append:$LOG_DIR/server.log
StandardError=append:$LOG_DIR/server.log
User=root
Group=root
Restart=always
RestartSec=5
StartLimitBurst=10
StartLimitIntervalSec=300

# Ensure service starts even if network isn't fully ready
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

# RFID Service with better error handling and restart logic
if [ "$RFID_SERVICE_PRESENT" = true ]; then
    # Create enhanced device waiting script
    cat > /usr/local/bin/wait-for-acr122u.sh << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/smartwardrobe/rfid.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

reset_acr122u() {
    log "Attempting to reset ACR122U..."
    
    # Try to reset USB device
    for device in /sys/bus/usb/devices/*; do
        if [ -f "$device/idVendor" ] && [ -f "$device/idProduct" ]; then
            vendor=$(cat "$device/idVendor" 2>/dev/null)
            product=$(cat "$device/idProduct" 2>/dev/null)
            if [ "$vendor" = "072f" ] && [ "$product" = "2200" ]; then
                log "Found ACR122U at $device, attempting reset..."
                echo 0 > "$device/authorized" 2>/dev/null || true
                sleep 2
                echo 1 > "$device/authorized" 2>/dev/null || true
                sleep 3
                break
            fi
        fi
    done
    
    # Restart PC/SC service
    systemctl restart pcscd
    sleep 5
}

log "Waiting for ACR122U device to be ready..."

# Start PC/SC service if not running
if ! systemctl is-active pcscd >/dev/null 2>&1; then
    log "Starting PC/SC service..."
    systemctl start pcscd || true
    sleep 3
fi

# Wait up to 60 seconds for ACR122U to be ready
for i in {1..60}; do
    # Check if USB device is present
    if lsusb | grep -qi "072f:2200\|Advanced Card Systems"; then
        log "ACR122U USB device detected (attempt $i/60)"
        sleep 2
        
        # Check if PC/SC can see it
        if timeout 10 pcsc_scan -n 2>/dev/null | grep -q "Reader"; then
            log "ACR122U is ready and accessible"
            exit 0
        else
            log "ACR122U detected but not accessible via PC/SC"
            
            # Try reset every 10 attempts
            if [ $((i % 10)) -eq 0 ]; then
                reset_acr122u
            fi
        fi
    else
        log "Waiting for ACR122U USB device (attempt $i/60)"
    fi
    
    sleep 1
done

log "WARNING: ACR122U not ready after 60 seconds, starting service anyway"
exit 0
EOF
    chmod +x /usr/local/bin/wait-for-acr122u.sh

    # Create enhanced RFID reset script for when it stops working
    cat > /usr/local/bin/reset-acr122u.sh << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/smartwardrobe/rfid.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESET: $1" | tee -a "$LOG_FILE"
}

log "Resetting ACR122U due to read failures..."

# Stop RFID service
systemctl stop smartwardrobe-rfid.service

# Reset USB device
for device in /sys/bus/usb/devices/*; do
    if [ -f "$device/idVendor" ] && [ -f "$device/idProduct" ]; then
        vendor=$(cat "$device/idVendor" 2>/dev/null)
        product=$(cat "$device/idProduct" 2>/dev/null)
        if [ "$vendor" = "072f" ] && [ "$product" = "2200" ]; then
            log "Resetting ACR122U USB device..."
            echo 0 > "$device/authorized" 2>/dev/null || true
            sleep 3
            echo 1 > "$device/authorized" 2>/dev/null || true
            sleep 5
            break
        fi
    fi
done

# Restart PC/SC service
log "Restarting PC/SC service..."
systemctl restart pcscd
sleep 5

# Restart RFID service
log "Restarting RFID service..."
systemctl start smartwardrobe-rfid.service

log "ACR122U reset complete"
EOF
    chmod +x /usr/local/bin/reset-acr122u.sh

    cat > /etc/systemd/system/smartwardrobe-rfid.service << EOF
[Unit]
Description=Smart Wardrobe RFID Service
After=smartwardrobe-boot.service network.target pcscd.service
Wants=pcscd.service

[Service]
ExecStartPre=/usr/local/bin/wait-for-acr122u.sh
ExecStart=/usr/bin/node $TARGET_DIR/rfid_service.js
WorkingDirectory=$TARGET_DIR
StandardOutput=append:$LOG_DIR/rfid.log
StandardError=append:$LOG_DIR/rfid.log
User=root
Group=root
Restart=always
RestartSec=15
StartLimitBurst=5
StartLimitIntervalSec=300

# If service fails 3 times, try resetting the device
ExecStartPost=/bin/bash -c 'if [ $(systemctl show smartwardrobe-rfid.service -p NRestarts --value) -gt 3 ]; then /usr/local/bin/reset-acr122u.sh; fi'

[Install]
WantedBy=multi-user.target
EOF

    log "RFID service configured with enhanced reset capabilities"
    ENABLE_RFID=true
else
    log "RFID service not configured - rfid_service.js not found"
    ENABLE_RFID=false
fi

# =======================================
# Configure udev rules for ACR122U
# =======================================

log "Setting up udev rules..."
cat > /etc/udev/rules.d/99-acr122u.rules << 'EOF'
# ACR122U NFC Reader
SUBSYSTEM=="usb", ATTRS{idVendor}=="072f", ATTRS{idProduct}=="2200", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTRS{idVendor}=="072f", ATTRS{idProduct}=="90cc", MODE="0666", GROUP="plugdev"
EOF

udevadm control --reload-rules
udevadm trigger

# Add root to plugdev group
usermod -a -G plugdev root 2>/dev/null || true

# =======================================
# Enable and start services
# =======================================

log "Reloading systemd and enabling services..."
systemctl daemon-reload

# Enable core services
systemctl enable hostapd.service || warn "Failed to enable hostapd"
systemctl enable dnsmasq.service || warn "Failed to enable dnsmasq"
systemctl enable pcscd.service || warn "Failed to enable pcscd"
systemctl enable netfilter-persistent || warn "Failed to enable netfilter-persistent"

# Enable our custom services
systemctl enable smartwardrobe-boot.service || error "Failed to enable boot service"
systemctl enable smartwardrobe-server.service || error "Failed to enable server service"

if [ "$ENABLE_RFID" = true ]; then
    systemctl enable smartwardrobe-rfid.service || warn "Failed to enable RFID service"
fi

log "Starting core system services..."
systemctl start pcscd.service || warn "Failed to start pcscd"
systemctl start netfilter-persistent || warn "Failed to start netfilter-persistent"

# =======================================
# Create test scripts for debugging
# =======================================

log "Creating debug scripts..."
cat > /usr/local/bin/smartwardrobe-debug.sh << 'EOF'
#!/bin/bash
echo "=== Smart Wardrobe Debug Information ==="
echo
echo "=== Service Status ==="
systemctl status smartwardrobe-boot.service --no-pager -l
echo
systemctl status smartwardrobe-server.service --no-pager -l
echo
systemctl status smartwardrobe-rfid.service --no-pager -l 2>/dev/null || echo "RFID service not available"
echo
echo "=== Network Status ==="
echo "WiFi Interface: $(ip link show | grep wl | head -1 | cut -d: -f2 | tr -d ' ')"
echo "IP Addresses:"
ip addr show | grep inet
echo
echo "=== Processes ==="
ps aux | grep -E "(node|hostapd|dnsmasq)" | grep -v grep
echo
echo "=== Recent Logs ==="
echo "--- Boot Service ---"
journalctl -u smartwardrobe-boot.service --no-pager -n 10
echo
echo "--- Server Service ---"
journalctl -u smartwardrobe-server.service --no-pager -n 10
echo
echo "--- RFID Service ---"
journalctl -u smartwardrobe-rfid.service --no-pager -n 10 2>/dev/null || echo "No RFID logs"
EOF

chmod +x /usr/local/bin/smartwardrobe-debug.sh

# =======================================
# Final verification and startup
# =======================================

log "Starting Smart Wardrobe services..."
systemctl start smartwardrobe-boot.service || {
    error "Boot service failed to start"
    journalctl -u smartwardrobe-boot.service --no-pager -n 20
}

sleep 10

systemctl start smartwardrobe-server.service || {
    error "Server service failed to start"
    journalctl -u smartwardrobe-server.service --no-pager -n 20
}

if [ "$ENABLE_RFID" = true ]; then
    systemctl start smartwardrobe-rfid.service || {
        warn "RFID service failed to start"
        journalctl -u smartwardrobe-rfid.service --no-pager -n 20
    }
fi

# Wait for services to initialize
sleep 15

# =======================================
# Final status check
# =======================================

log "Checking final service status..."

BOOT_STATUS=$(systemctl is-active smartwardrobe-boot.service || echo "failed")
SERVER_STATUS=$(systemctl is-active smartwardrobe-server.service || echo "failed")
RFID_STATUS=$(systemctl is-active smartwardrobe-rfid.service 2>/dev/null || echo "disabled")

echo
echo -e "${GREEN}=============================================="
echo "   Installation Complete!"
echo "=============================================="
echo -e "${NC}"
echo
echo "Service Status:"
echo "  Boot Service: $BOOT_STATUS"
echo "  Web Server: $SERVER_STATUS"
echo "  RFID Service: $RFID_STATUS"
echo
echo "Your Smart Wardrobe device should now be running:"
echo "  • SSID: SmartWardrobe-Setup"
echo "  • Password: smartwardrobe123"
echo "  • Setup URL: http://192.168.4.1"
echo
echo "To configure:"
echo "1. Connect your device to 'SmartWardrobe-Setup' WiFi"
echo "2. Open browser and go to http://192.168.4.1"
echo "3. Enter your home WiFi credentials and API key"
echo
echo "Debug commands:"
echo "  • Status check: sudo /usr/local/bin/smartwardrobe-debug.sh"
echo "  • View logs: sudo journalctl -u smartwardrobe-server.service -f"
echo "  • Restart services: sudo systemctl restart smartwardrobe-boot.service"
echo
echo "Log files: /var/log/smartwardrobe/"
echo "Config: /etc/smartwardrobe/config.json"
echo

# Show any service failures
if [ "$BOOT_STATUS" = "failed" ]; then
    error "Boot service failed - check logs with: journalctl -u smartwardrobe-boot.service"
fi

if [ "$SERVER_STATUS" = "failed" ]; then
    error "Server service failed - check logs with: journalctl -u smartwardrobe-server.service"
fi

if [ "$RFID_STATUS" = "failed" ]; then
    warn "RFID service failed - check logs with: journalctl -u smartwardrobe-rfid.service"
fi

log "Installation script completed. Services should be running."
log "If services are still failing, run: sudo /usr/local/bin/smartwardrobe-debug.sh"

echo
echo "System will reboot in 15 seconds to ensure clean startup..."
sleep 15
reboot

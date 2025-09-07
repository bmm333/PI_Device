#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/opt/smartwardrobe"
LOG_DIR="/var/log/smartwardrobe"
CONFIG_DIR="/etc/smartwardrobe"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

echo -e "${BLUE}"
echo "=============================================="
echo "   Smart Wardrobe Device Setup - ONE COMMAND"
echo "=============================================="
echo -e "${NC}"

if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root: sudo ./install.sh"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/server.js" ]; then
    error "server.js not found in $SCRIPT_DIR"
    echo "Please ensure server.js is in the same directory as this install script"
    exit 1
fi

if [ -f "$SCRIPT_DIR/rfid_service.js" ]; then
    log "rfid_service.js found - RFID support ENABLED"
    RFID_SERVICE_PRESENT=true
else
    warn "rfid_service.js not found - RFID support will be disabled"
    RFID_SERVICE_PRESENT=false
fi

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

WIFI_IFACE=""
for iface in wlan0 wlp* wl*; do
    if ip link show "$iface" >/dev/null 2>&1; then
        WIFI_IFACE="$iface"
        break
    fi
done

if [ -z "$WIFI_IFACE" ]; then
    WIFI_IFACE=$(iw dev | awk '$1=="Interface"{print $2}' | head -1)
fi

if [ -z "$WIFI_IFACE" ]; then
    error "No WiFi interface detected. WiFi must be available."
    echo "Available interfaces:"
    ip link show
    exit 1
fi
log "WiFi interface detected: $WIFI_IFACE"

log "Stopping all Smart Wardrobe services..."
systemctl stop smartwardrobe-boot.service smartwardrobe-server.service smartwardrobe-rfid.service smartwardrobe-watchdog.service 2>/dev/null || true
systemctl disable smartwardrobe-boot.service smartwardrobe-server.service smartwardrobe-rfid.service smartwardrobe-watchdog.service 2>/dev/null || true
pkill -f "node.*server.js" || true
pkill -f "node.*rfid_service.js" || true

log "Updating package lists..."
apt update || { error "apt update failed"; exit 1; }

log "Installing system packages..."
PACKAGES="hostapd dnsmasq iptables-persistent netfilter-persistent jq nodejs npm python3-pip libusb-1.0-0-dev libnfc-dev pcscd pcsc-tools libccid python3-setuptools python3-dev build-essential curl openssh-server"

for package in $PACKAGES; do
    log "Installing $package..."
    if ! apt install -y "$package"; then
        warn "Failed to install $package - continuing"
    fi
done

log "Enabling SSH service..."
systemctl enable ssh
systemctl start ssh

log "Installing Python RFID libraries..."
PYSCARD_INSTALLED=false

if pip3 install --break-system-packages pyscard 2>/dev/null; then
    log "pyscard installed with --break-system-packages"
    PYSCARD_INSTALLED=true
elif pip3 install pyscard 2>/dev/null; then
    log "pyscard installed with pip3"
    PYSCARD_INSTALLED=true
elif apt install -y python3-pyscard 2>/dev/null; then
    log "pyscard installed from system packages"
    PYSCARD_INSTALLED=true
elif python3 -m pip install pyscard 2>/dev/null; then
    log "pyscard installed with python3 -m pip"
    PYSCARD_INSTALLED=true
elif pip install pyscard 2>/dev/null; then
    log "pyscard installed with pip"
    PYSCARD_INSTALLED=true
else
    warn "All pyscard installation methods failed - installing build dependencies first"
    
    apt install -y python3-dev python3-pip python3-setuptools build-essential libpcsclite-dev swig
    
    if pip3 install --break-system-packages pyscard 2>/dev/null; then
        log "pyscard installed after installing build dependencies"
        PYSCARD_INSTALLED=true
    else
        error "pyscard installation completely failed - RFID will not work"
        RFID_SERVICE_PRESENT=false
    fi
fi

if [ "$PYSCARD_INSTALLED" = true ]; then
    if python3 -c "import smartcard; print('pyscard working')" 2>/dev/null; then
        log "pyscard verification successful"
    else
        warn "pyscard installed but verification failed"
        RFID_SERVICE_PRESENT=false
    fi
fi

log "Configuring services..."
SERVICES_TO_UNMASK="hostapd.service dnsmasq.service NetworkManager.service wpa_supplicant.service dhcpcd.service pcscd.service ssh.service"
for service in $SERVICES_TO_UNMASK; do
    systemctl unmask "$service" 2>/dev/null || true
done

systemctl stop wpa_supplicant dhcpcd NetworkManager hostapd dnsmasq 2>/dev/null || true
systemctl disable wpa_supplicant dhcpcd 2>/dev/null || true

pkill -f wpa_supplicant || true
pkill -f dhclient || true
pkill -f hostapd || true
pkill -f dnsmasq || true

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

cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup 2>/dev/null || true
cat > /etc/dnsmasq.conf << EOF
interface=$WIFI_IFACE
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
address=/#/192.168.4.1
EOF

log "Configuring network forwarding..."
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-smartwardrobe.conf
sysctl -p /etc/sysctl.d/99-smartwardrobe.conf

iptables -F
iptables -t nat -F
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i "$WIFI_IFACE" -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i eth0 -o "$WIFI_IFACE" -j ACCEPT

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
systemctl enable netfilter-persistent

log "Setting up application files..."
mkdir -p "$TARGET_DIR" "$CONFIG_DIR" "$LOG_DIR"
chmod 755 "$TARGET_DIR" "$CONFIG_DIR" "$LOG_DIR"

cp "$SCRIPT_DIR/server.js" "$TARGET_DIR/"
log "Copied server.js from $SCRIPT_DIR"

if [ "$RFID_SERVICE_PRESENT" = true ]; then
    cp "$SCRIPT_DIR/rfid_service.js" "$TARGET_DIR/"
    log "Copied rfid_service.js"
fi

chmod +x "$TARGET_DIR"/*.js 2>/dev/null || true
chown -R root:root "$TARGET_DIR"

log "Creating system management scripts..."

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

systemctl stop NetworkManager.service 2>/dev/null || true
sleep 2

pkill -f wpa_supplicant || true
pkill -f dhclient || true
pkill -f hostapd || true
pkill -f dnsmasq || true
sleep 2

ip link set "\$WIFI_IFACE" down 2>/dev/null || true
sleep 1
ip addr flush dev "\$WIFI_IFACE" 2>/dev/null || true
ip link set "\$WIFI_IFACE" up 2>/dev/null || true
sleep 2

if ! ip addr add 192.168.4.1/24 dev "\$WIFI_IFACE" 2>/dev/null; then
    log "Failed to set IP address, trying to flush and retry..."
    ip addr flush dev "\$WIFI_IFACE" 2>/dev/null || true
    sleep 1
    ip addr add 192.168.4.1/24 dev "\$WIFI_IFACE" || {
        log "ERROR: Failed to configure interface IP"
        exit 1
    }
fi

log "Starting hostapd..."
if ! systemctl start hostapd.service; then
    log "hostapd failed to start, checking configuration..."
    systemctl status hostapd.service || true
    exit 1
fi
sleep 3

log "Starting dnsmasq..."
if ! systemctl start dnsmasq.service; then
    log "dnsmasq failed to start, checking configuration..."
    systemctl status dnsmasq.service || true
    exit 1
fi
sleep 2

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

if [ ! -f "\$CONFIG_FILE" ]; then
    log "No configuration file found, starting AP mode"
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 0
fi

SSID=\$(jq -r '.ssid // empty' "\$CONFIG_FILE" 2>/dev/null)
PASSWORD=\$(jq -r '.password // empty' "\$CONFIG_FILE" 2>/dev/null)

if [ -z "\$SSID" ] || [ -z "\$PASSWORD" ]; then
    log "Invalid configuration, starting AP mode"
    /usr/local/bin/smartwardrobe-force-ap.sh
    exit 0
fi

log "Attempting to connect to WiFi: \$SSID"

systemctl stop hostapd.service dnsmasq.service 2>/dev/null || true
pkill -f hostapd || true
pkill -f dnsmasq || true
sleep 2

ip addr flush dev "\$WIFI_IFACE" 2>/dev/null || true
ip link set "\$WIFI_IFACE" down 2>/dev/null || true
sleep 1
ip link set "\$WIFI_IFACE" up 2>/dev/null || true
sleep 2

systemctl start NetworkManager.service
sleep 5

nmcli device set "\$WIFI_IFACE" managed yes
nmcli radio wifi on
sleep 3

CONNECTION_NAME="SmartWardrobe-WiFi"
nmcli con delete "\$CONNECTION_NAME" 2>/dev/null || true
sleep 1

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

log "WiFi connection failed, falling back to AP mode"
nmcli con delete "\$CONNECTION_NAME" 2>/dev/null || true
systemctl stop NetworkManager.service || true
sleep 2
/usr/local/bin/smartwardrobe-force-ap.sh
EOF

chmod +x /usr/local/bin/smartwardrobe-*.sh

log "Creating watchdog system..."

cat > /usr/local/bin/smartwardrobe-watchdog.sh << 'WATCHDOG_SCRIPT'
#!/bin/bash

LOG_DIR="/var/log/smartwardrobe"
LOG_FILE="$LOG_DIR/watchdog.log"
CHECK_INTERVAL=30

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG: $1" | tee -a "$LOG_FILE"
}

check_and_restart_service() {
    local service_name="$1"
    local display_name="$2"
    
    if ! systemctl is-active "$service_name" >/dev/null 2>&1; then
        log "$display_name is DOWN - attempting restart"
        
        if systemctl restart "$service_name"; then
            sleep 5
            if systemctl is-active "$service_name" >/dev/null 2>&1; then
                log "$display_name successfully restarted"
                return 0
            else
                log "$display_name restart FAILED - service still not active"
                return 1
            fi
        else
            log "$display_name restart command FAILED"
            return 1
        fi
    else
        log "$display_name is running OK"
        return 0
    fi
}

reset_acr122u() {
    log "Resetting ACR122U due to failures..."
    
    systemctl stop smartwardrobe-rfid.service
    
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
    
    log "Restarting PC/SC service..."
    systemctl restart pcscd
    sleep 5
    
    log "Restarting RFID service..."
    systemctl start smartwardrobe-rfid.service
    
    log "ACR122U reset complete"
}

check_network_connectivity() {
    local mode_file="/tmp/smartwardrobe-mode"
    local current_mode="unknown"
    
    if [ -f "$mode_file" ]; then
        current_mode=$(cat "$mode_file")
    fi
    
    case "$current_mode" in
        "ap")
            if ! systemctl is-active hostapd >/dev/null 2>&1; then
                log "AP mode: hostapd is down, restarting..."
                systemctl restart hostapd
            fi
            
            if ! systemctl is-active dnsmasq >/dev/null 2>&1; then
                log "AP mode: dnsmasq is down, restarting..."
                systemctl restart dnsmasq
            fi
            
            if ! ip addr show | grep -q "192.168.4.1"; then
                log "AP mode: Missing IP address, triggering network restart"
                /usr/local/bin/smartwardrobe-force-ap.sh &
            fi
            ;;
            
        "client")
            if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
                log "Client mode: No internet connectivity detected"
            fi
            ;;
            
        *)
            log "Unknown network mode, checking if any network is configured"
            if [ ! -f "/etc/smartwardrobe/config.json" ]; then
                log "No config found, ensuring AP mode is running"
                /usr/local/bin/smartwardrobe-force-ap.sh &
            fi
            ;;
    esac
}

check_web_server_response() {
    if ! curl -s --connect-timeout 5 http://localhost >/dev/null 2>&1; then
        log "Web server not responding to HTTP requests"
        return 1
    else
        log "Web server responding to HTTP requests OK"
        return 0
    fi
}

check_rfid_service_health() {
    if systemctl is-enabled smartwardrobe-rfid.service >/dev/null 2>&1; then
        if systemctl is-active smartwardrobe-rfid.service >/dev/null 2>&1; then
            local recent_errors=$(journalctl -u smartwardrobe-rfid.service --since "5 minutes ago" | grep -c "error\|Error\|ERROR" 2>/dev/null || echo "0")
            local recent_scans=$(journalctl -u smartwardrobe-rfid.service --since "5 minutes ago" | grep -c "Scan failed\|PC/SC error" 2>/dev/null || echo "0")
            
            if [ "$recent_scans" -gt 10 ]; then
                log "RFID service showing many scan failures ($recent_scans in 5 min) - resetting ACR122U"
                reset_acr122u &
                return 1
            fi
            
            local restart_count=$(systemctl show smartwardrobe-rfid.service -p NRestarts --value 2>/dev/null || echo "0")
            if [ "$restart_count" -gt 10 ]; then
                log "RFID service has restarted $restart_count times - triggering device reset"
                reset_acr122u &
                return 1
            fi
            
            if ! timeout 5 pcsc_scan -n 2>/dev/null | grep -q "Reader"; then
                log "ACR122U not accessible via PC/SC - triggering reset"
                reset_acr122u &
                return 1
            fi
            
        fi
        return 0
    else
        return 0
    fi
}

perform_system_health_check() {
    log "=== Starting system health check ==="
    
    check_and_restart_service "smartwardrobe-boot.service" "Boot Manager"
    sleep 2
    
    check_and_restart_service "smartwardrobe-server.service" "Web Server"
    sleep 2
    
    if systemctl is-enabled smartwardrobe-rfid.service >/dev/null 2>&1; then
        check_and_restart_service "smartwardrobe-rfid.service" "RFID Service"
        check_rfid_service_health
        sleep 2
    fi
    
    check_network_connectivity
    
    sleep 5
    check_web_server_response
    
    local mem_usage=$(free | awk 'NR==2{printf "%.1f%%", $3/$2*100}' 2>/dev/null || echo "unknown")
    local disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//' 2>/dev/null || echo "0")
    
    log "System resources: Memory: $mem_usage, Disk: $disk_usage%"
    
    if [ "$disk_usage" -gt 90 ] 2>/dev/null; then
        log "WARNING: Disk usage is high ($disk_usage%)"
    fi
    
    log "=== Health check completed ==="
}

log "Smart Wardrobe Watchdog starting up..."
log "Check interval: ${CHECK_INTERVAL} seconds"

sleep 60
log "Performing initial system health check..."
perform_system_health_check

while true; do
    sleep "$CHECK_INTERVAL"
    
    if ! systemctl is-active smartwardrobe-server.service >/dev/null 2>&1; then
        log "CRITICAL: Web server is down, immediate restart"
        check_and_restart_service "smartwardrobe-server.service" "Web Server"
    fi
    
    if [ $(($(date +%s) % 300)) -lt "$CHECK_INTERVAL" ]; then
        perform_system_health_check
    fi
done
WATCHDOG_SCRIPT

chmod +x /usr/local/bin/smartwardrobe-watchdog.sh

cat > /usr/local/bin/fix-rfid << 'FIX_RFID'
#!/bin/bash
echo "=== Fixing RFID Reader ==="
LOG_FILE="/var/log/smartwardrobe/rfid.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MANUAL: $1" | tee -a "$LOG_FILE"
}

log "Manual RFID reset initiated"

systemctl stop smartwardrobe-rfid.service

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

log "Restarting PC/SC service..."
systemctl restart pcscd
sleep 5

log "Restarting RFID service..."
systemctl start smartwardrobe-rfid.service

echo "RFID reader reset complete!"
echo "Check status with: sudo rfid-status"
FIX_RFID

cat > /usr/local/bin/rfid-status << 'RFID_STATUS'
#!/bin/bash
echo "=== RFID Service Status ==="
systemctl status smartwardrobe-rfid.service --no-pager -l
echo
echo "=== Recent RFID Logs ==="
journalctl -u smartwardrobe-rfid.service -n 20 --no-pager
echo
echo "=== USB Device Status ==="
lsusb | grep -i "072f\|advanced card" || echo "No ACR122U detected"
echo
echo "=== PC/SC Status ==="
timeout 5 pcsc_scan -n 2>/dev/null || echo "PC/SC scan failed or no readers"
echo
echo "=== Python pyscard test ==="
python3 -c "import smartcard; print('pyscard module working!')" 2>/dev/null || echo "pyscard module not working"
RFID_STATUS

cat > /usr/local/bin/rfid-logs << 'RFID_LOGS'
#!/bin/bash
echo "=== Live RFID Logs ==="
echo "Press Ctrl+C to exit"
journalctl -u smartwardrobe-rfid.service -f
RFID_LOGS

chmod +x /usr/local/bin/fix-rfid
chmod +x /usr/local/bin/rfid-status
chmod +x /usr/local/bin/rfid-logs

log "Creating systemd services..."

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

cat > /etc/systemd/system/smartwardrobe-server.service << EOF
[Unit]
Description=Smart Wardrobe Web Server
After=smartwardrobe-boot.service network.target
Wants=smartwardrobe-boot.service network.target
RequiredBy=multi-user.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 20
ExecStart=/usr/bin/node $TARGET_DIR/server.js
WorkingDirectory=$TARGET_DIR
StandardOutput=append:$LOG_DIR/server.log
StandardError=append:$LOG_DIR/server.log
User=root
Group=root
Restart=always
RestartSec=5
StartLimitBurst=0
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
RequiredBy=multi-user.target
EOF

if [ "$RFID_SERVICE_PRESENT" = true ]; then
    cat > /usr/local/bin/wait-for-acr122u.sh << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/smartwardrobe/rfid.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Waiting for ACR122U device to be ready..."

if ! systemctl is-active pcscd >/dev/null 2>&1; then
    log "Starting PC/SC service..."
    systemctl start pcscd || true
    sleep 3
fi

for i in {1..60}; do
    if lsusb | grep -qi "072f:2200\|Advanced Card Systems"; then
        log "ACR122U USB device detected (attempt $i/60)"
        sleep 2
        
        if timeout 10 pcsc_scan -n 2>/dev/null | grep -q "Reader"; then
            log "ACR122U is ready and accessible"
            exit 0
        else
            log "ACR122U detected but not accessible via PC/SC"
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
StartLimitBurst=0

[Install]
WantedBy=multi-user.target
EOF

    log "RFID service configured with enhanced reset capabilities"
    ENABLE_RFID=true
else
    log "RFID service not configured - rfid_service.js not found"
    ENABLE_RFID=false
fi

cat > /etc/systemd/system/smartwardrobe-watchdog.service << EOF
[Unit]
Description=Smart Wardrobe Watchdog Service
After=multi-user.target network.target smartwardrobe-boot.service smartwardrobe-server.service
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/smartwardrobe-watchdog.sh
StandardOutput=append:$LOG_DIR/watchdog.log
StandardError=append:$LOG_DIR/watchdog.log
User=root
Group=root
Restart=always
RestartSec=10
StartLimitBurst=0

[Install]
WantedBy=multi-user.target
EOF

log "Setting up udev rules..."
cat > /etc/udev/rules.d/99-acr122u.rules << 'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="072f", ATTRS{idProduct}=="2200", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTRS{idVendor}=="072f", ATTRS{idProduct}=="90cc", MODE="0666", GROUP="plugdev"
EOF

udevadm control --reload-rules
udevadm trigger

usermod -a -G plugdev root 2>/dev/null || true

log "Reloading systemd and enabling services..."
systemctl daemon-reload

systemctl enable hostapd.service || warn "Failed to enable hostapd"
systemctl enable dnsmasq.service || warn "Failed to enable dnsmasq"
systemctl enable pcscd.service || warn "Failed to enable pcscd"
systemctl enable netfilter-persistent || warn "Failed to enable netfilter-persistent"
systemctl enable ssh.service || warn "Failed to enable ssh"

systemctl enable smartwardrobe-boot.service || error "Failed to enable boot service"
systemctl enable smartwardrobe-server.service || error "Failed to enable server service"
systemctl enable smartwardrobe-watchdog.service || error "Failed to enable watchdog service"

if [ "$ENABLE_RFID" = true ]; then
    systemctl enable smartwardrobe-rfid.service || warn "Failed to enable RFID service"
fi

log "Starting core system services..."
systemctl start pcscd.service || warn "Failed to start pcscd"
systemctl start netfilter-persistent || warn "Failed to start netfilter-persistent"
systemctl start ssh.service || warn "Failed to start ssh"

log "Creating debug and utility scripts..."

cat > /usr/local/bin/smartwardrobe-debug.sh << 'EOF'
#!/bin/bash
echo "=== Smart Wardrobe Debug Information ==="
echo
echo "=== Service Status ==="
echo "Boot Service:"
systemctl status smartwardrobe-boot.service --no-pager -l
echo
echo "Web Server:"
systemctl status smartwardrobe-server.service --no-pager -l
echo
echo "RFID Service:"
systemctl status smartwardrobe-rfid.service --no-pager -l 2>/dev/null || echo "RFID service not available"
echo
echo "Watchdog Service:"
systemctl status smartwardrobe-watchdog.service --no-pager -l
echo
echo "=== Network Status ==="
echo "WiFi Interface: $(ip link show | grep wl | head -1 | cut -d: -f2 | tr -d ' ' 2>/dev/null || echo 'none')"
echo "Current Mode: $(cat /tmp/smartwardrobe-mode 2>/dev/null || echo 'unknown')"
echo "IP Addresses:"
ip addr show | grep inet | grep -v 127.0.0.1
echo
echo "=== Active Processes ==="
ps aux | grep -E "(node|hostapd|dnsmasq)" | grep -v grep
echo
echo "=== USB Devices ==="
lsusb | grep -i "072f\|advanced card" || echo "No ACR122U detected"
echo
echo "=== Recent Logs (last 10 lines each) ==="
echo "--- Boot Service ---"
journalctl -u smartwardrobe-boot.service --no-pager -n 10
echo
echo "--- Server Service ---"
journalctl -u smartwardrobe-server.service --no-pager -n 10
echo
echo "--- RFID Service ---"
journalctl -u smartwardrobe-rfid.service --no-pager -n 10 2>/dev/null || echo "No RFID logs"
echo
echo "--- Watchdog Service ---"
journalctl -u smartwardrobe-watchdog.service --no-pager -n 10
EOF

cat > /usr/local/bin/smartwardrobe-restart-all << 'RESTART_ALL'
#!/bin/bash
echo "=== Restarting All Smart Wardrobe Services ==="
systemctl restart smartwardrobe-boot.service
sleep 5
systemctl restart smartwardrobe-server.service
systemctl restart smartwardrobe-rfid.service 2>/dev/null || true
systemctl restart smartwardrobe-watchdog.service
echo "All services restarted!"
echo "Check status with: sudo smartwardrobe-debug"
RESTART_ALL

chmod +x /usr/local/bin/smartwardrobe-debug.sh
chmod +x /usr/local/bin/smartwardrobe-restart-all

log "Force starting Smart Wardrobe services..."

systemctl start smartwardrobe-boot.service || {
    error "Boot service failed to start"
    journalctl -u smartwardrobe-boot.service --no-pager -n 20
}

sleep 20

systemctl start smartwardrobe-server.service || {
    error "Server service failed to start"
    journalctl -u smartwardrobe-server.service --no-pager -n 20
}

sleep 5

if [ "$ENABLE_RFID" = true ]; then
    systemctl start smartwardrobe-rfid.service || {
        warn "RFID service failed to start"
        journalctl -u smartwardrobe-rfid.service --no-pager -n 10
    }
fi

sleep 5

systemctl start smartwardrobe-watchdog.service || {
    error "Watchdog service failed to start"
    journalctl -u smartwardrobe-watchdog.service --no-pager -n 10
}

sleep 10

log "Verifying service startup..."

BOOT_STATUS=$(systemctl is-active smartwardrobe-boot.service || echo "failed")
SERVER_STATUS=$(systemctl is-active smartwardrobe-server.service || echo "failed")
RFID_STATUS=$(systemctl is-active smartwardrobe-rfid.service 2>/dev/null || echo "disabled")
WATCHDOG_STATUS=$(systemctl is-active smartwardrobe-watchdog.service || echo "failed")

echo
echo -e "${GREEN}=============================================="
echo "   SMART WARDROBE INSTALLATION COMPLETE!"
echo "=============================================="
echo -e "${NC}"
echo
echo "Service Status:"
echo "  Boot Manager: $BOOT_STATUS"
echo "  Web Server: $SERVER_STATUS"
echo "  RFID Service: $RFID_STATUS"
echo "  Watchdog: $WATCHDOG_STATUS"
echo
echo "WiFi Access Point:"
echo "  SSID: SmartWardrobe-Setup"
echo "  Password: smartwardrobe123"
echo "  Setup URL: http://192.168.4.1"
echo
echo "Setup Instructions:"
echo "1. Connect your phone/laptop to 'SmartWardrobe-Setup' WiFi"
echo "2. Open browser and go to http://192.168.4.1"
echo "3. Enter your home WiFi credentials and API key"
echo "4. Device will automatically switch to your WiFi"
echo
echo "Manual Commands:"
echo "  Debug info: sudo smartwardrobe-debug"
echo "  Restart all: sudo smartwardrobe-restart-all"
echo "  Fix RFID: sudo fix-rfid"
echo "  RFID status: sudo rfid-status"
echo "  View logs: sudo journalctl -u smartwardrobe-server.service -f"
echo
echo "Files:"
echo "  Logs: /var/log/smartwardrobe/"
echo "  Config: /etc/smartwardrobe/config.json"
echo "  App: /opt/smartwardrobe/"
echo

CRITICAL_FAILURES=false

if [ "$BOOT_STATUS" = "failed" ]; then
    error "CRITICAL: Boot service failed!"
    echo "  Fix with: sudo systemctl restart smartwardrobe-boot.service"
    CRITICAL_FAILURES=true
fi

if [ "$SERVER_STATUS" = "failed" ]; then
    error "CRITICAL: Web server failed!"
    echo "  Fix with: sudo systemctl restart smartwardrobe-server.service"
    CRITICAL_FAILURES=true
fi

if [ "$WATCHDOG_STATUS" = "failed" ]; then
    error "CRITICAL: Watchdog failed!"
    echo "  Fix with: sudo systemctl restart smartwardrobe-watchdog.service"
    CRITICAL_FAILURES=true
fi

if [ "$RFID_STATUS" = "failed" ]; then
    warn "RFID service failed - not critical for web setup"
    echo "  Fix with: sudo fix-rfid"
fi

if [ "$CRITICAL_FAILURES" = true ]; then
    error "Some critical services failed - run 'sudo smartwardrobe-debug' for details"
    echo
    echo "Common fixes:"
    echo "  sudo smartwardrobe-restart-all"
    echo "  sudo shutdown -r now"
    exit 1
fi

log "Installation completed successfully!"
log "Watchdog is now monitoring all services automatically"
log "System ready for headless operation"

echo
echo -e "${GREEN}SUCCESS: All systems operational!${NC}"
echo
echo "What happens next:"
echo "  Watchdog monitors everything every 30 seconds"
echo "  Auto-restarts any failed services"
echo "  Auto-resets RFID reader if it stops working"
echo "  Maintains AP mode or WiFi connection automatically"
echo
echo "For headless operation, this device is now fully autonomous!"
echo
echo "System will reboot in 10 seconds for clean startup..."
echo "After reboot, connect to 'SmartWardrobe-Setup' WiFi to configure"
echo "SSH is enabled - you can connect via ssh pi@192.168.4.1 (in AP mode)"

for i in {10..1}; do
    echo -n "$i..."
    sleep 1
done
echo
echo "Rebooting now..."
sync
shutdown -r now

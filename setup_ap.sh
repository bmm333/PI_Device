#!/bin/bash
set -e

echo "---Setting up Smart Wardrobe Access Point..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Please run as root (sudo)"
    exit 1
fi

# Install required packages
echo "---Installing required packages..."
apt update
apt install -y hostapd dnsmasq iptables-persistent netfilter-persistent jq

# Stop services before configuration
echo "---Stopping services..."
systemctl stop hostapd dnsmasq || true

# Configure hostapd WiFi AP
echo "---Configuring WiFi Access Point..."
cat > /etc/hostapd/hostapd.conf << 'EOF'
interface=wlan0
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

# Point hostapd to config (replace if already exists)
sed -i '/^DAEMON_CONF/d' /etc/default/hostapd
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd

# Configure dnsmasq DHCP server
echo "---Configuring DHCP server..."
# Backup original config
[ -f /etc/dnsmasq.conf ] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig

cat > /etc/dnsmasq.conf << 'EOF'
interface=wlan0
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h

# Captive portal - redirect all HTTP requests to our setup server
address=/#/192.168.4.1
EOF

# Configure network interfaces
echo "---Configuring network interfaces..."
cat >> /etc/dhcpcd.conf << 'EOF'

# Static IP for AP mode
interface wlan0
static ip_address=192.168.4.1/24
nohook wpa_supplicant
EOF

# Enable IP forwarding
echo "---Enabling IP forwarding..."
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# Configure iptables for NAT internet sharing
echo "---Configuring firewall rules..."
iptables -F
iptables -t nat -F

iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

# Save iptables rules permanently
netfilter-persistent save
systemctl enable netfilter-persistent

# Create systemd service for setup server
echo "---Creating setup server service..."
cat > /etc/systemd/system/smartwardrobe-setup.service << 'EOF'
[Unit]
Description=Smart Wardrobe AP Setup Server
After=network.target
Wants=hostapd.service dnsmasq.service

[Service]
Type=simple
User=root
WorkingDirectory=/home/m3b/smartwardrobe/setup-server
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# Create setup server directory
echo "---Creating setup server directory..."
mkdir -p /home/m3b/smartwardrobe/setup-server
chown -R m3b:m3b /home/m3b/smartwardrobe

# package.json for the setup server
cat > /home/m3b/smartwardrobe/setup-server/package.json << 'EOF'
{
  "name": "smartwardrobe-setup",
  "version": "1.0.0",
  "description": "Smart Wardrobe AP Setup Server",
  "main": "server.js",
  "dependencies": {
    "express": "^4.18.0"
  },
  "scripts": {
    "start": "node server.js"
  }
}
EOF

# Install Node.js dependencies
echo "---Installing Node.js dependencies..."
cd /home/m3b/smartwardrobe/setup-server
npm install

echo ">>> Save the AP setup server as server.js in /home/m3b/smartwardrobe/setup-server/"

# Create start/stop scripts
cat > /home/m3b/start_setup_mode.sh << 'EOF'
#!/bin/bash
echo "---Starting Smart Wardrobe Setup Mode..."
sudo nmcli device disconnect wlan0 2>/dev/null || true

# Remove existing WiFi connections that might interfere
for con in $(nmcli -t -f NAME,TYPE con show 2>/dev/null | grep wifi | cut -d: -f1); do
    echo "Removing old WiFi connection: $con"
    sudo nmcli con delete "$con" 2>/dev/null || true
done

sudo systemctl start hostapd dnsmasq smartwardrobe-setup

echo "** Setup mode started!"
echo "*** Connect to WiFi: SmartWardrobe-Setup"
echo "**** Password: smartwardrobe123" 
echo "***** Open browser to: http://192.168.4.1"
echo ""
echo "****** To stop setup mode: sudo bash /home/m3b/stop_setup_mode.sh"
EOF

cat > /home/m3b/stop_setup_mode.sh << 'EOF'
#!/bin/bash
echo "** Stopping Smart Wardrobe Setup Mode..."
sudo systemctl stop smartwardrobe-setup hostapd dnsmasq
sudo systemctl restart dhcpcd

echo "*** Setup mode stopped. Device will try to reconnect to configured WiFi."
EOF

chmod +x /home/m3b/start_setup_mode.sh /home/m3b/stop_setup_mode.sh

# Improved auto setup check with WiFi retry logic
cat > /home/m3b/auto_setup_check.sh << 'EOF'
#!/bin/bash

CONFIG_FILE="/etc/smartwardrobe/config.json"
SETUP_MODE_FLAG="/tmp/smartwardrobe_setup_mode"
RETRY_COUNT_FILE="/tmp/smartwardrobe_wifi_retry"
CONNECTION_LOG="/var/log/smartwardrobe.log"
MAX_RETRIES=3

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$CONNECTION_LOG"
}

# Check if we have working internet connection
check_internet() {
    if ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 10 1.1.1.1 >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Try to connect to configured WiFi
try_wifi_connection() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    # Extract credentials
    local ssid=$(jq -r '.ssid // empty' "$config_file" 2>/dev/null)
    local password=$(jq -r '.password // empty' "$config_file" 2>/dev/null)
    
    if [ -z "$ssid" ] || [ -z "$password" ]; then
        log "Invalid config: missing SSID or password"
        return 1
    fi
    
    log "Attempting to connect to: $ssid"
    
    # Try to connect
    if nmcli dev wifi connect "$ssid" password "$password" 2>/dev/null; then
        # Wait up to 30 seconds for connection
        local waited=0
        while [ $waited -lt 30 ]; do
            if nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null | grep -q "100 (connected)"; then
                # Connected, check internet
                sleep 5
                if check_internet; then
                    log "Successfully connected to $ssid with internet access"
                    return 0
                else
                    log "Connected to $ssid but no internet access"
                    return 1
                fi
            fi
            sleep 2
            waited=$((waited + 2))
        done
    fi
    
    log "Failed to connect to: $ssid"
    return 1
}

# Get current retry count
get_retry_count() {
    if [ -f "$RETRY_COUNT_FILE" ]; then
        cat "$RETRY_COUNT_FILE"
    else
        echo "0"
    fi
}

# Increment retry count
increment_retry_count() {
    local count=$(get_retry_count)
    count=$((count + 1))
    echo "$count" > "$RETRY_COUNT_FILE"
}

# Reset retry count
reset_retry_count() {
    rm -f "$RETRY_COUNT_FILE"
}

# Main logic
log "Smart Wardrobe startup check..."

# Force setup mode
if [ -f "$SETUP_MODE_FLAG" ]; then
    log "Setup mode flag detected - starting AP mode"
    /home/m3b/start_setup_mode.sh
    exit 0
fi

# No configuration file
if [ ! -f "$CONFIG_FILE" ]; then
    log "No configuration found - starting AP mode"
    /home/m3b/start_setup_mode.sh
    exit 0
fi

# Configuration exists - try to connect
if try_wifi_connection "$CONFIG_FILE"; then
    log "WiFi connection successful"
    reset_retry_count
    # Make sure setup mode is stopped
    /home/m3b/stop_setup_mode.sh 2>/dev/null || true
    exit 0
fi

# Connection failed - check retry count
retry_count=$(get_retry_count)
log "WiFi connection failed (attempt $((retry_count + 1))/$MAX_RETRIES)"

if [ "$retry_count" -ge "$((MAX_RETRIES - 1))" ]; then
    log "Max retries reached - entering setup mode"
    reset_retry_count
    /home/m3b/start_setup_mode.sh
    exit 0
fi

# Increment retry and schedule another attempt
increment_retry_count
log "Will retry WiFi connection in 30 seconds..."

# Schedule retry (run in background)
(
    sleep 30
    /home/m3b/auto_setup_check.sh
) &

exit 1
EOF

chmod +x /home/m3b/auto_setup_check.sh

# Create systemd service for auto setup check
echo "---Creating systemd auto-setup service..."
cat > /etc/systemd/system/smartwardrobe-autosetup.service << 'EOF'
[Unit]
Description=Smart Wardrobe Auto Setup Check
After=network.target dhcpcd.service
Wants=network.target

[Service]
Type=forking
ExecStart=/home/m3b/auto_setup_check.sh
Restart=no
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Create a watchdog service for ongoing monitoring
cat > /etc/systemd/system/smartwardrobe-watchdog.service << 'EOF'
[Unit]
Description=Smart Wardrobe Connection Watchdog
After=smartwardrobe-autosetup.service

[Service]
Type=simple
ExecStart=/home/m3b/wifi_watchdog.sh
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

# Create watchdog script
cat > /home/m3b/wifi_watchdog.sh << 'EOF'
#!/bin/bash

CONNECTION_LOG="/var/log/smartwardrobe.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCHDOG: $1" | tee -a "$CONNECTION_LOG"
}

check_internet() {
    ping -c 1 -W 10 8.8.8.8 >/dev/null 2>&1
}

is_setup_mode_active() {
    systemctl is-active --quiet hostapd
}

while true; do
    sleep 300  # Check every 5 minutes
    
    if is_setup_mode_active; then
        # Setup mode is active, don't interfere
        continue
    fi
    
    # Check if WiFi is connected and has internet
    if nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null | grep -q "100 (connected)"; then
        if ! check_internet; then
            log "WiFi connected but no internet - triggering reconnect"
            /home/m3b/auto_setup_check.sh &
        fi
    else
        log "WiFi not connected - triggering reconnect"
        /home/m3b/auto_setup_check.sh &
    fi
done
EOF

chmod +x /home/m3b/wifi_watchdog.sh

# Enable services
echo "---Enabling services..."
systemctl enable hostapd dnsmasq smartwardrobe-setup smartwardrobe-autosetup smartwardrobe-watchdog

# Create manual control shortcuts
cat > /home/m3b/force_setup.sh << 'EOF'
#!/bin/bash
echo "🔧 Forcing setup mode..."
sudo touch /tmp/smartwardrobe_setup_mode
sudo rm -f /tmp/smartwardrobe_wifi_retry
sudo systemctl restart smartwardrobe-autosetup
echo "✅ Setup mode will start shortly"
EOF

cat > /home/m3b/clear_config.sh << 'EOF'
#!/bin/bash
echo "🗑️ Clearing WiFi configuration..."
sudo rm -f /etc/smartwardrobe/config.json
sudo rm -f /tmp/smartwardrobe_wifi_retry
sudo rm -f /tmp/smartwardrobe_setup_mode
sudo systemctl restart smartwardrobe-autosetup
echo "✅ Configuration cleared - will enter setup mode"
EOF

chmod +x /home/m3b/force_setup.sh /home/m3b/clear_config.sh

echo ""
echo "_*_*_* Smart Wardrobe Access Point setup complete!"
echo ""
echo "_*_*_*_*_* Features:"
echo "✅ Automatic setup mode if no WiFi config"
echo "✅ Retry WiFi connection 3 times before entering setup mode"  
echo "✅ Continuous monitoring of WiFi health"
echo "✅ Handles WiFi password changes, router reboots, etc."
echo ""
echo "_*_*_*_*_* Next steps:"
echo "1. Save the server.js code to /home/m3b/smartwardrobe/setup-server/server.js"
echo "2. Reboot the Pi: sudo reboot"
echo "3. Pi will automatically manage WiFi connections"
echo ""
echo "_*_*_*_*_* Manual controls:"
echo "   Force setup mode:     sudo ./force_setup.sh"
echo "   Clear WiFi config:    sudo ./clear_config.sh"
echo "   View logs:           tail -f /var/log/smartwardrobe.log"
echo ""
echo "_*_*_*_*_* How it works for users:"
echo "📱 New device → Automatic setup mode"
echo "🏠 Normal use → Connects to saved WiFi"
echo "🔄 WiFi problems → Retries 3x, then setup mode"
echo "📶 WiFi password changed → Auto-detects and enters setup mode"

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
apt install -y hostapd dnsmasq iptables-persistent netfilter-persistent

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

echo "*** Setup mode stopped. Device will reconnect to configured WiFi."
EOF

chmod +x /home/m3b/start_setup_mode.sh /home/m3b/stop_setup_mode.sh

# Script to automatically enter setup mode if no WiFi config exists
cat > /home/m3b/auto_setup_check.sh << 'EOF'
#!/bin/bash
CONFIG_FILE="/etc/smartwardrobe/config.json"
SETUP_MODE_FLAG="/tmp/smartwardrobe_setup_mode"
if [ ! -f "$CONFIG_FILE" ] || [ -f "$SETUP_MODE_FLAG" ]; then
    echo "No configuration found or setup mode requested. Starting AP mode..."
    /home/m3b/start_setup_mode.sh
else
    echo "Configuration exists. Connecting to WiFi..."
    /home/m3b/stop_setup_mode.sh 2>/dev/null || true
fi
EOF

chmod +x /home/m3b/auto_setup_check.sh

# Create systemd service for auto setup check
echo "---Creating systemd auto-setup service..."
cat > /etc/systemd/system/smartwardrobe-autosetup.service << 'EOF'
[Unit]
Description=Smart Wardrobe Auto Setup Check
After=network.target

[Service]
Type=oneshot
ExecStart=/home/m3b/auto_setup_check.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable smartwardrobe-autosetup

# Enable services
echo "---Enabling services..."
systemctl enable hostapd dnsmasq smartwardrobe-setup

echo ""
echo "_*_*_* Smart Wardrobe Access Point setup complete!"
echo ""
echo "_*_*_*_*_* Next steps:"
echo "1. Save the server.js code to /home/m3b/smartwardrobe/setup-server/server.js"
echo "2. Reboot the Pi: sudo reboot"
echo "3. Pi will automatically start in setup mode if no WiFi is configured"
echo "4. Connect to 'SmartWardrobe-Setup' WiFi (password: smartwardrobe123)"
echo "5. Open http://192.168.4.1 in your browser"
echo ""
echo "Manual control:"
echo "   Start setup mode: sudo bash /home/m3b/start_setup_mode.sh"
echo "   Stop setup mode:  sudo bash /home/m3b/stop_setup_mode.sh"
echo "   Force setup mode: sudo touch /tmp/smartwardrobe_setup_mode && sudo reboot"

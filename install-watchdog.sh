#!/bin/bash

# Smart Wardrobe Watchdog Service
# This service monitors and restarts failed services automatically

LOG_DIR="/var/log/smartwardrobe"
LOG_FILE="$LOG_DIR/watchdog.log"
CHECK_INTERVAL=30  # Check every 30 seconds

# Ensure log directory exists
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
        
        # Try to restart the service
        if systemctl restart "$service_name"; then
            # Wait a bit and check if it's actually running
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

check_network_connectivity() {
    local mode_file="/tmp/smartwardrobe-mode"
    local current_mode="unknown"
    
    if [ -f "$mode_file" ]; then
        current_mode=$(cat "$mode_file")
    fi
    
    case "$current_mode" in
        "ap")
            # In AP mode, check if hostapd and dnsmasq are running
            if ! systemctl is-active hostapd >/dev/null 2>&1; then
                log "AP mode: hostapd is down, restarting..."
                systemctl restart hostapd
            fi
            
            if ! systemctl is-active dnsmasq >/dev/null 2>&1; then
                log "AP mode: dnsmasq is down, restarting..."
                systemctl restart dnsmasq
            fi
            
            # Check if AP interface has correct IP
            if ! ip addr show | grep -q "192.168.4.1"; then
                log "AP mode: Missing IP address, triggering network restart"
                /usr/local/bin/smartwardrobe-force-ap.sh &
            fi
            ;;
            
        "client")
            # In client mode, check internet connectivity
            if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
                log "Client mode: No internet, may need to restart network"
                # Don't automatically restart network in client mode as it might be temporary
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
    # Try to connect to the web server
    if ! curl -s --connect-timeout 5 http://localhost >/dev/null 2>&1; then
        log "Web server not responding to HTTP requests"
        return 1
    else
        log "Web server responding to HTTP requests OK"
        return 0
    fi
}

check_rfid_service_health() {
    # Check if RFID service is enabled first
    if systemctl is-enabled smartwardrobe-rfid.service >/dev/null 2>&1; then
        # Check if it's running
        if systemctl is-active smartwardrobe-rfid.service >/dev/null 2>&1; then
            # Check if it's actually working by looking at recent logs
            local recent_errors=$(journalctl -u smartwardrobe-rfid.service --since "5 minutes ago" | grep -c "error\|Error\|ERROR" || echo "0")
            local recent_scans=$(journalctl -u smartwardrobe-rfid.service --since "5 minutes ago" | grep -c "Scan failed\|PC/SC error" || echo "0")
            
            if [ "$recent_scans" -gt 10 ]; then
                log "RFID service showing many scan failures ($recent_scans in 5 min) - resetting ACR122U"
                /usr/local/bin/reset-acr122u.sh &
                return 1
            fi
            
            # Check restart count
            local restart_count=$(systemctl show smartwardrobe-rfid.service -p NRestarts --value)
            if [ "$restart_count" -gt 10 ]; then
                log "RFID service has restarted $restart_count times - may need device reset"
                /usr/local/bin/reset-acr122u.sh &
                return 1
            fi
            
            # Check if ACR122U is still physically accessible
            if ! timeout 5 pcsc_scan -n 2>/dev/null | grep -q "Reader"; then
                log "ACR122U not accessible via PC/SC - triggering reset"
                /usr/local/bin/reset-acr122u.sh &
                return 1
            fi
            
        fi
        return 0
    else
        # RFID service is disabled, that's OK
        return 0
    fi
}

perform_system_health_check() {
    log "=== Starting system health check ==="
    
    # Check core Smart Wardrobe services
    check_and_restart_service "smartwardrobe-boot.service" "Boot Manager"
    sleep 2
    
    check_and_restart_service "smartwardrobe-server.service" "Web Server"
    sleep 2
    
    # Check if RFID service should be running
    if systemctl is-enabled smartwardrobe-rfid.service >/dev/null 2>&1; then
        check_and_restart_service "smartwardrobe-rfid.service" "RFID Service"
        check_rfid_service_health
        sleep 2
    fi
    
    # Check network services based on current mode
    check_network_connectivity
    
    # Check if web server is actually responding
    sleep 5  # Give services time to start
    check_web_server_response
    
    # Check system resources
    local mem_usage=$(free | awk 'NR==2{printf "%.1f%%", $3/$2*100}')
    local disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//')
    
    log "System resources: Memory: $mem_usage, Disk: $disk_usage%"
    
    if [ "$disk_usage" -gt 90 ]; then
        log "WARNING: Disk usage is high ($disk_usage%)"
    fi
    
    log "=== Health check completed ==="
}

# Startup message
log "Smart Wardrobe Watchdog starting up..."
log "Check interval: ${CHECK_INTERVAL} seconds"

# Perform initial health check after a delay to let system boot
sleep 60
log "Performing initial system health check..."
perform_system_health_check

# Main watchdog loop
while true; do
    sleep "$CHECK_INTERVAL"
    
    # Quick check every cycle
    if ! systemctl is-active smartwardrobe-server.service >/dev/null 2>&1; then
        log "CRITICAL: Web server is down, immediate restart"
        check_and_restart_service "smartwardrobe-server.service" "Web Server"
    fi
    
    # Full health check every 5 minutes
    if [ $(($(date +%s) % 300)) -lt "$CHECK_INTERVAL" ]; then
        perform_system_health_check
    fi
done

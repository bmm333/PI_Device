const express = require('express');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = 80; // Standard HTTP port for captive portal

// Device configuration
const DEVICE_SERIAL = '0001';
const DEVICE_MAC = '2c:cf:67:c6:97:2c';
const CONFIG_PATH = '/etc/smartwardrobe/config.json';
const AP_SSID = 'SmartWardrobe-Setup';

// Middleware
app.use(express.json());
app.use(express.static('public'));

// Ensure config directory exists
if (!fs.existsSync('/etc/smartwardrobe')) {
  fs.mkdirSync('/etc/smartwardrobe', { recursive: true });
}

// Log helper
const log = (level, ...args) => {
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${level}:`, ...args);
};

// Serving the setup page
app.get('/', (req, res) => {
  const setupPage = `
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Smart Wardrobe Setup</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 600px;
            margin: 0 auto;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            min-height: 100vh;
        }
        .container {
            background: rgba(255,255,255,0.1);
            border-radius: 15px;
            padding: 30px;
            backdrop-filter: blur(10px);
        }
        h1 {
            text-align: center;
            margin-bottom: 30px;
        }
        .form-group {
            margin-bottom: 20px;
        }
        label {
            display: block;
            margin-bottom: 5px;
            font-weight: bold;
        }
        input, select, button {
            width: 100%;
            padding: 12px;
            border: none;
            border-radius: 8px;
            font-size: 16px;
        }
        input, select {
            background: rgba(255,255,255,0.9);
            color: #333;
        }
        button {
            background: #4CAF50;
            color: white;
            cursor: pointer;
            margin-top: 10px;
            font-weight: bold;
        }
        button:hover {
            background: #45a049;
        }
        button:disabled {
            background: #ccc;
            cursor: not-allowed;
        }
        .status {
            margin-top: 20px;
            padding: 15px;
            border-radius: 8px;
            text-align: center;
        }
        .loading {
            background: rgba(255,193,7,0.8);
            color: #333;
        }
        .success {
            background: rgba(40,167,69,0.8);
        }
        .error {
            background: rgba(220,53,69,0.8);
        }
        .device-info {
            background: rgba(255,255,255,0.1);
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 20px;
        }
        .spinner {
            display: inline-block;
            width: 20px;
            height: 20px;
            border: 3px solid #f3f3f3;
            border-top: 3px solid #333;
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin-right: 10px;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🏠 Smart Wardrobe Setup</h1>
        
        <div class="device-info">
            <h3>📱 Device Information</h3>
            <p><strong>Serial:</strong> ${DEVICE_SERIAL}</p>
            <p><strong>MAC:</strong> ${DEVICE_MAC}</p>
        </div>

        <form id="setupForm">
            <div class="form-group">
                <label for="ssid">🌐 WiFi Network Name (SSID):</label>
                <select id="ssid" name="ssid" required>
                    <option value="">Select a network...</option>
                </select>
                <button type="button" onclick="scanWiFi()" style="margin-top: 10px; background: #007bff;">
                    🔍 Scan for Networks
                </button>
            </div>

            <div class="form-group">
                <label for="password">🔒 WiFi Password:</label>
                <input type="password" id="password" name="password" required>
            </div>

            <div class="form-group">
                <label for="apiKey">🔑 API Key (from your account):</label>
                <input type="text" id="apiKey" name="apiKey" required placeholder="Enter your Smart Wardrobe API key">
            </div>

            <div class="form-group">
                <label for="backendUrl">🌍 Backend URL:</label>
                <input type="url" id="backendUrl" name="backendUrl" value="https://your-backend.com" required>
            </div>

            <button type="submit">✅ Configure Device</button>
        </form>

        <div id="status"></div>
    </div>

    <script>
        let isConfiguring = false;

        function showStatus(message, type = 'loading') {
            const statusEl = document.getElementById('status');
            const spinner = type === 'loading' ? '<div class="spinner"></div>' : '';
            statusEl.innerHTML = \`<div class="status \${type}">\${spinner}\${message}</div>\`;
        }

        function clearStatus() {
            document.getElementById('status').innerHTML = '';
        }

        async function scanWiFi() {
            showStatus('Scanning for WiFi networks...', 'loading');
            try {
                const response = await fetch('/api/wifi/scan');
                const networks = await response.json();
                
                const ssidSelect = document.getElementById('ssid');
                ssidSelect.innerHTML = '<option value="">Select a network...</option>';
                
                networks.forEach(network => {
                    const option = document.createElement('option');
                    option.value = network.ssid;
                    option.textContent = \`\${network.ssid} (\${network.signal})\`;
                    ssidSelect.appendChild(option);
                });
                
                showStatus(\`Found \${networks.length} networks\`, 'success');
                setTimeout(clearStatus, 2000);
            } catch (error) {
                showStatus('Failed to scan networks: ' + error.message, 'error');
            }
        }

        document.getElementById('setupForm').addEventListener('submit', async (e) => {
            e.preventDefault();
            
            if (isConfiguring) return;
            isConfiguring = true;
            
            const formData = new FormData(e.target);
            const config = {
                ssid: formData.get('ssid'),
                password: formData.get('password'),
                apiKey: formData.get('apiKey'),
                backendUrl: formData.get('backendUrl')
            };

            if (!config.ssid || !config.password || !config.apiKey) {
                showStatus('Please fill in all required fields', 'error');
                isConfiguring = false;
                return;
            }

            try {
                showStatus('Configuring device...', 'loading');
                
                const response = await fetch('/api/configure', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(config)
                });

                if (!response.ok) {
                    throw new Error(\`Configuration failed: \${response.statusText}\`);
                }

                const result = await response.json();
                showStatus('Device configured successfully! Connecting to WiFi...', 'success');
                
                // Check connection status
                setTimeout(checkConnectionStatus, 3000);
                
            } catch (error) {
                showStatus('Configuration failed: ' + error.message, 'error');
                isConfiguring = false;
            }
        });

        async function checkConnectionStatus() {
            try {
                const response = await fetch('/api/status');
                const status = await response.json();
                
                if (status.connected) {
                    showStatus(\`Setup complete! Device IP: \${status.ip}. You can now close this page.\`, 'success');
                    setTimeout(() => {
                        // Try to redirect to the device's new IP
                        window.location.href = \`http://\${status.ip}\`;
                    }, 3000);
                } else {
                    showStatus('Still connecting to WiFi...', 'loading');
                    setTimeout(checkConnectionStatus, 2000);
                }
            } catch (error) {
                showStatus('Connection check failed: ' + error.message, 'error');
            }
            isConfiguring = false;
        }

        // Auto-scan networks on page load
        window.addEventListener('load', () => {
            setTimeout(scanWiFi, 1000);
        });
    </script>
</body>
</html>`;
  
  res.send(setupPage);
});

// API: Scan for WiFi networks
app.get('/api/wifi/scan', (req, res) => {
  log('INFO', '🔍 WiFi scan requested');
  
  exec('nmcli -t -f SSID,SIGNAL dev wifi | grep -v "^$" | sort -t: -k2 -nr', (err, stdout) => {
    if (err) {
      log('ERROR', '❌ WiFi scan failed:', err.message);
      return res.status(500).json({ error: 'WiFi scan failed' });
    }

    const networks = stdout.trim().split('\n').map(line => {
      const [ssid, signal] = line.split(':');
      return { ssid: ssid || 'Hidden Network', signal: signal ? signal + '%' : 'Unknown' };
    }).filter((network, index, self) => 
      // Remove duplicates
      index === self.findIndex(n => n.ssid === network.ssid)
    );

    log('INFO', `✅ Found ${networks.length} WiFi networks`);
    res.json(networks);
  });
});

// API: Configure device
app.post('/api/configure', (req, res) => {
  const { ssid, password, apiKey, backendUrl } = req.body;
  
  log('INFO', '⚙️ Configuration request received for SSID:', ssid);
  
  if (!ssid || !password || !apiKey) {
    return res.status(400).json({ error: 'Missing required fields' });
  }

  const config = {
    ssid,
    password,
    apiKey,
    backendUrl: backendUrl || 'https://your-backend.com',
    deviceSerial: DEVICE_SERIAL,
    deviceMac: DEVICE_MAC,
    configuredAt: new Date().toISOString()
  };

  try {
    // Save configuration
    fs.writeFileSync(CONFIG_PATH + '.tmp', JSON.stringify(config, null, 2));
    fs.renameSync(CONFIG_PATH + '.tmp', CONFIG_PATH);
    log('INFO', '✅ Configuration saved');

    // Connect to WiFi
    const escapedSSID = ssid.replace(/"/g, '\\"');
    const escapedPassword = password.replace(/"/g, '\\"');
    const cmd = `nmcli device wifi connect "${escapedSSID}" password "${escapedPassword}"`;
    
    exec(cmd, { timeout: 30000 }, (err, stdout, stderr) => {
      if (err) {
        log('ERROR', '❌ WiFi connection failed:', err.message);
      } else {
        log('INFO', '✅ WiFi connection successful');
        
        // Schedule AP shutdown after WiFi connection is stable
        setTimeout(() => {
          log('INFO', '🔄 Disabling setup AP...');
          exec('sudo systemctl stop hostapd dnsmasq', (stopErr) => {
            if (stopErr) {
              log('WARN', '⚠️  Failed to stop AP services:', stopErr.message);
            } else {
              log('INFO', '✅ Setup AP disabled');
            }
          });
        }, 10000); // Wait 10 seconds for WiFi to stabilize
      }
    });

    res.json({ success: true, message: 'Configuration saved and WiFi connection started' });
    
  } catch (error) {
    log('ERROR', '❌ Configuration save failed:', error.message);
    res.status(500).json({ error: 'Failed to save configuration' });
  }
});

// API: Get connection status
app.get('/api/status', (req, res) => {
  exec('hostname -I', (err, stdout) => {
    const ip = stdout ? stdout.trim().split(' ')[0] : null;
    const connected = ip && !ip.startsWith('192.168.4.'); // Not AP IP
    
    res.json({
      connected,
      ip,
      timestamp: new Date().toISOString()
    });
  });
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
  log('INFO', `🚀 Smart Wardrobe Setup Server running on port ${PORT}`);
  log('INFO', `🌐 Access setup page at: http://192.168.4.1`);
  log('INFO', `📱 Device Serial: ${DEVICE_SERIAL}`);
});

// Graceful shutdown
process.on('SIGINT', () => {
  log('INFO', '🛑 Setup server shutting down...');
  process.exit(0);
});

process.on('SIGTERM', () => {
  log('INFO', '🛑 Setup server shutting down...');
  process.exit(0);
});

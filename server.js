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
  const message = `[${timestamp}] ${level}: ${args.join(' ')}`;
  console.log(message);
  
  // Also log to file
  fs.appendFileSync('/var/log/smartwardrobe.log', message + '\n');
};

// Check if device already has configuration
const hasExistingConfig = () => {
  return fs.existsSync(CONFIG_PATH);
};

// Serving the setup page
app.get('/', (req, res) => {
  const existingConfig = hasExistingConfig();
  let configInfo = '';
  
  if (existingConfig) {
    try {
      const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
      configInfo = `
        <div class="existing-config">
          <h3>⚠️ Existing Configuration Detected</h3>
          <p><strong>Current WiFi:</strong> ${config.ssid || 'Unknown'}</p>
          <p><strong>Last Configured:</strong> ${new Date(config.configuredAt).toLocaleString()}</p>
          <p>You can update the configuration below.</p>
        </div>
      `;
    } catch (error) {
      log('WARN', 'Failed to read existing config:', error.message);
    }
  }

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
            box-sizing: border-box;
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
        .existing-config {
            background: rgba(255,193,7,0.2);
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 20px;
            border: 2px solid rgba(255,193,7,0.5);
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
        .network-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 8px;
            margin: 4px 0;
            background: rgba(255,255,255,0.1);
            border-radius: 6px;
        }
        .signal-strength {
            font-size: 12px;
            opacity: 0.8;
        }
        .test-connection {
            background: #17a2b8 !important;
        }
        .test-connection:hover {
            background: #138496 !important;
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
            <p><strong>Setup Mode:</strong> ${existingConfig ? 'Reconfiguration' : 'Initial Setup'}</p>
        </div>

        ${configInfo}

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
                <button type="button" onclick="testConnection()" class="test-connection" style="margin-top: 10px;">
                    🧪 Test Connection
                </button>
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
        let networks = [];

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
                networks = await response.json();
                
                const ssidSelect = document.getElementById('ssid');
                ssidSelect.innerHTML = '<option value="">Select a network...</option>';
                
                networks.forEach(network => {
                    const option = document.createElement('option');
                    option.value = network.ssid;
                    option.textContent = \`\${network.ssid} (\${network.signal})\`;
                    if (network.security) {
                        option.textContent += \` 🔒\`;
                    }
                    ssidSelect.appendChild(option);
                });
                
                showStatus(\`Found \${networks.length} networks\`, 'success');
                setTimeout(clearStatus, 2000);
            } catch (error) {
                showStatus('Failed to scan networks: ' + error.message, 'error');
            }
        }

        async function testConnection() {
            const ssid = document.getElementById('ssid').value;
            const password = document.getElementById('password').value;
            
            if (!ssid || !password) {
                showStatus('Please select a network and enter password first', 'error');
                return;
            }
            
            showStatus('Testing WiFi connection...', 'loading');
            
            try {
                const response = await fetch('/api/wifi/test', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ ssid, password })
                });

                const result = await response.json();
                
                if (result.success) {
                    showStatus('✅ Connection test successful!', 'success');
                    setTimeout(clearStatus, 3000);
                } else {
                    showStatus('❌ Connection test failed: ' + result.error, 'error');
                }
            } catch (error) {
                showStatus('Connection test failed: ' + error.message, 'error');
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
                setTimeout(checkConnectionStatus, 5000);
                
            } catch (error) {
                showStatus('Configuration failed: ' + error.message, 'error');
                isConfiguring = false;
            }
        });

        async function checkConnectionStatus() {
            let attempts = 0;
            const maxAttempts = 12; // 2 minutes total
            
            const checkLoop = async () => {
                try {
                    const response = await fetch('/api/status');
                    const status = await response.json();
                    
                    if (status.connected && status.ip && !status.ip.startsWith('192.168.4.')) {
                        showStatus(\`✅ Setup complete! Device IP: \${status.ip}\\n\\nSetup mode will automatically close.\\n\\nYou can now use your Smart Wardrobe!\`, 'success');
                        
                        // Close setup mode after successful connection
                        setTimeout(() => {
                            fetch('/api/close-setup', { method: 'POST' });
                        }, 5000);
                        
                    } else if (attempts < maxAttempts) {
                        attempts++;
                        showStatus(\`Connecting to WiFi... (attempt \${attempts}/\${maxAttempts})\`, 'loading');
                        setTimeout(checkLoop, 10000);
                    } else {
                        showStatus('❌ Connection timeout. Please check your WiFi credentials and try again.', 'error');
                        isConfiguring = false;
                    }
                } catch (error) {
                    attempts++;
                    if (attempts < maxAttempts) {
                        showStatus(\`Connecting to WiFi... (attempt \${attempts}/\${maxAttempts})\`, 'loading');
                        setTimeout(checkLoop, 10000);
                    } else {
                        showStatus('Connection check failed. Please verify your setup.', 'error');
                        isConfiguring = false;
                    }
                }
            };
            
            checkLoop();
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
  
  exec('nmcli -t -f SSID,SIGNAL,SECURITY dev wifi | grep -v "^$" | sort -t: -k2 -nr', (err, stdout) => {
    if (err) {
      log('ERROR', '❌ WiFi scan failed:', err.message);
      return res.status(500).json({ error: 'WiFi scan failed' });
    }

    const networks = stdout.trim().split('\n').map(line => {
      const [ssid, signal, security] = line.split(':');
      return { 
        ssid: ssid || 'Hidden Network', 
        signal: signal ? signal + '%' : 'Unknown',
        security: security && security !== '--'
      };
    }).filter((network, index, self) => 
      // Remove duplicates and filter out current AP
      network.ssid !== AP_SSID && 
      index === self.findIndex(n => n.ssid === network.ssid)
    );

    log('INFO', `✅ Found ${networks.length} WiFi networks`);
    res.json(networks);
  });
});

// API: Test WiFi connection
app.post('/api/wifi/test', (req, res) => {
  const { ssid, password } = req.body;
  
  log('INFO', '🧪 Testing WiFi connection to:', ssid);
  
  if (!ssid || !password) {
    return res.status(400).json({ error: 'Missing SSID or password' });
  }

  // Create a temporary connection to test
  const testConnectionName = 'temp-test-connection';
  const cmd = `nmcli con add type wifi con-name "${testConnectionName}" ssid "${ssid}" && nmcli con modify "${testConnectionName}" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "${password}" && nmcli con up "${testConnectionName}"`;
  
  exec(cmd, { timeout: 30000 }, (err, stdout, stderr) => {
    // Clean up test connection
    exec(`nmcli con delete "${testConnectionName}" 2>/dev/null`, () => {});
    
    if (err) {
      log('WARN', '❌ WiFi test failed for', ssid, ':', err.message);
      res.json({ success: false, error: 'Connection failed - please check password' });
    } else {
      log('INFO', '✅ WiFi test successful for:', ssid);
      res.json({ success: true });
    }
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
    configuredAt: new Date().toISOString(),
    version: '2.0'
  };

  try {
    // Save configuration atomically
    fs.writeFileSync(CONFIG_PATH + '.tmp', JSON.stringify(config, null, 2));
    fs.renameSync(CONFIG_PATH + '.tmp', CONFIG_PATH);
    log('INFO', '✅ Configuration saved');

    // Clear any retry flags
    try {
      fs.unlinkSync('/tmp/smartwardrobe_wifi_retry');
      fs.unlinkSync('/tmp/smartwardrobe_setup_mode');
    } catch (e) {
      // Files might not exist, that's ok
    }

    // Connect to WiFi in background
    const escapedSSID = ssid.replace(/"/g, '\\"');
    const escapedPassword = password.replace(/"/g, '\\"');
    
    // Remove any existing connections for this SSID first
    exec(`nmcli con show | grep "${escapedSSID}" | awk '{print $1}' | xargs -r nmcli con delete`, (delErr) => {
      // Now create new connection
      const cmd = `nmcli dev wifi connect "${escapedSSID}" password "${escapedPassword}"`;
      
      exec(cmd, { timeout: 45000 }, (err, stdout, stderr) => {
        if (err) {
          log('ERROR', '❌ WiFi connection failed:', err.message);
          log('ERROR', 'stderr:', stderr);
        } else {
          log('INFO', '✅ WiFi connection initiated successfully');
          
          // Schedule AP shutdown after connection is confirmed stable
          setTimeout(() => {
            exec('nmcli -t -f GENERAL.STATE dev show wlan0', (stateErr, stateOut) => {
              if (!stateErr && stateOut.includes('100 (connected)')) {
                log('INFO', '🔄 WiFi connection stable, scheduling AP shutdown...');
                
                setTimeout(() => {
                  log('INFO', '🛑 Shutting down setup AP...');
                  exec('systemctl stop smartwardrobe-setup hostapd dnsmasq', (stopErr) => {
                    if (stopErr) {
                      log('WARN', '⚠️  Failed to stop AP services:', stopErr.message);
                    } else {
                      log('INFO', '✅ Setup AP shutdown complete');
                    }
                  });
                }, 10000);
              }
            });
          }, 15000);
        }
      });
    });

    res.json({ success: true, message: 'Configuration saved and WiFi connection initiated' });
    
  } catch (error) {
    log('ERROR', '❌ Configuration save failed:', error.message);
    res.status(500).json({ error: 'Failed to save configuration' });
  }
});

// API: Get connection status
app.get('/api/status', (req, res) => {
  exec('hostname -I && nmcli -t -f GENERAL.STATE dev show wlan0', (err, stdout) => {
    const lines = stdout.trim().split('\n');
    const ip = lines[0] ? lines[0].trim().split(' ')[0] : null;
    const state = lines[1] || '';
    
    const connected = state.includes('100 (connected)') && ip && !ip.startsWith('192.168.4.');
    
    log('INFO', `📊 Status check - Connected: ${connected}, IP: ${ip}`);
    
    res.json({
      connected,
      ip,
      state,
      timestamp: new Date().toISOString()
    });
  });
});

// API: Close setup mode (called after successful configuration)
app.post('/api/close-setup', (req, res) => {
  log('INFO', '🚪 Setup close requested');
  
  // Give a small delay then shut down setup mode
  setTimeout(() => {
    exec('systemctl stop smartwardrobe-setup hostapd dnsmasq', (err) => {
      if (err) {
        log('WARN', '⚠️  Error stopping setup services:', err.message);
      } else {
        log('INFO', '✅ Setup services stopped successfully');
      }
    });
  }, 2000);
  
  res.json({ success: true });
});

// API: Get device info and logs (for debugging)
app.get('/api/debug', (req, res) => {
  exec('tail -50 /var/log/smartwardrobe.log', (err, stdout) => {
    const logs = err ? 'No logs available' : stdout;
    
    res.json({
      deviceSerial: DEVICE_SERIAL,
      deviceMac: DEVICE_MAC,
      hasConfig: fs.existsSync(CONFIG_PATH),
      logs: logs.split('\n'),
      timestamp: new Date().toISOString()
    });
  });
});

// Catch-all redirect for captive portal
app.get('*', (req, res) => {
  if (req.path !== '/' && !req.path.startsWith('/api/')) {
    log('INFO', '🔄 Redirecting captive portal request:', req.path);
    res.redirect('/');
  } else {
    res.status(404).send('Not found');
  }
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
  log('INFO', `🚀 Smart Wardrobe Setup Server v2.0 running on port ${PORT}`);
  log('INFO', `🌐 Access setup page at: http://192.168.4.1`);
  log('INFO', `📱 Device Serial: ${DEVICE_SERIAL}`);
  log('INFO', `🔧 Mode: ${hasExistingConfig() ? 'Reconfiguration' : 'Initial Setup'}`);
});

// Graceful shutdown
process.on('SIGINT', () => {
  log('INFO', '🛑 Setup server shutting down gracefully...');
  process.exit(0);
});

process.on('SIGTERM', () => {
  log('INFO', '🛑 Setup server shutting down gracefully...');
  process.exit(0);
});

process.on('uncaughtException', (error) => {
  log('ERROR', '❌ Uncaught exception:', error.message);
  process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  log('ERROR', '❌ Unhandled rejection at:', promise, 'reason:', reason);
});

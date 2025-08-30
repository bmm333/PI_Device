const http = require('http');
const fs = require('fs');
const { exec } = require('child_process');
const url = require('url');
const querystring = require('querystring');

const PORT = 80;
const CONFIG_PATH = '/etc/smartwardrobe/config.json';
const LOG_DIR = '/var/log/smartwardrobe';

// Ensure log directory exists
if (!fs.existsSync(LOG_DIR)) {
  fs.mkdirSync(LOG_DIR, { recursive: true });
}

function log(level, message) {
  const timestamp = new Date().toISOString();
  const logMessage = `[${timestamp}] ${level}: ${message}`;
  console.log(logMessage);
  
  try {
    fs.appendFileSync(`${LOG_DIR}/server.log`, logMessage + '\n');
  } catch (e) {
    console.error('Failed to write log:', e.message);
  }
}

function hasExistingConfig() {
  return fs.existsSync(CONFIG_PATH);
}

const setupHTML = `
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
        h1 { text-align: center; margin-bottom: 30px; }
        .form-group { margin-bottom: 20px; }
        label { display: block; margin-bottom: 5px; font-weight: bold; }
        input, button {
            width: 100%;
            padding: 12px;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            box-sizing: border-box;
        }
        input { background: rgba(255,255,255,0.9); color: #333; }
        button {
            background: #4CAF50;
            color: white;
            cursor: pointer;
            margin-top: 10px;
            font-weight: bold;
        }
        button:hover { background: #45a049; }
        .status {
            margin-top: 20px;
            padding: 15px;
            border-radius: 8px;
            text-align: center;
        }
        .success { background: rgba(40,167,69,0.8); }
        .error { background: rgba(220,53,69,0.8); }
        .device-info {
            background: rgba(255,255,255,0.1);
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 20px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Smart Wardrobe Setup</h1>
        
        <div class="device-info">
            <h3>Device Information</h3>
            <p><strong>Serial:</strong> 0001</p>
            <p><strong>MAC:</strong> 2c:cf:67:c6:97:2c</p>
        </div>

        <form id="setupForm" method="POST" action="/configure">
            <div class="form-group">
                <label for="ssid">WiFi Network Name (SSID):</label>
                <input type="text" id="ssid" name="ssid" required>
            </div>

            <div class="form-group">
                <label for="password">WiFi Password:</label>
                <input type="password" id="password" name="password" required>
            </div>

            <div class="form-group">
                <label for="apiKey">API Key:</label>
                <input type="text" id="apiKey" name="apiKey" required>
            </div>

            <button type="submit">Configure Device</button>
        </form>

        <div id="status"></div>
    </div>

    <script>
        document.getElementById('setupForm').addEventListener('submit', async (e) => {
            e.preventDefault();
            
            const formData = new FormData(e.target);
            const params = new URLSearchParams(formData);
            
            try {
                const response = await fetch('/configure', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: params
                });
                
                const text = await response.text();
                document.getElementById('status').innerHTML = 
                    '<div class="status success">' + text + '</div>';
                    
            } catch (error) {
                document.getElementById('status').innerHTML = 
                    '<div class="status error">Error: ' + error.message + '</div>';
            }
        });
    </script>
</body>
</html>`;

const server = http.createServer((req, res) => {
  const parsedUrl = url.parse(req.url, true);
  
  log('INFO', `${req.method} ${req.url}`);
  
  if (req.method === 'GET' && parsedUrl.pathname === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(setupHTML);
    
  } else if (req.method === 'POST' && parsedUrl.pathname === '/configure') {
    let body = '';
    
    req.on('data', chunk => {
      body += chunk.toString();
    });
    
    req.on('end', () => {
      try {
        const formData = querystring.parse(body);
        const config = {
          ssid: formData.ssid,
          password: formData.password,
          apiKey: formData.apiKey,
          deviceSerial: '0001',
          configuredAt: new Date().toISOString()
        };
        
        if (!config.ssid || !config.password || !config.apiKey) {
          res.writeHead(400, { 'Content-Type': 'text/plain' });
          res.end('Missing required fields');
          return;
        }
        
        // Save configuration
        const configDir = require('path').dirname(CONFIG_PATH);
        if (!fs.existsSync(configDir)) {
          fs.mkdirSync(configDir, { recursive: true });
        }
        
        fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
        log('INFO', `Configuration saved for SSID: ${config.ssid}`);
        
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('Configuration saved! Device will now switch to WiFi mode.');
        
        // Switch to WiFi mode
        setTimeout(() => {
            exec('/usr/local/bin/smartwardrobe-connect-wifi.sh', (error) => {
            if (error) {
              log('ERROR', `WiFi switch failed: ${error.message}`);
            }
          });
        }, 2000);
        
      } catch (error) {
        log('ERROR', `Configuration failed: ${error.message}`);
        res.writeHead(500, { 'Content-Type': 'text/plain' });
        res.end('Configuration failed: ' + error.message);
      }
    });
    
  } else if (req.method === 'GET' && parsedUrl.pathname === '/status') {
    exec('systemctl is-active hostapd', (error) => {
      const mode = error ? 'client' : 'ap';
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ mode, timestamp: new Date().toISOString() }));
    });
    
  } else {
    // Captive portal redirect
    if (parsedUrl.pathname !== '/' && !parsedUrl.pathname.startsWith('/api/')) {
      res.writeHead(302, { 'Location': '/' });
      res.end();
    } else {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not found');
    }
  }
});

server.listen(PORT, '0.0.0.0', () => {
  log('INFO', `Smart Wardrobe Setup Server running on port ${PORT}`);
  log('INFO', `Access setup page at: http://192.168.4.1`);
});

process.on('SIGINT', () => {
  log('INFO', 'Server shutting down');
  process.exit(0);
});

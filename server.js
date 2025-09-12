const http = require('http');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const url = require('url');
const querystring = require('querystring');

const PORT = 8080;
const CONFIG_PATH = '/etc/smartwardrobe/config.json';
const LOG_DIR = '/var/log/smartwardrobe';

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

const mimeTypes = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.json': 'application/json'
};

function getMimeType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  return mimeTypes[ext] || 'text/plain';
}

function serveFile(res, fileName) {
  const filePath = path.join(__dirname, fileName);
  
  fs.readFile(filePath, (err, content) => {
    if (err) {
      log('ERROR', `Failed to read ${fileName}: ${err.message}`);
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('File not found');
      return;
    }
    
    const mimeType = getMimeType(filePath);
    res.writeHead(200, { 'Content-Type': mimeType });
    res.end(content);
  });
}

function hasExistingConfig() {
  return fs.existsSync(CONFIG_PATH);
}

const server = http.createServer((req, res) => {
  const parsedUrl = url.parse(req.url, true);
  
  log('INFO', `${req.method} ${req.url}`);
  
  if (req.method === 'GET') {
    switch (parsedUrl.pathname) {
      case '/':
        serveFile(res, 'setup.html');
        break;
        
      case '/styles.css':
        serveFile(res, 'styles.css');
        break;
        
      case '/app.js':
        serveFile(res, 'app.js');
        break;
        
      case '/status':
        exec('systemctl is-active hostapd', (error) => {
          const mode = error ? 'client' : 'ap';
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ mode, timestamp: new Date().toISOString() }));
        });
        break;
        
      default:
        res.writeHead(302, { 'Location': '/' });
        res.end();
    }
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
          serialNumber: '0001',
          configuredAt: new Date().toISOString()
        };
        
        if (!config.ssid || !config.password || !config.apiKey) {
          res.writeHead(400, { 'Content-Type': 'text/plain' });
          res.end('Missing required fields');
          return;
        }
        
        const configDir = path.dirname(CONFIG_PATH);
        if (!fs.existsSync(configDir)) {
          fs.mkdirSync(configDir, { recursive: true });
        }
        
        fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
        log('INFO', `Configuration saved for SSID: ${config.ssid}`);
        
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('Configuration saved! Device will now switch to WiFi mode.');
        
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
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
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

const fs = require('fs');
const { exec } = require('child_process');
const http = require('https');

const CONFIG_PATH = '/etc/smartwardrobe/config.json';
const LOG_DIR = '/var/log/smartwardrobe';
const DEVICE_SERIAL = '0001';
const DEVICE_MAC = '2c:cf:67:c6:97:2c';

if (!fs.existsSync(LOG_DIR)) {
  fs.mkdirSync(LOG_DIR, { recursive: true });
}

function log(level, message) {
  const timestamp = new Date().toISOString();
  const logMessage = `[${timestamp}] RFID-${level}: ${message}`;
  console.log(logMessage);
  
  try {
    fs.appendFileSync(`${LOG_DIR}/rfid-service.log`, logMessage + '\n');
  } catch (e) {
    console.error('Failed to write log:', e.message);
  }
}

class RFIDService {
  constructor() {
    this.config = null;
    this.isRunning = false;
    this.lastTagTime = {};
    this.tagCooldown = 2000; // 2 seconds between same tag reads
    
    this.loadConfig();
  }
  
  loadConfig() {
    try {
      if (fs.existsSync(CONFIG_PATH)) {
        const configData = fs.readFileSync(CONFIG_PATH, 'utf8');
        this.config = JSON.parse(configData);
        log('INFO', 'Configuration loaded successfully');
      } else {
        log('WARN', 'No configuration found - waiting for setup');
        // Check again in 30 seconds
        setTimeout(() => this.loadConfig(), 30000);
        return;
      }
    } catch (error) {
      log('ERROR', `Failed to load config: ${error.message}`);
      setTimeout(() => this.loadConfig(), 30000);
      return;
    }
    
    if (!this.isRunning) {
      this.startRFIDMonitoring();
    }
  }
  
  startRFIDMonitoring() {
    if (!this.config) {
      log('WARN', 'Cannot start RFID monitoring - no configuration');
      return;
    }
    
    this.isRunning = true;
    log('INFO', 'Starting RFID monitoring service');
    
    // Method 1: If using RC522 with Python script
    this.startPythonRFID();
    
    // Method 2: If using USB/Serial RFID reader
    // this.startSerialRFID();
    
  }
  
  // Method 1: Python RC522 integration
  startPythonRFID() {
    log('INFO', 'Starting Python RFID reader');
    
    // Create a simple Python RFID reader script if it doesn't exist
    const pythonScript = `#!/usr/bin/env python3
import RPi.GPIO as GPIO
from mfrc522 import SimpleMFRC522
import time
import sys
import json

reader = SimpleMFRC522()

try:
    while True:
        print("Waiting for RFID tag...", file=sys.stderr)
        id, text = reader.read()
        
        # Output tag data as JSON
        tag_data = {
            "id": str(id),
            "text": text.strip() if text else "",
            "timestamp": time.time()
        }
        
        print(json.dumps(tag_data))
        sys.stdout.flush()
        
        time.sleep(0.5)  # Small delay to prevent spam
        
except KeyboardInterrupt:
    print("RFID reader stopped", file=sys.stderr)
finally:
    GPIO.cleanup()
`;

    // Save Python script
    try {
      fs.writeFileSync('/opt/smartwardrobe/rfid_reader.py', pythonScript);
      exec('chmod +x /opt/smartwardrobe/rfid_reader.py');
    } catch (error) {
      log('ERROR', `Failed to create Python script: ${error.message}`);
    }
    
    // Start Python process
    const { spawn } = require('child_process');
    const pythonProcess = spawn('python3', ['/opt/smartwardrobe/rfid_reader.py'], {
      stdio: ['ignore', 'pipe', 'pipe']
    });
    
    pythonProcess.stdout.on('data', (data) => {
      try {
        const lines = data.toString().split('\n').filter(line => line.trim());
        lines.forEach(line => {
          const tagData = JSON.parse(line);
          this.handleRFIDTag(tagData);
        });
      } catch (error) {
        log('WARN', `Failed to parse RFID data: ${error.message}`);
      }
    });
    
    pythonProcess.stderr.on('data', (data) => {
      log('DEBUG', `Python RFID: ${data.toString().trim()}`);
    });
    
    pythonProcess.on('close', (code) => {
      log('WARN', `Python RFID process exited with code ${code}`);
      // Restart after 5 seconds
      setTimeout(() => this.startPythonRFID(), 5000);
    });
  }
  
  // Method 2: Serial/USB RFID reader
  startSerialRFID() {
    log('INFO', 'Starting Serial RFID reader');
    
    try {
      const SerialPort = require('serialport');
      const port = new SerialPort('/dev/ttyUSB0', { baudRate: 9600 });
      
      port.on('data', (data) => {
        const tagId = data.toString().trim();
        if (tagId.length > 0) {
          this.handleRFIDTag({
            id: tagId,
            text: '',
            timestamp: Date.now() / 1000
          });
        }
      });
      
      port.on('error', (error) => {
        log('ERROR', `Serial RFID error: ${error.message}`);
      });
      
    } catch (error) {
      log('ERROR', `Failed to start serial RFID: ${error.message}`);
    }
  }
  
  handleRFIDTag(tagData) {
    const now = Date.now();
    const tagId = tagData.id;
    
    // Implement cooldown to prevent spam
    if (this.lastTagTime[tagId] && (now - this.lastTagTime[tagId]) < this.tagCooldown) {
      return;
    }
    
    this.lastTagTime[tagId] = now;
    
    log('INFO', `RFID tag detected: ${tagId}`);
    
    // Send to backend
    this.sendToBackend(tagData);
  }
  
  async sendToBackend(tagData) {
    if (!this.config || !this.config.backendUrl || !this.config.apiKey) {
      log('WARN', 'No backend configuration - cannot send tag data');
      return;
    }
    
    const payload = {
      deviceSerial: DEVICE_SERIAL,
      deviceMac: DEVICE_MAC,
      tagId: tagData.id,
      tagText: tagData.text || '',
      timestamp: new Date().toISOString(),
      rawTimestamp: tagData.timestamp
    };
    
    const postData = JSON.stringify(payload);
    const url = new URL(this.config.backendUrl);
    
    const options = {
      hostname: url.hostname,
      port: url.port || 443,
      path: '/api/rfid/tag-event',  // Adjust this endpoint as needed
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.config.apiKey}`,
        'Content-Length': Buffer.byteLength(postData)
      }
    };
    
    const req = http.request(options, (res) => {
      let data = '';
      
      res.on('data', (chunk) => {
        data += chunk;
      });
      
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          log('INFO', `Tag event sent successfully: ${tagData.id}`);
        } else {
          log('ERROR', `Backend returned ${res.statusCode}: ${data}`);
        }
      });
    });
    
    req.on('error', (error) => {
      log('ERROR', `Failed to send tag event: ${error.message}`);
    });
    
    req.write(postData);
    req.end();
  }
  
  // Graceful shutdown
  shutdown() {
    log('INFO', 'RFID service shutting down');
    this.isRunning = false;
    process.exit(0);
  }
}

const rfidService = new RFIDService();

// Handle graceful shutdown
process.on('SIGINT', () => rfidService.shutdown());
process.on('SIGTERM', () => rfidService.shutdown());

process.on('uncaughtException', (error) => {
  log('ERROR', `Uncaught exception: ${error.message}`);
  process.exit(1);
});
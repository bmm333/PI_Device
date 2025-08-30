const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const http = require('http');

// Configuration
const CONFIG_PATH = '/etc/smartwardrobe/config.json';
const BACKEND_URL = 'http://192.168.1.4:3001'; // Development backend
const SCAN_INTERVAL = 5000; // Scan every 5 seconds
const HEARTBEAT_INTERVAL = 30000; // Heartbeat every 30 seconds
const LOG_PATH = '/var/log/smartwardrobe/rfid.log';

// Load configuration (API key from setup)
function loadConfig() {
  try {
    const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    return {
      apiKey: config.apiKey,
      serialNumber: config.serialNumber || 'unknown'
    };
  } catch (error) {
    log('ERROR', `Failed to load config: ${error.message}`);
    process.exit(1);
  }
}

// Logging function
function log(level, message) {
  const timestamp = new Date().toISOString();
  const logMessage = `[${timestamp}] [${level}] ${message}\n`;
  console.log(logMessage);
  fs.appendFileSync(LOG_PATH, logMessage);
}

// Send data to backend
function sendToBackend(endpoint, data, apiKey) {
  return new Promise((resolve, reject) => {
    const url = `${BACKEND_URL}${endpoint}`;
    const payload = JSON.stringify(data);
    
    const options = {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'Content-Length': Buffer.byteLength(payload)
      }
    };

    const req = http.request(url, options, (res) => {
      let body = '';
      res.on('data', (chunk) => body += chunk);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          log('INFO', `Backend response: ${body}`);
          resolve(JSON.parse(body));
        } else {
          reject(new Error(`HTTP ${res.statusCode}: ${body}`));
        }
      });
    });

    req.on('error', (error) => {
      reject(error);
    });

    req.write(payload);
    req.end();
  });
}

// Send heartbeat to backend
async function sendHeartbeat(apiKey) {
  try {
    await sendToBackend('/rfid/heartbeat', {}, apiKey);
    log('INFO', 'Heartbeat sent successfully');
  } catch (error) {
    log('ERROR', `Heartbeat failed: ${error.message}`);
  }
}

// Process detected tags and send to backend
async function processTags(tags, apiKey) {
  if (tags.length === 0) return;

  const detectedTags = tags.map(tag => ({
    tagId: tag.id,
    event: 'detected',
    signalStrength: tag.signalStrength || 0
  }));

  try {
    const response = await sendToBackend('/rfid/scan', { detectedTags }, apiKey);
    log('INFO', `Tags processed: ${detectedTags.length} sent, response: ${JSON.stringify(response)}`);
  } catch (error) {
    log('ERROR', `Failed to send tags: ${error.message}`);
  }
}

// Scan for RFID tags using nfcpy
function scanTags() {
  return new Promise((resolve, reject) => {
    const pythonProcess = spawn('python3', ['-c', `
import sys
import json
import time
from smartcard.System import readers
from smartcard.util import toHexString

def scan_cards():
    try:
        reader_list = readers()
        if not reader_list:
            return []
        
        cards = []
        for reader in reader_list:
            try:
                connection = reader.createConnection()
                connection.connect()
                
                # Get ATR (Answer To Reset) as card identifier
                atr = connection.getATR()
                card_id = ''.join(['%02X' % x for x in atr])
                
                cards.append({
                    'id': card_id,
                    'signalStrength': 100,
                    'reader': str(reader)
                })
                
                connection.disconnect()
            except Exception as e:
                # No card present or connection failed
                continue
        
        return cards
    except Exception as e:
        raise Exception(f"PC/SC error: {str(e)}")

try:
    cards = scan_cards()
    for card in cards:
        print(json.dumps(card))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
    sys.exit(1)
`]);

    let output = '';
    let errorOutput = '';

    pythonProcess.stdout.on('data', (data) => {
      output += data.toString();
    });

    pythonProcess.stderr.on('data', (data) => {
      errorOutput += data.toString();
    });

    pythonProcess.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`PC/SC error: ${errorOutput}`));
        return;
      }

      try {
        const tags = output.trim().split('\n')
          .filter(line => line.trim())
          .map(line => JSON.parse(line))
          .filter(tag => !tag.error);
        resolve(tags);
      } catch (parseError) {
        reject(new Error(`Parse error: ${parseError.message}, output: ${output}`));
      }
    });

    pythonProcess.on('error', (error) => {
      reject(new Error(`Process error: ${error.message}`));
    });
  });
}

// Main service loop
async function main() {
  const config = loadConfig();
  log('INFO', `Starting RFID service for device: ${config.serialNumber}`);

  // Heartbeat timer
  const heartbeatTimer = setInterval(() => sendHeartbeat(config.apiKey), HEARTBEAT_INTERVAL);

  // Scanning loop
  while (true) {
    try {
      const tags = await scanTags();
      if (tags.length > 0) {
        log('INFO', `Detected tags: ${tags.map(t => t.id).join(', ')}`);
        await processTags(tags, config.apiKey);
      }
    } catch (error) {
      log('ERROR', `Scan failed: ${error.message}`);
    }
    await new Promise(resolve => setTimeout(resolve, SCAN_INTERVAL));
  }
}

// Graceful shutdown
process.on('SIGINT', () => {
  log('INFO', 'Shutting down RFID service');
  process.exit(0);
});

process.on('SIGTERM', () => {
  log('INFO', 'Shutting down RFID service');
  process.exit(0);
});

// Start the service
main().catch((error) => {
  log('ERROR', `Service crashed: ${error.message}`);
  process.exit(1);
});

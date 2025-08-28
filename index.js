const bleno = require('bleno');
const axios = require('axios');
const os = require('os');
const express = require('express');
const cors = require('cors');
const config = require('./config.json');

const SERVICE_UUID = '12345678-1234-5678-9abc-123456789abc';
const DEVICE_INFO_CHAR_UUID = '12345678-1234-5678-9abc-123456789abe';
const WIFI_CHAR_UUID = '12345678-1234-5678-9abc-123456789abd';

// HTTP server as fallback
const app = express();
app.use(cors());
app.use(express.json());

function getMacAddress() {
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name]) {
      if (!iface.internal && iface.mac && iface.mac !== '00:00:00:00:00:00') return iface.mac;
    }
  }
  return null;
}

class DeviceInfoCharacteristic extends bleno.Characteristic {
  constructor() {
    super({
      uuid: DEVICE_INFO_CHAR_UUID,
      properties: ['read'],
      descriptors: [
        new bleno.Descriptor({
          uuid: '2901',
          value: 'Device Information'
        })
      ]
    });
  }

  onReadRequest(offset, callback) {
    const payload = {
      serialNumber: config.serialNumber,
      apiKey: config.apiKey,
      deviceName: config.deviceName,
      macAddress: getMacAddress(),
      version: '1.0.0'
    };
    const data = Buffer.from(JSON.stringify(payload));
    
    if (offset > data.length) {
      callback(this.RESULT_INVALID_OFFSET, null);
    } else {
      callback(this.RESULT_SUCCESS, data.slice(offset));
    }
  }
}

class WifiConfigCharacteristic extends bleno.Characteristic {
  constructor() {
    super({
      uuid: WIFI_CHAR_UUID,
      properties: ['write', 'writeWithoutResponse'],
      descriptors: [
        new bleno.Descriptor({
          uuid: '2901',
          value: 'WiFi Configuration'
        })
      ]
    });
  }

  async onWriteRequest(data, offset, withoutResponse, callback) {
    try {
      const json = JSON.parse(data.toString());
      console.log('Received WiFi config over BLE:', json);

      const wifi = json.wifi || json;
      const backendUrl = json.backendUrl || config.backendUrl;

      // StoreWiFi config
      config.wifiConfig = wifi;
      
      // Confirm with backend
      const url = `${backendUrl}/rfid/device/${encodeURIComponent(config.serialNumber)}/wifi-confirm`;
      console.log('Confirming WiFi with backend:', url);

      const resp = await axios.put(url, {
        ssid: wifi.ssid,
        password: wifi.password,
        security: wifi.security || 'WPA2'
      }, {
        timeout: 5000
      });

      console.log('Backend response:', resp.status, resp.data);
      callback(this.RESULT_SUCCESS);
    } catch (err) {
      console.error('Failed to handle WiFi write:', err.message || err);
      callback(this.RESULT_SUCCESS); // Still return success to avoid BLE errors
    }
  }
}

// HTTP API endpoints as fallback
app.get('/api/device-info', (req, res) => {
  res.json({
    serialNumber: config.serialNumber,
    apiKey: config.apiKey,
    deviceName: config.deviceName,
    macAddress: getMacAddress(),
    version: '1.0.0',
    status: 'ready'
  });
});

app.post('/api/wifi-config', async (req, res) => {
  try {
    const { ssid, password, security = 'WPA2' } = req.body;
    
    config.wifiConfig = { ssid, password, security };
    console.log('Received WiFi config via HTTP:', { ssid, security });

    // Confirm with backend
    const backendUrl = req.body.backendUrl || config.backendUrl;
    const url = `${backendUrl}/rfid/device/${encodeURIComponent(config.serialNumber)}/wifi-confirm`;
    
    await axios.put(url, { ssid, password, security }, { timeout: 5000 });
    
    res.json({ success: true, message: 'WiFi configuration received' });
  } catch (error) {
    console.error('HTTP WiFi config error:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

// BLE Setup
const deviceInfoChar = new DeviceInfoCharacteristic();
const wifiChar = new WifiConfigCharacteristic();

bleno.on('stateChange', (state) => {
  console.log('BLE stateChange:', state);
  if (state === 'poweredOn') {
    // Enhanced advertising with proper service announcement
    bleno.startAdvertising(config.deviceName || 'SmartWardrobe-Pi', [SERVICE_UUID], (err) => {
      if (err) {
        console.error('startAdvertising error:', err);
      } else {
        console.log('BLE Advertising started with service UUID:', SERVICE_UUID);
      }
    });
  } else {
    bleno.stopAdvertising();
  }
});

bleno.on('advertisingStart', (err) => {
  if (err) {
    console.error('advertisingStart error:', err);
  } else {
    console.log('BLE advertising started successfully');
    bleno.setServices([
      new bleno.PrimaryService({
        uuid: SERVICE_UUID,
        characteristics: [deviceInfoChar, wifiChar]
      })
    ], (err2) => {
      if (err2) {
        console.error('setServices error:', err2);
      } else {
        console.log('BLE GATT service registered successfully');
      }
    });
  }
});

bleno.on('accept', (clientAddress) => {
  console.log('BLE connection accepted from:', clientAddress);
});

bleno.on('disconnect', (clientAddress) => {
  console.log('BLE disconnected from:', clientAddress);
});

// Start HTTP server
const httpPort = config.httpPort || 8080;
app.listen(httpPort, '0.0.0.0', () => {
  console.log(`HTTP server listening on port ${httpPort}`);
  console.log(`Device: ${config.serialNumber}`);
  console.log(`Access via: http://<pi-ip>:${httpPort}/api/device-info`);
});

// Heartbeat with both BLE and HTTP status
setInterval(async () => {
  try {
    const hbUrl = `${config.backendUrl}/rfid/heartbeat`;
    await axios.post(hbUrl, {
      bleAdvertising: bleno.state === 'poweredOn',
      httpServer: true,
      wifiConfigured: !!config.wifiConfig
    }, { 
      headers: { 'x-api-key': config.apiKey },
      timeout: 5000 
    });
    console.log('Heartbeat sent');
  } catch (err) {
    console.warn('Heartbeat error:', err.message);
  }
}, 30000);

// Demo tag scan simulator
if (config.simulateTagScan) {
  setInterval(async () => {
    try {
      const tagId = 'TAG-' + String(Math.floor(Math.random() * 100000)).padStart(5, '0');
      const scanUrl = `${config.backendUrl}/rfid/scan`;
      await axios.post(scanUrl, { 
        tagId, 
        timestamp: new Date().toISOString(),
        deviceId: config.serialNumber 
      }, { 
        headers: { 'x-api-key': config.apiKey },
        timeout: 5000 
      });
      console.log('Simulated tag scan:', tagId);
    } catch (err) {
      console.warn('Simulated scan error:', err.message);
    }
  }, (config.simulateScanIntervalSec || 45) * 1000);
}

console.log('Smart Wardrobe Device Server Started');
console.log('Serial:', config.serialNumber);
console.log('BLE Service UUID:', SERVICE_UUID);
console.log('HTTP Port:', httpPort);

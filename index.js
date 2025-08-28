const bleno = require('bleno');
const axios = require('axios');
const os = require('os');
const config = require('./config.json');

const SERVICE_UUID = '12345678-1234-5678-9abc-123456789abc';
const DEVICE_INFO_CHAR_UUID = '12345678-1234-5678-9abc-123456789abe';
const WIFI_CHAR_UUID = '12345678-1234-5678-9abc-123456789abd';

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
      properties: ['read']
    });
  }

  onReadRequest(offset, callback) {
    const payload = {
      serialNumber: config.serialNumber,
      apiKey: config.apiKey,
      deviceName: config.deviceName,
      macAddress: getMacAddress()
    };
    const data = Buffer.from(JSON.stringify(payload));
    callback(this.RESULT_SUCCESS, data.slice(offset));
  }
}

class WifiConfigCharacteristic extends bleno.Characteristic {
  constructor() {
    super({
      uuid: WIFI_CHAR_UUID,
      properties: ['write']
    });
  }

  async onWriteRequest(data, offset, withoutResponse, callback) {
    try {
      const json = JSON.parse(data.toString());
      console.log('Received WiFi config over BLE:', json);

      // Validate payload minimally for demo
      const wifi = json.wifi || json;
      const backendUrl = json.backendUrl || config.backendUrl;

      // For demo: call backend confirm endpoint
      const url = `${backendUrl}/rfid/device/${encodeURIComponent(config.serialNumber)}/wifi-confirm`;
      console.log('Confirming WiFi with backend:', url);

      const resp = await axios.put(url, {
        ssid: wifi.ssid,
        password: wifi.password,
        security: wifi.security || 'WPA2'
      });

      console.log('Backend response:', resp.status, resp.data);

      // in a real device, you'd apply the WiFi config and attempt to connect here
      callback(this.RESULT_SUCCESS);
    } catch (err) {
      console.error('Failed to handle WiFi write:', err.message || err);
      callback(this.RESULT_UNLIKELY_ERROR);
    }
  }
}

const deviceInfoChar = new DeviceInfoCharacteristic();
const wifiChar = new WifiConfigCharacteristic();

bleno.on('stateChange', (state) => {
  console.log('BLE stateChange:', state);
  if (state === 'poweredOn') {
    bleno.startAdvertising(config.deviceName || 'SmartWardrobe', [SERVICE_UUID], (err) => {
      if (err) console.error('startAdvertising error:', err);
      else console.log('Advertising started');
    });
  } else {
    bleno.stopAdvertising();
  }
});

bleno.on('advertisingStart', (err) => {
  if (err) {
    console.error('advertisingStart error:', err);
  } else {
    bleno.setServices([
      new bleno.PrimaryService({
        uuid: SERVICE_UUID,
        characteristics: [deviceInfoChar, wifiChar]
      })
    ], (err2) => {
      if (err2) console.error('setServices error:', err2);
      else console.log('GATT service set');
    });
  }
});

// Heartbeat loop
setInterval(async () => {
  try {
    const hbUrl = `${config.backendUrl.replace(/\/$/, '')}/rfid/heartbeat`;
    await axios.post(hbUrl, {}, { headers: { 'x-api-key': config.apiKey } });
    console.log('Heartbeat sent');
  } catch (err) {
    console.warn('Heartbeat error:', err.message || err);
  }
}, 30_000); // every 30s

// Demo tag scan simulator
if (config.simulateTagScan) {
  setInterval(async () => {
    try {
      const tagId = 'TAG-' + (Math.floor(Math.random() * 100000));
      const scanUrl = `${config.backendUrl.replace(/\/$/, '')}/rfid/scan`;
      await axios.post(scanUrl, { tagId, timestamp: new Date().toISOString() }, { headers: { 'x-api-key': config.apiKey } });
      console.log('Simulated tag scan sent:', tagId);
    } catch (err) {
      console.warn('Simulated scan error:', err.message || err);
    }
  }, (config.simulateScanIntervalSec || 30) * 1000);
}

console.log('Device server started. Serial:', config.serialNumber);

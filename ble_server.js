const bleno = require('@abandonware/bleno');
const fs = require('fs');
const { exec } = require('child_process');

const SERVICE_UUID = '12345678-1234-5678-9abc-123456789abc';
const WIFI_CHAR_UUID = '12345678-1234-5678-9abc-123456789abd';
const DEVICE_INFO_CHAR_UUID = '12345678-1234-5678-9abc-123456789abe';

const CONFIG_PATH = '/etc/smartwardrobe/config.json';
const DEVICE_NAME = 'SmartWardrobe';
const DEVICE_SERIAL = '0001';
const DEVICE_MAC = '2c:cf:67:c6:97:2c';

if (!fs.existsSync('/etc/smartwardrobe')) {
  try { fs.mkdirSync('/etc/smartwardrobe', { recursive: true }); } catch (e) { console.error(e); }
}

if (typeof process.getuid === 'function' && process.getuid() !== 0) {
  console.warn('Warning: running without root. Ensure node has CAP_NET_RAW or run with sudo.');
}

class WifiConfigCharacteristic extends bleno.Characteristic {
  constructor() {
    super({
      uuid: WIFI_CHAR_UUID,
      properties: ['write'],
      descriptors: [
        new bleno.Descriptor({
          uuid: '2901',
          value: 'Write WiFi JSON: {"ssid":"...","password":"...","apiKey":"...","deviceSerial":"...","backendUrl":"http://..."}'
        })
      ]
    });
  }

  onWriteRequest(data, offset, withoutResponse, callback) {
    try {
      if (offset && offset > 0) {
        // This example doesn't support long writes; reject if offset provided
        console.warn('WifiConfigCharacteristic: long write offset not supported:', offset);
        return callback(this.RESULT_ATTR_NOT_LONG);
      }

      const s = data.toString('utf8').trim();
      let cfg = null;
      if (s.startsWith('{')) {
        cfg = JSON.parse(s);
      } else {
        const parts = s.split(';');
        cfg = {
          ssid: parts[0] || null,
          password: parts[1] || null,
          apiKey: parts[2] || null,
          deviceSerial: parts[3] || null,
          backendUrl: parts[4] || 'http://localhost:3001'
        };
      }

      if (!cfg.ssid || !cfg.password) {
        console.error('Invalid wifi payload', cfg);
        return callback(this.RESULT_UNLIKELY_ERROR);
      }

      // Save config atomically
      try {
        fs.writeFileSync(CONFIG_PATH + '.tmp', JSON.stringify(cfg, null, 2));
        fs.renameSync(CONFIG_PATH + '.tmp', CONFIG_PATH);
        console.log('Saved config to', CONFIG_PATH);
      } catch (fsErr) {
        console.error('Failed to write config file', fsErr);
        return callback(this.RESULT_UNLIKELY_ERROR);
      }

      // Trigger connection attempt (non-blocking)
      const cmd = `nmcli device wifi connect "${cfg.ssid}" password "${cfg.password}" || nmcli connection up "${cfg.ssid}"`;
      exec(cmd, { timeout: 20000 }, (err, stdout, stderr) => {
        if (err) {
          console.error('nmcli connect failed:', err.message, stderr);
        } else {
          console.log('nmcli output:', stdout);
        }
      });

      console.log('WifiConfigCharacteristic: write handled OK');
      callback(this.RESULT_SUCCESS);
    } catch (e) {
      console.error('Write handling error', e);
      callback(this.RESULT_UNLIKELY_ERROR);
    }
  }
}

class DeviceInfoCharacteristic extends bleno.Characteristic {
  constructor() {
    super({
      uuid: DEVICE_INFO_CHAR_UUID,
      properties: ['read'],
      descriptors: [
        new bleno.Descriptor({
          uuid: '2901',
          value: 'Device Information: JSON with serial, mac, name, etc.'
        })
      ]
    });
  }

  onReadRequest(offset, callback) {
    try {
      const deviceInfo = {
        serialNumber: DEVICE_SERIAL,
        macAddress: DEVICE_MAC,
        deviceName: DEVICE_NAME,
        firmwareVersion: '1.0.0',
        timestamp: new Date().toISOString()
      };

      const jsonString = JSON.stringify(deviceInfo);
      const data = Buffer.from(jsonString, 'utf8');

      if (offset > data.length) {
        return callback(this.RESULT_INVALID_OFFSET, null);
      }

      // Support offset reads
      const chunk = data.slice(offset);
      callback(this.RESULT_SUCCESS, chunk);
    } catch (e) {
      console.error('Read handling error', e);
      callback(this.RESULT_UNLIKELY_ERROR, null);
    }
  }
}

const wifiChar = new WifiConfigCharacteristic();
const deviceInfoChar = new DeviceInfoCharacteristic();

const primaryService = new bleno.PrimaryService({
  uuid: SERVICE_UUID,
  characteristics: [wifiChar, deviceInfoChar]
});

// Helper for robust startup: set services first, then advertise.
// This avoids a race where a central connects before services are registered.
const startAdvertisingAndServe = () => {
  console.log('Setting GATT services...');
  bleno.setServices([primaryService], (setErr) => {
    if (setErr) {
      console.error('setServices error', setErr);
      return;
    }
    console.log('GATT services set. Starting advertising:', DEVICE_NAME, SERVICE_UUID);
    bleno.startAdvertising(DEVICE_NAME, [SERVICE_UUID], (advErr) => {
      if (advErr) console.error('startAdvertising error', advErr);
      else console.log(`Advertising as ${DEVICE_NAME}`);
    });
  });
};

bleno.on('stateChange', (state) => {
  console.log('bleno stateChange:', state);
  if (state === 'poweredOn') {
    startAdvertisingAndServe();
  } else {
    console.log('bleno: stopping advertising/services because state != poweredOn');
    bleno.stopAdvertising();
    bleno.setServices([], () => {});
  }
});

bleno.on('advertisingStart', (err) => {
  console.log('bleno advertisingStart - err=', err);
  if (!err) {
    console.log('Advertising started successfully');
  } else {
    console.error('advertisingStart error', err);
  }
});

bleno.on('advertisingStop', () => {
  console.log('bleno advertisingStop');
});

bleno.on('accept', (clientAddress) => {
  console.log('bleno accepted connection from', clientAddress);
});

bleno.on('disconnect', (clientAddress) => {
  console.log('bleno client disconnected', clientAddress);
  // re-advertise so other centrals can connect again
  // small delay to let BlueZ settle
  setTimeout(() => {
    if (bleno.state === 'poweredOn') {
      console.log('Re-advertising after disconnect');
      startAdvertisingAndServe();
    }
  }, 250);
});

bleno.on('servicesSet', (error) => {
  console.log('bleno servicesSet callback, error=', error);
});

bleno.on('mtuChange', (mtu) => {
  console.log('bleno MTU changed to', mtu);
});

// Graceful shutdown
process.on('SIGINT', () => {
  console.log('SIGINT received: stopping BLE advertising and exiting');
  try {
    bleno.stopAdvertising();
    bleno.disconnect && bleno.disconnect();
  } catch (e) {
    /* ignore */
  }
  process.exit(0);
});

// Start-up summary
console.log('BLE server starting. DEVICE_NAME=', DEVICE_NAME, 'SERVICE_UUID=', SERVICE_UUID);
console.log('Ensure node has CAP_NET_RAW (sudo setcap cap_net_raw+eip $(which node)) or run as root.');

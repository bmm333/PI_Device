const bleno = require('@abandonware/bleno');
const fs = require('fs');
const { exec } = require('child_process');

const SERVICE_UUID = '12345678123456789abc123456789abc'; // 128-bit, no hyphens
const WIFI_CHAR_UUID = '12345678123456789abc123456789abd';

const CONFIG_PATH = '/etc/smartwardrobe/config.json';
const DEVICE_NAME = 'SmartWardrobe';

if (!fs.existsSync('/etc/smartwardrobe')) {
  try { fs.mkdirSync('/etc/smartwardrobe', { recursive: true }); } catch (e) { console.error(e); }
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
      const s = data.toString('utf8').trim();
      // Accept either raw JSON or "ssid;password;apiKey;deviceSerial;backendUrl"
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

      // Basic validation
      if (!cfg.ssid || !cfg.password) {
        console.error('Invalid wifi payload', cfg);
        return callback(this.RESULT_UNLIKELY_ERROR);
      }

      // Save config atomically
      fs.writeFileSync(CONFIG_PATH + '.tmp', JSON.stringify(cfg, null, 2));
      fs.renameSync(CONFIG_PATH + '.tmp', CONFIG_PATH);
      console.log('Saved config to', CONFIG_PATH);

      // Connect using nmcli
      const cmd = `nmcli device wifi connect "${cfg.ssid}" password "${cfg.password}" || nmcli connection up "${cfg.ssid}"`;
      exec(cmd, { timeout: 20000 }, (err, stdout, stderr) => {
        if (err) {
          console.error('nmcli connect failed:', err.message, stderr);
        } else {
          console.log('nmcli output:', stdout);
        }
      });

      callback(this.RESULT_SUCCESS);
    } catch (e) {
      console.error('Write handling error', e);
      callback(this.RESULT_UNLIKELY_ERROR);
    }
  }
}

const wifiChar = new WifiConfigCharacteristic();

const primaryService = new bleno.PrimaryService({
  uuid: SERVICE_UUID,
  characteristics: [wifiChar]
});

bleno.on('stateChange', (state) => {
  console.log('bleno stateChange:', state);
  if (state === 'poweredOn') {
    bleno.startAdvertising(DEVICE_NAME, [SERVICE_UUID], (err) => {
      if (err) console.error('startAdvertising error', err);
      else console.log(`Advertising as ${DEVICE_NAME}`);
    });
  } else {
    bleno.stopAdvertising();
  }
});

bleno.on('advertisingStart', (err) => {
  if (!err) {
    bleno.setServices([primaryService], (err2) => {
      if (err2) console.error('setServices error', err2);
      else console.log('Service registered');
    });
  } else console.error('advertisingStart error', err);
});

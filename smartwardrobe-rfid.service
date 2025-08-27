import time
import json
import logging
import os
import requests
import socket
import subprocess
import signal
import sys
from pathlib import Path
from smartcard.System import readers
from smartcard.util import toHexString
import threading
from queue import Queue
import traceback
CONFIG_PATH = '/etc/smartwardrobe/config.json'
LOG_PATH = '/var/log/smartwardrobe_rfid.log'
ACTIVATION_FLAG = '/etc/smartwardrobe/.activated'
PID_FILE = '/var/run/smartwardrobe_rfid.pid'
HEARTBEAT_INTERVAL = 30  # seconds
RFID_SCAN_INTERVAL = 0.4  # seconds
MAX_RETRY_ATTEMPTS = 5
NETWORK_TIMEOUT = 60
RESTART_DELAY = 10
shutdown_event = threading.Event()
config = None
device_activated = False
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_PATH, maxBytes=10*1024*1024, backupCount=3),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger('rfid_service')
class RFIDServiceManager:
    def __init__(self):
        self.config = None
        self.device_activated = False
        self.rfid_connection = None
        self.last_tag = None
        self.heartbeat_failures = 0
        self.max_heartbeat_failures = 5
        self.event_queue = Queue()
        
    def load_config(self):
        """Load configuration written by BLE server"""
        if not os.path.exists(CONFIG_PATH):
            logger.error(f'Config missing: {CONFIG_PATH}')
            return None
            
        try:
            with open(CONFIG_PATH, 'r') as f:
                config = json.load(f)
                # Validate required fields
                required = ['deviceSerial', 'apiKey', 'backendUrl']
                missing = [field for field in required if not config.get(field)]
                if missing:
                    logger.error(f'Config missing required fields: {missing}')
                    return None
                return config
        except Exception as e:
            logger.exception('Failed to read config')
            return None

    def wait_for_network(self, timeout=NETWORK_TIMEOUT):
        """Wait for network connectivity with retry logic"""
        logger.info('Waiting for network connectivity...')
        start_time = time.time()
        
        while time.time() - start_time < timeout and not shutdown_event.is_set():
            try:
                # Try multiple DNS servers
                for dns in ['8.8.8.8', '1.1.1.1', '208.67.222.222']:
                    try:
                        socket.create_connection((dns, 53), timeout=3).close()
                        logger.info('Network connectivity confirmed')
                        return True
                    except:
                        continue
            except:
                pass
            time.sleep(2)
        
        logger.error('Network connectivity timeout')
        return False

    def get_system_info(self):
        """Get system information for device registration"""
        try:
            # Get local IP
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            
            # Get MAC address
            mac = None
            try:
                result = subprocess.run(['cat', '/sys/class/net/wlan0/address'], 
                                      capture_output=True, text=True, timeout=5)
                if result.returncode == 0:
                    mac = result.stdout.strip()
            except:
                pass
            
            return {
                'ipAddress': ip,
                'macAddress': mac,
                'firmwareVersion': '1.0.0'
            }
        except Exception as e:
            logger.warning(f'Failed to get system info: {e}')
            return {'firmwareVersion': '1.0.0'}

    def activate_device(self):
        """Activate device with backend API"""
        if not self.config:
            return False
            
        logger.info(f'Activating device: {self.config["deviceSerial"]}')
        
        url = f"{self.config['backendUrl'].rstrip('/')}/rfid/device/{self.config['deviceSerial']}/activate"
        payload = self.get_system_info()
        payload['timestamp'] = int(time.time())
        
        headers = {'Content-Type': 'application/json'}
        
        for attempt in range(MAX_RETRY_ATTEMPTS):
            try:
                response = requests.post(url, json=payload, headers=headers, timeout=10)
                
                if response.status_code == 200:
                    logger.info('Device activated successfully')
                    Path(ACTIVATION_FLAG).touch()
                    self.device_activated = True
                    return True
                else:
                    logger.error(f'Activation failed: {response.status_code} - {response.text}')
                    
            except requests.exceptions.RequestException as e:
                logger.error(f'Activation attempt {attempt + 1} failed: {e}')
                
            if attempt < MAX_RETRY_ATTEMPTS - 1:
                time.sleep(RESTART_DELAY)
        
        return False

    def send_heartbeat(self):
        """Send heartbeat to backend"""
        if not self.config or not self.device_activated:
            return False
            
        url = self.config['backendUrl'].rstrip('/') + '/rfid/heartbeat'
        headers = {
            'Content-Type': 'application/json',
            'x-api-key': self.config['apiKey']
        }
        
        try:
            response = requests.post(url, headers=headers, timeout=10)
            
            if response.status_code == 200:
                logger.debug('Heartbeat sent successfully')
                self.heartbeat_failures = 0
                return True
            else:
                logger.warning(f'Heartbeat failed: {response.status_code}')
                
        except requests.exceptions.RequestException as e:
            logger.debug(f'Heartbeat request failed: {e}')
            
        self.heartbeat_failures += 1
        return False

    def post_rfid_event(self, tag_id, event_type):
        """Post RFID event to backend"""
        if not self.config or not self.device_activated:
            logger.warning(f'Cannot post event {event_type} for {tag_id} - device not ready')
            return
            
        url = self.config['backendUrl'].rstrip('/') + '/rfid/scan'
        payload = {
            'detectedTags': [{
                'tagId': tag_id,
                'event': event_type,
                'signalStrength': -50,
                'timestamp': int(time.time())
            }]
        }
        
        headers = {
            'Content-Type': 'application/json',
            'x-api-key': self.config['apiKey']
        }
        
        try:
            response = requests.post(url, json=payload, headers=headers, timeout=10)
            if response.status_code == 200:
                logger.info(f'RFID event {event_type} sent for tag {tag_id}')
            else:
                logger.warning(f'RFID event failed: {response.status_code} for {event_type} {tag_id}')
                # Queue for retry
                self.event_queue.put((tag_id, event_type, time.time()))
                
        except Exception as e:
            logger.error(f'Failed to post RFID event: {e}')
            # Queue for retry
            self.event_queue.put((tag_id, event_type, time.time()))

    def retry_failed_events(self):
        """Retry failed RFID events"""
        retry_events = []
        current_time = time.time()
        
        while not self.event_queue.empty():
            tag_id, event_type, timestamp = self.event_queue.get()
            # Only retry events less than 5 minutes old
            if current_time - timestamp < 300:
                retry_events.append((tag_id, event_type, timestamp))
        
        for tag_id, event_type, timestamp in retry_events:
            logger.info(f'Retrying RFID event {event_type} for {tag_id}')
            self.post_rfid_event(tag_id, event_type)

    def setup_rfid_reader(self):
        """Initialize RFID reader connection"""
        try:
            reader_list = readers()
            if not reader_list:
                logger.error('No smartcard readers found')
                return None
                
            reader = reader_list[0]
            logger.info(f'Using RFID reader: {reader}')
            
            connection = reader.createConnection()
            connection.connect()
            return connection
            
        except Exception as e:
            logger.error(f'Failed to setup RFID reader: {e}')
            return None

    def rfid_scan_loop(self):
        """Main RFID scanning loop with error recovery"""
        logger.info('Starting RFID scan loop')
        
        while not shutdown_event.is_set():
            try:
                if not self.rfid_connection:
                    self.rfid_connection = self.setup_rfid_reader()
                    if not self.rfid_connection:
                        logger.error('Failed to connect to RFID reader, retrying in 10s')
                        time.sleep(10)
                        continue
                
                # APDU command to get card UID
                GET_UID = [0xFF, 0xCA, 0x00, 0x00, 0x00]
                data, sw1, sw2 = self.rfid_connection.transmit(GET_UID)
                
                if sw1 == 0x90 and sw2 == 0x00 and data:
                    # Card detected
                    tag_id = toHexString(data).replace(' ', '')
                    if tag_id != self.last_tag:
                        self.post_rfid_event(tag_id, 'detected')
                        self.last_tag = tag_id
                else:
                    # No card present
                    if self.last_tag is not None:
                        self.post_rfid_event(self.last_tag, 'removed')
                        self.last_tag = None
                
                time.sleep(RFID_SCAN_INTERVAL)
                
            except Exception as e:
                logger.debug(f'RFID scan exception: {e}')
                # Handle card removal or connection issues
                if self.last_tag is not None:
                    try:
                        self.post_rfid_event(self.last_tag, 'removed')
                    except:
                        pass
                    self.last_tag = None
                
                # Reset connection
                self.rfid_connection = None
                time.sleep(2)
                
                # Reload config in case it changed
                new_config = self.load_config()
                if new_config:
                    self.config = new_config

    def heartbeat_loop(self):
        """Heartbeat maintenance loop"""
        logger.info('Starting heartbeat loop')
        
        while not shutdown_event.is_set():
            if self.device_activated:
                success = self.send_heartbeat()
                
                if not success:
                    if self.heartbeat_failures >= self.max_heartbeat_failures:
                        logger.error('Too many heartbeat failures - attempting device reactivation')
                        self.device_activated = False
                        try:
                            os.remove(ACTIVATION_FLAG)
                        except:
                            pass
                else:
                    # On successful heartbeat, retry any failed events
                    self.retry_failed_events()
            
            time.sleep(HEARTBEAT_INTERVAL)

    def run(self):
        """Main service execution"""
        logger.info('RFID Service starting...')
        
        # Create PID file
        with open(PID_FILE, 'w') as f:
            f.write(str(os.getpid()))
        
        try:
            # Wait for network
            if not self.wait_for_network():
                logger.error('No network connectivity - exiting')
                return 1
            
            # Load configuration
            self.config = self.load_config()
            if not self.config:
                logger.error('No valid config found')
                return 1
            
            # Check activation status
            if not os.path.exists(ACTIVATION_FLAG):
                if not self.activate_device():
                    logger.error('Device activation failed')
                    return 1
            else:
                logger.info('Device already activated')
                self.device_activated = True
            
            # Start background threads
            heartbeat_thread = threading.Thread(target=self.heartbeat_loop, daemon=True)
            heartbeat_thread.start()
            
            # Run RFID scanning in main thread
            self.rfid_scan_loop()
            
        except KeyboardInterrupt:
            logger.info('Service interrupted by user')
        except Exception as e:
            logger.exception('Unexpected error in main service')
            return 1
        finally:
            # Cleanup
            shutdown_event.set()
            try:
                os.remove(PID_FILE)
            except:
                pass
            logger.info('RFID Service stopped')
        
        return 0

def signal_handler(signum, frame):
    """Handle shutdown signals gracefully"""
    logger.info(f'Received signal {signum} - shutting down gracefully')
    shutdown_event.set()

def main():
    # Setup signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    # Run the service
    service = RFIDServiceManager()
    return service.run()

if __name__ == '__main__':
    sys.exit(main())

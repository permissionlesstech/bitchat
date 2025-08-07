"""
BitChat Meshtastic Bridge Service

Main orchestrator for Meshtastic integration that handles device discovery,
connection management, and message routing between BitChat and LoRa mesh networks.
"""

import asyncio
import threading
import time
import signal
import sys
from typing import List, Optional, Callable, Dict, Any
from dataclasses import dataclass
import json
import logging

try:
    import meshtastic
    import meshtastic.serial_interface
    import meshtastic.tcp_interface
    import meshtastic.ble_interface
    from pubsub import pub
except ImportError as e:
    print(f"Missing Meshtastic dependencies: {e}")
    print("Install with: pip install meshtastic protobuf pubsub pyserial")
    sys.exit(1)

from clean_bitchat_meshtastic_types import (
    BitChatMessage, MeshtasticDeviceInfo, FallbackRequest, FallbackResponse,
    FallbackStatus, BitChatMeshtasticProtocol
)
from clean_meshtastic_config import MeshtasticConfig
from clean_protocol_translator import ProtocolTranslator


class MeshtasticBridge:
    """Bridge between BitChat and Meshtastic mesh network"""
    
    def __init__(self):
        self.config = MeshtasticConfig()
        self.translator = ProtocolTranslator()
        self.interface = None
        self.status = FallbackStatus.DISABLED
        self.available_devices: List[MeshtasticDeviceInfo] = []
        self.connected_device: Optional[MeshtasticDeviceInfo] = None
        self.is_running = False
        self.monitor_thread = None
        
        # Callbacks for integration
        self.message_callbacks: List[Callable[[bytes], None]] = []
        self.status_callbacks: List[Callable[[FallbackStatus], None]] = []
        
        # Message queue for retry handling
        self.message_queue: List[FallbackRequest] = []
        self.queue_lock = threading.Lock()
        
        # Setup logging
        logging.basicConfig(level=logging.INFO)
        self.logger = logging.getLogger(__name__)
        
        # Setup signal handlers for clean shutdown
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
    
    def start(self):
        """Start the Meshtastic bridge service"""
        if not self.config.is_enabled():
            self.logger.info("Meshtastic integration disabled in configuration")
            return False
        
        self.is_running = True
        self._update_status(FallbackStatus.CHECKING_MESHTASTIC)
        
        # Start background monitoring
        self.monitor_thread = threading.Thread(target=self._monitor_loop, daemon=True)
        self.monitor_thread.start()
        
        # Attempt initial connection
        if self._auto_connect():
            self.logger.info("Meshtastic bridge started successfully")
            return True
        else:
            self.logger.warning("No Meshtastic devices available, running in standby mode")
            return False
    
    def stop(self):
        """Stop the bridge service"""
        self.is_running = False
        self._disconnect_interface()
        self._update_status(FallbackStatus.DISABLED)
        
        if self.monitor_thread and self.monitor_thread.is_alive():
            self.monitor_thread.join(timeout=5)
        
        self.logger.info("Meshtastic bridge stopped")
    
    def scan_devices(self) -> List[MeshtasticDeviceInfo]:
        """Scan for available Meshtastic devices"""
        self.logger.info("Scanning for Meshtastic devices...")
        devices = []
        
        # Scan different connection types
        devices.extend(self._scan_serial_devices())
        devices.extend(self._scan_tcp_devices())
        devices.extend(self._scan_ble_devices())
        
        # Test device availability
        available_devices = []
        for device in devices:
            if self._test_device_availability(device):
                available_devices.append(device)
                self.config.add_known_device(device)
        
        self.available_devices = available_devices
        self.config.update_scan_timestamp()
        
        self.logger.info(f"Found {len(available_devices)} available Meshtastic devices")
        return available_devices
    
    def connect_device(self, device_id: Optional[str] = None) -> bool:
        """Connect to a Meshtastic device"""
        if device_id:
            # Connect to specific device
            device = next((d for d in self.available_devices if d.device_id == device_id), None)
            if not device:
                self.logger.error(f"Device {device_id} not found in available devices")
                return False
        else:
            # Auto-select best device
            preferred_id = self.config.get_preferred_device()
            if preferred_id:
                device = next((d for d in self.available_devices if d.device_id == preferred_id), None)
            if not device and self.available_devices:
                device = self.available_devices[0]  # Use first available
            if not device:
                self.logger.error("No devices available for connection")
                return False
        
        return self._connect_to_device(device)
    
    def send_message(self, message: BitChatMessage) -> FallbackResponse:
        """Send a message via Meshtastic"""
        if not self.interface or self.status != FallbackStatus.MESHTASTIC_ACTIVE:
            return FallbackResponse(
                success=False,
                message_id=message.message_id,
                status=self.status,
                error_message="Meshtastic interface not active"
            )
        
        try:
            # Translate message to Meshtastic format
            mesh_messages = self.translator.bitchat_to_meshtastic(
                self._encode_message_for_translation(message)
            )
            
            # Send each fragment
            for mesh_msg in mesh_messages:
                port = mesh_msg.get('port', BitChatMeshtasticProtocol.BITCHAT_TEXT_PORT)
                payload = mesh_msg.get('payload', b'')
                
                self.interface.sendText(
                    text=payload.decode('utf-8') if isinstance(payload, bytes) else str(payload),
                    destinationId=None,  # Broadcast
                    channelIndex=0,
                    requestResponse=False
                )
            
            return FallbackResponse(
                success=True,
                message_id=message.message_id,
                status=self.status,
                meshtastic_node_id=self.connected_device.device_id if self.connected_device else None
            )
            
        except Exception as e:
            self.logger.error(f"Failed to send message via Meshtastic: {e}")
            return FallbackResponse(
                success=False,
                message_id=message.message_id,
                status=self.status,
                error_message=str(e)
            )
    
    def check_fallback_needed(self, ble_activity_timestamp: float) -> bool:
        """Check if fallback to Meshtastic is needed"""
        if not self.config.should_auto_fallback():
            return False
        
        current_time = time.time()
        time_since_activity = current_time - ble_activity_timestamp
        threshold = self.config.get_fallback_threshold()
        
        return time_since_activity > threshold
    
    def handle_fallback_request(self, request: FallbackRequest) -> FallbackResponse:
        """Handle a fallback request from BitChat"""
        # Add to queue for retry handling
        with self.queue_lock:
            self.message_queue.append(request)
        
        # Attempt immediate send
        response = self.send_message(request.message)
        
        if not response.success and request.retry_count < request.max_retries:
            # Schedule retry
            request.retry_count += 1
            self.logger.info(f"Message {request.message.message_id} queued for retry ({request.retry_count}/{request.max_retries})")
        
        return response
    
    def _scan_serial_devices(self):
        """Scan for serial Meshtastic devices"""
        devices = []
        try:
            import serial.tools.list_ports
            ports = serial.tools.list_ports.comports()
            
            for port in ports:
                # Look for common Meshtastic device patterns
                if any(vid in str(port.vid) for vid in ['10c4', '1a86', '0403']) or \
                   any(name in port.description.lower() for name in ['esp32', 'cp210', 'ch340']):
                    
                    device = MeshtasticDeviceInfo(
                        device_id=f"serial_{port.device}",
                        name=f"Meshtastic Serial ({port.device})",
                        interface_type="serial",
                        connection_string=port.device
                    )
                    devices.append(device)
        except Exception as e:
            self.logger.debug(f"Serial scan error: {e}")
        
        return devices
    
    def _scan_tcp_devices(self):
        """Scan for TCP Meshtastic devices (configured IPs)"""
        devices = []
        # Could scan common IP ranges or use configured addresses
        # For now, return empty - users can manually configure TCP devices
        return devices
    
    def _scan_ble_devices(self):
        """Scan for BLE Meshtastic devices"""
        devices = []
        try:
            # BLE scanning would go here
            # This requires platform-specific BLE libraries
            pass
        except Exception as e:
            self.logger.debug(f"BLE scan error: {e}")
        
        return devices
    
    def _test_device_availability(self, device: MeshtasticDeviceInfo) -> bool:
        """Test if a device is available and responsive"""
        try:
            # Quick connection test
            if device.interface_type == "serial":
                test_interface = meshtastic.serial_interface.SerialInterface(
                    devPath=device.connection_string,
                    debugOut=None
                )
            elif device.interface_type == "tcp":
                host, port = device.connection_string.split(':')
                test_interface = meshtastic.tcp_interface.TCPInterface(
                    hostname=host,
                    portNumber=int(port),
                    debugOut=None
                )
            else:
                return False  # BLE not implemented yet
            
            # Test basic connectivity
            node_info = test_interface.getMyNodeInfo()
            test_interface.close()
            
            return node_info is not None
            
        except Exception as e:
            self.logger.debug(f"Device {device.device_id} test failed: {e}")
            return False
    
    def _connect_to_device(self, device: MeshtasticDeviceInfo) -> bool:
        """Connect to a specific device"""
        try:
            self._update_status(FallbackStatus.MESHTASTIC_CONNECTING)
            
            # Disconnect existing interface
            self._disconnect_interface()
            
            # Create new interface
            if device.interface_type == "serial":
                self.interface = meshtastic.serial_interface.SerialInterface(
                    devPath=device.connection_string,
                    debugOut=None
                )
            elif device.interface_type == "tcp":
                host, port = device.connection_string.split(':')
                self.interface = meshtastic.tcp_interface.TCPInterface(
                    hostname=host,
                    portNumber=int(port),
                    debugOut=None
                )
            else:
                self.logger.error(f"Unsupported interface type: {device.interface_type}")
                return False
            
            # Setup message handlers
            pub.subscribe(self._on_receive, "meshtastic.receive")
            pub.subscribe(self._on_connection, "meshtastic.connection.established")
            pub.subscribe(self._on_disconnect, "meshtastic.connection.lost")
            
            # Test connection
            if self._test_connection():
                self.connected_device = device
                self.config.set_preferred_device(device.device_id)
                self._update_status(FallbackStatus.MESHTASTIC_ACTIVE)
                self.logger.info(f"Connected to Meshtastic device: {device.name}")
                return True
            else:
                self._disconnect_interface()
                return False
                
        except Exception as e:
            self.logger.error(f"Failed to connect to device {device.name}: {e}")
            self._disconnect_interface()
            return False
    
    def _test_connection(self) -> bool:
        """Test the current Meshtastic connection"""
        try:
            if not self.interface:
                return False
            
            node_info = self.interface.getMyNodeInfo()
            return node_info is not None
            
        except Exception as e:
            self.logger.debug(f"Connection test failed: {e}")
            return False
    
    def _auto_connect(self) -> bool:
        """Automatically connect to best available device"""
        if self.config.should_rescan():
            self.scan_devices()
        
        if not self.available_devices:
            return False
        
        return self.connect_device()
    
    def _disconnect_interface(self):
        """Disconnect current Meshtastic interface"""
        if self.interface:
            try:
                self.interface.close()
            except Exception as e:
                self.logger.debug(f"Interface close error: {e}")
            finally:
                self.interface = None
                self.connected_device = None
    
    def _monitor_loop(self):
        """Background monitoring loop"""
        while self.is_running:
            try:
                # Process message queue retries
                self._process_message_queue()
                
                # Monitor connection health
                if self.status == FallbackStatus.MESHTASTIC_ACTIVE:
                    if not self._test_connection():
                        self.logger.warning("Meshtastic connection lost, attempting reconnect")
                        self._auto_connect()
                
                # Check for new devices periodically
                elif self.status in [FallbackStatus.BLE_ACTIVE, FallbackStatus.CHECKING_MESHTASTIC]:
                    if self.config.should_rescan(max_age=300):  # 5 minutes
                        self._auto_connect()
                
                time.sleep(10)  # Check every 10 seconds
                
            except Exception as e:
                self.logger.error(f"Monitor loop error: {e}")
                time.sleep(30)  # Longer sleep on error
    
    def _process_message_queue(self):
        """Process pending message retries"""
        with self.queue_lock:
            pending_messages = self.message_queue.copy()
            self.message_queue.clear()
        
        for request in pending_messages:
            if request.retry_count < request.max_retries:
                response = self.send_message(request.message)
                if not response.success:
                    request.retry_count += 1
                    with self.queue_lock:
                        self.message_queue.append(request)
    
    def _on_receive(self, packet, interface):
        """Handle received Meshtastic message"""
        try:
            # Convert to BitChat format
            binary_data = self.translator.meshtastic_to_bitchat(packet)
            if binary_data:
                # Notify callbacks
                for callback in self.message_callbacks:
                    callback(binary_data)
        except Exception as e:
            self.logger.error(f"Message receive error: {e}")
    
    def _on_connection(self, interface, topic=None):
        """Handle Meshtastic connection established"""
        self.logger.info("Meshtastic connection established")
        self._update_status(FallbackStatus.MESHTASTIC_ACTIVE)
    
    def _on_disconnect(self, interface, topic=None):
        """Handle Meshtastic connection lost"""
        self.logger.warning("Meshtastic connection lost")
        self._update_status(FallbackStatus.CHECKING_MESHTASTIC)
    
    def _update_status(self, new_status: FallbackStatus):
        """Update fallback status and notify callbacks"""
        if self.status != new_status:
            self.status = new_status
            self.logger.info(f"Status changed to: {new_status.value}")
            
            # Notify callbacks
            for callback in self.status_callbacks:
                callback(new_status)
    
    def _encode_message_for_translation(self, message: BitChatMessage) -> bytes:
        """Encode BitChat message for protocol translation"""
        # Convert message to JSON for translation layer
        message_dict = message.to_dict()
        return json.dumps(message_dict).encode('utf-8')
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        self.logger.info("Received shutdown signal, stopping bridge...")
        self.stop()
        sys.exit(0)
    
    def add_message_callback(self, callback: Callable[[bytes], None]):
        """Add callback for received messages"""
        self.message_callbacks.append(callback)
    
    def add_status_callback(self, callback: Callable[[FallbackStatus], None]):
        """Add callback for status changes"""
        self.status_callbacks.append(callback)


def main():
    """Main entry point for standalone bridge service"""
    import argparse
    
    parser = argparse.ArgumentParser(description="BitChat Meshtastic Bridge")
    parser.add_argument('--scan', action='store_true', help='Scan for devices and exit')
    parser.add_argument('--test-send', metavar='MESSAGE', help='Send test message')
    parser.add_argument('--debug', action='store_true', help='Enable debug logging')
    
    args = parser.parse_args()
    
    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)
    
    bridge = MeshtasticBridge()
    
    if args.scan:
        devices = bridge.scan_devices()
        print(f"Found {len(devices)} Meshtastic devices:")
        for device in devices:
            print(f"  {device.name} ({device.interface_type}) - {device.connection_string}")
        return
    
    if args.test_send:
        from clean_bitchat_meshtastic_types import MessageType
        
        # Create test message
        test_message = BitChatMessage(
            message_id="test_001",
            sender_id="bridge_test",
            sender_name="Bridge Test",
            content=args.test_send,
            message_type=MessageType.TEXT
        )
        
        # Start bridge and send
        if bridge.start():
            response = bridge.send_message(test_message)
            print(f"Send result: {response.success}")
            if not response.success:
                print(f"Error: {response.error_message}")
        else:
            print("Failed to start bridge")
        
        bridge.stop()
        return
    
    # Start bridge service
    print("Starting BitChat Meshtastic Bridge...")
    if bridge.start():
        print("Bridge started successfully. Press Ctrl+C to stop.")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
    else:
        print("Failed to start bridge")
    
    bridge.stop()


if __name__ == "__main__":
    main()
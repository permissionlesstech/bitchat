"""
Main Meshtastic bridge service for BitChat integration
Handles device discovery, connection management, and message routing
"""

import os
import sys
import json
import time
import signal
import threading
import subprocess
from typing import Optional, List, Dict, Any, Callable
from dataclasses import asdict

# Meshtastic imports
try:
    import meshtastic
    import meshtastic.serial_interface
    import meshtastic.tcp_interface
    import meshtastic.ble_interface
    from pubsub import pub
except ImportError as e:
    print(f"Error importing Meshtastic: {e}")
    print("Please install with: pip3 install meshtastic")
    sys.exit(1)

from bitchat_meshtastic_types import (
    MeshtasticDeviceInfo, BitChatMessage, FallbackRequest, 
    FallbackResponse, FallbackStatus, MessageType
)
from meshtastic_config import MeshtasticConfig
from protocol_translator import ProtocolTranslator

class MeshtasticBridge:
    """Bridge between BitChat and Meshtastic mesh network"""
    
    def __init__(self):
        self.config = MeshtasticConfig()
        self.translator = ProtocolTranslator()
        self.interface = None
        self.status = FallbackStatus.DISABLED
        self.available_devices: List[MeshtasticDeviceInfo] = []
        self.message_callbacks: List[Callable] = []
        self.status_callbacks: List[Callable] = []
        self.running = False
        self.last_ble_activity = time.time()
        self.fallback_active = False
        
        # Set up signal handlers
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
        
        # Subscribe to Meshtastic events
        pub.subscribe(self._on_receive, "meshtastic.receive")
        pub.subscribe(self._on_connection, "meshtastic.connection.established")
        pub.subscribe(self._on_disconnect, "meshtastic.connection.lost")
    
    def start(self):
        """Start the Meshtastic bridge service"""
        self.running = True
        
        if not self.config.is_enabled():
            self.status = FallbackStatus.DISABLED
            print("Meshtastic integration disabled")
            return
        
        print("Starting Meshtastic bridge...")
        self._update_status(FallbackStatus.CHECKING_MESHTASTIC)
        
        # Start background monitoring thread
        monitor_thread = threading.Thread(target=self._monitor_loop, daemon=True)
        monitor_thread.start()
        
        # Initial device scan
        self.scan_devices()
    
    def stop(self):
        """Stop the bridge service"""
        self.running = False
        self._disconnect_interface()
        print("Meshtastic bridge stopped")
    
    def scan_devices(self) -> List[MeshtasticDeviceInfo]:
        """Scan for available Meshtastic devices"""
        print("Scanning for Meshtastic devices...")
        self.available_devices = []
        
        # Scan serial devices
        self._scan_serial_devices()
        
        # Scan TCP devices (if configured)
        self._scan_tcp_devices()
        
        # Scan BLE devices
        self._scan_ble_devices()
        
        # Update known devices
        for device in self.available_devices:
            self.config.add_known_device(device)
        
        self.config.update_scan_timestamp()
        print(f"Found {len(self.available_devices)} Meshtastic devices")
        
        return self.available_devices
    
    def connect_device(self, device_id: Optional[str] = None) -> bool:
        """Connect to a Meshtastic device"""
        if not self.config.is_enabled():
            return False
        
        self._update_status(FallbackStatus.MESHTASTIC_CONNECTING)
        
        # Choose device to connect to
        target_device = None
        if device_id:
            target_device = next((d for d in self.available_devices if d.device_id == device_id), None)
        else:
            # Use preferred device or first available
            preferred_id = self.config.get_preferred_device()
            if preferred_id:
                target_device = next((d for d in self.available_devices if d.device_id == preferred_id), None)
            
            if not target_device and self.available_devices:
                target_device = self.available_devices[0]
        
        if not target_device:
            print("No Meshtastic device available for connection")
            self._update_status(FallbackStatus.FALLBACK_FAILED)
            return False
        
        try:
            print(f"Connecting to Meshtastic device: {target_device.name}")
            
            # Create appropriate interface
            if target_device.interface_type == "serial":
                self.interface = meshtastic.serial_interface.SerialInterface(
                    devPath=target_device.connection_string
                )
            elif target_device.interface_type == "tcp":
                hostname = target_device.connection_string
                self.interface = meshtastic.tcp_interface.TCPInterface(hostname=hostname)
            elif target_device.interface_type == "ble":
                self.interface = meshtastic.ble_interface.BLEInterface(
                    address=target_device.connection_string
                )
            else:
                print(f"Unsupported interface type: {target_device.interface_type}")
                return False
            
            # Test connection
            if self._test_connection():
                self._update_status(FallbackStatus.MESHTASTIC_ACTIVE)
                print(f"Successfully connected to {target_device.name}")
                return True
            else:
                self._disconnect_interface()
                return False
                
        except Exception as e:
            print(f"Error connecting to Meshtastic device: {e}")
            self._disconnect_interface()
            self._update_status(FallbackStatus.FALLBACK_FAILED)
            return False
    
    def send_message(self, message: BitChatMessage) -> FallbackResponse:
        """Send a message via Meshtastic"""
        if not self.interface:
            return FallbackResponse(
                success=False,
                message_id=message.message_id,
                status=self.status,
                error_message="No Meshtastic connection available"
            )
        
        try:
            # Translate message to Meshtastic format
            meshtastic_messages = self.translator.bitchat_to_meshtastic(
                self._encode_message_for_translation(message)
            )
            
            if not meshtastic_messages:
                return FallbackResponse(
                    success=False,
                    message_id=message.message_id,
                    status=self.status,
                    error_message="Message translation failed"
                )
            
            # Send all fragments
            for msg in meshtastic_messages:
                self.interface.sendData(
                    msg['payload'],
                    destinationId=meshtastic.BROADCAST_ADDR,
                    portNum=msg['portnum'],
                    wantAck=False
                )
            
            print(f"Sent message via Meshtastic: {message.content[:50]}...")
            return FallbackResponse(
                success=True,
                message_id=message.message_id,
                status=self.status
            )
            
        except Exception as e:
            print(f"Error sending message via Meshtastic: {e}")
            return FallbackResponse(
                success=False,
                message_id=message.message_id,
                status=self.status,
                error_message=str(e)
            )
    
    def check_fallback_needed(self, ble_activity_timestamp: float) -> bool:
        """Check if fallback to Meshtastic is needed"""
        if not self.config.is_enabled() or not self.config.should_auto_fallback():
            return False
        
        time_since_ble = time.time() - ble_activity_timestamp
        threshold = self.config.get_fallback_threshold()
        
        return time_since_ble > threshold
    
    def handle_fallback_request(self, request: FallbackRequest) -> FallbackResponse:
        """Handle a fallback request from BitChat"""
        print(f"Handling fallback request for message: {request.message.content[:50]}...")
        
        # Ensure we're connected
        if not self.interface:
            if not self._auto_connect():
                return FallbackResponse(
                    success=False,
                    message_id=request.message.message_id,
                    status=FallbackStatus.FALLBACK_FAILED,
                    error_message="Could not connect to Meshtastic device"
                )
        
        # Send the message
        response = self.send_message(request.message)
        
        # Handle retries
        retry_count = 0
        while not response.success and retry_count < request.max_retries:
            print(f"Retrying message send ({retry_count + 1}/{request.max_retries})")
            time.sleep(2 ** retry_count)  # Exponential backoff
            response = self.send_message(request.message)
            retry_count += 1
        
        return response
    
    def _scan_serial_devices(self):
        """Scan for serial Meshtastic devices"""
        try:
            # Common serial device paths
            serial_paths = [
                '/dev/ttyUSB0', '/dev/ttyUSB1', '/dev/ttyUSB2',
                '/dev/ttyACM0', '/dev/ttyACM1', '/dev/ttyACM2',
                '/dev/cu.usbserial-*', '/dev/cu.usbmodem*'
            ]
            
            import glob
            import serial.tools.list_ports
            
            # Use pyserial to find ports
            ports = serial.tools.list_ports.comports()
            for port in ports:
                if any(keyword in port.description.lower() for keyword in ['cp210', 'ch340', 'ftdi', 'silicon']):
                    device = MeshtasticDeviceInfo(
                        device_id=f"serial_{port.device}",
                        name=f"Meshtastic ({port.description})",
                        interface_type="serial",
                        connection_string=port.device
                    )
                    
                    if self._test_device_availability(device):
                        self.available_devices.append(device)
        
        except Exception as e:
            print(f"Error scanning serial devices: {e}")
    
    def _scan_tcp_devices(self):
        """Scan for TCP Meshtastic devices (configured IPs)"""
        # This would scan configured IP addresses
        # For now, we'll rely on manual configuration
        pass
    
    def _scan_ble_devices(self):
        """Scan for BLE Meshtastic devices"""
        try:
            # This is a simplified BLE scan
            # In practice, you'd use proper BLE scanning
            pass
        except Exception as e:
            print(f"Error scanning BLE devices: {e}")
    
    def _test_device_availability(self, device: MeshtasticDeviceInfo) -> bool:
        """Test if a device is available and responsive"""
        try:
            if device.interface_type == "serial":
                # Quick serial port test
                import serial
                with serial.Serial(device.connection_string, 115200, timeout=1) as ser:
                    return True
            return True
        except Exception:
            return False
    
    def _test_connection(self) -> bool:
        """Test the current Meshtastic connection"""
        try:
            if not self.interface:
                return False
            
            # Try to get node info
            node_info = self.interface.getMyNodeInfo()
            return node_info is not None
        except Exception as e:
            print(f"Connection test failed: {e}")
            return False
    
    def _auto_connect(self) -> bool:
        """Automatically connect to best available device"""
        if self.config.should_rescan():
            self.scan_devices()
        
        return self.connect_device()
    
    def _disconnect_interface(self):
        """Disconnect current Meshtastic interface"""
        if self.interface:
            try:
                self.interface.close()
            except Exception as e:
                print(f"Error closing interface: {e}")
            finally:
                self.interface = None
    
    def _monitor_loop(self):
        """Background monitoring loop"""
        while self.running:
            try:
                # Check if we need to initiate fallback
                if self.config.should_auto_fallback() and not self.fallback_active:
                    # This would be triggered by BLE activity monitoring
                    pass
                
                # Periodic health check
                if self.interface and not self._test_connection():
                    print("Meshtastic connection lost, attempting reconnect...")
                    self._disconnect_interface()
                    self._auto_connect()
                
                time.sleep(10)  # Check every 10 seconds
                
            except Exception as e:
                print(f"Error in monitor loop: {e}")
                time.sleep(5)
    
    def _on_receive(self, packet, interface):
        """Handle received Meshtastic message"""
        try:
            # Translate Meshtastic message back to BitChat format
            binary_data = self.translator.meshtastic_to_bitchat(packet)
            if binary_data:
                # Notify callbacks about received message
                for callback in self.message_callbacks:
                    callback(binary_data)
        except Exception as e:
            print(f"Error handling received message: {e}")
    
    def _on_connection(self, interface, topic=None):
        """Handle Meshtastic connection established"""
        print("Meshtastic connection established")
        self._update_status(FallbackStatus.MESHTASTIC_ACTIVE)
    
    def _on_disconnect(self, interface, topic=None):
        """Handle Meshtastic connection lost"""
        print("Meshtastic connection lost")
        self._update_status(FallbackStatus.FALLBACK_FAILED)
    
    def _update_status(self, new_status: FallbackStatus):
        """Update fallback status and notify callbacks"""
        if self.status != new_status:
            self.status = new_status
            for callback in self.status_callbacks:
                callback(new_status)
    
    def _encode_message_for_translation(self, message: BitChatMessage) -> bytes:
        """Encode BitChat message for protocol translation"""
        # This would use the actual BitChat binary protocol
        # For now, we'll create a simplified encoding
        return json.dumps(message.to_dict()).encode('utf-8')
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        print(f"Received signal {signum}, shutting down...")
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
    parser.add_argument("--config", help="Config file path", default="meshtastic_config.json")
    parser.add_argument("--scan", action="store_true", help="Scan for devices and exit")
    parser.add_argument("--test-send", help="Send test message")
    args = parser.parse_args()
    
    bridge = MeshtasticBridge()
    
    if args.scan:
        devices = bridge.scan_devices()
        print(f"Found {len(devices)} devices:")
        for device in devices:
            print(f"  {device.name} ({device.interface_type}): {device.connection_string}")
        return
    
    if args.test_send:
        bridge.start()
        if bridge.connect_device():
            test_msg = BitChatMessage(
                message_id="test123",
                sender_id="bridge",
                sender_name="Bridge Test",
                content=args.test_send,
                message_type=MessageType.TEXT
            )
            response = bridge.send_message(test_msg)
            print(f"Send result: {response.success}")
        bridge.stop()
        return
    
    # Start bridge service
    bridge.start()
    
    try:
        while bridge.running:
            time.sleep(1)
    except KeyboardInterrupt:
        bridge.stop()

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
BitChat Meshtastic Integration Demo

Demonstrates the key features of the integration without requiring
actual Meshtastic hardware.
"""

import time
from clean_bitchat_meshtastic_types import (
    BitChatMessage, MessageType, FallbackStatus, MeshtasticDeviceInfo
)
from clean_meshtastic_config import MeshtasticConfig
from clean_protocol_translator import ProtocolTranslator


def demo_type_system():
    """Demonstrate the type system and message structures"""
    print("=== BitChat Message Types Demo ===")
    
    # Create sample message
    message = BitChatMessage(
        message_id="demo_001",
        sender_id="user_123",
        sender_name="Demo User",
        content="Hello from BitChat via LoRa mesh!",
        message_type=MessageType.TEXT,
        channel="general"
    )
    
    print(f"Message: {message.content}")
    print(f"Type: {message.message_type.name}")
    print(f"JSON: {message.to_dict()}")
    
    # Show device info structure
    device = MeshtasticDeviceInfo(
        device_id="serial_/dev/ttyUSB0",
        name="T-Beam Device",
        interface_type="serial",
        connection_string="/dev/ttyUSB0",
        signal_strength=-85,
        battery_level=78
    )
    
    print(f"\nDevice: {device.name}")
    print(f"Type: {device.interface_type}")
    print(f"Signal: {device.signal_strength}dBm")


def demo_protocol_translation():
    """Demonstrate message protocol translation"""
    print("\n=== Protocol Translation Demo ===")
    
    translator = ProtocolTranslator()
    
    # Create test message
    message = BitChatMessage(
        message_id="translate_001",
        sender_id="user_456",
        sender_name="Protocol Tester",
        content="Testing BitChat to Meshtastic translation",
        message_type=MessageType.TEXT
    )
    
    # Simulate BitChat binary encoding
    import json
    binary_data = json.dumps(message.to_dict()).encode('utf-8')
    
    # Translate to Meshtastic format
    mesh_messages = translator.bitchat_to_meshtastic(binary_data)
    
    print(f"Original message: {message.content}")
    print(f"Meshtastic fragments: {len(mesh_messages)}")
    
    for i, fragment in enumerate(mesh_messages):
        print(f"  Fragment {i}: {len(fragment['payload'])} bytes")
    
    # Test large message fragmentation
    large_message = BitChatMessage(
        message_id="large_001",
        sender_id="user_789",
        sender_name="Large Message Sender",
        content="A" * 500,  # Large content that requires fragmentation
        message_type=MessageType.TEXT
    )
    
    large_binary = json.dumps(large_message.to_dict()).encode('utf-8')
    large_fragments = translator.bitchat_to_meshtastic(large_binary)
    
    print(f"\nLarge message ({len(large_message.content)} chars)")
    print(f"Fragments needed: {len(large_fragments)}")


def demo_configuration():
    """Demonstrate configuration management"""
    print("\n=== Configuration Management Demo ===")
    
    config = MeshtasticConfig("demo_config.json")
    
    # Show default state
    print(f"Enabled: {config.is_enabled()}")
    print(f"User consent: {config.get_user_consent()}")
    print(f"Auto fallback: {config.should_auto_fallback()}")
    
    # Simulate user enabling the feature
    print("\nSimulating user consent...")
    config.set_user_consent(True)
    
    print(f"After consent - Enabled: {config.is_enabled()}")
    print(f"Fallback threshold: {config.get_fallback_threshold()}s")
    
    # Add mock devices
    device1 = MeshtasticDeviceInfo(
        device_id="serial_001",
        name="USB T-Beam",
        interface_type="serial",
        connection_string="/dev/ttyUSB0"
    )
    
    device2 = MeshtasticDeviceInfo(
        device_id="tcp_001", 
        name="WiFi Heltec",
        interface_type="tcp",
        connection_string="192.168.1.100:4403"
    )
    
    config.add_known_device(device1)
    config.add_known_device(device2)
    
    print(f"Known devices: {len(config.get_known_devices())}")
    for device in config.get_known_devices():
        print(f"  {device.name} ({device.interface_type})")


def demo_fallback_logic():
    """Demonstrate fallback activation logic"""
    print("\n=== Fallback Logic Demo ===")
    
    config = MeshtasticConfig()
    config.set_user_consent(True)  # Enable for demo
    
    # Simulate BLE activity timestamps
    current_time = time.time()
    recent_activity = current_time - 10    # 10 seconds ago
    old_activity = current_time - 60       # 60 seconds ago
    
    print(f"BLE activity 10s ago: Fallback needed? {config.get_fallback_threshold() < 10}")
    print(f"BLE activity 60s ago: Fallback needed? {config.get_fallback_threshold() < 60}")
    
    # Show status progression
    statuses = [
        FallbackStatus.BLE_ACTIVE,
        FallbackStatus.CHECKING_MESHTASTIC,
        FallbackStatus.MESHTASTIC_CONNECTING,
        FallbackStatus.MESHTASTIC_ACTIVE
    ]
    
    print("\nFallback status progression:")
    for status in statuses:
        print(f"  {status.value}")


def demo_complete_flow():
    """Demonstrate complete message flow"""
    print("\n=== Complete Message Flow Demo ===")
    
    # Step 1: BitChat creates message
    message = BitChatMessage(
        message_id="flow_001",
        sender_id="alice",
        sender_name="Alice",
        content="Emergency: Road blocked on Highway 101",
        message_type=MessageType.TEXT,
        channel="emergency"
    )
    
    print(f"1. BitChat message created: {message.content}")
    
    # Step 2: BLE fails, trigger fallback
    print("2. BLE mesh has no available hops")
    print("3. Automatic fallback to Meshtastic triggered")
    
    # Step 3: Protocol translation
    translator = ProtocolTranslator()
    binary_data = json.dumps(message.to_dict()).encode('utf-8')
    mesh_fragments = translator.bitchat_to_meshtastic(binary_data)
    
    print(f"4. Message translated to {len(mesh_fragments)} Meshtastic fragments")
    
    # Step 4: LoRa transmission (simulated)
    print("5. Fragments transmitted via LoRa mesh network")
    for i, fragment in enumerate(mesh_fragments):
        print(f"   Fragment {i}: {len(fragment['payload'])} bytes on port {fragment['port']}")
    
    # Step 5: Distant node receives and reconstructs
    print("6. Distant Meshtastic node receives fragments")
    print("7. Message reconstructed and delivered to BitChat")
    print("8. Emergency message delivered across 50km range!")


def main():
    """Run all demonstrations"""
    print("BitChat Meshtastic Integration Demo")
    print("=" * 50)
    
    try:
        demo_type_system()
        demo_protocol_translation()
        demo_configuration()
        demo_fallback_logic()
        demo_complete_flow()
        
        print("\n" + "=" * 50)
        print("Demo completed successfully!")
        print("\nThis integration enables BitChat to:")
        print("• Automatically detect when BLE mesh fails")
        print("• Seamlessly switch to LoRa mesh networking")
        print("• Extend range from 100m to 10-50km")
        print("• Maintain privacy with opt-in user consent")
        print("• Handle message fragmentation transparently")
        print("• Provide emergency communication capabilities")
        
    except Exception as e:
        print(f"Demo error: {e}")
        return 1
    
    return 0


if __name__ == "__main__":
    exit(main())
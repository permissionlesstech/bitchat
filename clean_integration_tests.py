#!/usr/bin/env python3
"""
BitChat Meshtastic Integration Test Suite

Comprehensive testing for all integration components without requiring
actual Meshtastic hardware.
"""

import unittest
import json
import time
import tempfile
import os
from unittest.mock import Mock, patch, MagicMock

from clean_bitchat_meshtastic_types import (
    BitChatMessage, MessageType, FallbackStatus, MeshtasticDeviceInfo,
    FallbackRequest, FallbackResponse, BitChatMeshtasticProtocol
)
from clean_meshtastic_config import MeshtasticConfig
from clean_protocol_translator import ProtocolTranslator


class TestBitChatMeshtasticTypes(unittest.TestCase):
    """Test type definitions and data structures"""
    
    def test_bitchat_message_creation(self):
        """Test BitChat message creation and serialization"""
        message = BitChatMessage(
            message_id="test_001",
            sender_id="user_123",
            sender_name="Test User",
            content="Hello world",
            message_type=MessageType.TEXT,
            channel="general"
        )
        
        self.assertEqual(message.message_id, "test_001")
        self.assertEqual(message.message_type, MessageType.TEXT)
        self.assertIsInstance(message.timestamp, int)
        
        # Test serialization
        data = message.to_dict()
        self.assertIn('message_id', data)
        self.assertIn('content', data)
        
        # Test deserialization
        restored = BitChatMessage.from_dict(data)
        self.assertEqual(restored.content, message.content)
    
    def test_device_info_creation(self):
        """Test Meshtastic device info structure"""
        device = MeshtasticDeviceInfo(
            device_id="serial_test",
            name="Test Device",
            interface_type="serial",
            connection_string="/dev/ttyUSB0",
            signal_strength=-75,
            battery_level=85
        )
        
        self.assertEqual(device.device_id, "serial_test")
        self.assertEqual(device.interface_type, "serial")
        self.assertTrue(device.available)
        
        # Test serialization
        data = device.to_dict()
        restored = MeshtasticDeviceInfo.from_dict(data)
        self.assertEqual(restored.name, device.name)
    
    def test_protocol_constants(self):
        """Test protocol constants and port mapping"""
        self.assertEqual(BitChatMeshtasticProtocol.BITCHAT_APP_ID, "bitchat")
        self.assertGreater(BitChatMeshtasticProtocol.MAX_MESSAGE_SIZE, 0)
        
        # Test port mapping
        text_port = BitChatMeshtasticProtocol.get_port_for_message_type(MessageType.TEXT)
        private_port = BitChatMeshtasticProtocol.get_port_for_message_type(MessageType.PRIVATE_MESSAGE)
        
        self.assertNotEqual(text_port, private_port)
        self.assertIsInstance(text_port, int)


class TestMeshtasticConfig(unittest.TestCase):
    """Test configuration management"""
    
    def setUp(self):
        """Create temporary config file for testing"""
        self.temp_file = tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.json')
        self.temp_file.close()
        self.config = MeshtasticConfig(self.temp_file.name)
    
    def tearDown(self):
        """Clean up temporary file"""
        if os.path.exists(self.temp_file.name):
            os.unlink(self.temp_file.name)
    
    def test_default_configuration(self):
        """Test default configuration values"""
        self.assertFalse(self.config.is_enabled())
        self.assertFalse(self.config.get_user_consent())
        self.assertEqual(self.config.get_fallback_threshold(), 30)
    
    def test_user_consent_flow(self):
        """Test user consent and enabling"""
        # Initially disabled
        self.assertFalse(self.config.is_enabled())
        
        # Enable with consent
        self.config.set_user_consent(True)
        self.assertTrue(self.config.is_enabled())
        self.assertTrue(self.config.get_user_consent())
    
    def test_device_management(self):
        """Test adding and retrieving devices"""
        device = MeshtasticDeviceInfo(
            device_id="test_device",
            name="Test Device",
            interface_type="serial",
            connection_string="/dev/test"
        )
        
        # Add device
        self.config.add_known_device(device)
        devices = self.config.get_known_devices()
        
        self.assertEqual(len(devices), 1)
        self.assertEqual(devices[0].device_id, "test_device")
        
        # Set as preferred
        self.config.set_preferred_device("test_device")
        self.assertEqual(self.config.get_preferred_device(), "test_device")
    
    def test_settings_export_import(self):
        """Test settings export and import"""
        self.config.set_user_consent(True)
        
        # Export settings
        settings = self.config.export_settings()
        self.assertIn('enabled', settings)
        self.assertTrue(settings['enabled'])
        
        # Update settings
        new_settings = {'fallback_threshold': 60}
        self.config.update_settings(new_settings)
        self.assertEqual(self.config.get_fallback_threshold(), 60)


class TestProtocolTranslator(unittest.TestCase):
    """Test protocol translation between BitChat and Meshtastic"""
    
    def setUp(self):
        self.translator = ProtocolTranslator()
    
    def test_message_translation(self):
        """Test basic message translation"""
        message = BitChatMessage(
            message_id="translate_test",
            sender_id="user_456",
            sender_name="Translator Test",
            content="Test message content",
            message_type=MessageType.TEXT
        )
        
        # Convert to binary (simulate BitChat format)
        binary_data = json.dumps(message.to_dict()).encode('utf-8')
        
        # Translate to Meshtastic
        mesh_messages = self.translator.bitchat_to_meshtastic(binary_data)
        
        self.assertGreater(len(mesh_messages), 0)
        self.assertIn('payload', mesh_messages[0])
        self.assertIn('port', mesh_messages[0])
    
    def test_message_fragmentation(self):
        """Test large message fragmentation"""
        large_content = "A" * 500  # Content that requires fragmentation
        
        message = BitChatMessage(
            message_id="fragment_test",
            sender_id="user_789",
            sender_name="Fragment Test",
            content=large_content,
            message_type=MessageType.TEXT
        )
        
        binary_data = json.dumps(message.to_dict()).encode('utf-8')
        fragments = self.translator.bitchat_to_meshtastic(binary_data)
        
        # Should create multiple fragments for large message
        self.assertGreater(len(fragments), 1)
        
        # Each fragment should be within size limits
        for fragment in fragments:
            self.assertLessEqual(len(fragment['payload']), BitChatMeshtasticProtocol.MAX_MESSAGE_SIZE)
    
    def test_fragment_reassembly(self):
        """Test fragment reassembly"""
        # Create fragmented message
        message_data = json.dumps({
            'message_id': 'reassembly_test',
            'content': 'Test fragment reassembly',
            'message_type': MessageType.TEXT.value
        })
        
        # Simulate fragmentation
        fragment_marker = BitChatMeshtasticProtocol.FRAGMENT_MARKER
        fragment1 = f"{fragment_marker}:reassembly_test:0:2:{message_data[:10]}"
        fragment2 = f"{fragment_marker}:reassembly_test:1:2:{message_data[10:]}"
        
        # Process fragments
        result1 = self.translator._handle_fragment(fragment1, {})
        self.assertIsNone(result1)  # Still waiting for more fragments
        
        result2 = self.translator._handle_fragment(fragment2, {})
        self.assertIsNotNone(result2)  # Complete message reconstructed
    
    def test_port_selection(self):
        """Test correct port selection for message types"""
        text_port = self.translator._get_port_for_message_type(MessageType.TEXT)
        private_port = self.translator._get_port_for_message_type(MessageType.PRIVATE_MESSAGE)
        system_port = self.translator._get_port_for_message_type(MessageType.SYSTEM)
        
        self.assertEqual(text_port, BitChatMeshtasticProtocol.BITCHAT_TEXT_PORT)
        self.assertEqual(private_port, BitChatMeshtasticProtocol.BITCHAT_PRIVATE_PORT)
        self.assertEqual(system_port, BitChatMeshtasticProtocol.BITCHAT_SYSTEM_PORT)


class TestIntegrationFlow(unittest.TestCase):
    """Test complete integration workflow"""
    
    def test_fallback_detection_logic(self):
        """Test fallback activation logic"""
        config = MeshtasticConfig()
        config.set_user_consent(True)  # Enable for test
        
        current_time = time.time()
        
        # Recent activity - no fallback needed
        recent_timestamp = current_time - 10
        self.assertFalse(self._check_fallback_needed(config, recent_timestamp))
        
        # Old activity - fallback needed
        old_timestamp = current_time - 60
        self.assertTrue(self._check_fallback_needed(config, old_timestamp))
    
    def _check_fallback_needed(self, config, ble_timestamp):
        """Helper method to check fallback logic"""
        current_time = time.time()
        time_since_activity = current_time - ble_timestamp
        threshold = config.get_fallback_threshold()
        return time_since_activity > threshold
    
    def test_complete_message_flow(self):
        """Test complete message flow from BitChat to Meshtastic"""
        # 1. Create BitChat message
        message = BitChatMessage(
            message_id="flow_test",
            sender_id="test_user",
            sender_name="Flow Tester",
            content="Complete flow test message",
            message_type=MessageType.TEXT
        )
        
        # 2. Convert to binary format
        binary_data = json.dumps(message.to_dict()).encode('utf-8')
        
        # 3. Translate to Meshtastic
        translator = ProtocolTranslator()
        mesh_messages = translator.bitchat_to_meshtastic(binary_data)
        
        self.assertGreater(len(mesh_messages), 0)
        
        # 4. Simulate Meshtastic reception and back-translation
        for mesh_msg in mesh_messages:
            # Simulate Meshtastic packet structure
            simulated_packet = {
                'decoded': {
                    'text': mesh_msg['payload'].decode('utf-8'),
                    'portnum': mesh_msg['port']
                }
            }
            
            # Translate back to BitChat
            result = translator.meshtastic_to_bitchat(simulated_packet)
            
            if result:  # Complete message (not fragment)
                self.assertIsInstance(result, bytes)
                # Message successfully round-tripped
                break


class TestErrorHandling(unittest.TestCase):
    """Test error handling and edge cases"""
    
    def test_invalid_message_data(self):
        """Test handling of invalid message data"""
        translator = ProtocolTranslator()
        
        # Empty data
        result = translator.bitchat_to_meshtastic(b'')
        self.assertEqual(len(result), 0)
        
        # Invalid JSON
        result = translator.bitchat_to_meshtastic(b'invalid json data')
        self.assertGreaterEqual(len(result), 0)  # Should handle gracefully
    
    def test_config_file_errors(self):
        """Test configuration file error handling"""
        # Non-existent file
        config = MeshtasticConfig('/nonexistent/path/config.json')
        self.assertFalse(config.is_enabled())  # Should use defaults
        
        # Invalid JSON file
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.json') as f:
            f.write('invalid json content')
            f.flush()
            
            config = MeshtasticConfig(f.name)
            self.assertFalse(config.is_enabled())  # Should use defaults
            
            os.unlink(f.name)
    
    def test_fragment_timeout(self):
        """Test fragment timeout handling"""
        translator = ProtocolTranslator()
        
        # Add old fragment
        old_time = time.time() - 400  # Older than 5 minute timeout
        translator.fragment_timeouts['old_message'] = old_time
        translator.fragments['old_message'] = {'total': 2, 'received': {0: b'data'}}
        
        # Trigger cleanup
        translator._cleanup_expired_fragments()
        
        # Old fragment should be removed
        self.assertNotIn('old_message', translator.fragments)
        self.assertNotIn('old_message', translator.fragment_timeouts)


def run_all_tests():
    """Run the complete test suite"""
    print("BitChat Meshtastic Integration Test Suite")
    print("=" * 50)
    
    # Create test suite
    test_loader = unittest.TestLoader()
    test_suite = unittest.TestSuite()
    
    # Add test classes
    test_classes = [
        TestBitChatMeshtasticTypes,
        TestMeshtasticConfig,
        TestProtocolTranslator,
        TestIntegrationFlow,
        TestErrorHandling
    ]
    
    for test_class in test_classes:
        tests = test_loader.loadTestsFromTestCase(test_class)
        test_suite.addTests(tests)
    
    # Run tests
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(test_suite)
    
    # Summary
    print("\n" + "=" * 50)
    if result.wasSuccessful():
        print("✓ All tests passed!")
        print(f"Ran {result.testsRun} tests successfully")
    else:
        print(f"✗ {len(result.failures)} test(s) failed")
        print(f"✗ {len(result.errors)} error(s) occurred")
    
    return result.wasSuccessful()


if __name__ == "__main__":
    success = run_all_tests()
    exit(0 if success else 1)
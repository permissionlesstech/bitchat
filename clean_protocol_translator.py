"""
Protocol Translator for BitChat-Meshtastic Integration

Handles message format conversion and fragmentation between BitChat's binary protocol
and Meshtastic's protobuf format, ensuring seamless communication across mesh networks.
"""

import json
import struct
import hashlib
from typing import List, Dict, Any, Optional
import time

from clean_bitchat_meshtastic_types import (
    BitChatMessage, MessageType, BitChatMeshtasticProtocol
)


class ProtocolTranslator:
    """Translates between BitChat binary protocol and Meshtastic protobuf"""
    
    def __init__(self):
        # Fragment storage for message reassembly
        self.fragments: Dict[str, Dict[str, Any]] = {}
        self.fragment_timeouts: Dict[str, float] = {}
        self.fragment_timeout = 300  # 5 minutes
    
    def bitchat_to_meshtastic(self, binary_data: bytes) -> List[Dict[str, Any]]:
        """
        Convert BitChat binary message to Meshtastic-compatible format
        Returns list of message fragments if message is too large
        """
        try:
            # Parse BitChat binary format
            message = self._parse_bitchat_binary(binary_data)
            
            # Convert to JSON for Meshtastic transmission
            message_dict = message.to_dict()
            json_data = json.dumps(message_dict, separators=(',', ':'))
            
            # Check if fragmentation is needed
            if len(json_data.encode('utf-8')) <= BitChatMeshtasticProtocol.MAX_MESSAGE_SIZE:
                # Single message
                return [{
                    'payload': json_data.encode('utf-8'),
                    'port': self._get_port_for_message_type(message.message_type),
                    'want_ack': True,
                    'destination': 0xFFFFFFFF,  # Broadcast
                    'channel': 0
                }]
            else:
                # Fragment large message
                return self._fragment_message(json_data, message.message_id)
        
        except Exception as e:
            print(f"BitChat to Meshtastic conversion error: {e}")
            return []
    
    def meshtastic_to_bitchat(self, meshtastic_data: Dict[str, Any]) -> Optional[bytes]:
        """
        Convert Meshtastic message back to BitChat binary format
        Handles message defragmentation
        """
        try:
            # Extract payload from Meshtastic packet
            if 'decoded' not in meshtastic_data:
                return None
            
            decoded = meshtastic_data['decoded']
            if 'text' not in decoded:
                return None
            
            text_data = decoded['text']
            
            # Check if this is a fragment
            if text_data.startswith(BitChatMeshtasticProtocol.FRAGMENT_MARKER):
                return self._handle_fragment(text_data, meshtastic_data)
            
            # Parse complete message
            try:
                message_dict = json.loads(text_data)
                message = BitChatMessage.from_dict(message_dict)
                return self._encode_bitchat_binary(message)
            except json.JSONDecodeError:
                return None
        
        except Exception as e:
            print(f"Meshtastic to BitChat conversion error: {e}")
            return None
    
    def _parse_bitchat_binary(self, data: bytes) -> BitChatMessage:
        """Parse BitChat's binary protocol format"""
        # This is a simplified parser - adjust based on actual BitChat binary format
        
        if len(data) < 16:
            raise ValueError("Invalid BitChat binary data - too short")
        
        # Basic binary format parsing (example structure)
        # Adjust this based on BitChat's actual binary protocol
        
        try:
            # Parse header (first 16 bytes)
            header = struct.unpack('<4I', data[:16])
            message_type_int = header[0]
            timestamp = header[1]
            content_length = header[2]
            flags = header[3]
            
            # Parse strings from remaining data
            string_data = data[16:].decode('utf-8', errors='ignore')
            parts = string_data.split('\0')  # Null-terminated strings
            
            if len(parts) < 4:
                raise ValueError("Insufficient string data in binary format")
            
            message_id = parts[0]
            sender_id = parts[1]
            sender_name = parts[2]
            content = parts[3]
            channel = parts[4] if len(parts) > 4 else None
            
            # Create BitChat message
            return BitChatMessage(
                message_id=message_id,
                sender_id=sender_id,
                sender_name=sender_name,
                content=content,
                message_type=MessageType(message_type_int % len(MessageType)),
                channel=channel,
                timestamp=timestamp,
                encrypted=bool(flags & 0x01)
            )
        
        except Exception:
            # Fallback: create message from raw data
            content = data.decode('utf-8', errors='ignore')[:100]
            return BitChatMessage(
                message_id=f"parsed_{int(time.time())}",
                sender_id="unknown",
                sender_name="Unknown",
                content=content,
                message_type=MessageType.TEXT,
                timestamp=int(time.time())
            )
    
    def _encode_bitchat_binary(self, message: BitChatMessage) -> bytes:
        """Encode message back to BitChat binary format"""
        # This should match BitChat's actual binary protocol
        
        try:
            # Prepare strings
            strings = [
                message.message_id,
                message.sender_id,
                message.sender_name,
                message.content,
                message.channel or ""
            ]
            
            # Join with null terminators
            string_data = '\0'.join(strings).encode('utf-8')
            
            # Create header
            flags = 0x01 if message.encrypted else 0x00
            header = struct.pack('<4I', 
                message.message_type.value,
                message.timestamp or int(time.time()),
                len(message.content),
                flags
            )
            
            return header + string_data
        
        except Exception:
            # Fallback: simple encoding
            message_dict = message.to_dict()
            return json.dumps(message_dict).encode('utf-8')
    
    def _fragment_message(self, json_data: str, message_id: str) -> List[Dict[str, Any]]:
        """Fragment large messages for Meshtastic transmission"""
        data_bytes = json_data.encode('utf-8')
        fragment_size = BitChatMeshtasticProtocol.MAX_FRAGMENT_SIZE
        
        # Calculate number of fragments needed
        total_fragments = (len(data_bytes) + fragment_size - 1) // fragment_size
        
        fragments = []
        for i in range(total_fragments):
            start = i * fragment_size
            end = min(start + fragment_size, len(data_bytes))
            chunk = data_bytes[start:end]
            
            # Create fragment header
            fragment_header = f"{BitChatMeshtasticProtocol.FRAGMENT_MARKER}:{message_id}:{i}:{total_fragments}:"
            fragment_payload = fragment_header.encode('utf-8') + chunk
            
            fragments.append({
                'payload': fragment_payload,
                'port': BitChatMeshtasticProtocol.BITCHAT_TEXT_PORT,
                'want_ack': True,
                'destination': 0xFFFFFFFF,  # Broadcast
                'channel': 0
            })
        
        return fragments
    
    def _handle_fragment(self, fragment_str: str, meshtastic_data: Dict[str, Any]) -> Optional[bytes]:
        """Handle incoming message fragment"""
        try:
            # Parse fragment header
            if not fragment_str.startswith(BitChatMeshtasticProtocol.FRAGMENT_MARKER + ":"):
                return None
            
            header_end = fragment_str.find(":", len(BitChatMeshtasticProtocol.FRAGMENT_MARKER) + 1)
            if header_end == -1:
                return None
            
            # Extract header components
            header_parts = fragment_str[len(BitChatMeshtasticProtocol.FRAGMENT_MARKER) + 1:].split(":", 3)
            if len(header_parts) < 4:
                return None
            
            message_id = header_parts[0]
            fragment_index = int(header_parts[1])
            total_fragments = int(header_parts[2])
            
            # Extract fragment data
            data_start = len(BitChatMeshtasticProtocol.FRAGMENT_MARKER) + 1 + len(":".join(header_parts[:3])) + 1
            fragment_data = fragment_str[data_start:].encode('utf-8')
            
            # Store fragment
            if message_id not in self.fragments:
                self.fragments[message_id] = {
                    'total': total_fragments,
                    'received': {},
                    'timestamp': time.time()
                }
            
            self.fragments[message_id]['received'][fragment_index] = fragment_data
            self.fragment_timeouts[message_id] = time.time()
            
            # Check if we have all fragments
            fragment_info = self.fragments[message_id]
            if len(fragment_info['received']) == fragment_info['total']:
                # Reassemble message
                complete_data = b''
                for i in range(fragment_info['total']):
                    if i in fragment_info['received']:
                        complete_data += fragment_info['received'][i]
                
                # Clean up
                del self.fragments[message_id]
                del self.fragment_timeouts[message_id]
                
                # Parse complete message
                try:
                    message_dict = json.loads(complete_data.decode('utf-8'))
                    message = BitChatMessage.from_dict(message_dict)
                    return self._encode_bitchat_binary(message)
                except json.JSONDecodeError:
                    return None
            
            # Clean up expired fragments
            self._cleanup_expired_fragments()
            
            return None  # Still waiting for more fragments
        
        except Exception as e:
            print(f"Fragment handling error: {e}")
            return None
    
    def _cleanup_expired_fragments(self):
        """Clean up expired fragments"""
        current_time = time.time()
        expired_ids = []
        
        for message_id, timestamp in self.fragment_timeouts.items():
            if current_time - timestamp > self.fragment_timeout:
                expired_ids.append(message_id)
        
        for message_id in expired_ids:
            if message_id in self.fragments:
                del self.fragments[message_id]
            if message_id in self.fragment_timeouts:
                del self.fragment_timeouts[message_id]
    
    def _get_port_for_message_type(self, message_type: MessageType) -> int:
        """Get appropriate Meshtastic port for message type"""
        return BitChatMeshtasticProtocol.get_port_for_message_type(message_type)
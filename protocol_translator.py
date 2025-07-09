"""
Protocol translator between BitChat binary format and Meshtastic protobuf
Handles message format conversion and fragmentation for size limits
"""

import json
import struct
import time
import hashlib
import uuid
from typing import List, Tuple, Optional, Dict, Any
from bitchat_meshtastic_types import (
    BitChatMessage, MessageType, BitChatMeshtasticProtocol
)

class ProtocolTranslator:
    """Translates between BitChat binary protocol and Meshtastic protobuf"""
    
    def __init__(self):
        self.fragment_cache: Dict[str, List[Tuple[int, str]]] = {}
        self.protocol = BitChatMeshtasticProtocol()
    
    def bitchat_to_meshtastic(self, binary_data: bytes) -> List[Dict[str, Any]]:
        """
        Convert BitChat binary message to Meshtastic-compatible format
        Returns list of message fragments if message is too large
        """
        try:
            # Parse BitChat binary format (simplified based on BitChat's BinaryProtocol)
            message = self._parse_bitchat_binary(binary_data)
            
            # Convert to JSON for Meshtastic transmission
            json_data = json.dumps(message.to_dict())
            
            # Fragment if necessary
            if len(json_data.encode('utf-8')) > self.protocol.MAX_MESSAGE_SIZE:
                return self._fragment_message(json_data, message.message_id)
            else:
                return [{
                    'portnum': self._get_port_for_message_type(message.message_type),
                    'payload': json_data.encode('utf-8'),
                    'id': int(message.message_id, 16) & 0xFFFFFFFF,
                    'hop_limit': message.ttl
                }]
                
        except Exception as e:
            print(f"Error translating BitChat to Meshtastic: {e}")
            return []
    
    def meshtastic_to_bitchat(self, meshtastic_data: Dict[str, Any]) -> Optional[bytes]:
        """
        Convert Meshtastic message back to BitChat binary format
        Handles message defragmentation
        """
        try:
            payload = meshtastic_data.get('decoded', {}).get('payload', b'')
            if isinstance(payload, bytes):
                json_str = payload.decode('utf-8')
            else:
                json_str = str(payload)
            
            # Check if this is a fragment
            if json_str.startswith(self.protocol.FRAGMENT_MARKER):
                return self._handle_fragment(json_str, meshtastic_data)
            
            # Parse complete message
            message_data = json.loads(json_str)
            message = BitChatMessage.from_dict(message_data)
            
            # Convert back to BitChat binary format
            return self._encode_bitchat_binary(message)
            
        except Exception as e:
            print(f"Error translating Meshtastic to BitChat: {e}")
            return None
    
    def _parse_bitchat_binary(self, data: bytes) -> BitChatMessage:
        """Parse BitChat's binary protocol format"""
        if len(data) < 13:  # Minimum header size based on BitChat protocol
            raise ValueError("Invalid BitChat binary data")
        
        # BitChat binary format (simplified):
        # [type:1][id:4][sender:4][ttl:1][timestamp:4][payload_len:1][payload:var]
        message_type = MessageType(data[0])
        message_id = str(struct.unpack('>I', data[1:5])[0])
        sender_id = str(struct.unpack('>I', data[5:9])[0])
        ttl = data[9]
        timestamp = struct.unpack('>I', data[10:14])[0] if len(data) >= 14 else int(time.time())
        
        if len(data) > 14:
            payload_len = data[14] if len(data) > 14 else 0
            payload = data[15:15+payload_len].decode('utf-8', errors='ignore')
        else:
            payload = ""
        
        # Extract sender name and content from payload
        if '\x00' in payload:
            parts = payload.split('\x00', 2)
            sender_name = parts[0] if len(parts) > 0 else f"user_{sender_id}"
            content = parts[1] if len(parts) > 1 else ""
            channel = parts[2] if len(parts) > 2 else None
        else:
            sender_name = f"user_{sender_id}"
            content = payload
            channel = None
        
        return BitChatMessage(
            message_id=message_id,
            sender_id=sender_id,
            sender_name=sender_name,
            content=content,
            message_type=message_type,
            channel=channel,
            timestamp=timestamp,
            ttl=ttl
        )
    
    def _encode_bitchat_binary(self, message: BitChatMessage) -> bytes:
        """Encode message back to BitChat binary format"""
        # Reconstruct payload
        payload_parts = [message.sender_name, message.content]
        if message.channel:
            payload_parts.append(message.channel)
        payload = '\x00'.join(payload_parts).encode('utf-8')
        
        # Build binary packet
        packet = bytearray()
        packet.append(message.message_type.value)
        packet.extend(struct.pack('>I', int(message.message_id) & 0xFFFFFFFF))
        packet.extend(struct.pack('>I', int(message.sender_id) & 0xFFFFFFFF))
        packet.append(message.ttl)
        packet.extend(struct.pack('>I', message.timestamp or int(time.time())))
        packet.append(min(len(payload), 255))
        packet.extend(payload[:255])
        
        return bytes(packet)
    
    def _fragment_message(self, json_data: str, message_id: str) -> List[Dict[str, Any]]:
        """Fragment large messages for Meshtastic transmission"""
        fragments = []
        data_bytes = json_data.encode('utf-8')
        fragment_size = self.protocol.MAX_MESSAGE_SIZE - 50  # Leave room for fragment header
        
        total_fragments = (len(data_bytes) + fragment_size - 1) // fragment_size
        
        for i in range(total_fragments):
            start = i * fragment_size
            end = min(start + fragment_size, len(data_bytes))
            fragment_data = data_bytes[start:end]
            
            # Create fragment header
            fragment_header = f"{self.protocol.FRAGMENT_MARKER}:{message_id}:{i}:{total_fragments}:"
            fragment_payload = fragment_header.encode('utf-8') + fragment_data
            
            fragments.append({
                'portnum': self.protocol.BITCHAT_SYSTEM_PORT,
                'payload': fragment_payload,
                'id': (int(message_id, 16) + i) & 0xFFFFFFFF,
                'hop_limit': 7
            })
        
        return fragments
    
    def _handle_fragment(self, fragment_str: str, meshtastic_data: Dict[str, Any]) -> Optional[bytes]:
        """Handle incoming message fragment"""
        try:
            # Parse fragment header
            parts = fragment_str.split(':', 4)
            if len(parts) < 5:
                return None
            
            marker, message_id, fragment_num, total_fragments = parts[:4]
            fragment_data = parts[4]
            
            fragment_num = int(fragment_num)
            total_fragments = int(total_fragments)
            
            # Store fragment
            if message_id not in self.fragment_cache:
                self.fragment_cache[message_id] = []
            
            self.fragment_cache[message_id].append((fragment_num, fragment_data))
            
            # Check if we have all fragments
            if len(self.fragment_cache[message_id]) == total_fragments:
                # Reconstruct message
                sorted_fragments = sorted(self.fragment_cache[message_id])
                complete_json = ''.join([frag[1] for frag in sorted_fragments])
                
                # Clean up cache
                del self.fragment_cache[message_id]
                
                # Parse reconstructed message
                message_data = json.loads(complete_json)
                message = BitChatMessage.from_dict(message_data)
                return self._encode_bitchat_binary(message)
            
            return None  # Wait for more fragments
            
        except Exception as e:
            print(f"Error handling fragment: {e}")
            return None
    
    def _get_port_for_message_type(self, message_type: MessageType) -> int:
        """Get appropriate Meshtastic port for message type"""
        if message_type == MessageType.PRIVATE_MESSAGE:
            return self.protocol.BITCHAT_PRIVATE_PORT
        elif message_type in [MessageType.SYSTEM, MessageType.CHANNEL_JOIN, MessageType.CHANNEL_LEAVE]:
            return self.protocol.BITCHAT_SYSTEM_PORT
        else:
            return self.protocol.BITCHAT_TEXT_PORT

"""
BitChat-Meshtastic type definitions and constants
Defines the data structures used for communication between BitChat and Meshtastic
"""

from dataclasses import dataclass
from typing import Optional, List, Dict, Any
from enum import Enum
import json

class MessageType(Enum):
    """BitChat message types that can be transmitted via Meshtastic"""
    TEXT = 0
    PRIVATE_MESSAGE = 1
    CHANNEL_JOIN = 2
    CHANNEL_LEAVE = 3
    USER_INFO = 4
    SYSTEM = 5
    ENCRYPTED = 6

class FallbackStatus(Enum):
    """Status of the fallback system"""
    DISABLED = "disabled"
    BLE_ACTIVE = "ble_active"
    CHECKING_MESHTASTIC = "checking_meshtastic"
    MESHTASTIC_CONNECTING = "meshtastic_connecting"
    MESHTASTIC_ACTIVE = "meshtastic_active"
    SEARCHING_TOWERS = "searching_towers"
    FALLBACK_FAILED = "fallback_failed"

@dataclass
class BitChatMessage:
    """BitChat message structure for Meshtastic translation"""
    message_id: str
    sender_id: str
    sender_name: str
    content: str
    message_type: MessageType
    channel: Optional[str] = None
    timestamp: Optional[int] = None
    ttl: int = 7
    encrypted: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'message_id': self.message_id,
            'sender_id': self.sender_id,
            'sender_name': self.sender_name,
            'content': self.content,
            'message_type': self.message_type.value,
            'channel': self.channel,
            'timestamp': self.timestamp,
            'ttl': self.ttl,
            'encrypted': self.encrypted
        }
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'BitChatMessage':
        return cls(
            message_id=data['message_id'],
            sender_id=data['sender_id'],
            sender_name=data['sender_name'],
            content=data['content'],
            message_type=MessageType(data['message_type']),
            channel=data.get('channel'),
            timestamp=data.get('timestamp'),
            ttl=data.get('ttl', 7),
            encrypted=data.get('encrypted', False)
        )

@dataclass
class MeshtasticDeviceInfo:
    """Information about a detected Meshtastic device"""
    device_id: str
    name: str
    interface_type: str  # 'serial', 'tcp', 'ble'
    connection_string: str
    signal_strength: Optional[int] = None
    battery_level: Optional[int] = None
    available: bool = True
    
@dataclass
class FallbackRequest:
    """Request to send a message via Meshtastic fallback"""
    message: BitChatMessage
    priority: int = 1  # 1=normal, 2=high, 3=emergency
    retry_count: int = 0
    max_retries: int = 3

@dataclass
class FallbackResponse:
    """Response from Meshtastic fallback attempt"""
    success: bool
    message_id: str
    status: FallbackStatus
    error_message: Optional[str] = None
    meshtastic_node_id: Optional[str] = None
    hops_used: Optional[int] = None
    signal_quality: Optional[float] = None

class BitChatMeshtasticProtocol:
    """Protocol constants for BitChat-Meshtastic communication"""
    
    # Meshtastic app identifier for BitChat messages
    BITCHAT_APP_ID = "bitchat"
    
    # Port numbers for different message types
    BITCHAT_TEXT_PORT = 1001
    BITCHAT_PRIVATE_PORT = 1002
    BITCHAT_SYSTEM_PORT = 1003
    
    # Maximum message size for Meshtastic (accounting for overhead)
    MAX_MESSAGE_SIZE = 200
    
    # Message fragmentation marker
    FRAGMENT_MARKER = "BCFRAG"
    
    # Protocol version
    PROTOCOL_VERSION = "1.0"

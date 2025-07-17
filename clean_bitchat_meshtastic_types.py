"""
BitChat-Meshtastic Integration Type Definitions

Defines the data structures and constants used for communication between 
BitChat and Meshtastic mesh networks.
"""

from dataclasses import dataclass, asdict
from enum import Enum
from typing import Dict, Any, Optional, List
import json
import time


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
    """Status of the Meshtastic fallback system"""
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
    
    def __post_init__(self):
        if self.timestamp is None:
            self.timestamp = int(time.time())
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert message to dictionary for JSON serialization"""
        data = asdict(self)
        data['message_type'] = self.message_type.value
        return data
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'BitChatMessage':
        """Create message from dictionary"""
        if 'message_type' in data and isinstance(data['message_type'], int):
            data['message_type'] = MessageType(data['message_type'])
        return cls(**data)


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
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for storage"""
        return asdict(self)
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'MeshtasticDeviceInfo':
        """Create from dictionary"""
        return cls(**data)


@dataclass
class FallbackRequest:
    """Request to send a message via Meshtastic fallback"""
    message: BitChatMessage
    priority: int = 1  # 1=normal, 2=high, 3=emergency
    retry_count: int = 0
    max_retries: int = 3
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary"""
        return {
            'message': self.message.to_dict(),
            'priority': self.priority,
            'retry_count': self.retry_count,
            'max_retries': self.max_retries
        }


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
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary"""
        data = asdict(self)
        data['status'] = self.status.value
        return data


class BitChatMeshtasticProtocol:
    """Protocol constants for BitChat-Meshtastic communication"""
    
    # Application identifier
    BITCHAT_APP_ID = "bitchat"
    
    # Port numbers for different message types
    BITCHAT_TEXT_PORT = 1001
    BITCHAT_PRIVATE_PORT = 1002
    BITCHAT_SYSTEM_PORT = 1003
    
    # Message size constraints
    MAX_MESSAGE_SIZE = 200  # Meshtastic payload limit
    MAX_FRAGMENT_SIZE = 180  # Leave room for headers
    
    # Fragment handling
    FRAGMENT_MARKER = "BCFRAG"
    FRAGMENT_HEADER_SIZE = 20
    
    # Protocol versioning
    PROTOCOL_VERSION = "1.0"
    
    # Timing constants
    DEFAULT_TTL = 7  # Message time-to-live in hops
    FALLBACK_TIMEOUT = 30  # Seconds before triggering fallback
    CONNECTION_TIMEOUT = 10  # Device connection timeout
    RETRY_DELAY = 5  # Seconds between retry attempts
    
    @classmethod
    def get_port_for_message_type(cls, message_type: MessageType) -> int:
        """Get appropriate Meshtastic port for message type"""
        port_mapping = {
            MessageType.TEXT: cls.BITCHAT_TEXT_PORT,
            MessageType.PRIVATE_MESSAGE: cls.BITCHAT_PRIVATE_PORT,
            MessageType.CHANNEL_JOIN: cls.BITCHAT_SYSTEM_PORT,
            MessageType.CHANNEL_LEAVE: cls.BITCHAT_SYSTEM_PORT,
            MessageType.USER_INFO: cls.BITCHAT_SYSTEM_PORT,
            MessageType.SYSTEM: cls.BITCHAT_SYSTEM_PORT,
            MessageType.ENCRYPTED: cls.BITCHAT_PRIVATE_PORT,
        }
        return port_mapping.get(message_type, cls.BITCHAT_TEXT_PORT)


# Export commonly used types
__all__ = [
    'MessageType',
    'FallbackStatus', 
    'BitChatMessage',
    'MeshtasticDeviceInfo',
    'FallbackRequest',
    'FallbackResponse',
    'BitChatMeshtasticProtocol'
]
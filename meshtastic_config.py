"""
Meshtastic device configuration and discovery
Handles device detection, connection testing, and configuration management
"""

import os
import json
import time
from typing import List, Optional, Dict, Any
from dataclasses import asdict
from bitchat_meshtastic_types import MeshtasticDeviceInfo, FallbackStatus

class MeshtasticConfig:
    """Manages Meshtastic device configuration and preferences"""
    
    def __init__(self, config_path: str = "meshtastic_config.json"):
        self.config_path = config_path
        self.config = self._load_config()
    
    def _load_config(self) -> Dict[str, Any]:
        """Load configuration from file"""
        default_config = {
            "enabled": False,
            "auto_fallback": True,
            "preferred_device": None,
            "scan_timeout": 10,
            "connection_timeout": 5,
            "retry_attempts": 3,
            "user_consented": False,
            "last_scan": 0,
            "known_devices": [],
            "fallback_threshold": 30  # seconds without BLE before fallback
        }
        
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r') as f:
                    loaded = json.load(f)
                    default_config.update(loaded)
            except Exception as e:
                print(f"Error loading config: {e}")
        
        return default_config
    
    def save_config(self):
        """Save current configuration to file"""
        try:
            with open(self.config_path, 'w') as f:
                json.dump(self.config, f, indent=2)
        except Exception as e:
            print(f"Error saving config: {e}")
    
    def set_user_consent(self, consented: bool):
        """Set user consent for Meshtastic integration"""
        self.config["user_consented"] = consented
        self.config["enabled"] = consented
        self.save_config()
    
    def get_user_consent(self) -> bool:
        """Check if user has consented to Meshtastic integration"""
        return self.config.get("user_consented", False)
    
    def is_enabled(self) -> bool:
        """Check if Meshtastic integration is enabled"""
        return self.config.get("enabled", False) and self.get_user_consent()
    
    def should_auto_fallback(self) -> bool:
        """Check if auto-fallback is enabled"""
        return self.config.get("auto_fallback", True)
    
    def get_fallback_threshold(self) -> int:
        """Get time threshold for BLE fallback in seconds"""
        return self.config.get("fallback_threshold", 30)
    
    def add_known_device(self, device: MeshtasticDeviceInfo):
        """Add a device to known devices list"""
        device_dict = asdict(device)
        
        # Remove existing entry for same device
        self.config["known_devices"] = [
            d for d in self.config["known_devices"] 
            if d.get("device_id") != device.device_id
        ]
        
        # Add updated device info
        self.config["known_devices"].append(device_dict)
        self.save_config()
    
    def get_known_devices(self) -> List[MeshtasticDeviceInfo]:
        """Get list of known Meshtastic devices"""
        devices = []
        for device_dict in self.config.get("known_devices", []):
            try:
                devices.append(MeshtasticDeviceInfo(**device_dict))
            except Exception as e:
                print(f"Error parsing known device: {e}")
        return devices
    
    def set_preferred_device(self, device_id: str):
        """Set preferred Meshtastic device"""
        self.config["preferred_device"] = device_id
        self.save_config()
    
    def get_preferred_device(self) -> Optional[str]:
        """Get preferred device ID"""
        return self.config.get("preferred_device")
    
    def update_scan_timestamp(self):
        """Update last scan timestamp"""
        self.config["last_scan"] = time.time()
        self.save_config()
    
    def should_rescan(self, max_age: int = 300) -> bool:
        """Check if devices should be rescanned (default 5 minutes)"""
        last_scan = self.config.get("last_scan", 0)
        return (time.time() - last_scan) > max_age
    
    def get_scan_timeout(self) -> int:
        """Get device scan timeout in seconds"""
        return self.config.get("scan_timeout", 10)
    
    def get_connection_timeout(self) -> int:
        """Get connection timeout in seconds"""
        return self.config.get("connection_timeout", 5)
    
    def get_retry_attempts(self) -> int:
        """Get number of retry attempts for failed connections"""
        return self.config.get("retry_attempts", 3)
    
    def export_settings(self) -> Dict[str, Any]:
        """Export settings for sharing with Swift app"""
        return {
            "enabled": self.is_enabled(),
            "auto_fallback": self.should_auto_fallback(),
            "fallback_threshold": self.get_fallback_threshold(),
            "user_consented": self.get_user_consent(),
            "preferred_device": self.get_preferred_device(),
            "known_devices_count": len(self.get_known_devices()),
            "last_scan": self.config.get("last_scan", 0)
        }
    
    def update_settings(self, settings: Dict[str, Any]):
        """Update settings from Swift app"""
        allowed_keys = [
            "enabled", "auto_fallback", "fallback_threshold", 
            "preferred_device", "scan_timeout", "connection_timeout"
        ]
        
        for key, value in settings.items():
            if key in allowed_keys:
                self.config[key] = value
        
        self.save_config()

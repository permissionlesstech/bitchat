//! Bluetooth LE Mesh Networking Module
//! 
//! Implements decentralized mesh networking over Bluetooth LE,
//! following the AI Guidance Protocol for ethical development.

pub mod mesh_service;
pub mod peer_manager;
pub mod protocol;

pub use mesh_service::BluetoothMeshService;
pub use peer_manager::PeerManager;
pub use protocol::BitchatProtocol;
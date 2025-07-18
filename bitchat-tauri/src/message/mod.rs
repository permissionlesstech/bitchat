//! Message Handling Module
//! 
//! Manages message routing, storage, and processing for the BitChat mesh network.
//! Follows AI Guidance Protocol for ethical message handling.

pub mod message_types;
pub mod router;
pub mod storage;

pub use message_types::BitchatMessage;
pub use router::MessageRouter;
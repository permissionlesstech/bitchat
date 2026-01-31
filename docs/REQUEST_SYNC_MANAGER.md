# Request Sync Manager & V2 Packet Updates

This document details the implementation of the Request Sync Manager and updates to the V2 packet structure to improve synchronization security and attribution on iOS, mirroring the Android implementation.

## Overview

The goal of these changes is to make the request sync functionality "less blind". Previously, sync requests were broadcast, and responses were accepted without strict attribution or timestamp validation (to allow syncing old messages). This opened up potential spoofing vectors and prevented us from enforcing timestamp checks on normal traffic.

The new implementation introduces a **RequestSyncManager** to track outgoing sync requests and attributes incoming responses (RSR - Request-Sync Response) to specific peers. This allows us to:
1.  **Enforce Timestamp Validation**: Normal packets now require timestamps to be within 2 minutes of the local clock.
2.  **Exempt Solicited Sync Responses**: Packets marked as RSR are exempt from timestamp validation *only if* they correspond to a valid, pending sync request sent to that specific peer.
3.  **Prevent Unsolicited Sync Floods**: Unsolicited RSR packets are rejected.

## Protocol Changes

### Binary Protocol Updates
*   **New Flag**: `IS_RSR` (0x10) added to the packet header flags.
*   **BitchatPacket**: Updated to include `isRSR: Bool` field.
*   **Encoding/Decoding**: Updated `BinaryProtocol` to handle the new flag.

### Request Sync Payload
The `REQUEST_SYNC` packet payload (TLV encoded) has been updated to include:
*   **Future Filters**:
    *   `sinceTimestamp` (Type 0x05): To request packets since a certain time (UInt64 big-endian).
    *   `fragmentIdFilter` (Type 0x06): To request specific fragments (UTF-8 string).

## Architecture

### RequestSyncManager
A new component (`Sync/RequestSyncManager.swift`) responsible for:
*   **Tracking**: Stores `peerID -> timestamp` mappings for pending sync requests.
*   **Validation**: `isValidResponse(from: PeerID, isRSR: Bool)` checks if an incoming RSR packet matches a pending request within the 30-second window.
*   **Cleanup**: Periodically removes expired requests.

### GossipSyncManager Updates
*   **Unicast Sync**: Instead of blind broadcasting, the periodic sync task now iterates over connected peers and sends unicast `REQUEST_SYNC` packets.
*   **Registration**: Before sending, requests are registered with `RequestSyncManager`.
*   **Response Marking**: When responding to a `REQUEST_SYNC`, generated packets (Announce/Message) are explicitly marked with `isRSR = true` (and `ttl = 0`).

### BLEService (Security Manager) Updates
*   **Timestamp Enforcement**: Checks `abs(now - packetTimestamp) < 2 minutes` for standard packets.
*   **Conditional Exemption**: If `packet.isRSR` is true (or packet is a legacy TTL=0 response), it queries `RequestSyncManager`.
    *   **Valid**: If solicited, timestamp check is skipped (allowing historical data sync).
    *   **Invalid**: If unsolicited or timed out, the packet is rejected.

## Usage

These changes are integrated into `BLEService` and `GossipSyncManager`. No external API changes are required for clients, but all peers must be updated to support the new `IS_RSR` flag and protocol logic to participate in the secure sync process.

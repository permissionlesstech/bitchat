# Connection Stability Fixes for BluetoothMeshService

## Issues Causing Disconnect/Reconnect

1. **Simultaneous Connection Attempts**: Both devices acting as central and peripheral can create duplicate connections
2. **Temporary ID Management**: Using peripheral UUIDs as temporary IDs causes confusion
3. **Premature State Updates**: Peer list updates happen before connections are fully established
4. **Aggressive Disconnect Handling**: Peers are removed immediately on disconnect without grace period

## Recommended Fixes

### 1. Implement Connection Deduplication
- Track ongoing connection attempts by peer ID
- Reject duplicate connections from same peer
- Use deterministic logic to decide which side maintains connection (e.g., compare peer IDs)

### 2. Improve Peer State Management
- Add connection states: CONNECTING, CONNECTED, DISCONNECTING
- Only show "joined" after key exchange AND announce received
- Add grace period before showing "left" messages (e.g., 5 seconds)

### 3. Fix Temporary ID Handling
- Don't add temp IDs to activePeers
- Only update peer lists after receiving real peer ID
- Use a separate pendingPeripherals dictionary

### 4. Consolidate Key Exchange and Announce
- Send key exchange and announce as atomic operation
- Wait for both before considering peer "connected"
- Add sequence numbers to prevent duplicate processing

### 5. Add Connection Stability Timer
- Don't show "joined" until connection stable for 1 second
- Buffer rapid connect/disconnect cycles
- Implement exponential backoff for reconnection attempts

## Implementation Priority
1. Fix duplicate connection handling (highest impact)
2. Add connection grace period
3. Improve state management
4. Consolidate initialization messages
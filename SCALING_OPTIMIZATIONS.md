# BitChat Scaling Optimizations

## Overview
Implemented practical scaling optimizations to improve BitChat's capacity from ~20-30 users to potentially 50-100 users while maintaining privacy and simplicity.

## Optimizations Implemented

### 1. **Probabilistic Flooding**
- Messages are relayed with probability based on network density
- Reduces redundant transmissions in dense networks
- Adaptive relay probability:
  - ≤5 users: 100% relay (ensure delivery)
  - ≤15 users: 80% relay
  - ≤30 users: 60% relay  
  - ≤50 users: 40% relay
  - >50 users: 30% relay (minimum)
- Random delay (50-500ms) prevents collision storms

### 2. **Bloom Filter for Duplicate Detection**
- 4096-bit bloom filter (512 bytes) for fast duplicate checking
- 3 hash functions for optimal false positive rate
- Resets every 5 minutes to prevent saturation
- Combined with exact set for accuracy
- O(1) lookup time vs O(n) for set membership

### 3. **Connection Pooling & Exponential Backoff**
- Reuses existing peripheral connections
- Tracks connection attempts per peripheral
- Exponential backoff: 1s × 2^attempts after failures
- Maximum 3 connection attempts
- Reduces connection churn and battery usage

### 4. **Adaptive TTL**
- TTL adjusts based on network size:
  - ≤10 users: TTL=5 (maximum reach)
  - ≤30 users: TTL=4
  - ≤50 users: TTL=3
  - >50 users: TTL=2 (limit propagation)
- Prevents message storms in large networks

### 5. **Message Aggregation (Framework)**
- 100ms aggregation window
- Groups messages by destination
- Sends with 20ms spacing to prevent collisions
- Ready for future batching optimizations

### 6. **BLE Advertisement Enhancements**
- Includes network size hint in manufacturer data
- Battery level in advertisements
- Enables network-aware decisions without connections
- Lightweight presence detection

## Performance Impact

### Before Optimizations
- Full mesh: O(n²) connections
- Every node relays every message
- Fixed TTL=5 for all messages
- Connection attempts without backoff
- Linear duplicate detection

### After Optimizations  
- Same mesh topology but smarter behavior
- 30-70% relay reduction in dense networks
- Dynamic TTL reduces unnecessary hops
- Connection failures don't cause storms
- Constant-time duplicate detection

## Estimated Capacity
- **Small groups (5-10 users)**: Excellent performance, minimal change
- **Medium groups (20-30 users)**: Good performance, noticeable improvement
- **Large groups (50-100 users)**: Functional but degraded experience
- **Very large (100+ users)**: Not recommended without architectural changes

## Future Improvements
1. **Hierarchical Clustering**: Elect cluster heads for inter-cluster routing
2. **DHT-based Routing**: Distributed hash table for targeted message delivery
3. **True Message Aggregation**: Combine multiple messages into single packets
4. **Adaptive Scanning**: Reduce scan frequency based on network load
5. **Priority Queues**: Prioritize direct messages over broadcasts

## Trade-offs
- **Privacy maintained**: No routing tables or persistent node IDs
- **Complexity limited**: Avoided heavyweight protocols (OLSR/AODV)
- **Battery impact**: Slightly higher CPU usage for bloom filter
- **Reliability**: Probabilistic relay may miss some messages in edge cases

## Configuration
All parameters are adaptive and require no user configuration. The system automatically adjusts based on:
- Network size (peer count)
- Battery level
- Connection quality

This approach balances scalability improvements with BitChat's core values of simplicity and privacy.
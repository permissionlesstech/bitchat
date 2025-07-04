# Bitchat Technical Debt Remediation Plan

## Overview
This document outlines the technical debt in the bitchat project and provides a prioritized plan for addressing it.

## Priority 1: Critical Security & Stability (1-2 weeks)

### 1.1 Thread Safety Issues
**Problem**: Potential race conditions in message processing and peer management
**Solution**:
- Audit all concurrent access to shared state
- Add proper synchronization to message queues
- Use actor pattern for BluetoothMeshService
- Add thread sanitizer to debug builds

### 1.2 Error Handling
**Problem**: Many errors are silently logged without proper recovery
**Solution**:
- Implement proper error propagation
- Add user-visible error states
- Create recovery mechanisms for common failures
- Add crash reporting for TestFlight

### 1.3 Memory Management
**Problem**: Fragment cleanup could leak memory, no proper cleanup on errors
**Solution**:
- Add fragment timeout cleanup
- Implement proper weak references in closures
- Add memory pressure handling
- Profile with Instruments

## Priority 2: Code Quality & Maintainability (2-3 weeks)

### 2.1 Service Refactoring
**Problem**: BluetoothMeshService is 1600+ lines, doing too much
**Solution**:
- Extract message handling into MessageProcessor
- Extract peer management into PeerManager
- Extract fragment handling into FragmentManager
- Create proper dependency injection

### 2.2 Testing Infrastructure
**Problem**: No unit tests, making refactoring risky
**Solution**:
- Add XCTest target
- Create mock implementations for Bluetooth
- Test encryption service thoroughly
- Add integration tests for message flow
- Aim for 70% code coverage

### 2.3 Documentation
**Problem**: Limited code comments, no architecture docs
**Solution**:
- Add comprehensive header comments
- Document protocol specifications
- Create architecture diagrams
- Add inline documentation for complex logic

## Priority 3: Performance & UX (3-4 weeks)

### 3.1 Message Deduplication
**Problem**: Simple Set-based deduplication can grow unbounded
**Solution**:
- Implement LRU cache for message IDs
- Add time-based expiration
- Consider bloom filters for efficiency

### 3.2 Connection Management
**Problem**: No connection pooling or retry logic
**Solution**:
- Implement connection state machine
- Add exponential backoff for retries
- Pool peripheral connections
- Add connection quality metrics

### 3.3 UI Responsiveness
**Problem**: Heavy operations on main thread
**Solution**:
- Move encryption to background queues
- Add loading states for operations
- Implement message pagination
- Add pull-to-refresh

## Priority 4: Feature Enhancements (4-6 weeks)

### 4.1 Message Persistence (Optional)
**Problem**: All messages ephemeral, no history
**Solution**:
- Add encrypted SQLite storage
- Implement configurable retention
- Add search functionality
- Maintain privacy-first approach

### 4.2 Protocol Improvements
**Problem**: No versioning, hard to upgrade
**Solution**:
- Add protocol version negotiation
- Implement capability discovery
- Plan migration strategy
- Add feature flags

### 4.3 Network Visualization
**Problem**: Users don't understand mesh topology
**Solution**:
- Add network graph view
- Show message routing paths
- Display peer connection quality
- Add statistics dashboard

## Implementation Strategy

### Phase 1: Foundation (Weeks 1-2)
1. Set up testing infrastructure
2. Add thread sanitizer and memory profiler
3. Begin service refactoring
4. Fix critical thread safety issues

### Phase 2: Stability (Weeks 3-4)
1. Complete service refactoring
2. Add comprehensive error handling
3. Implement proper memory management
4. Add initial test coverage

### Phase 3: Quality (Weeks 5-6)
1. Add documentation
2. Improve connection management
3. Optimize performance bottlenecks
4. Enhance UI responsiveness

### Phase 4: Enhancement (Weeks 7-10)
1. Add optional persistence
2. Implement protocol versioning
3. Build network visualization
4. Polish for production

## Success Metrics
- Zero crashes in TestFlight
- 70% test coverage
- Sub-100ms message processing
- < 5% battery drain per hour
- Clean architecture with < 300 lines per class

## Risk Mitigation
- Keep all changes backwards compatible initially
- Add feature flags for risky changes
- Extensive TestFlight testing between phases
- Maintain current security properties
- Regular security audits of changes
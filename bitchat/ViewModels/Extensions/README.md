# ChatViewModel Extensions

This directory contains extensions to `ChatViewModel` to modularize its functionality.

- `ChatViewModel+Tor.swift`: Handles Tor lifecycle events and notifications.
- `ChatViewModel+PrivateChat.swift`: Manages private chat logic, media transfers (images, voice notes), and file handling.
- `ChatViewModel+Nostr.swift`: Contains all logic related to Nostr integration, Geohash channels, and Nostr identity management.

The main `ChatViewModel.swift` retains core state, initialization, and coordination logic.
